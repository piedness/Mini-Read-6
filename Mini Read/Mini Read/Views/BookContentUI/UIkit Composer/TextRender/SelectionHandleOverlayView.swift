//
//  SelectionHandleOverlayView.swift
//  TheNewVellium
//
//  选中文本两端的可拖拽手柄。
//
//  为什么不画在 TextRenderView 里：正文视图被约束在版心内（见 TextVC 的四边约束），
//  手柄要落在行首/行尾外侧、甚至压到页边距里，画出去会被裁掉。这里用一层铺满
//  整页的兄弟视图，只在自己的"手柄命中区"接收触摸，其余位置 `point(inside:)`
//  返回 false，触摸照常穿透给正文。
//
//  手柄的几何来自 `ChapterLayout.lineRects`——与选中高亮、标注绘制共用同一份
//  排版结果，不存在"另算一遍坐标"的可能。iPad 双页下，起点手柄与终点手柄
//  可能分别落在左右两页，各自画自己那一端。
//

import UIKit

// MARK: - 端点

enum SelectionHandle {
    case start
    case end
}

// MARK: - 手柄层

final class SelectionHandleOverlayView: UIView, SelectionStateObserver {

    // MARK: 依赖

    private let chapterLayout: ChapterLayout
    private let pageIndex: Int
    private let margins: ReaderMargins
    private let selectionState: SelectionState

    // MARK: 回调

    /// 手指按下手柄（菜单需要先收起来，但不能清掉选区）。
    /// 第二个参数是按下瞬间的选区，供上层在菜单退场清空选区时恢复。
    var onHandleTouchDown: ((SelectionHandle, NSRange) -> Void)?
    /// 手柄拖动到某个点（本视图坐标系）。
    var onHandleMoved: ((SelectionHandle, CGPoint) -> Void)?
    /// 手柄抬起 / 取消。
    var onHandleDragEnded: (() -> Void)?

    // MARK: 几何

    private var startHandleRect: CGRect = .zero
    private var endHandleRect: CGRect = .zero
    private var startHitRect: CGRect = .zero
    private var endHitRect: CGRect = .zero

    private var activeHandle: SelectionHandle?

    // MARK: 外观

    private let stemLength: CGFloat = 6
    private let circleRadius: CGFloat = 7.5
    private let handleColor = UIColor.systemBlue
    /// 手柄可见部分很小，命中区要按 HIG 放大到 44pt。
    private let hitSize: CGFloat = 44

    // MARK: Init

