import UIKit

// MARK: - 标注的无障碍元素

/// `UIAccessibilityElement` 默认没有"双击激活"行为。给每个标注一个
/// 可激活元素，VoiceOver 双击它就能打开笔记，与普通按钮一致。
private final class AnnotationAccessibilityElement: UIAccessibilityElement {

    var onActivate: (() -> Void)?

    override func accessibilityActivate() -> Bool {
        guard let onActivate else { return false }
        onActivate()
        return true
    }
}

// MARK: - TextRenderView

/// 基于 NSLayoutManager 的纯渲染视图。
///
/// 只负责将 ChapterLayout 中对应 NSTextContainer 的内容绘制到屏幕上——
/// 标注底色/下划线、选中高亮、字形。
///
/// 不持有任何手势识别器，不参与触摸事件处理。
/// 选中状态与标注状态都由外部写入共享对象，本视图通过弱观察者表自动重绘。
final class TextRenderView: UIView, AnnotationStateObserver, SelectionStateObserver, UIGestureRecognizerDelegate {

    // MARK: - Properties

    let chapterLayout: ChapterLayout
    let pageIndex: Int
    let selectionState: SelectionState
    let annotationState: ChapterAnnotationState

    /// 全局标注透明度（设置 → 高亮与标注）。
    private let highlightOpacity: CGFloat
    /// 线条粗细档位（设置 → 高亮与标注）。只影响下划线 / 波浪线 / 删除线。
    private let annotationLineWeight: AnnotationLineWeight

    private var container: NSTextContainer { chapterLayout.pageContainers[pageIndex] }
    private var layoutManager: NSLayoutManager  { chapterLayout.layoutManager }
    var textStorage: NSTextStorage              { chapterLayout.textStorage }

    private var containerGlyphRange: NSRange { layoutManager.glyphRange(for: container) }

    // MARK: - Callbacks

    /// 读者点中一处标注：选中该标注并弹出操作菜单。
    var onAnnotationTap: ((UUID) -> Void)?
    /// 打开编辑页。指针入口已移到右侧的笔记指示器（见 `AnnotationMarginView`），
    /// 这里只剩 VoiceOver 的「编辑标注」自定义动作在用。
    var onAnnotationEdit: ((UUID) -> Void)?
    /// 点在正文空白处（未命中标注）。由容器决定是切换阅读控件还是取消选中。
    var onBackgroundTap: (() -> Void)?

    /// 本次触摸是否落在标注上。决定要不要让 pageCurl 的翻页点击同时生效。
    private var tapStartedOnAnnotation = false
    private var tapRecognizer: UITapGestureRecognizer?

    // MARK: - 聚焦闪烁

    private var flashID: UUID?
    private var flashStart: CFTimeInterval = 0
    private var flashLink: CADisplayLink?
    private let flashDuration: CFTimeInterval = 0.9

    // MARK: - Init

