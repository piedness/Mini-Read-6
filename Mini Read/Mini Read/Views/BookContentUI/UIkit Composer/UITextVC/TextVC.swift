import UIKit

// MARK: - TextViewController

/// 单页文本视图控制器。使用 TextRenderView 替代 UITextView，基于共享 TextKit 链路渲染。
///
/// TextRenderView 通过 ChapterLayout 的共享 NSTextStorage + NSLayoutManager 绘制文本，
/// 标注和选中均为章节全局坐标，跨页自动一致。
///
/// 页眉/页脚元素（页码、章节标题）互相独立，布局由父 VC 通过
/// `ReaderChrome.Placement` 注入：本类只负责把元素摆到与浮动按钮同高的位置，
/// 不自行解释设置字段。
class TextViewControllerTest: UIViewController {

    // MARK: - Properties

    private let chapterLayout: ChapterLayout
    private let pageIndex: Int
    /// 由父 VC 解析好的纸面。本页不读设置里的背景字段，避免两处各写一套回退。
    private let background: ReadingBackground
    private let settings: AppSettings
    /// 与 `ChapterLayout` 分页时使用的同一份有效边距（极端边距会被收缩）。
    /// 直接读 `settings.margin*` 会与排版算出的版心不一致。
    private let margins: ReaderMargins
    private let chapterTitle: String?
    /// 本页两个元素的布局（含「不显示」）。由父 VC 从设置 + 章节位置算出。
    private let chromePlacement: ReaderChrome.Placement
    let selectionState: SelectionState
    /// 本章共享的标注投影。同一章的每一页拿到的是同一个实例。
    let annotationState: ChapterAnnotationState

    /// 标注透明度、线条粗细与边注指示器。属于绘制参数，不参与分页。
    private let highlightOpacity: CGFloat
    private let annotationLineWeight: AnnotationLineWeight
    private let showsNoteIndicator: Bool
    private let noteIndicatorStyle: NoteIndicatorStyle

    /// 读者点中标注：选中该标注并弹出操作菜单。
    var onAnnotationTap: ((UUID) -> Void)?
    /// 点笔记指示器（或 VoiceOver 自定义动作）：打开编辑页。
    var onAnnotationEdit: ((UUID) -> Void)?
    /// 点在正文空白处（未命中标注）时上报。
    var onBackgroundTap: (() -> Void)?

    // MARK: 选区手柄

    var onSelectionHandleTouchDown: ((SelectionHandle, NSRange) -> Void)?
    /// 手柄移动（点已转换到本 VC 的 view 坐标系）。
    var onSelectionHandleMoved: ((SelectionHandle, CGPoint) -> Void)?
    var onSelectionHandleDragEnded: (() -> Void)?

    private weak var selectionHandleOverlay: SelectionHandleOverlayView?

    /// 供 iPad overlay / 容器访问
    private(set) weak var textRenderView: TextRenderView!

    /// 底部页码。
    private weak var pageLabel: UILabel!
    /// 顶部章节标题。
    private weak var titleLabel: UILabel!

    // MARK: - Page Element

    /// 由父 VC 注入，调用时返回**当前格式下**的页码数值（整书口径或本章口径）。
    /// 索引未就绪时分量可为 nil，由 `ReaderChrome.pageNumberText` 渐进呈现。
    var pageNumberValuesProvider: (() -> (current: Int?, total: Int?))?

    /// 两个元素与浮动按钮同高的垂直约束。安全区变化（旋转 / 状态栏）时更新常量。
    private var pageLabelCenterY: NSLayoutConstraint?
    private var titleLabelCenterY: NSLayoutConstraint?

    init(chapterLayout: ChapterLayout,
         pageIndex: Int,
         background: ReadingBackground,
         settings: AppSettings,
         margins: ReaderMargins,
         chapterTitle: String?,
         chromePlacement: ReaderChrome.Placement,
         selectionState: SelectionState? = nil,
         annotationState: ChapterAnnotationState) {
        self.chapterLayout   = chapterLayout
        self.pageIndex       = pageIndex
        self.background      = background
        self.settings        = settings
        self.margins         = margins
        self.chapterTitle    = chapterTitle
        self.chromePlacement = chromePlacement
        self.selectionState  = selectionState ?? SelectionState()
        self.annotationState = annotationState
        self.highlightOpacity = CGFloat(settings.highlightOpacity)
        self.annotationLineWeight = AnnotationLineWeight(rawValue: settings.annotationLineWeight) ?? .standard
        self.showsNoteIndicator = settings.showNoteIndicators
        self.noteIndicatorStyle = NoteIndicatorStyle(rawValue: settings.noteIndicatorStyle) ?? .bar
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupBackground()
        setupTextRenderView()
        setupPageNumberLabel()
        setupChapterTitleLabel()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refreshChromeElements()
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        updateVerticalAlignment()
    }

