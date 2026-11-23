//
//  AnnotationDrawing.swift
//  TheNewVellium
//
//  标注的绘制与边注指示器。
//
//  绘制发生在 `TextRenderView.draw` 里、字形之前：底色压在字下，
//  下划线/波浪线/删除线压在字后。所有矩形都来自 `NSLayoutManager`
//  的行片段/字形几何，与正文共享同一套排版结果，
//  不存在"另算一遍坐标"的可能。
//

import UIKit

// MARK: - 绘制参数
//
// 所有标注的视觉参数集中在这里：下划线的位置/粗细、高亮的内缩、
// 波浪线的振幅、聚焦圈的描边、边注条的尺寸……调样式只改这一处。
private enum AnnotationMetrics {

    // 通用
    static let minOpacity: CGFloat = 0.05
    static let maxOpacity: CGFloat = 0.9
    static let minimumDrawableSide: CGFloat = 0.5
    /// 线条类标注的不透明度。
    ///
    /// 与「底色透明度」分开：线条是描边不是色块，让它跟着底色一起变淡
    /// 只会把下划线调成一根灰线。粗细由 `AnnotationLineWeight` 单独控制。
    static let lineAlpha: CGFloat = 0.85

    // 高亮底色
    static let highlightHorizontalExpansion: CGFloat = 2
    static let highlightVerticalInset: CGFloat = 0.5
    static let highlightCornerRadius: CGFloat = 3

    // 下划线
    /// 基线往下偏移多少（pt）。想更贴字就调小，想更往下就调大。
    static let underlineOffset: CGFloat = 10
    /// 线宽（pt）。实际绘制时乘 `AnnotationLineWeight.scale`。
    static let underlineWidth: CGFloat = 3
    /// 没有基线几何时的兜底：从行框底部往上收多少。
    static let fallbackBaselineInset: CGFloat = 2

    // 波浪线
    static let wavyOffset: CGFloat = 10
    static let wavyAmplitude: CGFloat = 2.5
    static let wavyHalfWave: CGFloat = 8
    static let wavyControlFactor: CGFloat = 1.6
    static let wavyWidth: CGFloat = 3

    // 删除线
    static let strikethroughWidth: CGFloat = 1.3
    /// 删除线位于基线上方 `xHeight × factor` 处。
    static let strikethroughOffsetFactor: CGFloat = 0.5

    // 聚焦圈
    static let focusMaxAlpha: CGFloat = 0.9
    static let focusMinAlpha: CGFloat = 0.02
    static let focusHorizontalInset: CGFloat = 3.5
    static let focusVerticalInset: CGFloat = 2.5
    static let focusCornerRadius: CGFloat = 4
    static let focusLineWidth: CGFloat = 2

    // 边注指示条
    static let marginBarWidth: CGFloat = 3
    static let marginBarHeight: CGFloat = 11
    /// 圆点样式的直径。比竖条宽一点才不至于看起来是个脏点。
    static let marginDotDiameter: CGFloat = 6
    static let marginMinimumInset: CGFloat = 7
    static let marginInsetFactor: CGFloat = 0.55
    static let marginBarAlpha: CGFloat = 0.8
    /// 指示器的触控高度（HIG 最小 44pt）。横向只铺满留白，见 `AnnotationMarginView.hitBox`。
    static let marginHitHeight: CGFloat = 44
}

// MARK: - 绘制

enum AnnotationDrawing {