    init(
        chapterLayout: ChapterLayout,
        pageIndex: Int,
        margins: ReaderMargins,
        selectionState: SelectionState
    ) {
        self.chapterLayout = chapterLayout
        self.pageIndex = pageIndex
        self.margins = margins
        self.selectionState = selectionState
        super.init(frame: .zero)
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw
        isMultipleTouchEnabled = false
        isAccessibilityElement = false
        accessibilityElementsHidden = true

        selectionState.addObserver(self)

        // 0 秒长按 = 按下即开始拖动。比 pan 更适合手柄：
        // - 按下就能通知上层收起菜单（不需要等手指移动几 pt 才识别）；
        // - 抬手一定会有 ended/cancelled，不会留下"调整中"的悬挂状态。
        let drag = UILongPressGestureRecognizer(target: self, action: #selector(handleDrag(_:)))
        drag.minimumPressDuration = 0
        drag.allowableMovement = .greatestFiniteMagnitude
        drag.cancelsTouchesInView = true
        addGestureRecognizer(drag)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - 命中

    /// 只有手柄附近才接收触摸，其余位置让给正文/翻页手势。
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard selectionState.range != nil else { return false }
        return startHitRect.contains(point) || endHitRect.contains(point)
    }

    /// 某个点是否落在手柄命中区（供容器的长按手势判断要不要让路）。
    func containsHandle(at point: CGPoint) -> Bool {
        guard selectionState.range != nil else { return false }
        return startHitRect.contains(point) || endHitRect.contains(point)
    }

    private func handle(at point: CGPoint) -> SelectionHandle? {
        let hitsStart = startHitRect.contains(point)
        let hitsEnd = endHitRect.contains(point)

        switch (hitsStart, hitsEnd) {
        case (true, true):
            // 单行选区两端很近：取离手指更近的那一个。
            let ds = abs(point.x - startHandleRect.midX)
            let de = abs(point.x - endHandleRect.midX)
            return ds <= de ? .start : .end
        case (true, false):
            return .start
        case (false, true):
            return .end
        default:
            return nil
        }
    }

    // MARK: - 拖动

    @objc private func handleDrag(_ gesture: UILongPressGestureRecognizer) {
        let point = gesture.location(in: self)

        switch gesture.state {
        case .began:
            guard let handle = handle(at: point),
                  let range = selectionState.range
            else { return }

            activeHandle = handle
            onHandleTouchDown?(handle, range)

        case .changed:
            guard let handle = activeHandle else { return }
            onHandleMoved?(handle, point)

        case .ended, .cancelled, .failed:
            guard activeHandle != nil else { return }
            activeHandle = nil
            onHandleDragEnded?()

        default:
            break
        }
    }

    // MARK: - SelectionStateObserver

    func selectionStateDidChange() {
        updateHandleGeometry()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateHandleGeometry()
    }

    // MARK: - 几何

    private func updateHandleGeometry() {
        guard let range = selectionState.range,
              let pageRange = chapterLayout.characterRange(forPage: pageIndex)
        else {
            resetGeometry()
            return
        }

        let rects = chapterLayout.lineRects(
            forCharacterRange: range,
            pageIndex: pageIndex
        )
        guard !rects.isEmpty else {
            resetGeometry()
            return
        }

        // 起点/终点是否真的落在本页：跨页选区在中间页上只画延续的高亮，
        // 不能凭空多出一对手柄。
        let startsHere = NSLocationInRange(range.location, pageRange)
        let lastCharacter = NSMaxRange(range) - 1
        let endsHere = lastCharacter >= 0 && NSLocationInRange(lastCharacter, pageRange)

        let newStart = startsHere ? handleRect(for: rects[0], atStart: true) : .zero
        let newEnd = endsHere ? handleRect(for: rects[rects.count - 1], atStart: false) : .zero

        guard newStart != startHandleRect || newEnd != endHandleRect else { return }

        startHandleRect = newStart
        endHandleRect = newEnd
        startHitRect = newStart == .zero ? .zero : hitRect(for: newStart, circleOnTop: true)
        endHitRect = newEnd == .zero ? .zero : hitRect(for: newEnd, circleOnTop: false)
        setNeedsDisplay()
    }

    private func resetGeometry() {
        guard startHandleRect != .zero || endHandleRect != .zero else { return }
        startHandleRect = .zero
        endHandleRect = .zero
        startHitRect = .zero
        endHitRect = .zero
        setNeedsDisplay()
    }

    /// 手柄的外接矩形：圆点 + 一小段柄。坐标已加上版心偏移。
    ///
    /// 参考 Apple Books：起点手柄在首行**上方**（柄向下接行顶），
    /// 终点手柄在末行**下方**（柄向上接行底）。两手柄都落在选区外侧，
    /// 不会盖住选中的文字。
    private func handleRect(for lineRect: CGRect, atStart: Bool) -> CGRect {
        let centerX = (atStart ? lineRect.minX + 1 : lineRect.maxX - 1) + margins.left
        let lineTop = lineRect.minY + margins.top
        let lineBottom = lineRect.maxY + margins.top
        let diameter = circleRadius * 2

        if atStart {
            let centerY = max(circleRadius + 1, lineTop - stemLength - circleRadius)
            let circleRect = CGRect(
                x: centerX - circleRadius,
                y: centerY - circleRadius,
                width: diameter,
                height: diameter
            )
            let stemRect = CGRect(
                x: centerX - 0.75,
                y: circleRect.maxY,
                width: 1.5,
                height: max(0, lineTop - circleRect.maxY)
            )
            return circleRect.union(stemRect)
        } else {
            let centerY = lineBottom + stemLength + circleRadius
            let circleRect = CGRect(
                x: centerX - circleRadius,
                y: centerY - circleRadius,
                width: diameter,
                height: diameter
            )
            let stemRect = CGRect(
                x: centerX - 0.75,
                y: lineBottom,
                width: 1.5,
                height: max(0, circleRect.minY - lineBottom)
            )
            return circleRect.union(stemRect)
        }
    }

    private func hitRect(for handleRect: CGRect, circleOnTop: Bool) -> CGRect {
        // 命中区以圆点为中心放大到 44pt；柄本身也落在这个方形附近。
        let centerY = circleOnTop
            ? handleRect.minY + circleRadius
            : handleRect.maxY - circleRadius
        return CGRect(
            x: handleRect.midX - hitSize / 2,
            y: centerY - hitSize / 2,
            width: hitSize,
            height: hitSize
        )
    }

    // MARK: - 绘制

    override func draw(_ rect: CGRect) {
        drawHandle(startHandleRect, circleOnTop: true)
        drawHandle(endHandleRect, circleOnTop: false)
    }

    private func drawHandle(_ box: CGRect, circleOnTop: Bool) {
        guard box != .zero else { return }

        let diameter = circleRadius * 2
        let circleRect = circleOnTop
            ? CGRect(x: box.minX, y: box.minY, width: diameter, height: diameter)
            : CGRect(x: box.minX, y: box.maxY - diameter, width: diameter, height: diameter)
        let centerX = box.midX

        // 柄：从圆点边缘接到行边缘，圆点盖住末端。
        let stem = UIBezierPath()
        if circleOnTop {
            stem.move(to: CGPoint(x: centerX, y: circleRect.maxY))
            stem.addLine(to: CGPoint(x: centerX, y: box.maxY))
        } else {
            stem.move(to: CGPoint(x: centerX, y: box.minY))
            stem.addLine(to: CGPoint(x: centerX, y: circleRect.minY))
        }
        stem.lineWidth = 1.5
        stem.lineCapStyle = .round
        handleColor.setStroke()
        stem.stroke()

        // 圆点：填充 + 一圈白描边，深浅纸面上都能看清。
        let circle = UIBezierPath(ovalIn: circleRect)
        handleColor.setFill()
        circle.fill()

        UIColor.white.withAlphaComponent(0.92).setStroke()
        circle.lineWidth = 1.5
        circle.stroke()
    }
}