    init(
        chapterLayout: ChapterLayout,
        pageIndex: Int,
        selectionState: SelectionState,
        annotationState: ChapterAnnotationState,
        highlightOpacity: CGFloat,
        annotationLineWeight: AnnotationLineWeight = .standard
    ) {
        self.chapterLayout    = chapterLayout
        self.pageIndex        = pageIndex
        self.selectionState   = selectionState
        self.annotationState  = annotationState
        self.highlightOpacity = highlightOpacity
        self.annotationLineWeight = annotationLineWeight
        super.init(frame: .zero)
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw
        isAccessibilityElement = false
        // 注册为观察者而不是覆盖共享状态上的回调：同一章的每一页都要跟着重绘，
        // 否则跨页选中/跨页标注只有最后建出来的那一页会刷新。
        selectionState.addObserver(self)
        annotationState.addObserver(self)

        // 点按挂在**正文视图自身**上，而不是阅读器容器上：
        // 它在触摸链里比 UIPageViewController 的页面手势更深，
        // 命中标注时可以先于翻页点击识别，从根上避免"点标注也翻一页"。
        // 容器只再补一个"留白/扉页"用的背景点击（见 MainViewController）。
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.delegate = self
        tap.cancelsTouchesInView = false
        addGestureRecognizer(tap)
        tapRecognizer = tap
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        flashLink?.invalidate()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            flashLink?.invalidate()
            flashLink = nil
        }
    }

    // MARK: - Drawing

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let glyphRange = containerGlyphRange
        guard glyphRange.length > 0 else { return }

        // 1. 正文自身的背景属性（正文目前不带 backgroundColor；
        //    保留这一步是为了将来排版层加入底色时不丢绘制顺序）。
        layoutManager.drawBackground(forGlyphRange: glyphRange, at: .zero)

        // 2. 标注：压在字形下面。底色在字下，下划线/波浪线在字后。
        drawAnnotations(in: ctx)

        // 3. 选中高亮
        if let selRange = selectionState.range {
            drawSelection(selRange, in: ctx)
        }

        // 4. 字形
        layoutManager.drawGlyphs(forGlyphRange: glyphRange, at: .zero)
    }

    private func drawAnnotations(in context: CGContext) {
        guard let pageRange = chapterLayout.characterRange(forPage: pageIndex) else { return }
        let items = annotationState.items(intersecting: pageRange)
        guard !items.isEmpty else { return }

        let progress: CGFloat? = {
            guard flashID != nil else { return nil }
            return CGFloat(min(1, (CACurrentMediaTime() - flashStart) / flashDuration))
        }()

        for item in items {
            let rects = lineRects(for: item.range)
            guard !rects.isEmpty else { continue }

            // 高亮需要 textRect（不含行距），下划线/波浪线/删除线需要基线；
            // 统一算一次逐行几何。
            let geometries = chapterLayout.lineFragmentGeometries(
                forCharacterRange: item.range,
                pageIndex: pageIndex
            )

            AnnotationDrawing.draw(
                item,
                rects: rects,
                lineGeometries: geometries,
                fillOpacity: highlightOpacity,
                lineWeight: annotationLineWeight,
                in: context
            )

            if item.id == flashID, let progress {
                AnnotationDrawing.drawFocus(item, rects: rects, progress: progress, in: context)
            }
        }
    }

    private func drawSelection(_ range: NSRange, in context: CGContext) {
        let rects = lineRects(for: range)
        guard !rects.isEmpty else { return }

        // 1. 底色：方角色块。参考图是方角 + 细边框，不是圆角。
        context.setFillColor(UIColor.systemBlue.withAlphaComponent(0.18).cgColor)
        for rect in rects {
            context.fill(rect)
        }

        // 2. 细边框：左右两边每行都画；上/下边只在选区真正开始/结束的页画。
        //    跨页选区在中间页上不应该出现横线。
        guard let pageRange = chapterLayout.characterRange(forPage: pageIndex) else { return }
        let startsHere = NSLocationInRange(range.location, pageRange)
        let endsHere = NSLocationInRange(NSMaxRange(range) - 1, pageRange)

        context.setStrokeColor(UIColor.systemBlue.withAlphaComponent(0.9).cgColor)
        context.setLineWidth(1)

        for (index, rect) in rects.enumerated() {
            context.move(to: CGPoint(x: rect.minX, y: rect.minY))
            context.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            context.move(to: CGPoint(x: rect.maxX, y: rect.minY))
            context.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))

            // 每行是一个独立的文字块：顶边/底边逐行画，行距处自然留白。
            // 只有跨页延续的那一端不画，避免在页边界多出一条横线。
            if index > 0 || startsHere {
                context.move(to: CGPoint(x: rect.minX, y: rect.minY))
                context.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            }
            if index < rects.count - 1 || endsHere {
                context.move(to: CGPoint(x: rect.minX, y: rect.maxY))
                context.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            }
        }
        context.strokePath()
    }

    /// 某个字符区间在本页上的行矩形。
    ///
    /// 这是选中高亮、标注绘制、菜单锚点、VoiceOver 元素共用的唯一几何来源。
    func lineRects(for range: NSRange) -> [CGRect] {
        chapterLayout.lineRects(forCharacterRange: range, pageIndex: pageIndex)
    }

    // MARK: - State Observer

    func selectionStateDidChange() {
        setNeedsDisplay()
    }

    func annotationStateDidChange() {
        // VoiceOver 元素每次都由投影重建（见 accessibilityElements），
        // 这里只需要重绘。
        setNeedsDisplay()
    }

    // MARK: - Hit Testing

    /// 将本视图坐标系内的点映射为章节全局字符索引。
    func characterIndex(at point: CGPoint) -> Int? {
        guard bounds.contains(point) else { return nil }
        let gi = layoutManager.glyphIndex(for: point, in: container, fractionOfDistanceThroughGlyph: nil)
        guard gi != NSNotFound, gi < layoutManager.numberOfGlyphs else { return nil }
        return layoutManager.characterIndexForGlyph(at: gi)
    }

    /// 点中的标注。重叠时由 `ChapterAnnotationState` 取最短的一条。
    func annotation(at point: CGPoint) -> AnnotationItem? {
        guard let ci = characterIndex(at: point) else { return nil }
        return annotationState.item(atCharacter: ci)
    }

    // MARK: - Tap

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: self)
        if let item = annotation(at: point) {
            onAnnotationTap?(item.id)
        } else {
            onBackgroundTap?()
        }
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldReceive touch: UITouch
    ) -> Bool {
        guard gestureRecognizer === tapRecognizer else { return true }
        tapStartedOnAnnotation = annotation(at: touch.location(in: self)) != nil
        return true
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        guard gestureRecognizer === tapRecognizer || otherGestureRecognizer === tapRecognizer else {
            return false
        }
        // 背景点击允许与翻页点击同时识别：点边缘既翻页也切控件，与改造前一致。
        // 命中标注时独占，避免"打开笔记的同时翻过去一页"。
        return !tapStartedOnAnnotation
    }

    /// 长按选中期间临时关掉点按：否则同一次抬手既结束长按、又触发一次
    /// "点空白"（把刚弹出的菜单立刻清掉）。
    func setTapEnabled(_ enabled: Bool) {
        tapRecognizer?.isEnabled = enabled
    }

    // MARK: - Focus

    /// 从笔记列表跳转落页后闪一下，告诉读者"就是这一处"。
    func flash(annotationID: UUID) {
        guard annotationState.item(id: annotationID) != nil else { return }

        flashLink?.invalidate()
        flashID = annotationID
        flashStart = CACurrentMediaTime()

        let link = CADisplayLink(target: self, selector: #selector(stepFlash))
        link.add(to: .main, forMode: .common)
        flashLink = link
        setNeedsDisplay()
    }

    @objc private func stepFlash() {
        guard flashID != nil else {
            flashLink?.invalidate()
            flashLink = nil
            return
        }

        if CACurrentMediaTime() - flashStart >= flashDuration {
            flashLink?.invalidate()
            flashLink = nil
            flashID = nil
        }
        setNeedsDisplay()
    }

    // MARK: - Accessibility

    /// 自绘的高亮对 VoiceOver 是不可见的。为每一处标注生成一个可聚焦元素，
    /// 让读屏用户也能发现、朗读并编辑它们。
    override var accessibilityElements: [Any]? {
        get {
            guard let pageRange = chapterLayout.characterRange(forPage: pageIndex) else { return nil }
            let items = annotationState.items(intersecting: pageRange)
            guard !items.isEmpty else { return nil }

            return items.compactMap { item -> UIAccessibilityElement? in
                let rects = lineRects(for: item.range)
                guard let first = rects.first else { return nil }
                let union = rects.dropFirst().reduce(first) { $0.union($1) }

                let element = AnnotationAccessibilityElement(accessibilityContainer: self)
                element.onActivate = { [weak self] in
                    self?.onAnnotationTap?(item.id)
                }
                element.accessibilityFrameInContainerSpace = union
                element.accessibilityLabel = item.hasNote
                    ? "笔记：\(item.quote)"
                    : "\(item.style.displayName)：\(item.quote)"
                element.accessibilityValue = item.hasNote ? item.note : ""
                element.accessibilityHint = "双击打开操作菜单，或用自定义动作编辑"
                element.accessibilityTraits = .button

                var actions: [UIAccessibilityCustomAction] = []
                actions.append(UIAccessibilityCustomAction(name: "打开菜单", image: nil) { [weak self] _ in
                    self?.onAnnotationTap?(item.id)
                    return true
                })
                actions.append(UIAccessibilityCustomAction(name: "编辑标注", image: nil) { [weak self] _ in
                    self?.onAnnotationEdit?(item.id)
                    return true
                })
                actions.append(UIAccessibilityCustomAction(name: "复制原文", image: nil) { _ in
                    UIPasteboard.general.string = item.quote
                    return true
                })
                element.accessibilityCustomActions = actions
                return element
            }
        }
        set { /* 由投影重建，不接受外部赋值 */ }
    }
}