    /// 画一处标注的所有行。
    ///
    /// - Parameters:
    ///   - rects: 该标注在当前页上的行矩形（`TextRenderView` 坐标系）。
    ///   - lineGeometries: 逐行基线几何。下划线/波浪线/删除线必须按基线画，
    ///     不能用行矩形底部——那是行框底部，含行距与 descender，会沉下去。
    ///   - fillOpacity: 底色高亮的透明度（设置项）。只作用于 `.highlight`，
    ///     线条类标注用固定的 `AnnotationMetrics.lineAlpha`，不随它变淡。
    ///   - lineWeight: 线条粗细档位（设置项）。只对下划线 / 波浪线 / 删除线生效。
    static func draw(
        _ item: AnnotationItem,
        rects: [CGRect],
        lineGeometries: [ChapterLayout.LineFragmentGeometry] = [],
        fillOpacity: CGFloat,
        lineWeight: AnnotationLineWeight = .standard,
        in context: CGContext
    ) {
        guard !rects.isEmpty else { return }
        let clampedOpacity = max(AnnotationMetrics.minOpacity, min(AnnotationMetrics.maxOpacity, fillOpacity))
        let lineScale = lineWeight.scale
        let color = item.color.uiColor

        switch item.style {
        case .highlight:
            // 每一行单独一块底色。高度必须用 `textRect`（font.lineHeight），
            // 不能用 `rect`：行距较大时 `rect` 会把行距一起包进去，
            // 色块向下填满行距，两行看起来就粘在一起。
            // 行间空白由行距自然提供；这里只再做一次很小的纵向内缩，
            // 保证行距为 0 时也有一条缝。
            context.setFillColor(color.withAlphaComponent(clampedOpacity).cgColor)
            let boxes = lineGeometries.isEmpty ? rects : lineGeometries.map(\.textRect)

            for rect in boxes {
                let box = rect.insetBy(
                    dx: -AnnotationMetrics.highlightHorizontalExpansion,
                    dy: AnnotationMetrics.highlightVerticalInset
                )
                guard box.width > AnnotationMetrics.minimumDrawableSide,
                      box.height > AnnotationMetrics.minimumDrawableSide
                else { continue }
                context.addPath(
                    UIBezierPath(
                        roundedRect: box,
                        cornerRadius: AnnotationMetrics.highlightCornerRadius
                    ).cgPath
                )
                context.fillPath()
            }

        case .underline:
            let stroke = color.withAlphaComponent(AnnotationMetrics.lineAlpha)
            context.setStrokeColor(stroke.cgColor)
            context.setLineWidth(AnnotationMetrics.underlineWidth * lineScale)

            if lineGeometries.isEmpty {
                // 兜底：没有拿到字体基线时贴着行框底部画，至少不会消失。
                for rect in rects {
                    let y = rect.maxY - AnnotationMetrics.fallbackBaselineInset
                    context.move(to: CGPoint(x: rect.minX, y: y))
                    context.addLine(to: CGPoint(x: rect.maxX, y: y))
                }
            } else {
                for line in lineGeometries {
                    let y = line.baselineY + AnnotationMetrics.underlineOffset
                    context.move(to: CGPoint(x: line.rect.minX, y: y))
                    context.addLine(to: CGPoint(x: line.rect.maxX, y: y))
                }
            }
            context.strokePath()

        case .wavy:
            let stroke = color.withAlphaComponent(AnnotationMetrics.lineAlpha)
            stroke.setStroke()

            if lineGeometries.isEmpty {
                for rect in rects {
                    wavyPath(
                        from: rect.minX,
                        to: rect.maxX,
                        baselineY: rect.maxY - AnnotationMetrics.fallbackBaselineInset,
                        scale: lineScale
                    ).stroke()
                }
            } else {
                for line in lineGeometries {
                    wavyPath(
                        from: line.rect.minX,
                        to: line.rect.maxX,
                        baselineY: line.baselineY + AnnotationMetrics.wavyOffset,
                        scale: lineScale
                    ).stroke()
                }
            }

        case .strikethrough:
            context.setStrokeColor(color.withAlphaComponent(AnnotationMetrics.lineAlpha).cgColor)
            context.setLineWidth(AnnotationMetrics.strikethroughWidth * lineScale)

            if lineGeometries.isEmpty {
                for rect in rects {
                    let y = rect.midY
                    context.move(to: CGPoint(x: rect.minX, y: y))
                    context.addLine(to: CGPoint(x: rect.maxX, y: y))
                }
            } else {
                for line in lineGeometries {
                    let y = line.baselineY
                        - line.xHeight * AnnotationMetrics.strikethroughOffsetFactor
                    context.move(to: CGPoint(x: line.rect.minX, y: y))
                    context.addLine(to: CGPoint(x: line.rect.maxX, y: y))
                }
            }
            context.strokePath()
        }
    }