    // MARK: - Chrome Elements

    /// 刷新页码与标题（全书页数索引完成、安全区变化时由父 VC 调用）。
    func refreshChromeElements() {
        if let pageLabel {
            let values = pageNumberValuesProvider?() ?? (current: nil, total: nil)
            if let text = ReaderChrome.pageNumberText(
                format: chromePlacement.pageNumberFormat,
                current: values.current,
                total: values.total
            ) {
                pageLabel.text = text
                pageLabel.accessibilityLabel = "第\(text)页"
            } else {
                pageLabel.text = "…"
                pageLabel.accessibilityLabel = "正在计算页码"
            }
        }

        if let titleLabel {
            let title = chapterTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            titleLabel.text = title
            titleLabel.accessibilityLabel = "章节：\(title)"
        }
    }

    // MARK: - Background

    /// 复用 `PageBackgroundView`，保证空白页/占位页与本页使用同一份纸面与兜底逻辑。
    private func setupBackground() {
        PageBackgroundView.install(in: view, background: background)
    }

    // MARK: - TextRenderView

    private func setupTextRenderView() {
        let rv = TextRenderView(
            chapterLayout: chapterLayout,
            pageIndex: pageIndex,
            selectionState: selectionState,
            annotationState: annotationState,
            highlightOpacity: highlightOpacity,
            annotationLineWeight: annotationLineWeight
        )
        rv.translatesAutoresizingMaskIntoConstraints = false
        rv.onAnnotationTap = { [weak self] id in
            self?.onAnnotationTap?(id)
        }
        rv.onAnnotationEdit = { [weak self] id in
            self?.onAnnotationEdit?(id)
        }
        rv.onBackgroundTap = { [weak self] in
            self?.onBackgroundTap?()
        }
        view.addSubview(rv)
        textRenderView = rv

        NSLayoutConstraint.activate([
            rv.topAnchor.constraint(equalTo: view.topAnchor,       constant:  margins.top),
            rv.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -margins.bottom),
            rv.leadingAnchor.constraint(equalTo: view.leadingAnchor,   constant:  margins.left),
            rv.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -margins.right)
        ])

        rv.setContentHuggingPriority(.required, for: .vertical)
        rv.setContentCompressionResistancePriority(.required, for: .vertical)

        // 边注指示器画在正文版心之外，必须是一层铺满整页的兄弟视图。
        // 它只在指示器的命中区里接收触摸（见 `AnnotationMarginView.point(inside:)`），
        // 其余位置照常透给正文与翻页手势。
        let margin = AnnotationMarginView(
            chapterLayout: chapterLayout,
            pageIndex: pageIndex,
            margins: margins,
            annotationState: annotationState,
            showsIndicators: showsNoteIndicator,
            indicatorStyle: noteIndicatorStyle
        )
        // 点右侧的笔记指示器 = 打开编辑页。这是编辑已有笔记的唯一指针入口：
        // 长按正文一律只做选区（见 `MainViewController.handleSelectionLongPress`）。
        margin.onIndicatorTap = { [weak self] id in
            self?.onAnnotationEdit?(id)
        }
        margin.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(margin)

        NSLayoutConstraint.activate([
            margin.topAnchor.constraint(equalTo: view.topAnchor),
            margin.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            margin.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            margin.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])

        // 选区手柄：铺满整页，但只在手柄命中区接收触摸。
        let handles = SelectionHandleOverlayView(
            chapterLayout: chapterLayout,
            pageIndex: pageIndex,
            margins: margins,
            selectionState: selectionState
        )
        handles.translatesAutoresizingMaskIntoConstraints = false
        handles.onHandleTouchDown = { [weak self] handle, range in
            self?.onSelectionHandleTouchDown?(handle, range)
        }
        handles.onHandleMoved = { [weak self, weak handles] handle, point in
            guard let self, let handles else { return }
            self.onSelectionHandleMoved?(handle, handles.convert(point, to: self.view))
        }
        handles.onHandleDragEnded = { [weak self] in
            self?.onSelectionHandleDragEnded?()
        }
        view.addSubview(handles)
        selectionHandleOverlay = handles

        NSLayoutConstraint.activate([
            handles.topAnchor.constraint(equalTo: view.topAnchor),
            handles.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            handles.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            handles.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
    }

    // MARK: - Annotation Access

    /// 本章正文。只在选中/取原文时桥接一次，不放进每帧的绘制路径。
    var chapterText: NSString {
        chapterLayout.textStorage.string as NSString
    }

    /// 章节字符数。手柄拖动会高频调用，不能每次都桥接整章文本。
    var chapterLength: Int {
        chapterLayout.textStorage.length
    }

    /// 某个字符区间在本页上的行矩形（**本 VC 的 view 坐标系**）。
    func rects(for range: NSRange) -> [CGRect] {
        guard let rv = textRenderView else { return [] }
        return rv.lineRects(for: range).map { rv.convert($0, to: view) }
    }

    /// 点中的标注（入参是**本 VC 的 view 坐标系**）。
    func annotation(at point: CGPoint) -> AnnotationItem? {
        guard let rv = textRenderView else { return nil }
        return rv.annotation(at: rv.convert(point, from: view))
    }

    /// 本页上的一处标注。章内有、但不在本页的返回 nil。
    func annotation(id: UUID) -> AnnotationItem? {
        guard let item = annotationState.item(id: id),
              let pageRange = chapterLayout.characterRange(forPage: pageIndex),
              NSIntersectionRange(item.range, pageRange).length > 0
        else { return nil }
        return item
    }

    /// 跳转落页后的聚焦提示。
    func flash(annotationID: UUID) {
        textRenderView?.flash(annotationID: annotationID)
    }

    /// 长按选中期间临时关掉正文点按（见 `TextRenderView.setTapEnabled`）。
    func setTextTapEnabled(_ enabled: Bool) {
        textRenderView?.setTapEnabled(enabled)
    }

    /// 某个点（本 VC 的 view 坐标系）是否落在选区手柄上。
    /// 容器的长按手势据此让路，避免"按住手柄 0.45 秒"又重新选一次词。
    func containsSelectionHandle(at point: CGPoint) -> Bool {
        guard let overlay = selectionHandleOverlay else { return false }
        return overlay.containsHandle(at: overlay.convert(point, from: view))
    }

    // MARK: - Font

    /// 页眉/页脚用的字体。
    ///
    /// 跟随用户选择的阅读字体，让书口 expressive 的排版保持统一；
    /// 与正文共用 `FontFamily` 解析，缺失时同样回退到系统字体。
    private func resolvedFont(ofSize size: CGFloat) -> UIFont {
        resolveReadingUIFont(settings.fontFamily, size: size)
    }

    // MARK: - Chrome Element Layout

    /// 底部页码：固定在底部（与 TableButton 同高），水平可选偏左 / 中间 / 偏右。
    private func setupPageNumberLabel() {
        guard chromePlacement.showsPageNumber else { return }

        let label = makeChromeLabel()
        view.addSubview(label)
        pageLabel = label

        var constraints = horizontalConstraints(for: label, alignment: chromePlacement.pageNumberAlignment)
        let centerY = label.centerYAnchor.constraint(
            equalTo: view.bottomAnchor,
            constant: -chromeBottomCenterConstant()
        )
        pageLabelCenterY = centerY
        constraints.append(centerY)
        NSLayoutConstraint.activate(constraints)
    }

    /// 顶部章节标题：固定在顶部（与 dismissButton 同高），水平可选偏左 / 中间 / 偏右。
    /// 本章没有标题时不创建元素（留白比重复的页眉干净）。
    private func setupChapterTitleLabel() {
        guard chromePlacement.showsChapterTitle,
              !(chapterTitle?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        else { return }

        let label = makeChromeLabel()
        view.addSubview(label)
        titleLabel = label

        var constraints = horizontalConstraints(for: label, alignment: chromePlacement.chapterTitleAlignment)
        let centerY = label.centerYAnchor.constraint(
            equalTo: view.topAnchor,
            constant: chromeTopCenterConstant()
        )
        titleLabelCenterY = centerY
        constraints.append(centerY)
        NSLayoutConstraint.activate(constraints)
    }

    /// 页眉/页脚元素共用的外观。
    private func makeChromeLabel() -> UILabel {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font          = resolvedFont(ofSize: 16)
        label.textColor     = background.textTone.secondaryInkColor
        label.numberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        label.isAccessibilityElement = true
        return label
    }

    /// 水平约束：偏左/偏右贴正文版心的左右边界，居中则整体居中。
    private func horizontalConstraints(
        for label: UILabel,
        alignment: ReaderChrome.HorizontalAlignment
    ) -> [NSLayoutConstraint] {
        let marginLeft  = margins.left
        let marginRight = margins.right

        var constraints: [NSLayoutConstraint] = [
            label.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: marginLeft),
            label.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -marginRight),
        ]

        switch alignment {
        case .left:
            label.textAlignment = .left
            constraints.append(label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: marginLeft))
        case .right:
            label.textAlignment = .right
            constraints.append(label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -marginRight))
        case .center:
            label.textAlignment = .center
            constraints.append(label.centerXAnchor.constraint(equalTo: view.centerXAnchor))
        }
        return constraints
    }

    /// 顶部标题中心距**屏幕顶**的距离。
    ///
    /// - iPhone：与 dismissButton 同高（按钮贴屏幕边，元素也锚屏幕边）。
    /// - iPad：与右上角按钮组同高（按钮贴安全区上沿，元素锚安全区顶）。
    private func chromeTopCenterConstant() -> CGFloat {
        if chromePlacement.isRegular {
            return view.safeAreaInsets.top + ReaderChromeMetrics.Pad.topCenterOffset
        }
        return ReaderChromeMetrics.Phone.topCenterOffset
    }

    /// 底部页码中心距**屏幕底**的距离。
    ///
    /// - iPhone：与 TableButton 同高（按钮贴屏幕边）。
    /// - iPad：底部没有浮动按钮，页码贴着安全区底，只留避让 Home Indicator 的余量。
    private func chromeBottomCenterConstant() -> CGFloat {
        if chromePlacement.isRegular {
            return view.safeAreaInsets.bottom + ReaderChromeMetrics.Pad.bottomCenterOffset
        }
        return ReaderChromeMetrics.Phone.bottomCenterOffset
    }

    /// 旋转 / 状态栏变化后重新对齐安全区。
    private func updateVerticalAlignment() {
        pageLabelCenterY?.constant = -chromeBottomCenterConstant()
        titleLabelCenterY?.constant = chromeTopCenterConstant()
    }

    // MARK: - 页张背面

    /// 本页作为「页张正面」时，背面透印所需的素材。
    ///
    /// 只有 iPhone 的仿真卷曲会用到（`.min` 书脊 + 正反面模型）。返回的是
    /// **共享排版**的引用而不是快照：背面在自己的 `draw(_:)` 里把同一段字形
    /// 以极低 alpha 重画一遍即可，不需要离屏渲染，也不需要每页多一份位图。
    ///
    /// `inset` 必须与 `TextRenderView` 的 frame 原点逐点相同——透印落错位置，
    /// 卷曲到一半时字会"跳"一下。这里直接取同一批边距设置，不另算一遍。
    var sheetBackGhost: PageBackGhost? {
        guard chapterLayout.pageContainers.indices.contains(pageIndex) else { return nil }
        return PageBackGhost(
            layout: chapterLayout,
            pageIndex: pageIndex,
            inset: CGPoint(x: margins.left, y: margins.top),
            // 同样的 alpha 下，浅墨压在深纸上的可见度高于深墨压在浅纸上
            // （暗底的对比增益更大）。夜读纸面压一档，两种纸面的"透过来"
            // 程度才看起来一致。
            alpha: background.textTone == .light ? 0.05 : 0.07
        )
    }

    // MARK: - 书签锚点

    /// 本页的书签锚点：字符范围 + 开头一段预览文字。
    ///
    /// 返回 nil 表示这一页没有可锚定的文字，调用方不应写书签。
    /// 字符范围取自 `ChapterLayout` 的当前分页结果，因此天然与「这一页
    /// 究竟显示了哪几个字」一致，不存在另算一遍坐标的可能。
    func bookmarkAnchor(previewLimit: Int = 90) -> (start: Int, length: Int, preview: String)? {
        guard let range = chapterLayout.characterRange(forPage: pageIndex),
              range.length > 0,
              // 折叠空白最多把字符数减半，取两倍长度足够填满预览。
              let raw = chapterLayout.text(forPage: pageIndex, maxLength: previewLimit * 2)
        else { return nil }

        return (
            range.location,
            range.length,
            ReaderLocation.makePreview(from: raw, limit: previewLimit)
        )
    }

    /// 字符锚点 → 本章页下标（书签跳转用）。由 `ChapterLayout` 在当前排版上解析。
    func pageIndex(forCharacterOffset offset: Int) -> Int? {
        chapterLayout.pageIndex(forCharacterOffset: offset)
    }

    /// 目录锚点 → 本章字符偏移（目录跳转用）。
    ///
    /// 返回 nil = 本章没有这个 id（旧缓存 / 坏书），调用方退回章首。
    func characterOffset(forAnchor anchorID: String) -> Int? {
        chapterLayout.characterOffset(forAnchor: anchorID)
    }
}