    /// 跳转落点后的聚焦提示：在标注外圈描一道逐渐消失的线。
    ///
    /// 只做透明度淡出，不做缩放/位移——`reduceMotion` 下它也仍然成立，
    /// 不需要额外分支。
    static func drawFocus(
        _ item: AnnotationItem,
        rects: [CGRect],
        progress: CGFloat,
        in context: CGContext
    ) {
        let alpha = max(0, 1 - progress) * AnnotationMetrics.focusMaxAlpha
        guard alpha > AnnotationMetrics.focusMinAlpha else { return }

        let color = item.color.uiColor.withAlphaComponent(alpha)
        color.setStroke()

        for rect in rects {
            let path = UIBezierPath(
                roundedRect: rect.insetBy(
                    dx: -AnnotationMetrics.focusHorizontalInset,
                    dy: -AnnotationMetrics.focusVerticalInset
                ),
                cornerRadius: AnnotationMetrics.focusCornerRadius
            )
            path.lineWidth = AnnotationMetrics.focusLineWidth
            path.stroke()
        }
    }

    private static func wavyPath(
        from startX: CGFloat,
        to endX: CGFloat,
        baselineY: CGFloat,
        scale: CGFloat
    ) -> UIBezierPath {
        let path = UIBezierPath()
        // 振幅跟着线宽一起放大：只加粗不抬高，波形会挤成一条毛边。
        let amplitude = AnnotationMetrics.wavyAmplitude * scale
        let halfWave = AnnotationMetrics.wavyHalfWave

        var x = startX
        var up = true
        path.move(to: CGPoint(x: x, y: baselineY))

        while x < endX {
            let nextX = min(x + halfWave, endX)
            let controlY = baselineY
                + (up ? -amplitude : amplitude) * AnnotationMetrics.wavyControlFactor
            path.addQuadCurve(
                to: CGPoint(x: nextX, y: baselineY),
                controlPoint: CGPoint(x: (x + nextX) / 2, y: controlY)
            )
            x = nextX
            up.toggle()
        }

        path.lineWidth = AnnotationMetrics.wavyWidth * scale
        return path
    }
}

// MARK: - 边注指示器

/// 页面右侧留白里的「这条标注有笔记」指示条。
///
/// 为什么不画在 `TextRenderView` 里：它的 frame 被约束在版心内（见 `TextVC`
/// 的四边约束），右边距在视图之外，画出去会被裁掉。这里用一层铺满整页的
/// 兄弟视图，只负责在留白里画几根短线。
///
/// 它同时是「打开编辑页」的入口：命中区只覆盖右侧留白（不越进版心），
/// 其余位置 `point(inside:)` 一律返回 false，触摸照常落到正文与翻页手势上。
final class AnnotationMarginView: UIView, AnnotationStateObserver, UIGestureRecognizerDelegate {

    /// 点中某条指示器：打开这处标注的编辑页。
    var onIndicatorTap: ((UUID) -> Void)?

    private let chapterLayout: ChapterLayout
    private let pageIndex: Int
    private let margins: ReaderMargins
    private let annotationState: ChapterAnnotationState
    private let showsIndicators: Bool
    private let indicatorStyle: NoteIndicatorStyle

    /// 一条指示器的图形与所属标注。`draw` 与点按共用同一份几何，
    /// 避免"看得到却点不中"。
    private struct Indicator {
        let item: AnnotationItem
        let box: CGRect
    }

    private var cachedIndicators: [Indicator]?
    private var tapRecognizer: UITapGestureRecognizer?

    init(
        chapterLayout: ChapterLayout,
        pageIndex: Int,
        margins: ReaderMargins,
        annotationState: ChapterAnnotationState,
        showsIndicators: Bool,
        indicatorStyle: NoteIndicatorStyle = .bar
    ) {
        self.chapterLayout = chapterLayout
        self.pageIndex = pageIndex
        self.margins = margins
        self.annotationState = annotationState
        self.showsIndicators = showsIndicators
        self.indicatorStyle = indicatorStyle
        super.init(frame: .zero)
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw
        // 开着交互才能收到点按；是否真的接住这一下由 `point(inside:)` 决定。
        isUserInteractionEnabled = true
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.delegate = self
        tap.cancelsTouchesInView = false
        addGestureRecognizer(tap)
        tapRecognizer = tap
        annotationState.addObserver(self)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func annotationStateDidChange() {
        cachedIndicators = nil
        setNeedsDisplay()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // 指示条跟着正文行位置走，版心或尺寸一变就得重算命中框。
        cachedIndicators = nil
    }

    // MARK: 命中

    /// 点中指示器时独占这一下。
    ///
    /// 留白与书口边缘同时是 pageCurl 的翻页点击区；允许同时识别会变成
    /// "打开编辑页的同时翻过去一页"。与 `TextRenderView` 命中标注时的处理一致。
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        false
    }

    /// 只有落在指示器的命中区里才接住触摸。
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        // 手势被关掉时（选中菜单在场，见 `MainViewController.setPageTurnTapGesturesEnabled`）
        // 连命中都不要：让这一下穿到正文/翻页上，而不是变成一块点不动的死区。
        guard tapRecognizer?.isEnabled ?? true else { return false }
        return indicators().contains { hitBox(for: $0.box).contains(point) }
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: self)
        // 相邻两行都有笔记时命中区会重叠，取纵向最近的那条。
        let nearest = indicators()
            .filter { hitBox(for: $0.box).contains(point) }
            .min { abs($0.box.midY - point.y) < abs($1.box.midY - point.y) }
        guard let nearest else { return }
        onIndicatorTap?(nearest.item.id)
    }

    /// 指示条只有 3pt 宽，按图形命中等于点不中。
    ///
    /// 命中区纵向放宽到 44pt（HIG 的最小触控高度），横向铺满右侧留白，
    /// 但**不越进版心**：这一层盖在正文之上，越界就会抢走正文的点按。
    private func hitBox(for box: CGRect) -> CGRect {
        let textRight = max(0, bounds.width - margins.right)
        let minX = min(textRight, box.minX)
        return CGRect(
            x: minX,
            y: box.midY - AnnotationMetrics.marginHitHeight / 2,
            width: max(0, bounds.width - minX),
            height: AnnotationMetrics.marginHitHeight
        )
    }

    // MARK: 绘制

    override func draw(_ rect: CGRect) {
        for indicator in indicators() {
            let path: UIBezierPath
            switch indicatorStyle {
            case .bar:
                path = UIBezierPath(
                    roundedRect: indicator.box,
                    cornerRadius: indicator.box.width / 2
                )
            case .dot:
                path = UIBezierPath(ovalIn: indicator.box)
            }
            indicator.item.color.uiColor
                .withAlphaComponent(AnnotationMetrics.marginBarAlpha)
                .setFill()
            path.fill()
        }
    }

    /// 本页所有笔记指示器的位置（含页面底部的贴边修正）。
    private func indicators() -> [Indicator] {
        if let cached = cachedIndicators { return cached }

        var result: [Indicator] = []
        if showsIndicators,
           bounds.width > 0,
           let pageRange = chapterLayout.characterRange(forPage: pageIndex) {

            let items = annotationState.items(intersecting: pageRange).filter(\.hasNote)
            let markWidth = indicatorStyle == .dot
                ? AnnotationMetrics.marginDotDiameter
                : AnnotationMetrics.marginBarWidth
            let markHeight = indicatorStyle == .dot
                ? AnnotationMetrics.marginDotDiameter
                : AnnotationMetrics.marginBarHeight
            // 右边距通常 16–40pt；取中间偏外一点，太贴版心会像正文的一部分。
            let centerX = bounds.width - max(
                AnnotationMetrics.marginMinimumInset,
                margins.right * AnnotationMetrics.marginInsetFactor
            )

            for item in items {
                guard let first = lineRects(for: item.range).first else { continue }
                let box = CGRect(
                    x: centerX - markWidth / 2,
                    // 贴着页底时上移，而不是直接不画：读者至少能看到"这一页有笔记"。
                    y: min(
                        max(0, margins.top + first.midY - markHeight / 2),
                        bounds.height - markHeight
                    ),
                    width: markWidth,
                    height: markHeight
                )
                guard box.maxY <= bounds.height else { continue }
                result.append(Indicator(item: item, box: box))
            }
        }

        cachedIndicators = result
        return result
    }

    private func lineRects(for range: NSRange) -> [CGRect] {
        chapterLayout.lineRects(forCharacterRange: range, pageIndex: pageIndex)
    }
}
