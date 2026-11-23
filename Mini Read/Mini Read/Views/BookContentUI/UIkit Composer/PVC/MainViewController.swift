import UIKit
import SwiftUI
import SwiftData

// MARK: - UIViewControllerRepresentable

struct PageViewControllerRepresentable: UIViewControllerRepresentable {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.horizontalSizeClass) private var hSizeClass
    var isRegular: Bool { hSizeClass == .regular }

    let currentSrc: String
    let allSrcs: [String]
    let epubBaseURL: URL
    let bookKey: String
    /// 书库元数据：扉页（封面 + 书名 + 作者）的数据源。
    let bookTitle: String
    let bookAuthor: String
    /// 封面文件 URL（指向解压目录内的图片）。nil 或读不到时扉页退化为纯文字。
    let coverImageURL: URL?
    let titleBySrc: [String: String]
    let tocJumpRequest: TOCJumpRequest?
    /// 目录派生数据的版本号。`allSrcs` / `titleBySrc` 每次打开一本书只整体替换一次，
    /// 用它做 O(1) 判断即可，不必每帧对数组和字典做全量深比较。
    let derivedVersion: Int

    /// 全书标注快照 + 版本号。版本号用于 O(1) 判断，
    /// 不拿数组本身做逐帧深比较（标注可能有几百条）。
    let annotations: [AnnotationSnapshot]
    let annotationsVersion: Int
    /// 从笔记列表跳转后的聚焦请求。
    let annotationFocusRequest: AnnotationFocusRequest?

    var onChapterChange: ((String) -> Void)?
    /// 第一页真正上屏时回调一次。供上层开闸放行转场静默窗内的写入
    /// （见 `ContentsPanelViewModel.openWriteGateAndCommit`）。
    var onFirstPageShown: (() -> Void)?
    /// 可见页变化（翻页 / 跳转 / 旋转重排）时回调。nil 表示当前页不可锚定
    /// （扉页、空白页）——书签按钮据此决定可用与否。
    var onLocationChange: ((ReaderLocation?) -> Void)?

    // MARK: 标注交互出口

    var onHighlightSelection: ((ReaderTextSelection, AnnotationStyle, AnnotationColor) -> Void)?
    var onNoteSelection: ((ReaderTextSelection) -> Void)?
    var onAnnotationActivate: ((UUID) -> Void)?
    var onDeleteAnnotation: ((UUID) -> Void)?
    /// 点击纸面（未命中标注）。替代原先 SwiftUI 层的 simultaneousGesture。
    var onBackgroundTap: (() -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var lastSrc: String = ""
        var lastDerivedVersion: Int = -1
        var lastTOCJumpRequestID: UUID?
        var lastAnnotationsVersion: Int = -1
        var lastFocusRequestID: UUID?
    }

    func makeUIViewController(context: Context) -> ViewController {
        let vc = ViewController(
            modelContext: modelContext,
            epubBaseURL: epubBaseURL,
            bookKey: bookKey,
            allSrcs: allSrcs,
            titleBySrc: titleBySrc,
            bookTitle: bookTitle,
            bookAuthor: bookAuthor,
            coverImageURL: coverImageURL,
            isRegular: isRegular
        )
        vc.onChapterChange = onChapterChange
        vc.onFirstPageShown = onFirstPageShown
        vc.onLocationChange = onLocationChange
        vc.onHighlightSelection = onHighlightSelection
        vc.onNoteSelection = onNoteSelection
        vc.onAnnotationActivate = onAnnotationActivate
        vc.onDeleteAnnotation = onDeleteAnnotation
        vc.onBackgroundTap = onBackgroundTap
        vc.updateAnnotations(annotations)
        return vc
    }

    func updateUIViewController(_ uiViewController: ViewController, context: Context) {
        let coord = context.coordinator
        uiViewController.updateHorizontalSizeClass(isRegular: isRegular)

        // 标注交互的闭包每次更新都重新挂一遍：它们会读到当前的阅读设置
        // （默认颜色/样式）与 SwiftUI 状态，只在 make 时挂一次会用到旧值。
        uiViewController.onHighlightSelection = onHighlightSelection
        uiViewController.onNoteSelection = onNoteSelection
        uiViewController.onAnnotationActivate = onAnnotationActivate
        uiViewController.onDeleteAnnotation = onDeleteAnnotation
        uiViewController.onBackgroundTap = onBackgroundTap

        // 目录结构只在解析完成时变一次；版本号相等就说明下面的两份数据都是同一批，
        // 逐帧深比较（`!=` 会遍历整个数组/字典）在长目录书上足以拖慢首屏。
        if coord.lastDerivedVersion != derivedVersion {
            coord.lastDerivedVersion = derivedVersion
            uiViewController.updateAllSrcs(allSrcs)
            uiViewController.updateTitleBySrc(titleBySrc)
        }

        // 标注同样走版本号：一次高亮/删除只下发一次，
        // 不会因为 SwiftUI 的无关重绘把整章标注重新解析一遍。
        if coord.lastAnnotationsVersion != annotationsVersion {
            coord.lastAnnotationsVersion = annotationsVersion
            uiViewController.updateAnnotations(annotations)
        }

        if let request = annotationFocusRequest,
           coord.lastFocusRequestID != request.id {
            coord.lastFocusRequestID = request.id
            uiViewController.focusAnnotation(request.annotationID)
        }

        // 目录跳转是一个比普通 currentSrc 同步更强的 intent：它明确要求
        // 从章节首屏开始，而不是恢复该章上次的页码。两条路径必须互斥，
        // 否则同一次 SwiftUI 更新会先执行 false，再执行默认 true，
        // 把用户刚选的目录位置改回保存页。
        if let request = tocJumpRequest,
           coord.lastTOCJumpRequestID != request.id {
            coord.lastTOCJumpRequestID = request.id
            coord.lastSrc = request.src
            // 书签跳转只带字符锚点；目录跳转带章内锚点（EPUB 的 `#fragment`）。
            // 两者都不带页码：页码由阅读器在本章**当前**排版结果上解析，
            // 目录侧存下的页码改过字号就失效了，不能拿来当跳转目标。
            uiViewController.navigateTo(
                src: request.src,
                anchorID: request.anchorID,
                characterOffset: request.characterOffset
            )
        } else if coord.lastSrc != currentSrc {
            coord.lastSrc = currentSrc
            // 手势翻页跨章时，阅读器自己已经换了页并回调 `onChapterChange`，
            // `currentSrc` 的这次变化只是 SwiftUI 侧对**同一次**换章的回报。
            // 此时再 navigateToSrc 等于对着同一个 VC 又调一次
            // `setViewControllers(animated: true)`：compact 下会重播一遍翻页
            // 动画（方向还按目录次序硬算——往回翻会播成向前翻），并多写一次
            // 进度。已经在屏幕上了就什么都不做。
            if !uiViewController.isDisplaying(src: currentSrc) {
                uiViewController.navigateToSrc(currentSrc)
            }
        }
    }
}


// MARK: - ViewController

final class ViewController: UIViewController,
                             UIPageViewControllerDelegate,
                             UIPageViewControllerDataSource,
                             UIGestureRecognizerDelegate,
                             UIEditMenuInteractionDelegate {

    // MARK: - Properties

    private var pageVC: UIPageViewController!
    private let modelContext: ModelContext
    private let epubBaseURL: URL
    private let bookKey: String
    private var titleBySrc: [String: String]
    /// 扉页用的书库元数据（封面在 `coverImageURL`，缺失时扉页退化为纯文字）。
    private let bookTitle: String
    private let bookAuthor: String
    private let coverImageURL: URL?

    /// 前置页（扉页 + 版权页）所在章的 src。nil = 本书没有前置页。
    ///
    /// 只可能是 `allSrcs.first`：版权页检测仅在全书第一章上执行
    /// （见 `ChapterRender.outcome` 的 `isFirstChapter` 总闸）。
    /// 一旦置位，正文页码从 1 起算（见 `globalPageNumber`），
    /// 翻页/预载/索引都绕开特例逻辑。
    private var frontMatterSrc: String?

    private let pageCache = ChapterLRUCache(capacity: 5)
    private var vcIndexMap: [ObjectIdentifier: (src: String, pageArrayIndex: Int)] = [:]
    private var loadingChapters: Set<String> = []
    private var chapterLoadCompletions: [String: [(Bool) -> Void]] = [:]
    private var pageCountBySrc: [String: Int] = [:]
    /// 全书正文总页数（不含扉页与版权页）。「整书页数」页码格式的分母，
    /// 只在全书页数索引完整后赋值；未就绪时页码先显示当前页，随后补全。
    private var totalBookPageCount: Int?
    private var pageCountIndexGeneration = UUID()

    /// 当前分页会话的代号。设置、尺寸或阅读器重建后递增（换 UUID），
    /// 旧的异步解析/排版结果即使晚到，也不能再写入当前 pageCache。
    private var paginationGeneration = UUID()

    private(set) var allSrcs: [String]
    private var currentSrc: String = ""

    var onChapterChange: ((String) -> Void)?

    /// 第一页真正摆上屏时回调一次（只回调一次）。
    var onFirstPageShown: (() -> Void)?

    /// 可见页变化时回调（页级位置出口，见 `ReaderLocation`）。
    var onLocationChange: ((ReaderLocation?) -> Void)?

    /// 上一次上报的位置。翻页、旋转、跳转都会走到上报点，用等值判断挡掉
    /// 无变化的重复通知——每次通知都会让 SwiftUI 外壳重新求值一次。
    private var lastReportedLocation: ReaderLocation?

    private var _cachedSettings: AppSettings?
    private var cachedSettings: AppSettings? {
        if _cachedSettings == nil { _cachedSettings = loadAppSettings() }
        return _cachedSettings
    }

    /// 音量键翻页。开关见 `AppSettings.volumeKeysTurn`（设置 → 翻页与交互）。
    private let volumeKeyPager = VolumeKeyPager()

    /// 程序化翻页动画是否还在进行。只用于拦音量键的连发，手势翻页不受影响。
    private var isTurningPage = false

    private var pageSize: CGSize = .zero
    private var pendingSrc: String = ""
    private var pendingResumeProgress = true
    /// 首屏布局前被拦下的书签跳转锚点，见 `handleFirstLayout`。
    private var pendingCharacterOffset: Int?
    /// 首屏布局前被拦下的目录锚点（`#fragment`），与 `pendingCharacterOffset`
    /// 同寿。两者互斥：书签给偏移，目录给 id。
    private var pendingAnchorID: String?

    /// 重排前的字符锚点：章 + 本页首字符在章节文本中的偏移。
    ///
    /// 字号/尺寸/边距一变，旧页号就指向另一段文字——直接拿 PageProgress 的
    /// 页号恢复，读者会在"没有翻页"的情况下被带到别处。这里在作废分页前
    /// 记下当前页首字符，新 layout 就绪后由 `ChapterLayout` 反解页下标。
    /// 只活在一次 invalidate → reloadPages 之间，不是持久化数据。
    private var repaginationAnchor: (src: String, characterOffset: Int)?

    private var isRegular: Bool

    /// 当前 `pageVC` 实际使用的翻页样式。
    ///
    /// `UIPageViewController` 的 `transitionStyle` 是 init 参数，运行期改不了，
    /// 只能整只换掉容器。所以这里记下"已经建出来的那一只是什么样式"，
    /// 用于在设置变更 / 降低动态效果开关翻转时判断要不要重建。
    ///
    /// nil = 还没建过（`setupPageVC` 之前）。
    private var appliedTurnStyle: PageTurnStyle?

    /// 首次布局前 size class 发生了变化。
    ///
    /// `pageVC` 已经按旧尺寸类建好（可能是 `.scroll`/`.min`），但 `isRegular`
    /// 已经改成新值。若首屏直接落页，`showPages` 会按 regular 传两个 VC 给
    /// 只接受一个的容器，UIKit 会抛 `NSInvalidArgumentException`（不是可恢复错误）。
    /// 因此把重建推迟到尺寸就绪后的第一屏，先换容器再落页。
    private var needsPageVCReconfiguration = false

    private var sharedSelectionAnchor: Int = 0
    /// 跨页选中的长按识别器。挂在 `self.view` 上，随 VC 存活而不是随 pageVC，
    /// 因此必须自己保证只装一次（见 `setupSelectionGesture`）。
    private var selectionGesture: UILongPressGestureRecognizer?

    // MARK: - 标注

    /// 每章一份标注投影。键是章相对路径。
    ///
    /// 只持有投影、不持有 SwiftData 对象：绘制层在每帧 draw 里访问的必须是
    /// 值类型，不能是可能触发 fault 的 @Model。
    private var annotationStates: [String: ChapterAnnotationState] = [:]

    /// 全书标注快照。由 SwiftUI 侧按版本号下发（见 `updateAnnotations`）。
    private var annotationSnapshots: [AnnotationSnapshot] = []

    /// 从笔记列表跳转后待闪烁的标注 id。目标章可能还在加载，
    /// 因此要等到 `showPages` 真正落页后再消费。
    private var pendingAnnotationFocusID: UUID?

    /// 留白/扉页用的背景点击。正文区域内的点按由 `TextRenderView` 自己处理
    /// （它在触摸链里更深，能先于翻页点击识别）。
    private var marginTapGesture: UITapGestureRecognizer?
    /// 选中文本后的系统编辑菜单。
    private var editMenuInteraction: UIEditMenuInteraction?
    /// 当前选中的文本（章节 + 字符区间 + 原文）。
    private var activeSelection: ReaderTextSelection?
    /// 正在拖动的选区属于哪一章。
    ///
    /// 拖动期间只维护共享的 `SelectionState`（画高亮），**不**每次触摸事件都
    /// 去桥接整章文本取原文——选区可能跨十几页，逐字复制会变成 O(n²)。
    /// 原文只在抬手、真正要弹菜单时取一次（见 `handleSelectionLongPress` 的 `.ended`）。
    private var selectionSrc: String?

    /// 正在拖拽选区手柄。
    ///
    /// 这个标志决定菜单退场时要不要清选区：手柄拖动期间菜单只是让位，
    /// 选区必须留着给手柄继续调。
    private var isAdjustingSelection = false

    /// 菜单展示/退场的计数。
    ///
    /// 只用一个 bool 会在"手柄按下 → 菜单退场动画还没结束 → 手柄已经抬起
    /// 并弹出新菜单"时错位：旧菜单的退场回调会把新菜单误判成已关闭。
    /// 用计数判断"此刻是否真的还有菜单在场"。
    private var presentedMenuCount = 0
    private var dismissedMenuCount = 0
    private var isSelectionMenuPresented: Bool {
        presentedMenuCount > dismissedMenuCount
    }

    /// 本次菜单退场是手柄拖动引起的（不能清选区）。
    private var menuDismissedForHandleDrag = false

    /// 手柄抬起后已经排了一次"把菜单放回来"。
    ///
    /// 旧菜单的退场回调可能比新菜单的呈现更早到；这个标志让它在
    /// 0.12s 的空窗里不要恢复翻页手势、也不要把选区清掉。
    private var expectsSelectionMenu = false

    /// 标注交互的上行出口。持久化全部由 SwiftUI 侧的 ViewModel 负责，
    /// 阅读器只负责"选中了什么"与"点了哪一处"。
    var onHighlightSelection: ((ReaderTextSelection, AnnotationStyle, AnnotationColor) -> Void)?
    var onNoteSelection: ((ReaderTextSelection) -> Void)?
    var onAnnotationActivate: ((UUID) -> Void)?
    var onDeleteAnnotation: ((UUID) -> Void)?
    /// 点击纸面（未命中标注）时切换阅读控件。替代原先 SwiftUI 层的
    /// `.simultaneousGesture(TapGesture())`，让"点标注"与"点背景"只有一个决策点。
    var onBackgroundTap: (() -> Void)?

    /// 待执行的设置重排任务（用于合并连续变更）
    private var settingsReloadWork: DispatchWorkItem?
    private static let settingsReloadDelay: TimeInterval = 0.35

    /// 待执行的尺寸变化重排任务（旋转 / 分栏拖动期间合并成一次，见
    /// `scheduleRepaginationForSizeChange`）。
    private var resizeWork: DispatchWorkItem?
    /// 略长于一帧：让同一次旋转里的多次 `viewDidLayoutSubviews` 全部落到
    /// 同一个 work item 上，又不至于让读者等得到重排。
    private static let resizeSettleDelay: TimeInterval = 0.12

    // MARK: - Init

    init(modelContext: ModelContext, epubBaseURL: URL, bookKey: String, allSrcs: [String], titleBySrc: [String: String], bookTitle: String, bookAuthor: String, coverImageURL: URL?, isRegular: Bool) {
        self.modelContext = modelContext
        self.epubBaseURL  = epubBaseURL
        self.bookKey      = bookKey
        self.allSrcs      = allSrcs
        self.titleBySrc   = titleBySrc
        self.bookTitle    = bookTitle
        self.bookAuthor   = bookAuthor
        self.coverImageURL = coverImageURL
        self.isRegular = isRegular
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Pagination Geometry

    private func effectivePageSize() -> CGSize {
        CGSize(
            width: isRegular ? view.bounds.width * 0.5 : view.bounds.width,
            height: view.bounds.height
        )
    }

    private func pageSizeChanged(from oldSize: CGSize, to newSize: CGSize) -> Bool {
        abs(oldSize.width - newSize.width) > 0.5
            || abs(oldSize.height - newSize.height) > 0.5
    }

    /// 使当前分页会话失效，并丢弃旧请求的 completion。
    ///
    /// `PaginationCache` 的 key 会隔离排版配置，但 `pageCache` 存的是已经
    /// 构造好的 UIViewController；如果只清 pageCache 而不切换 generation，
    /// 晚到的旧任务仍可能把旧字体/旧版心的页面重新塞回来。
    /// - Parameter resetBookIndex: 是否连全书页数索引一起作废。
    ///   尺寸/排版变了必须作废（页数全错）；只改了页码格式、标题位置这类
    ///   与分页无关的设置时传 false，省掉一次整书重排。
    private func invalidatePagination(rebuildPageController: Bool, resetBookIndex: Bool = true) {
        // 必须在 pageCache / vcIndexMap 被清空**之前**抓锚点：之后可见页就
        // 找不到自己的位置了。重排完成后 `reloadPages` 会消费它。
        captureRepaginationAnchor()

        paginationGeneration = UUID()

        if resetBookIndex {
            pageCountIndexGeneration = UUID()
            pageCountIndexWork?.cancel()
            pageCountIndexWork = nil
        }

        // 旧请求回调不再有接收者；新的同 src 请求可以立即启动。
        loadingChapters.removeAll()
        chapterLoadCompletions.removeAll()
        pageCache.removeAll()
        vcIndexMap.removeAll()
        if resetBookIndex {
            pageCountBySrc.removeAll()
            totalBookPageCount = nil
        }
        isTurningPage = false

        if rebuildPageController {
            rebuildPageVC()
        }
    }

    /// 记下当前可见页的字符锚点。不可锚定的页（扉页 / 空白页 / 尚未上屏）
    /// 没有可恢复的正文位置，清空旧锚点、让 reload 回退到 PageProgress。
    private func captureRepaginationAnchor() {
        guard pageSize != .zero,
              let location = visibleLocation(),
              location.isAnchorable
        else {
            repaginationAnchor = nil
            return
        }
        repaginationAnchor = (location.src, location.pageStartOffset)
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        setupPageVC()
        pageCache.onEvict = { [weak self] _, vcs in
            for vc in vcs { self?.vcIndexMap.removeValue(forKey: ObjectIdentifier(vc)) }
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSettingsChanged),
            name: .appSettingsDidChange,
            object: nil
        )

        // 「降低动态效果」是系统级开关，不经过 AppSettings，因此不会触发
        // .appSettingsDidChange。读者在阅读途中去系统设置里打开它再切回来，
        // 卷曲必须当场换成滑动——否则这条无障碍支持只有在下次冷启动才生效，
        // 等于没做。
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleReduceMotionChanged),
            name: UIAccessibility.reduceMotionStatusDidChangeNotification,
            object: nil
        )

        // 音量键翻页。挂载点是 self.view 而不是 pageVC.view：
        // 后者在字号/横竖排切换时会被 rebuildPageVC 整体拆掉重建，
        // 挂在上面的话每改一次排版，音量键就悄悄失效一次。
        volumeKeyPager.onTurn = { [weak self] direction in
            self?.turnPage(forward: direction == .next)
        }
        // 这里只挂 host（赋一个弱引用，纳秒级），**不开**开关。
        // 开关在 viewDidAppear 里才置位——见 `activateVolumeKeyPagerIfNeeded`。
        volumeKeyPager.attach(to: view)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        let size = effectivePageSize()
        guard size.width > 0, size.height > 0 else { return }

        if pageSize == .zero {
            pageSize = size
            scheduleBookPageCountIndexing()
            handleFirstLayout()
            return
        }

        // 旋转、iPad 分栏宽度变化以及窗口 resize 都可能不改变 horizontal
        // size class。分页尺寸必须以真实 bounds 为准，不能只在 size class
        // 切换时更新，否则 TextKit 仍按旧版心分页而 UIView 已经变宽/变高。
        guard pageSizeChanged(from: pageSize, to: size) else { return }
        // **不在这一帧重建**：见 scheduleRepaginationForSizeChange。
        scheduleRepaginationForSizeChange()
    }

    /// 尺寸变化后合并重排分页。
    ///
    /// 为什么不能就地重排：`viewDidLayoutSubviews` 在**一次**旋转里会连着来
    /// 好几次，iPad 分栏拖动时更是每帧一次。每帧都走一次
    /// `invalidatePagination` + `reloadPages()` 意味着：
    /// 1. 每帧都排一次整章 TextKit 排版（新尺寸 = 新 digest = 必然缓存未命中），
    ///    分栏拖动期间后台队列被几十个必然作废的排版任务占满；
    /// 2. 如果连容器一起拆建，新实例会先铺一张**占位空白页**——旋转动画还
    ///    没结束，读者看到的就是一闪白。
    ///
    /// 改为等尺寸稳定（一个动画帧多一点）后只做**一次**，并且**不重建
    /// `UIPageViewController`**：翻页样式、书脊位置、`isDoubleSided` 都没变，
    /// 容器本身按新 bounds 自适应即可。旧页会按新尺寸拉伸一瞬（文字可能暂时
    /// 贴到边缘），新排版就绪后由 `reloadPages` 整页替换——Apple Books 在
    /// 旋转/分屏时同样是转场结束后才重排，不是逐帧重排，也不会先给一张白页。
    ///
    /// 跨 size class（compact ↔ regular）是例外：书脊要从 `.min` 切到 `.mid`
    /// 或反过来，那条路仍由 `updateHorizontalSizeClass` 重建容器。
    private func scheduleRepaginationForSizeChange() {
        resizeWork?.cancel()

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.resizeWork = nil
            let size = self.effectivePageSize()
            guard size.width > 0, size.height > 0,
                  self.pageSizeChanged(from: self.pageSize, to: size) else { return }
            self.pageSize = size
            self.invalidatePagination(rebuildPageController: false)
            self.reloadPages()
            self.scheduleBookPageCountIndexing()
        }
        resizeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.resizeSettleDelay, execute: work)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        syncPageVCDoubleSided()
        activateVolumeKeyPagerIfNeeded()
    }

    /// 真正打开音量键翻页。只在首次 `viewDidAppear` 之后跑一次。
    ///
    /// 为什么推迟：`VolumeKeyPager.start()` 会在**主线程同步**做完一串重活——
    /// `AVAudioSession.setCategory/setActive`、`AVAudioPlayer` 的
    /// `prepareToPlay()`、`MPVolumeView` 加进层级、`layoutIfNeeded()`、
    /// 再递归遍历层级找内部滑块。放在 `viewDidLoad` 里做，等于让这一串
    /// 正好撞上首屏建页面的那一帧（根因 A 已把 UIKit 层级构造也压到同一段
    /// 转场之后，两者叠加）。
    ///
    /// 幂等有两道门：`isEnabled` 的 `didSet` 里有 `guard isEnabled != oldValue`，
    /// 重复赋同值根本不会走到 `start()`；即便走到，`start()` 自身的
    /// `guard !isRunning` 也会挡住。所以 `viewDidAppear` 后续再进不会重启。
    /// 挂载 host 仍在 `viewDidLoad` 完成，因此这里置位时 host 已就绪。
    private func activateVolumeKeyPagerIfNeeded() {
        volumeKeyPager.isEnabled = cachedSettings?.volumeKeysTurn ?? false
        // 诊断：音量键只能在真机上验（模拟器按不了），这条打印用来确认
        // "设置里的开关到底有没有传到阅读器"。排查完可以删掉。
        print("🔊 音量键翻页开关：\(volumeKeyPager.isEnabled ? "开" : "关")")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        settingsReloadWork?.cancel()
        resizeWork?.cancel()
        pageCountIndexWork?.cancel()
    }

    // MARK: - External Interface

    /// 阅读器是否已经把这个 src 当作"当前章"。
    ///
    /// 只用于让 SwiftUI 侧分辨「这条位置变更是不是我已经做完的那一次」——
    /// 手势翻页跨章后，`onChapterChange` 会让 `currentSrc` 回流一次，
    /// 那不是一次新的跳转意图。见 `updateUIViewController` 的调用点。
    func isDisplaying(src: String) -> Bool { currentSrc == src }

    func updateAllSrcs(_ srcs: [String]) {
        guard srcs != allSrcs else { return }
        allSrcs = srcs
        frontMatterSrc = nil
        pageCountBySrc.removeAll()
        totalBookPageCount = nil

        if pageSize != .zero, !currentSrc.isEmpty {
            // 目录结构真的变了（正常只在首次打开解析完成时发生一次）：
            // 旧页面数组与页码闭包都基于旧 src 序列，不能继续上屏。
            // 复用统一作废/重载路径，不在两处各拼一套换代逻辑。
            invalidatePagination(rebuildPageController: false)
            reloadPages()
        }
        scheduleBookPageCountIndexing()
    }

    func updateTitleBySrc(_ titles: [String: String]) {
        guard titles != titleBySrc else { return }
        titleBySrc = titles
    }

    func updateHorizontalSizeClass(isRegular: Bool) {
        guard self.isRegular != isRegular else { return }
        self.isRegular = isRegular

        guard pageSize != .zero else {
            // 容器已经建好但还没拿到首屏尺寸：样式/书脊是按旧尺寸类定的，
            // 等第一屏尺寸就绪再重建（见 handleFirstLayout）。
            if pageVC != nil {
                needsPageVCReconfiguration = true
            }
            return
        }
        let size = effectivePageSize()
        guard size.width > 0, size.height > 0 else { return }
        // 这里已经立刻按新尺寸重排了，排队中的尺寸合并任务作废。
        resizeWork?.cancel()
        resizeWork = nil
        pageSize = size
        PaginationCache.shared.invalidateAll()
        invalidatePagination(rebuildPageController: true)
        // 与 applySettingsChange 同序：当前页先重排上屏，全书索引延后。
        reloadPages()
        scheduleBookPageCountIndexing()
        // 跨页选中现在 iPhone / iPad 都支持。compact → regular 时补装手势
        // （viewDidLoad 那一刻如果尺寸类未就绪，这个手势可能还没装）。
        setupSelectionGesture()
    }

    func navigateToSrc(_ src: String, resumeProgress: Bool = true) {
        guard !src.isEmpty else { return }

        let previousSrc = currentSrc
        if src == currentSrc {
            guard !resumeProgress else { return }
        } else {
            currentSrc = src
        }

        // 新的导航意图优先于上一次重排留下的字符锚点。
        repaginationAnchor = nil

        guard pageSize != .zero else {
            pendingSrc = src
            pendingResumeProgress = resumeProgress
            pendingCharacterOffset = nil
            pendingAnchorID = nil
            return
        }

        // 章间跳转的翻页方向按目录次序推导：跳到靠后的章播放"向前翻"，
        // 跳到靠前的章播放"向后翻"。此前固定 .forward——从第 20 章跳回
        // 第 2 章也播下一页动画，读者会以为方向判错了。
        //
        // 方向以**屏幕上的那一章**为准，而不是 `currentSrc`：连续两次跳转时
        // `currentSrc` 可能已经指向一个还在加载的章，拿它当起点会把方向算反。
        //
        // 同章目录跳转的目标是正文首屏（前置页章节还要跳过合成扉页），
        // `.scroll` 下必须按"当前页 → 目标页"的真实先后决定滑动方向，
        // 否则从第 N 页回章首会朝"下一页"方向滑过去。
        let sameChapterStart: Int? = {
            guard src == previousSrc, !resumeProgress,
                  let pages = pageCache.get(src), !pages.isEmpty
            else { return nil }
            return chapterStartIndex(for: pages)
        }()
        let direction = navigationDirection(to: src, targetArrayIndex: sameChapterStart)

        if pageCache.contains(src) {
            guard showPages(of: src, animated: true, resumeProgress: resumeProgress, direction: direction) else {
                // 缓存里存着空页数组（损坏的磁盘缓存 / 空章）：屏幕没有换，
                // 位置也不能留在目标章，否则目录高亮与屏幕脱钩（见 revertNavigation）。
                revertNavigation(to: previousSrc)
                return
            }
            prefetchWindow(center: src)
        } else {
            loadChapterAsync(src: src, priority: .userInitiated) { [weak self] success in
                guard let self, self.currentSrc == src else { return }
                guard success else {
                    self.revertNavigation(to: previousSrc)
                    return
                }
                guard self.showPages(
                    of: src,
                    animated: false,
                    resumeProgress: resumeProgress,
                    direction: direction
                ) else {
                    self.revertNavigation(to: previousSrc)
                    return
                }
                self.prefetchWindow(center: src)
            }
        }
    }

    /// 章节打不开（文件缺失 / 解析不出任何段落 / 空章）时，把位置退回**屏幕
    /// 上真正显示着的那一章**。
    ///
    /// `currentSrc` 是"请求到的章"，它在加载开始前就改了；如果失败后不回退，
    /// 会留下一个自锁的死角：
    /// - 屏幕上还是旧页，但 `currentSrc` 已经指向打不开的章；
    /// - 目录高亮、`markSubChapterRead`、`lastReadSrc` 全部记在那一章上；
    /// - 再点同一章不会再触发跳转（协调器的 `lastSrc` 已经等于它了），
    ///   读者只能靠翻页或退出重进才出得来。
    ///
    /// 回退**不主动重排**：屏幕本来就停在那一章时只需把状态对齐。上层的
    /// `@Published` 不能在当前事务里改（本方法可能从
    /// `updateUIViewController` 的调用栈里进来），挪到下一个 turn。
    /// 只有一种例外要补页：重排刚清空缓存、屏幕上只剩占位空白页时，
    /// 光对齐状态会让读者永远停在白页上。
    ///
    /// 目标章优先取**屏幕上真正显示的那一章**，调用方给的 `fallbackSrc` 只
    /// 在没有可见页时兜底。原因：读者连续点两个目录项时，第二次调用拿到的
    /// `previousSrc` 可能只是"上一次请求的章"（它从未上屏），按它回退会让
    /// `currentSrc`、目录高亮和屏幕三者再次错位。
    private func revertNavigation(to fallbackSrc: String) {
        // 跳转没成功：聚焦请求也不能留到下一次无关导航再闪。
        pendingAnnotationFocusID = nil
        let onScreenSrc = visibleFrontController.flatMap { findLocation(of: $0)?.src }
        let target = onScreenSrc ?? fallbackSrc
        guard !target.isEmpty, target != currentSrc else { return }
        currentSrc = target

        // 正常情况下屏幕本来就停在 target 上，只需对齐 currentSrc。
        // 但如果重排刚把 pageCache / vcIndexMap 清空、屏幕上只剩占位空白页，
        // 只改状态会让读者永远停在白页上——这时必须把 target 的页重新铺回去。
        // 优先用已缓存的分页，没有再走完整加载。
        if onScreenSrc != target, pageSize != .zero {
            if !showPages(of: target, animated: false) {
                reloadPages()
            }
        }

        DispatchQueue.main.async { [weak self] in
            guard let self, self.currentSrc == target else { return }
            self.onChapterChange?(target)
        }
    }

    /// 统一跳转入口。
    ///
    /// - 两个锚点都为 nil：章节首屏（目录项只指到文件时的既有语义，
    ///   恢复页位置在这里被显式关掉）。
    /// - `characterOffset` 有值：跳到本章包含该字符的那一页（书签）。
    /// - `anchorID` 有值：把 EPUB 的 `#fragment` 解析成本章字符偏移再落页
    ///   （目录里指向小节的那些项）；解析不到退回章首。
    func navigateTo(src: String, anchorID: String?, characterOffset: Int?) {
        guard !src.isEmpty else { return }
        // 两个锚点都没有 = 目录项只指到文件：从章首开始（既有语义）。
        guard characterOffset != nil || anchorID != nil else {
            navigateToSrc(src, resumeProgress: false)
            return
        }
        jumpTo(src: src, anchorID: anchorID, characterOffset: characterOffset)
    }

    /// 按字符锚点或目录锚点跳到某一页。
    ///
    /// 页码不参与传输：`ChapterLayout` 的当前分页结果才是唯一真值。
    /// 解析失败（章节文本换了版本、偏移越界、fragment 对不上 id）时退回章首——
    /// 比停在原地好，也与"目录项只指到文件"的既有语义一致。
    private func jumpTo(src: String, anchorID: String?, characterOffset: Int?) {
        // 书签锚点本身就是这次跳转的目标，重排锚点不应再盖过它。
        repaginationAnchor = nil
        let previousSrc = currentSrc
        currentSrc = src

        guard pageSize != .zero else {
            // 首屏布局尚未完成（正常交互下到不了这里）：记下意图，由
            // `handleFirstLayout` 在尺寸就绪后补跳，别把锚点丢掉。
            pendingSrc = src
            pendingResumeProgress = false
            pendingCharacterOffset = characterOffset
            pendingAnchorID = anchorID
            return
        }

        let perform: () -> Void = { [weak self] in
            guard let self, self.currentSrc == src else { return }
            guard let pages = self.pageCache.get(src), !pages.isEmpty else {
                // 章存在但没有一页（空章 / 全是解析不出内容的标签）：
                // 停在原地比停在一个没有页的章上好，位置退回上屏那一章。
                self.revertNavigation(to: previousSrc)
                return
            }

            let textPage = pages
                .lazy
                .compactMap { $0 as? TextViewControllerTest }
                .first
            // 偏移优先（书签）；否则把目录锚点解成本章**当前**排版下的字符偏移。
            // 锚点解析不到时 `layoutPage` 为 nil，走下面"退回本章正文首页"的
            // 分支——与本次改动之前的行为完全一致，不会跳错位置。
            let resolvedOffset: Int? = {
                if let characterOffset { return characterOffset }
                guard let anchorID else { return nil }
                return textPage?.characterOffset(forAnchor: anchorID)
            }()
            let layoutPage = resolvedOffset.flatMap {
                textPage?.pageIndex(forCharacterOffset: $0)
            }

            guard let layoutPage else {
                // 锚点在当前排版里解析不出来：退回本章正文首页。
                // 仍然要检查落页是否真的发生——空页数组会让 showPages 直接返回，
                // 不检查就会留下「屏幕停在旧章、currentSrc 指向新章」的死角。
                guard self.showPages(of: src, animated: true, resumeProgress: false) else {
                    self.revertNavigation(to: previousSrc)
                    return
                }
                self.prefetchWindow(center: src)
                return
            }

            // 前置页章节的页面数组前面多一张扉页，layout 页下标要换算成数组下标。
            //
            // 覆盖页是否真的存在要以**这次拿到的页面数组**为准，不能只看
            // `frontMatterSrc`：索引在章节加载之后才判定前置页时，旧缓存里的
            // 数组可能还没有扉页，按 +1 换算会把书签落到后一页。
            let arrayIndex = ChapterPageSequence.arrayIndex(
                forLayoutPage: layoutPage,
                hasCoverPage: pages.first is CoverPageViewController
            )
            // 往回跳书签要反着翻：同一章里从后页跳到前页却播放"向前翻"的动画，
            // 会让读者以为位置算错了。跨章同样按目录次序判方向，不能一律
            // `.forward`（从后面的一章跳回前面的章时方向会反）。
            let isBackward = self.isBackwardJump(to: src, targetArrayIndex: arrayIndex)
            // 书签跳转是明确的"我要读这里"，落页即记位置：读者紧接着退出，
            // 下次打开也该回到这一页。写回由 showPages 统一负责（见其注释），
            // 这里不再重复保存。
            guard self.showPages(
                of: src,
                animated: true,
                resumeProgress: false,
                explicitArrayIndex: arrayIndex,
                direction: isBackward ? .reverse : .forward
            ) else {
                self.revertNavigation(to: previousSrc)
                return
            }
            self.prefetchWindow(center: src)
        }

        if pageCache.contains(src) {
            perform()
        } else {
            loadChapterAsync(src: src, priority: .userInitiated) { [weak self] success in
                guard let self, self.currentSrc == src else { return }
                guard success else {
                    self.revertNavigation(to: previousSrc)
                    return
                }
                perform()
            }
        }
    }

    // MARK: - First Layout Deferred Navigation

    private func handleFirstLayout() {
        // 首屏尺寸已经就绪。若此前 size class 改过，此时才具备重建条件：
        // `pageSize` 已按新的 isRegular 算好，`setupPageVC` 也才能选对样式/书脊。
        if needsPageVCReconfiguration {
            needsPageVCReconfiguration = false
            invalidatePagination(rebuildPageController: true)
        }

        let target = pendingSrc.isEmpty ? currentSrc : pendingSrc
        let shouldResumeProgress = pendingSrc.isEmpty ? true : pendingResumeProgress
        let targetOffset = pendingCharacterOffset
        let targetAnchor = pendingAnchorID
        pendingSrc = ""
        pendingResumeProgress = true
        pendingCharacterOffset = nil
        pendingAnchorID = nil
        guard !target.isEmpty else { return }
        currentSrc = target

        // 首屏前被拦下的书签 / 目录跳转：此刻 `pageSize` 已就绪，直接按锚点补跳。
        if targetOffset != nil || targetAnchor != nil {
            jumpTo(src: target, anchorID: targetAnchor, characterOffset: targetOffset)
            return
        }

        if pageCache.contains(target) {
            showPages(of: target, animated: false, resumeProgress: shouldResumeProgress)
            prefetchWindow(center: target)
        } else {
            loadChapterAsync(src: target, priority: .userInitiated) { [weak self] success in
                guard let self, success, self.currentSrc == target else { return }
                self.showPages(of: target, animated: false, resumeProgress: shouldResumeProgress)
                self.prefetchWindow(center: target)
            }
        }
    }

    // MARK: - Show Pages

    /// 用已加载好的页面数组把当前章摆上屏。
    ///
    /// `resumeProgress=false` 用于目录跳转：即使该章有保存页码，也要从
    /// 章节首屏开始；这是目录点击的明确意图，不是恢复位置。
    ///
    /// `explicitArrayIndex` 优先级最高（书签跳转）：它是按字符锚点在本章
    /// **当前**排版上解析出来的数组下标，既不该被保存页码覆盖，也不受
    /// `resumeProgress` 影响。
    ///
    /// `resumeCharacterOffset` 用于重排后恢复位置：旧页号在新排版里会指向
    /// 另一段文字，而"这一页从哪个字开始"不会随字号/尺寸漂移。
    ///
    /// - Returns: 是否真的把目标页交给了 `UIPageViewController`。
    ///   false 只出现在目标章节的页面数组为空时（损坏缓存 / 空章）：此时
    ///   屏幕没有变化，调用方必须把 `currentSrc` 退回屏幕上那一章，不能
    ///   留下「位置在新章、画面在旧章」的错位。
    @discardableResult
    private func showPages(
        of src: String,
        animated: Bool,
        resumeProgress: Bool = true,
        explicitArrayIndex: Int? = nil,
        resumeCharacterOffset: Int? = nil,
        direction: UIPageViewController.NavigationDirection = .forward
    ) -> Bool {
        guard let pages = pageCache.get(src), !pages.isEmpty else { return false }

        // 目录点击的「章节首屏」是正文首屏，不是阅读器合成的那张扉页。
        // 前置页章节的数组是 [扉页, 版权页...]，从 0 起会落在扉页上，
        // 读者点了目录里的「版权申明」却看到一张封面，会以为跳转失败。
        //
        // 是否真的有扉页以本次页面数组为准（见 jumpTo 的同类说明）。
        let firstContentIndex = chapterStartIndex(for: pages)

        // 字符锚点 → 新排版的数组下标。`ChapterLayout` 的当前 container
        // 分布才是唯一真值；越界时它会把偏移夹到末页。
        let anchoredIndex: Int? = {
            guard let resumeCharacterOffset,
                  let layoutPage = pages
                      .lazy
                      .compactMap({ $0 as? TextViewControllerTest })
                      .first?
                      .pageIndex(forCharacterOffset: resumeCharacterOffset)
            else { return nil }
            return ChapterPageSequence.arrayIndex(
                forLayoutPage: layoutPage,
                hasCoverPage: pages.first is CoverPageViewController
            )
        }()

        let saved = explicitArrayIndex
            ?? anchoredIndex
            ?? (resumeProgress ? loadPageProgress(src: src) : firstContentIndex)

        // 真正摆上屏的页面数组下标（双页模式是 spread 左页）。落页后要写回
        // PageProgress——见下方 savePageProgress 处的说明。
        let shownIndex: Int
        if isRegular {
            let leftIndex = ChapterPageSequence.spreadLeftIndex(for: saved, pageCount: pages.count)
                ?? min(saved, pages.count - 1)
            // 负索引兜底：`spreadLeftIndex` 对负数返回 nil，若这里只做上限
            // 裁剪，损坏/迁移失败的 PageProgress 会让 `pages[-1]` 直接崩。
            let safeLeft  = min(max(0, leftIndex), pages.count - 1)
            shownIndex = safeLeft
            // 偏移末 spread（如 [3,4]）的页数差 1，这里仍需要补一张空白右页。
            let rightVC = safeLeft + 1 < pages.count ? pages[safeLeft + 1] : makeClearVC()
            // 双页模式下 pageCurl 只对「起止 spread 相邻」的动画有定义。
            // 书签/目录跳转常跨章或跨多个 spread，对非相邻目标播动画会停在
            // 只铺好左页的状态——右半屏露底（2026-10-17 实机报告：iPad 点
            // 书签跳转后右半屏白屏）。相邻才翻，其余瞬切。
            let animation: ChapterPageSequence.JumpAnimation
            if let current = currentVisibleSpread() {
                animation = ChapterPageSequence.spreadJumpAnimation(
                    currentSrc: current.src, currentLeft: current.left, currentPageCount: current.pageCount,
                    targetSrc: src, targetLeft: safeLeft, targetPageCount: pages.count,
                    orderedSources: allSrcs
                )
            } else {
                animation = .none
            }
            let animatedJump = animated && animation != .none
            let jumpDirection: UIPageViewController.NavigationDirection
            switch animation {
            case .forward: jumpDirection = .forward
            case .reverse: jumpDirection = .reverse
            case .none:    jumpDirection = direction   // 不动画时方向不参与呈现
            }
            pageVC.setViewControllers(
                pageControllers(front: pages[safeLeft], right: rightVC, animated: animatedJump),
                direction: jumpDirection,
                animated: animatedJump,
                completion: nil
            )
        } else {
            let safeIndex = min(max(0, saved), pages.count - 1)
            shownIndex = safeIndex

            // 单页卷曲（iPhone 的 .min + isDoubleSided）与 iPad 双页同理：
            // 一次合法的页张翻转只发生在 data source 链上相邻的两页之间。
            // 目录/书签的远距离跳转若仍传 `animated: true`，UIKit 会按一次
            // 页张翻转换算，结果可能是方向反了、停在纸背、或只翻一半——
            // 背景与正文都可能露空。非相邻目标一律瞬切；单页卷曲以外的
            // 翻页样式（.scroll）没有这条约束，保持调用方意图。
            var turnAnimated = animated
            var turnDirection = direction
            if animated, usesSheetBacks {
                if let current = currentVisiblePage() {
                    switch ChapterPageSequence.singlePageJumpAnimation(
                        currentSrc: current.src,
                        currentIndex: current.index,
                        currentPageCount: current.pageCount,
                        targetSrc: src,
                        targetIndex: safeIndex,
                        targetPageCount: pages.count,
                        orderedSources: allSrcs
                    ) {
                    case .forward: turnDirection = .forward
                    case .reverse: turnDirection = .reverse
                    case .none:    turnAnimated = false
                    }
                } else {
                    // 当前页不可定位（首屏占位 / 空白页 / 刚重建完）：
                    // 没有可靠的起止对，不能把转场交给未定义行为。
                    turnAnimated = false
                }
            }

            // 动画落页要带背面、瞬切只要正面，两条口径都收在 pageControllers 里。
            pageVC.setViewControllers(
                pageControllers(front: pages[safeIndex], right: nil, animated: turnAnimated),
                direction: turnDirection,
                animated: turnAnimated,
                completion: nil
            )
        }

       // 当前上屏章必须固定在 pageCache：预取/旧加载的晚到 put 不能把它挤出
       // 容量。否则 VC 还在屏幕上，`vcIndexMap` 却被 onEvict 删掉，所有翻页
       // 输入与位置上报会静默失效（见 ChapterLRUCache.pinned）。
       pageCache.pinOnly(src)

       // 页面已经落位，音量键的翻页闩锁在这里无条件复位。
       //
       // `showPages` 是"页面终于摆好了"的权威入口（加载完成、旋转重排、
       // 设置重排、目录/书签跳转都走它）。若一次音量键翻页动画被这里新的
       // `setViewControllers` 打断，UIKit 未必回调上一个 completion——闩锁
       // 就会永远停在 true，音量键从此完全无响应（且没有任何日志）。
       isTurningPage = false

       // 落页即写回进度。
       //
       // 目录跳转（resumeProgress=false）此前**不**落盘：该章的保存页还停在
       // 上次阅读的位置，此后任何一次重建——旋转（viewDidLayoutSubviews →
       // reloadPages、spineLocationFor）、改字号（applySettingsChange）、
       // 切尺寸类（updateHorizontalSizeClass）——都按 loadPageProgress
       // 还原旧页，读者刚在目录里选的位置被悄悄拽回去。
       // 书签跳转（explicitArrayIndex）同理，落页就是"我要读这里"。
       //
       // 手势翻页不走这里（didFinishAnimating 自己保存），故不存在重复写。
       savePageProgress(
           src: src,
           pageIndex: displayProgressIndex(for: shownIndex, pageCount: pages.count)
       )

        // 内容真的上屏了 → 开闸放行全书页码索引（见 scheduleBookPageCountIndexing）。
        // 放在 setViewControllers 之后：此刻读者看到的是纸面，而 CPU 已空出来。
        markFirstPageShown()
        reportVisibleLocation()
        // 从笔记列表跳转过来时，目标页现在才真正上屏：此刻闪一下。
        consumePendingAnnotationFocusIfPossible()
        return true
    }

    // MARK: - Settings Change

    @objc private func handleSettingsChanged() {
        scheduleSettingsReload()
    }

    /// 系统「降低动态效果」开关翻转（见 `PageTurnStyleResolver` 第二条规则）。
    ///
    /// 走与设置变更同一条作废/重建序列，不自己拼一套：`invalidatePagination`
    /// 负责换代次、清缓存、清闩锁，`rebuildPageVC` 换容器，`reloadPages`
    /// 把当前页重新铺上去。少任何一步都会留下"旧代次的页面写回新容器"的缝。
    ///
    /// `resetBookIndex: false`——翻页样式不影响分页结果，全书页数索引仍然有效，
    /// 不该让读者为一个无障碍开关等一次整书重排。
    @objc private func handleReduceMotionChanged() {
        guard pageVC != nil else { return }
        guard resolvedTurnStyle() != appliedTurnStyle else { return }
        invalidatePagination(rebuildPageController: true, resetBookIndex: false)
        reloadPages()
    }

    /// 合并连续的设置变更，只执行最后一次重排。
    ///
    /// 字号/行距这类滑块一秒能触发几十次变更，而每次重排都要做整章排版 +
    /// 全缓存失效。这里把窗口期内的改动压成一次：连续拖动时不会反复排队。
    private func scheduleSettingsReload() {
        settingsReloadWork?.cancel()

        let work = DispatchWorkItem { [weak self] in
            self?.settingsReloadWork = nil
            self?.applySettingsChange()
        }
        settingsReloadWork = work

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settingsReloadDelay, execute: work)
    }

    private func applySettingsChange() {
        // 先把**旧**排版摘要算出来，再丢缓存——用于判断这批变更到底有没有
        // 动到排版。`PaginationConfig.stableDigest` 覆盖了全部影响分页的字段
        // （页尺寸/字号/字体/行距/段距/缩进/字距/四边距/墨色/内容模型版本）。
        let previousDigest = _cachedSettings.map {
            PaginationConfig($0, pageSize: pageSize).stableDigest
        }

        // 缓存延后到这里才清：合并窗口内若别处发起加载，读到的仍是有效布局，
        // 不会撞上"已清一半、还没重建"的状态
        _cachedSettings = nil

        let layoutChanged: Bool = {
            guard let previousDigest, let settings = cachedSettings else { return true }
            return PaginationConfig(settings, pageSize: pageSize).stableDigest != previousDigest
        }()

        if layoutChanged {
            PaginationCache.shared.invalidateAll()
        }

        // 翻页样式：**刻意不进 `PaginationConfig.stableDigest`**。它不影响
        // 分页结果，混进摘要会让"切一次翻页方式"顺带删光整个书库的磁盘分页
        // 缓存，并触发一次全书重排。但它是 `UIPageViewController` 的 init 参数，
        // 运行期改不了——只能整只换容器，所以单独检测、复用下面那次重建。
        let turnStyleChanged = resolvedTurnStyle() != appliedTurnStyle

        // 排版没变时（只改了页码/标题显示、触觉、音量键这类）：
        // **不**清分页缓存、**不**丢全书页数索引。此前一律全清，等于读者
        // 在设置里拨一下「显示页码」，整个书库的磁盘分页缓存被后台删光、
        // 当前书还要重排一遍全书才能把页码补回来。
        invalidatePagination(rebuildPageController: turnStyleChanged, resetBookIndex: layoutChanged)
        // 只换纸面时 `pageVC` 不一定重建（翻页样式没变），但它的容器底色
        // 是 setup 那一刻写死的旧纸色：`.scroll` 回弹 / 卷曲转场期间露出来
        // 的就是这一层，不刷新会在新纸面边缘留一道旧色的边。
        applyCurrentPaperToContainers()
        // 排在 reloadPages() 之后：读者的当前页要先重排上屏，全书索引再在
        // 合并窗口之后补跑（改字号这类操作会连着触发好几次，不合并就是几次全书重排）。
        // 即使排版没变也要重建页面 VC——纸面、页码格式、标题位置都在 VC 里。
        reloadPages()
        if layoutChanged {
            scheduleBookPageCountIndexing()
        }

        // 音量键翻页开关可能就在这一批变更里。它只影响按键响应，与排版无关，
        // 但这里已经拿到了刷新后的设置，顺手同步一下，省得再挂一个观察者。
        volumeKeyPager.isEnabled = cachedSettings?.volumeKeysTurn ?? false
    }

    func reloadPages() {
        pageCache.removeAll()
        vcIndexMap.removeAll()

        // 锚点只服务这一次重排，取走后立即清掉，避免下一次无关的 reload
        // 把旧位置套到新内容上。
        let anchor = repaginationAnchor
        repaginationAnchor = nil

        guard !currentSrc.isEmpty, pageSize != .zero else { return }
        let src = currentSrc
        let characterOffset = (anchor?.src == src) ? anchor?.characterOffset : nil
        loadChapterAsync(src: src, priority: .userInitiated) { [weak self] success in
            guard let self, success, self.currentSrc == src else { return }
            guard self.showPages(
                of: src,
                animated: false,
                resumeCharacterOffset: characterOffset
            ) else { return }
            // 重排把整章缓存清空后，邻章也必须重新预取。否则读者读到章末时
            // 下一章恰好不在缓存里，dataSource 只能返回 nil —— 那一次滑动被
            // 「吞掉」（`.scroll` 下尤其明显），要再滑一次才过章。
            self.prefetchWindow(center: src)
        }
    }

    // MARK: - Async Chapter Loading

    private func loadChapterAsync(
        src: String,
        priority: DispatchQoS.QoSClass = .userInitiated,
        completion: ((Bool) -> Void)? = nil
    ) {
        if pageCache.contains(src) { completion?(true); return }
        if loadingChapters.contains(src) {
            if let completion {
                chapterLoadCompletions[src, default: []].append(completion)
            }
            return
        }

        guard let settings = cachedSettings else {
            print("❌ Cannot load AppSettings"); completion?(false); return
        }
        guard pageSize != .zero else {
            print("⚠️ pageSize not ready, deferring \(src)"); completion?(false); return
        }

        let config = PaginationConfig(settings, pageSize: pageSize)
        // 键三要素：书籍身份 + 章相对路径 + 排版稳定摘要。缺书籍维度会跨书串内容（P0-A），
        // 用 hashValue 做摘要跨启动永不命中（P0-B）——两者都是踩过的坑，别再换回去。
        let key    = PaginationKey(bookKey: bookKey, src: src, configDigest: config.stableDigest)

        // 这次异步加载的分页会话代号。设置/尺寸变化会让旧代号整体作废，
        // 晚到的旧结果即便完成，也不会用旧字体旧版心盖住新上屏的页面。
        let generation = paginationGeneration

        let fileURL  = epubBaseURL.appendingPathComponent(src)
        loadingChapters.insert(src)
        if let completion {
            chapterLoadCompletions[src, default: []].append(completion)
        }

        // Check cache (memory + disk)
        //
        // 走异步入口：命中磁盘缓存时 `load` 内部要做「读文件 → JSON 解码 →
        // NSKeyedUnarchiver 解档 → 重建整章 ChapterLayout 排版」，全是很重的活。
        // 原先这里是主线程同步调用，缓存命中反而比重排还慢——
        // 翻回刚读过的书会明显卡一下，而"刚读过的书"恰恰是最常见的翻页方向。
        //
        // `loadingChapters` 已在上面登记，因此这里的异步不会与并发加载重复：
        // 期间到达的同 src 请求会挂到 `chapterLoadCompletions` 上等结果。
        PaginationCache.shared.loadAsync(
            key: key,
            usableSize: config.usableSize
        ) { [weak self] cached in
            guard let self else { return }
            guard self.paginationGeneration == generation else {
                // 旧会话晚到：**什么都不做，直接退出**。
                //
                // 这里曾经调 `finishChapterLoad(src:success:false)`，那是个
                // 会传染的错：它清的是 `loadingChapters` / `chapterLoadCompletions`
                // 这两张**按 src 索引、与代次无关**的表。而 `invalidatePagination`
                // 早已把它们清空、新一轮加载（新代次）也已重新登记了同一个 src。
                // 于是旧代次的收尾把新代次的登记连同 completion 一起摘掉：
                // 新排版结果稍后落地时，`finishChapterLoad` 找不到任何接收者，
                // 没有任何人调 `showPages` —— 屏幕就停在占位页上（旋转/改字号
                // 时表现为白屏），直到读者再翻一页才自愈。
                //
                // 代次不等 ⇒ `invalidatePagination` 一定跑过 ⇒ 那两张表已由它
                // 清空，这里不需要也不应该再碰它们。
                return
            }
            if let cached {
                // 零页缓存（旧版本把超边距/空文本也写进了磁盘）不能当命中：
                // 继续走下去会 put 一个空 VC 数组并报告成功，屏幕永久空白。
                // 当作未命中重新解析，让 ChapterRender 的版心/页数校验兜住。
                guard cached.pageCount > 0 else {
                    print("⚠️ 缓存零页，改走源码重排：\(src)")
                    self.loadChapterFromSource(
                        src: src,
                        fileURL: fileURL,
                        key: key,
                        config: config,
                        settings: settings,
                        generation: generation,
                        priority: priority
                    )
                    return
                }

                // 缓存命中时没有 HTML 可解析，但**不能**把已排版文本当成与
                // 解析路径相同的检测语料：排版路径检测的是 `contentText(blocks)`
                // （剔除全部 heading），而这里拿到的是标题+正文的混合文本。
                // 直接重判会让同一本书出现两种结论——普通章节若带「版权信息」
                // 标题，冷启动第二次就会被误判成前置页，凭空多一张扉页。
                //
                // 页首饰纹只在 `ChapterTypography.copyrightString` 里写入，
                // 也就是说"首行是饰纹"本身就证明了：这份缓存是**上次按前置页
                // 排版**产出的。以它为必要条件，缓存结论就与源码路径当初的
                // 结论对齐；没有饰纹的普通章节不会再被标题关键词带偏。
                var detectText = cached.textStorage.string
                let looksLikeCopyrightLayout: Bool
                if let firstLine = detectText.components(separatedBy: "\n").first,
                   firstLine == ChapterTypography.copyrightOrnamentLine {
                    detectText = String(detectText.dropFirst(firstLine.count + 1))
                    looksLikeCopyrightLayout = true
                } else {
                    looksLikeCopyrightLayout = false
                }
                if self.frontMatterSrc == nil,
                   src == self.allSrcs.first,
                   looksLikeCopyrightLayout {
                    if FrontMatterDetector.isCopyrightPage(
                        text: detectText,
                        chapterTitle: self.titleBySrc[src]
                    ) {
                        self.frontMatterSrc = src
                        print("📕 检测到前置页（扉页+版权页）：\(src)")
                    }
                }
                let isFrontMatter = (src == self.frontMatterSrc)
                // +1 = 扉页（封面/书名/作者），它单独成 VC，不在 layout 页数里
                self.pageCountBySrc[src] = cached.pageCount + (isFrontMatter ? 1 : 0)
                if self.refreshTotalBookPageCount() {
                    self.refreshVisiblePageIndicators()
                }
                let controllers = self.makeControllers(
                    src: src,
                    layout: cached,
                    settings: settings,
                    margins: config.margins
                )
                self.pageCache.put(src, value: controllers)
                print("✅ Cache hit: \(src), \(controllers.count) pages")
                self.finishChapterLoad(src: src, success: true)
                return
            }

            // 未命中 → 走原有的后台解析 + 排版路径。
            self.loadChapterFromSource(
                src: src,
                fileURL: fileURL,
                key: key,
                config: config,
                settings: settings,
                generation: generation,
                priority: priority
            )
        }
    }

    /// 磁盘缓存未命中：在后台读 XHTML、解析、构建富文本、整章排版，然后回主线程装页。
    ///
    /// 从 `loadChapterAsync` 拆出来的原因只有一个：磁盘缓存查询本身也是重 I/O，
    /// 它必须先异步完成，才知道该不该走这条排版路径。
    private func loadChapterFromSource(
        src: String,
        fileURL: URL,
        key: PaginationKey,
        config: PaginationConfig,
        settings: AppSettings,
        generation: UUID,
        priority: DispatchQoS.QoSClass
    ) {
        // `allSrcs` / `titleBySrc` 在**主线程**先取成局部值：后台排版期间
        // 上层可能整体替换这两份数据，跨线程读可变 Array / Dictionary 是
        // 数据竞争。局部捕获同时也让后台闭包不必强持 self（大章节排版期间
        // 阅读器仍能被正常释放）。
        let isFirstChapter = (src == allSrcs.first)
        let chapterTitle = titleBySrc[src]

        DispatchQueue.global(qos: priority).async { [weak self] in
            guard let htmlString = try? String(contentsOf: fileURL, encoding: .utf8) else {
                print("❌ Cannot read EPUB file: \(fileURL.path)")
                DispatchQueue.main.async {
                    // 代次必须在这里再校验一次：读取期间若发生尺寸/设置重排，
                    // invalidatePagination 已换到新代次并重新登记了同一个 src 的
                    // completion。旧代次此时再调 finishChapterLoad，会按 src 把
                    // **新代次**的登记一起摘掉——新排版稍后成功也无人 showPages，
                    // 屏幕就停在占位页/旧章上。
                    guard let self, self.paginationGeneration == generation else { return }
                    self.finishChapterLoad(src: src, success: false)
                }
                return
            }

            // 解析 + 版权页判定 + 排版走唯一入口（章加载与全书索引共用，
            // 防止「索引按普通样式数页、加载按版权样式渲染」的口径漂移）。
            guard let outcome = ChapterRender.outcome(
                htmlString: htmlString,
                config: config,
                imageBase: fileURL.deletingLastPathComponent(),
                isFirstChapter: isFirstChapter,
                chapterTitle: chapterTitle
            ) else {
                print("⚠️ [\(src)] 正文解析结果为空（既非良构也不含可提取块）")
                DispatchQueue.main.async {
                    // 同读取失败分支：旧代次的收尾不能碰新代次的登记表。
                    guard let self, self.paginationGeneration == generation else { return }
                    self.finishChapterLoad(src: src, success: false)
                }
                return
            }

            PaginationCache.shared.save(
                layout: outcome.layout,
                sourceAttributedString: outcome.attributedString,
                for: key
            )

            DispatchQueue.main.async {
                guard let self else { return }
                guard self.paginationGeneration == generation else {
                    // 旧会话的排版结果晚到：不能盖掉新设置/新尺寸的当前页。
                    // 同样**不碰** `finishChapterLoad`——理由见 loadChapterAsync
                    // 里那段注释：那两张表按 src 索引、与代次无关，旧代次去清
                    // 会把新代次正在等的 completion 一起摘掉，页面再也上不了屏。
                    return
                }
                if outcome.frontMatter { self.frontMatterSrc = src }
                // +1 = 扉页，见 makeControllers 的分支
                self.pageCountBySrc[src] = outcome.layout.pageCount + (outcome.frontMatter ? 1 : 0)
                if self.refreshTotalBookPageCount() {
                    self.refreshVisiblePageIndicators()
                }
                let controllers = self.makeControllers(
                    src: src,
                    layout: outcome.layout,
                    settings: settings,
                    margins: config.margins
                )
                self.pageCache.put(src, value: controllers)
                print("✅ Pagination done: \(src), \(controllers.count) pages\(outcome.frontMatter ? "（前置页：扉页+版权页）" : "")")
                self.finishChapterLoad(src: src, success: true)
            }
        }
    }

    private func finishChapterLoad(src: String, success: Bool) {
        loadingChapters.remove(src)
        let completions = chapterLoadCompletions.removeValue(forKey: src) ?? []
        completions.forEach { $0(success) }
    }

    // MARK: - Build Page VCs

    /// Creates TextVCs using ChapterLayout. Each TextVC plugs into the shared
    /// NSTextStorage/NSLayoutManager via its designated NSTextContainer.
    ///
    /// 前置页章节页数组为 [扉页, 版权页0, 版权页1, ...]；data source 的 VC
    /// 下标由 `ChapterPageSequence` 统一处理，页码标签仍使用 layout 本地页码。
    private func makeControllers(
        src: String,
        layout: ChapterLayout,
        settings: AppSettings,
        margins: ReaderMargins
    ) -> [UIViewController] {
        // `margins` 来自本次排版用的 `PaginationConfig` 快照，而不是当前
        // 设置重新算一遍：设置变更的合并窗内两者可能短暂不同，视图按新值、
        // 分页按旧值时正文会被裁掉。视图与分页必须共用同一份有效边距。

        // 前置页：扉页在最前，版权页随后。vcIndexMap 中的 index 一律是
        // `pages` 数组下标，而不是 ChapterLayout 页码；封面页过去没有登记，
        // data source 对它找不到位置就返回 nil，扉页因此成为翻页断点。
        if src == frontMatterSrc {
            let cover = makeCoverViewController(settings: settings, margins: margins)
            vcIndexMap[ObjectIdentifier(cover)] = (src, 0)
            var vcs: [UIViewController] = [cover]
            vcs.append(contentsOf: makeTextControllers(
                src: src,
                layout: layout,
                settings: settings,
                margins: margins,
                chromePlacement: .none,     // 扉页 / 版权页不显示页眉页脚元素
                hasCoverPage: true
            ))
            return vcs
        }
        return makeTextControllers(
            src: src,
            layout: layout,
            settings: settings,
            margins: margins,
            chromePlacement: chromePlacement(for: src, settings: settings)
        )
    }

    /// 扉页（封面 + 书名 + 作者）。纸面/字体跟随当前阅读设置。
    private func makeCoverViewController(
        settings: AppSettings,
        margins: ReaderMargins
    ) -> UIViewController {
        CoverPageViewController(
            background: settings.readingBackground,
            settings: settings,
            margins: margins,
            title: bookTitle,
            author: bookAuthor,
            coverImageURL: coverImageURL
        )
    }

    /// 当前章节两个元素（底部页码 / 顶部标题）的布局。
    /// 前置页（扉页 / 版权页）返回 `.none`：两个元素都不显示。
    private func chromePlacement(for src: String, settings: AppSettings) -> ReaderChrome.Placement {
        guard src != frontMatterSrc else { return .none }
        return ReaderChrome.placement(
            showPageNumber: settings.showPageNumber,
            pageNumberPosition: settings.pageNumberPosition,
            pageNumberFormat: settings.pageNumberFormat,
            showChapterTitle: settings.showChapterTitle,
            chapterTitlePosition: settings.chapterTitlePosition,
            isRegular: isRegular
        )
    }

    /// 正文章节（或版权页）的 TextVC 数组，一页一个。
    /// `hasCoverPage` 只影响 data source 定位索引；页码闭包始终使用
    /// ChapterLayout 的本地 0-based `idx`。
    private func makeTextControllers(
        src: String,
        layout: ChapterLayout,
        settings: AppSettings,
        margins: ReaderMargins,
        chromePlacement: ReaderChrome.Placement,
        hasCoverPage: Bool = false
    ) -> [UIViewController] {
        // 本章的标注投影：同一章的每一页共享同一份。
        // 必须在建 VC 之前 attach 当前 layout——重排/换字号后旧的解析结果作废，
        // 由这里统一按新正文重新解析一次。
        let annotationState = annotationState(for: src)
        annotationState.attach(layout: layout)

        var vcs: [UIViewController] = []
        for idx in 0..<layout.pageCount {
            let vc = TextViewControllerTest(
                chapterLayout: layout,
                pageIndex: idx,
                background: settings.readingBackground,
                settings: settings,
                margins: margins,
                chapterTitle: titleBySrc[src],
                chromePlacement: chromePlacement,
                selectionState: layout.selectionState,
                annotationState: annotationState
            )
            vc.onAnnotationTap = { [weak self] id in
                self?.handleAnnotationTap(id)
            }
            vc.onAnnotationEdit = { [weak self] id in
                self?.onAnnotationActivate?(id)
            }
            vc.onBackgroundTap = { [weak self] in
                self?.handleTextBackgroundTap()
            }
            vc.onSelectionHandleTouchDown = { [weak self, weak vc] handle, range in
                guard let self, let vc else { return }
                self.beginSelectionHandleDrag(handle, range: range, in: vc)
            }
            vc.onSelectionHandleMoved = { [weak self, weak vc] handle, point in
                guard let self, let vc else { return }
                self.moveSelectionHandle(handle, to: point, in: vc)
            }
            vc.onSelectionHandleDragEnded = { [weak self] in
                self?.endSelectionHandleDrag()
            }
            vc.pageNumberValuesProvider = { [weak self] in
                guard let self else { return (current: nil, total: nil) }
                switch chromePlacement.pageNumberFormat {
                case .book:
                    // 整书口径：分子来自全书页码索引，分母是正文总页数
                    return (
                        current: self.globalPageNumber(src: src, pageIndex: idx),
                        total: self.totalBookPageCount
                    )
                case .current:
                    // 只显示当前页码：仍用整书口径的序号，不需要分母
                    return (
                        current: self.globalPageNumber(src: src, pageIndex: idx),
                        total: nil
                    )
                case .chapter:
                    // 本章口径：页码索引无关，立刻可用
                    return (current: idx + 1, total: layout.pageCount)
                }
            }
            // `vcIndexMap.pageArrayIndex` 是本章 VC 数组下标：版权页前有一张封面，
            // 因而版权页本地页码 idx 要映射到 idx + 1；页码显示仍以 idx 为准。
            let arrayIndex = ChapterPageSequence.arrayIndex(
                forLayoutPage: idx,
                hasCoverPage: hasCoverPage
            )
            vcIndexMap[ObjectIdentifier(vc)] = (src, arrayIndex)
            vcs.append(vc)
        }
        return vcs
    }

    // MARK: - Global Page Number

    /// 全书页码。前置页（扉页 + 版权页）不参与编号：
    /// 正文第一页从 1 开始，与纸质书的页码惯例一致。
    private func globalPageNumber(src: String, pageIndex: Int) -> Int? {
        ReaderChrome.pageNumber(
            src: src,
            pageIndex: pageIndex,
            orderedSources: allSrcs,
            pageCounts: pageCountBySrc,
            frontMatterSrc: frontMatterSrc
        )
    }

    /// 用当前 `pageCountBySrc` 重算整书总页数（页码分母）。
    ///
    /// 索引完成时算过一次，但后续仍可能变化：前置页是索引之后才由章节加载
    /// 判定的、失败章节之后又加载成功……分母若一直沿用旧值，就会出现
    /// 「分子按新页数、分母是旧页数」的错位。只在确有变化时返回 true，
    /// 让调用方决定是否刷新可见页标签。
    @discardableResult
    private func refreshTotalBookPageCount() -> Bool {
        let newTotal = ReaderChrome.totalPageCount(
            orderedSources: allSrcs,
            pageCounts: pageCountBySrc,
            frontMatterSrc: frontMatterSrc
        )
        guard newTotal != totalBookPageCount else { return false }
        totalBookPageCount = newTotal
        return true
    }

    // MARK: - Refresh Visible Page Elements

    private func refreshVisiblePageIndicators() {
        pageVC.viewControllers?
            .compactMap { $0 as? TextViewControllerTest }
            .forEach { $0.refreshChromeElements() }
    }

    // MARK: - O(1) Location Lookup

    private func findLocation(of vc: UIViewController) -> (src: String, pageArrayIndex: Int)? {
        vcIndexMap[ObjectIdentifier(vc)]
    }

    /// 屏幕上真正的「当前页」。
    ///
    /// iPad 双页下 `viewControllers` 是 [左页, 右页]；右页可能是合成的空白页，
    /// 它不在 `vcIndexMap` 里、也不承载任何语义。这里按"谁有位置"取，而不是按
    /// 数组下标取——下标顺序是 UIKit 的实现细节，阅读位置不能押在它上面。
    private var visibleFrontController: UIViewController? {
        pageVC?.viewControllers?.first { findLocation(of: $0) != nil }
    }

    /// 当前可见页在本章的数组下标。可见页不属于 `src` 时返回 nil。
    private func currentVisibleIndex(in src: String) -> Int? {
        guard let vc = visibleFrontController,
              let (visibleSrc, index) = findLocation(of: vc),
              visibleSrc == src
        else { return nil }
        return index
    }

    /// 屏幕可见页的完整定位：章、本章数组下标、本章页数。
    ///
    /// 翻页动画的合法性判定需要「从哪一章的哪一页出发」。只用
    /// `currentSrc` 不够——它可能在异步加载期间已经指向目标章，而屏幕
    /// 还停在上一章。
    private func currentVisiblePage() -> (src: String, index: Int, pageCount: Int)? {
        guard let vc = visibleFrontController,
              let (src, index) = findLocation(of: vc),
              let pages = pageCache.get(src)
        else { return nil }
        return (src, index, pages.count)
    }

    /// 跳转的翻页方向：按目录次序，以**屏幕上的那一章**为起点。
    ///
    /// - Parameter targetArrayIndex: 同章跳转的目标页数组下标。给出时按
    ///   「目标在当前页之前 → reverse」判断，`.scroll` 的滑动方向才不会反。
    ///   没给（跨章/未知目标/无可见页）则按目录次序或 `.forward` 兜底。
    private func navigationDirection(
        to targetSrc: String,
        targetArrayIndex: Int? = nil
    ) -> UIPageViewController.NavigationDirection {
        guard let current = currentVisiblePage() else { return .forward }
        if current.src == targetSrc {
            guard let targetArrayIndex else { return .forward }
            return targetArrayIndex < current.index ? .reverse : .forward
        }
        guard let from = allSrcs.firstIndex(of: current.src),
              let to = allSrcs.firstIndex(of: targetSrc)
        else { return .forward }
        return to >= from ? .forward : .reverse
    }

    /// 章节"正文首屏"在页面数组中的下标：普通章节是 0，前置页章节跳过
    /// 阅读器合成的扉页。以页面数组里**实际存在**的扉页为准，避免索引与
    /// 缓存对前置页结论不一致时多跳一页。
    private func chapterStartIndex(for pages: [UIViewController]) -> Int {
        ChapterPageSequence.arrayIndex(
            forLayoutPage: 0,
            hasCoverPage: pages.first is CoverPageViewController
        )
    }

    /// 目标数组下标是否在当前可见页之前。同章按页序，跨章按目录次序。
    private func isBackwardJump(to targetSrc: String, targetArrayIndex: Int) -> Bool {
        guard let current = currentVisiblePage() else { return false }
        if current.src == targetSrc { return targetArrayIndex < current.index }
        guard let from = allSrcs.firstIndex(of: current.src),
              let to = allSrcs.firstIndex(of: targetSrc)
        else { return false }
        return to < from
    }

    /// 当前可见 spread：`(章 src, 左页数组下标, 本章页数)`。
    ///
    /// 右页不是真实页（单页章的合成空白页）或当前没有成对可见页时返回 nil——
    /// 这两种状态下不了「动画起止对相邻」的结论，调用方按瞬切处理。
    ///
    /// 只对 iPad 双页成立：iPhone 单页书脊下 `viewControllers` 只有一个元素，
    /// 这里按"左右成对"推导 spread 会得出错误结论，故先由 `isRegular` 拦下。
    private func currentVisibleSpread() -> (src: String, left: Int, pageCount: Int)? {
        // 不押 `viewControllers` 的数组顺序：iPad `.mid` 下它是左右两张纸，
        // 但 UIKit 没有承诺"第一个一定是左页"。按两页的数组下标取较小者作为
        // 左页，并要求它们确实相邻（同一个 spread），否则下不了动画结论。
        guard isRegular,
              let vcs = pageVC?.viewControllers, vcs.count == 2,
              let first = findLocation(of: vcs[0]),
              let second = findLocation(of: vcs[1]),
              first.src == second.src,
              let pages = pageCache.get(first.src)
        else { return nil }

        let left = min(first.pageArrayIndex, second.pageArrayIndex)
        let right = max(first.pageArrayIndex, second.pageArrayIndex)
        guard right == left + 1, left >= 0, right < pages.count else { return nil }
        return (first.src, left, pages.count)
    }

    // MARK: - 可见页位置上报

    /// 当前可见页的位置快照。不可锚定时返回 nil：
    /// 扉页（`CoverPageViewController`）、空白页都不是 `TextViewControllerTest`，
    /// 它们没有正文可锚。
    private func visibleLocation() -> ReaderLocation? {
        guard let vc = visibleFrontController,
              let (src, _) = findLocation(of: vc),
              let textVC = vc as? TextViewControllerTest,
              let anchor = textVC.bookmarkAnchor()
        else { return nil }

        return ReaderLocation(
            src: src,
            pageStartOffset: anchor.start,
            pageLength: anchor.length,
            chapterTitle: titleBySrc[src],
            preview: anchor.preview
        )
    }

    /// 上报可见页。**等值不上报**：翻页/重排都会走到这里，
    /// 无变化也发一遍等于让 SwiftUI 外壳跟着页码白刷新一次。
    private func reportVisibleLocation() {
        let location = visibleLocation()
        guard location != lastReportedLocation else { return }
        lastReportedLocation = location
        onLocationChange?(location)
    }

    // MARK: - Window Prefetch

    private func prefetchWindow(center src: String) {
        guard let idx = allSrcs.firstIndex(of: src) else { return }
        [(idx - 1), (idx + 1), (idx + 2)]
            .filter { $0 >= 0 && $0 < allSrcs.count }
            .forEach { i in
                let target = allSrcs[i]
                guard !pageCache.contains(target) else { return }
                loadChapterAsync(src: target, priority: .background)
            }
    }

    // MARK: - Book Page Count Indexing

    /// 首屏第一页是否已经摆上屏。页码索引在它之前不启动。
    private var hasShownFirstPage = false
    /// 首屏之前被拦下的索引请求；首屏落地后补跑。
    private var needsPageCountIndexAfterFirstPage = false
    /// 待执行的索引任务。连续触发只保留最后一次。
    private var pageCountIndexWork: DispatchWorkItem?
    private static let pageCountIndexDelay: TimeInterval = 0.35

    /// 请求全书页码索引。**所有触发点都应走这里，不要直接调 `runBookPageCountIndexing`。**
    ///
    /// 索引要把全书每一章都做一遍 TextKit 排版才能得出页数（`ChapterLayout` 的
    /// `glyphRange(for:)` 循环），是打开一本书里最重的一段计算。原先它在
    /// `viewDidLayoutSubviews` 里与首章排版同时启动，两者抢同一批 CPU 核心：
    /// 读者还在等转场动画，CPU 已经被后半本书的排版吃光，于是掉帧。
    ///
    /// 现在加两道闸：
    /// 1. **首屏落地后才开始**——先让读者看到第一页。页码在此之前显示「…」，
    ///    索引跑完由 `refreshVisiblePageIndicators` 回填，这本来就是既有行为
    ///    （`globalPageNumber` 在前置章节页数未知时返回 nil）。
    /// 2. **合并 + 降优先级**——改设置、切尺寸类、目录刷新都会触发它，
    ///    这些常常连着来；合并成一次并以 `.background` QoS 跑，不与首屏排版抢核。
    private func scheduleBookPageCountIndexing() {
        guard hasShownFirstPage else {
            // 首屏还没出来：只记下意图，等 showPages 落地第一页再补跑。
            needsPageCountIndexAfterFirstPage = true
            return
        }

        pageCountIndexWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.pageCountIndexWork = nil
            self?.runBookPageCountIndexing()
        }
        pageCountIndexWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.pageCountIndexDelay, execute: work)
    }

    /// 第一页真正摆上屏时调用：开闸，并补跑之前被拦下的索引请求。
    private func markFirstPageShown() {
        guard !hasShownFirstPage else { return }
        hasShownFirstPage = true
        // 通知上层：转场早已结束、内容也已上屏，此刻提交写入不会与任何动画抢帧。
        onFirstPageShown?()
        guard needsPageCountIndexAfterFirstPage else { return }
        needsPageCountIndexAfterFirstPage = false
        scheduleBookPageCountIndexing()
    }

    /// 真正执行全书索引（只应由 `scheduleBookPageCountIndexing` 调用）。
    private func runBookPageCountIndexing() {
        guard let settings = cachedSettings,
              pageSize != .zero,
              !allSrcs.isEmpty
        else { return }

        let pageSize = self.pageSize
        let config = PaginationConfig(settings, pageSize: pageSize)
        let srcs = allSrcs
        let baseURL = epubBaseURL
        // 书籍身份也要走局部捕获：后台闭包强持 self 会让 VC 在全书索引期间
        // （大书可达分钟级）无法释放。与下方 [weak self] 的回主线程块保持同一约定。
        let bookKey = self.bookKey
        // 章标题同理局部捕获（版权页检测的支撑信号）
        let titles = titleBySrc
        let generation = UUID()
        pageCountIndexGeneration = generation
        // 当前排版配置的稳定摘要。后台索引跑完回来时，若设置/尺寸已经变化，
        // 这个摘要会不再等于当时启动索引时的值——旧索引不能盖掉新页码。
        let configDigest = config.stableDigest

        // `.background` 而非 `.utility`：页码是渐进增强（未就绪时页码显示「…」），
        // 不该和首屏排版、翻页抢 CPU。`.utility` 在长循环里足以把主线程饿死。
        DispatchQueue.global(qos: .background).async {
            var counts: [String: Int] = [:]
            // 索引路径独立做一次版权页检测，把结论带回主线程：
            // 「用目录直接跳到中章打开」的书，前置页 src 从未被加载过，
            // frontMatterSrc 还是 nil，页码会少数一页扉页。
            var detectedFrontMatterSrc: String?

            for src in srcs {
                let key = PaginationKey(bookKey: bookKey, src: src, configDigest: config.stableDigest)

                // Prefer cached page count (fastest)。
                // 唯独第一章不走快路：它的页数 = 扉页 1 页 + 版权页布局页数，
                // 而磁盘条目里只存了后者；且检测结论要在这里落地。
                // 页数 0 也不走快路：那是旧版本/损坏缓存留下的无效条目，
                // 重新解析一次才有机会把它修好，而不是把 0 记进索引。
                if src != srcs.first,
                   let cachedPageCount = PaginationCache.shared.pageCount(key: key),
                   cachedPageCount > 0 {
                    counts[src] = cachedPageCount
                    continue
                }

                let fileURL = baseURL.appendingPathComponent(src)
                guard let htmlString = try? String(contentsOf: fileURL, encoding: .utf8) else {
                    counts[src] = 0
                    continue
                }

                guard let outcome = ChapterRender.outcome(
                    htmlString: htmlString,
                    config: config,
                    imageBase: fileURL.deletingLastPathComponent(),
                    isFirstChapter: src == srcs.first,
                    chapterTitle: titles[src]
                ) else {
                    counts[src] = 0
                    continue
                }

                counts[src] = outcome.layout.pageCount + (outcome.frontMatter ? 1 : 0)
                if outcome.frontMatter { detectedFrontMatterSrc = src }
            }

            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.pageCountIndexGeneration == generation,
                      self.allSrcs == srcs
                else { return }

                guard let currentSettings = self.cachedSettings,
                      PaginationConfig(currentSettings, pageSize: self.pageSize).stableDigest == configDigest
                else { return }

                if let detectedFrontMatterSrc, self.frontMatterSrc == nil {
                    self.frontMatterSrc = detectedFrontMatterSrc
                }
                // 索引是全书口径，正常情况下应覆盖单章加载的结果；但它对
                // 读取/解析失败的章节记 0。若那一章在索引期间恰好被阅读器
                // 成功加载过，0 会把有效页数盖掉。此时保留已加载的非零值。
                self.pageCountBySrc = counts.merging(self.pageCountBySrc) { indexed, loaded in
                    indexed > 0 ? indexed : loaded
                }
                // 整书页数（页码格式分母）只有索引完整时才有意义。
                // 无论分母是否变化，索引完成都要刷新可见页——分子的前缀和
                // 也可能刚刚才齐。
                self.refreshTotalBookPageCount()
                self.refreshVisiblePageIndicators()
            }
        }
    }

    // MARK: - Page Progress (SwiftData)

    private func savePageProgress(src: String, pageIndex: Int) {
        let key = bookKey
        let descriptor = FetchDescriptor<PageProgress>(
            predicate: #Predicate { $0.bookKey == key && $0.src == src }
        )
        if let existing = try? modelContext.fetch(descriptor).first {
            existing.pageIndex = pageIndex
            existing.updatedAt = .now
        } else {
            modelContext.insert(PageProgress(bookKey: key, src: src, pageIndex: pageIndex))
        }
        try? modelContext.save()
    }

    private func loadPageProgress(src: String) -> Int {
        let key = bookKey
        let descriptor = FetchDescriptor<PageProgress>(
            predicate: #Predicate { $0.bookKey == key && $0.src == src }
        )
        return (try? modelContext.fetch(descriptor).first?.pageIndex) ?? 0
    }

    // MARK: - Placeholder VC

    /// 生成「空白页」：双页模式下章节末尾的空白右页，以及内容尚未就绪时的占位页。
    ///
    /// 背景必须是真实的纸面，而不是 `.clear`——`UIPageViewController`
    /// 的 pageCurl 转场会把相邻页面合成在同一层级，透明页会漏出底层黑底。
    ///
    /// 纸面取当前设置：空白页与内容页相邻，两页纸面不一致会直接在书脊处露馅。
    private func makeClearVC() -> UIViewController {
        BlankPageViewController(background: currentPaper())
    }

    /// 只有纸面背景、没有任何内容的页面。
    ///
    /// 与内容页共用 `PageBackgroundView`，保证翻页时纹理完全一致。
    private final class BlankPageViewController: UIViewController {

        private let background: ReadingBackground

        init(background: ReadingBackground) {
            self.background = background
            super.init(nibName: nil, bundle: nil)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func viewDidLoad() {
            super.viewDidLoad()
            PageBackgroundView.install(in: view, background: background)
            // 空白页不承载任何信息，VoiceOver 无需在此停留
            view.accessibilityElementsHidden = true
        }
    }

    // MARK: - 翻页样式

    /// 此刻应该使用的翻页样式。
    ///
    /// 规则全部收在 `PageTurnStyleResolver` 里（iPad 双页 / 降低动态效果两条
    /// 硬约束，其余跟随用户偏好），这里只负责把当前状态喂进去，不再写第二套判断。
    private func resolvedTurnStyle() -> PageTurnStyle {
        PageTurnStyleResolver.resolve(
            preference: cachedSettings?.pageTransitionStyle ?? PageTurnStyle.curl.rawValue,
            isRegular: isRegular
        )
    }

    /// 此刻是否卷曲样式。
    ///
    /// `appliedTurnStyle` 在 `setupPageVC` 里先于容器赋值，正常情况下不为 nil；
    /// 兜底再解析一次，避免出现"书脊已是 `.mid`、`isDoubleSided` 却被置 false"
    /// 这种 UIKit 会直接抛异常的组合。
    private var isCurlTurnStyle: Bool {
        (appliedTurnStyle ?? resolvedTurnStyle()) == .curl
    }

    /// 此刻是否使用「页张正反面」模型。
    ///
    /// 只有 iPhone 的卷曲走这条路：`.min` 书脊 + `isDoubleSided = true`。
    /// iPad 的 `.mid` 里 `viewControllers` 的两个元素是**左右两张不同的纸**，
    /// 语义完全不同，绝不能套用背面的那一套邻接规则。
    private var usesSheetBacks: Bool {
        isCurlTurnStyle && !isRegular
    }

    /// 同步 `isDoubleSided`。
    ///
    /// 卷曲样式下一律为 true：
    /// - iPad 的 `.mid` 书脊本来就要求它（左右两页是同一张纸的两面）；
    /// - iPhone 的 `.min` 书脊靠它进入「单页 + 正反面」模型，背面才归 App 管
    ///   （见 `PageBackViewController`）。
    ///
    /// `.scroll` 下 `isDoubleSided` 不参与渲染，显式归零——否则会留下
    /// "状态双面、画面单页"的错位，一旦切回卷曲就会撞上数量校验。
    private func syncPageVCDoubleSided() {
        pageVC.isDoubleSided = isCurlTurnStyle
    }

    // MARK: - 页面数组契约

    /// 交给 `setViewControllers` 的页面数组。
    ///
    /// `UIPageViewController` 对**页数**有硬约束，数量不符会直接抛
    /// `NSInvalidArgumentException` 把进程打死（不是可恢复错误）。两条校验
    /// 口径还**不一致**，这是本类最容易踩的一处（iOS 18.5 与 27.0 模拟器
    /// 各跑一遍组合矩阵实测，不是照着头文件推的）：
    ///
    /// | 调用 | `.min` 要求 |
    /// |---|---|
    /// | `setViewControllers(animated: false)` | 恰好 **1** 个 |
    /// | `setViewControllers(animated: true)` + 双面 | 恰好 **2** 个（正 + 背） |
    ///
    /// 也就是：
    /// - **静态落页**（首屏、旋转重排、设置重排、瞬切跳转）传 2 个必崩
    ///   （"provided (2) ... required (1) ... SpineLocationMin"）；
    /// - **动画转场**传 1 个必崩（"provided (1) ... required (2) ...
    ///   requested transition"）。
    ///
    /// 所以页数不能只按平台推导，必须把 `animated` 一起带进来。落页后
    /// `viewControllers` 会回落到只剩正面一个元素（背面在转场结束时被摘掉），
    /// 下一次静态落页又得回到 1 个——这两条是同一个状态机的两个面。
    ///
    /// iPad 的 `.mid` 两种情况都要求 2 个（左页 + 右页），与上面无关。
    private func pageControllers(
        front: UIViewController,
        right: UIViewController?,
        animated: Bool
    ) -> [UIViewController] {
        if isRegular { return [front, right ?? makeClearVC()] }
        // 动画转场才需要背面；瞬切时背面根本没机会上屏，多传一个只会崩。
        guard animated, isCurlTurnStyle else { return [front] }
        return [front, makeSheetBack(for: front)]
    }

    /// 正面页 → 它所在页张的背面。
    ///
    /// 背面**不进 `vcIndexMap`**：它没有位置、没有页码，阅读位置永远以正面为准。
    /// 这里的 `pageIndex` 只是"万一手势把背面当成了当前页"时的找回线索
    /// （见 `recoverIfLandedOnSheetBack`）。
    ///
    /// 扉页（`CoverPageViewController`）与空白页没有正文可透，传 nil 幽灵即可——
    /// 纯纸背是最省内存、也最不会出错的一种。
    private func makeSheetBack(for front: UIViewController) -> PageBackViewController {
        let location = findLocation(of: front)
        return PageBackViewController(
            src: location?.src ?? currentSrc,
            pageIndex: location?.pageArrayIndex ?? 0,
            background: currentPaper(),
            ghost: (front as? TextViewControllerTest)?.sheetBackGhost
        )
    }

    /// 某章某页的正面 VC。找不到（未加载 / 越界）返回 nil。
    private func frontPage(in src: String, at index: Int) -> UIViewController? {
        guard let pages = pageCache.get(src), pages.indices.contains(index) else { return nil }
        return pages[index]
    }

    /// 当前纸面。阅读器里凡是"要一块纸"的地方都从这里取，避免三处各写一套回退。
    private func currentPaper() -> ReadingBackground {
        cachedSettings?.readingBackground
            ?? .color(hex: ReadingBackgroundDefaults.colorHex)
    }

    /// 把当前纸面同步到阅读器容器底色。
    ///
    /// 页面自身由 `PageBackgroundView` 铺满，但容器层在两种时刻会露出来：
    /// `.scroll` 在首/末页回弹、`.pageCurl` 在转场间隙。阅读背景变更后
    /// 只重排页面、不刷新这一层，就会在纸面边缘看到旧颜色的细边。
    private func applyCurrentPaperToContainers() {
        guard let pageVC else { return }
        let color = currentPaper().fillColor
        view.backgroundColor = color
        pageVC.view.backgroundColor = color
    }

    // MARK: - Setup

    private func setupPageVC() {
        // 样式必须在建容器之前算出来：`transitionStyle` 是 init 参数，
        // 建成之后再想换只能整只丢掉重建（见 rebuildPageVC）。
        let style = resolvedTurnStyle()
        appliedTurnStyle = style

        pageVC = UIPageViewController(
            transitionStyle: style.transitionStyle,
            navigationOrientation: .horizontal,
            options: nil
        )

        // 容器底色取当前纸面。`.scroll` 下相邻页之间是一条真实的 UIScrollView，
        // 在首/末页回弹、或转场间隙里，露出来的就是容器底色——默认是黑，
        // 浅色纸面上等于一道黑边。卷曲模式同样受益（转场期间容器可见）。
        applyCurrentPaperToContainers()

        syncPageVCDoubleSided()
        pageVC.delegate   = self
        pageVC.dataSource = self

        setPlaceholderPages()

        addChild(pageVC)
        view.addSubview(pageVC.view)
        pageVC.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            pageVC.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pageVC.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            pageVC.view.topAnchor.constraint(equalTo: view.topAnchor),
            pageVC.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        pageVC.didMove(toParent: self)
        setupSelectionGesture()
    }

    private func rebuildPageVC() {
        guard pageVC != nil else {
            setupPageVC()
            return
        }

        pageVC.willMove(toParent: nil)
        pageVC.view.removeFromSuperview()
        pageVC.removeFromParent()
        pageVC = nil

        setupPageVC()
    }

    /// 首屏之前的占位页。
    ///
    /// **只传一张**：这一刻容器还没有书脊（`.min` 是 pageCurl 的默认值），
    /// 静态落页在 `.min` 下只接受一个 VC——即使 `isDoubleSided` 已经是 true
    /// 也一样（背面只在**动画转场**里参与，见 `pageControllers` 的实测表）。
    /// iPad 的 `.mid` 双页由 `spineLocationFor` 在书脊确立的回调里补齐右页。
    private func setPlaceholderPages() {
        pageVC.setViewControllers(
            [makeClearVC()],
            direction: .forward,
            animated: false,
            completion: nil
        )
    }

    // MARK: - SwiftData

    /// 必须走统一入口 `appSettings()`。
    /// 以前这里用无排序的 `fetch().first`，可能挑到从未被编辑过的重复记录，
    /// 于是"设置里改了字体，书里却没变"。详见 `ModelContext.appSettings` 的注释。
    private func loadAppSettings() -> AppSettings {
        modelContext.appSettings()
    }

    // MARK: - 程序化翻页（音量键）

    /// 音量键触发的翻页。
    ///
    /// 与手势翻页共用同一套邻接规则：章内步进 → 章末跨章；
    /// 相邻章还没排版时先加载、加载完再执行这一次翻页。
    ///
    /// 到全书首页/末页时**不翻页**，但会给一次柔反馈——见下方那条 guard。
    private func turnPage(forward: Bool) {
        // 诊断：确认音量键事件确实走到了翻页层（排查完可删）
        print("🔊 turnPage(forward: \(forward ? "前进" : "后退"))")
        guard !isTurningPage,
              pageSize != .zero,
              let base = visibleFrontController,
              let (src, index) = findLocation(of: base),
              let pages = pageCache.get(src), !pages.isEmpty
        else { return }

        // 双页模式一次翻一个 spread（两页），与 showPages 的落页口径保持一致
        let step = isRegular ? 2 : 1
        let rawTarget = index + (forward ? step : -step)
        // 奇数页章节的末 spread 是偏移的（如 [3, 4]）：反向翻页必须回到
        // `[2, 3]`，否则会直接跨回 `[0, 1]`，跳过中间 spread。
        //
        // `previousSpreadTarget` 的入参契约是**当前 spread 的左页下标**
        // （见其文档注释），不是 naive 目标。曾经这里把 `index - 2` 传进去，
        // 而它内部会先把入参归一成所属 spread 左页再减：`[2,3]` 退一格
        // 得到 0 → 归一成 0 → 再减得 -2，结果任何一次后退都直接跨章，
        // 中间的 spread 永远翻不到（音量键路径，手势翻页不走这里）。
        let target: Int
        if isRegular, !forward {
            target = ChapterPageSequence.previousSpreadTarget(
                from: index,
                pageCount: pages.count
            ) ?? rawTarget
        } else {
            target = rawTarget
        }

        // 1) 章内还有页
        if pages.indices.contains(target) {
            // 只有**真的翻过去了**才落盘。`showSpread` 在动画期间会拒绝新请求，
            // 而 `target` 是按 `pageVC.viewControllers` 算出来的——`setViewControllers`
            // 一返回它就指向目标页了。于是长按音量键连发时，第二次请求算出的
            // target 比实际显示位再远一页，落盘就把它写成了阅读位置：
            // 读者明明停在原页，下次打开却前进了两页。
            guard showSpread(at: target, of: src, forward: forward) else { return }
            savePageProgress(src: src, pageIndex: displayProgressIndex(for: target, pageCount: pages.count))
            return
        }

        // 2) 章内到头 → 跨到相邻章节
        guard let ci = allSrcs.firstIndex(of: src) else { return }
        let targetCi = forward ? ci + 1 : ci - 1

        // 3) 全书到头：不翻页，但给一次**柔**反馈。
        //
        // 这条 guard 原来是完全静默的，理由是"音量键没有手势那种'拉到头'的
        // 物理反馈，能做的只有不响应"。可手势翻页在边界有橡皮筋回弹顶着，
        // 音量键什么都没有——读者按下去毫无动静，分不清是"到底了"还是"卡住了"。
        // 一次柔震正是当时缺的那份物理反馈，而且它不是一个提示框，不打断阅读。
        //
        // 刻意用 `.soft` 而不用翻页的 `.light`：两件事语义不同，手感必须能区分——
        // "翻过去了"是清脆的一下，"到头了"是被托住的软着陆。
        guard allSrcs.indices.contains(targetCi) else {
            triggerHaptic(.soft)
            return
        }
        let targetSrc = allSrcs[targetCi]

        guard pageCache.contains(targetSrc) else {
            loadChapterAsync(src: targetSrc, priority: .userInitiated) { [weak self] success in
                guard let self,
                      success,
                      // 加载期间读者可能已经用目录/书签去了别的章，或者自己
                      // 翻到了本章另一页。此时这次「以加载前那一页为起点」的
                      // 跨章翻页已经过期，再落页会盖掉读者刚做的导航，且把
                      // currentSrc 拉回一个不是屏幕上内容的章。
                      self.currentSrc == src,
                      self.currentVisibleIndex(in: src) == index
                else { return }
                self.enterChapter(targetSrc, forward: forward)
            }
            return
        }
        enterChapter(targetSrc, forward: forward)
    }

    /// 翻进相邻章节：前进落在章节首页，后退落在章节末页。
    private func enterChapter(_ src: String, forward: Bool) {
        guard let pages = pageCache.get(src), !pages.isEmpty else { return }
        // 后退时落在末页：`loadPageProgress` 存的就是页索引，showPages 会按同样口径还原
        let index = forward ? 0 : pages.count - 1

        // 翻页被拦下（上一次动画还没落定）时不能改 currentSrc / 上报章节变化，
        // 否则 SwiftUI 侧以为已经换章了，而屏幕还停在上一章。
        guard showSpread(at: index, of: src, forward: forward) else { return }
        savePageProgress(src: src, pageIndex: displayProgressIndex(for: index, pageCount: pages.count))

        guard src != currentSrc else { return }
        currentSrc = src
        // 手势翻页靠 didFinishAnimating 上报章节变化，程序化翻页拿不到那个回调，
        // 这里手动补上，SwiftUI 侧的阅读位置（含"记已读"）才跟得上
        onChapterChange?(src)
        prefetchWindow(center: src)
    }

    /// 保存到 PageProgress 的页索引口径：双页模式下必须是 spread 左页
    /// （与 `showPages` / `spineLocationFor` 的恢复口径一致），iPhone 下就是
    /// 当前页本身。偏移末 spread（如 `[3, 4]`）保存的是左页 3。
    private func displayProgressIndex(for pageIndex: Int, pageCount: Int) -> Int {
        guard isRegular else {
            return min(max(0, pageIndex), pageCount - 1)
        }
        return ChapterPageSequence.spreadLeftIndex(for: pageIndex, pageCount: pageCount)
            ?? min(max(0, pageIndex), pageCount - 1)
    }

    /// 把 `src` 的第 `index` 页摆到当前显示位。
    /// 双页模式会自动对齐到 spread 左页并补上右页，末页没有右邻居时整屏前挪一 spread。
    ///
    /// 翻页动画进行中直接忽略后续请求：长按音量键时系统会连续重复触发音量变化，
    /// 不拦的话每页动画都会被下一次翻页打断，既跳帧又空转 CPU。
    /// 这套"动画期间不响应"的规则本来就是 UIPageViewController 对手势的做法。
    ///
    /// - Returns: 是否**真的**发起了这次翻页。false = 被闩锁拦下（动画未落定），
    ///   调用方据此决定要不要落盘进度——拦下的那次绝不能写进 PageProgress。
    @discardableResult
    private func showSpread(at index: Int, of src: String, forward: Bool) -> Bool {
        guard !isTurningPage, let pages = pageCache.get(src), !pages.isEmpty else { return false }
        let direction: UIPageViewController.NavigationDirection = forward ? .forward : .reverse
        isTurningPage = true

        if isRegular {
            let left = ChapterPageSequence.spreadLeftIndex(for: index, pageCount: pages.count)
                ?? min(max(0, index), pages.count - 1)
            let rightVC = left + 1 < pages.count ? pages[left + 1] : makeClearVC()
            // 与 showPages 同一道相邻性判定：音量键的步进本来就是「一个 spread /
            // 章边界一对」，正常都判得动画；唯一被挡下的是翻进单页章
            // （右页是合成空白页）——那不是 data source 链上的真实起止对。
            let animation: ChapterPageSequence.JumpAnimation
            if let current = currentVisibleSpread() {
                animation = ChapterPageSequence.spreadJumpAnimation(
                    currentSrc: current.src, currentLeft: current.left, currentPageCount: current.pageCount,
                    targetSrc: src, targetLeft: left, targetPageCount: pages.count,
                    orderedSources: allSrcs
                )
            } else {
                animation = .none
            }
            let animatedTurn = animation != .none
            let turnDirection: UIPageViewController.NavigationDirection
            switch animation {
            case .forward: turnDirection = .forward
            case .reverse: turnDirection = .reverse
            case .none:    turnDirection = direction
            }
            if animatedTurn {
                pageVC.setViewControllers(
                    pageControllers(front: pages[left], right: rightVC, animated: true),
                    direction: turnDirection,
                    animated: true
                ) { [weak self] _ in
                    self?.isTurningPage = false
                    self?.pageTurnDidLand()
                }
            } else {
                // 瞬切：闩锁与落定收尾都在这里同步做完，不依赖 completion
                // （animated:false 时 completion 的调用时机不由我们保证）。
                isTurningPage = false
                pageVC.setViewControllers(
                    pageControllers(front: pages[left], right: rightVC, animated: false),
                    direction: turnDirection,
                    animated: false,
                    completion: nil
                )
                pageTurnDidLand()
            }
        } else {
            let safe = min(max(0, index), pages.count - 1)
            pageVC.setViewControllers(
                pageControllers(front: pages[safe], right: nil, animated: true),
                direction: direction,
                animated: true
            ) { [weak self] _ in
                self?.isTurningPage = false
                self?.pageTurnDidLand()
            }
        }
        // 程序化翻页同样会改变“当前上屏章”，pin 要跟着走，
        // 否则新章会被后续预取挤出缓存。
        pageCache.pinOnly(src)
        return true
    }

    /// 一次翻页**落定**后的收尾。手势翻页与音量键翻页共用。
    ///
    /// 时机刻意取"翻页动画结束"而不是"翻页发起"：
    /// 手势翻页只有一个可用信号（`didFinishAnimating`，回调时页面已经贴好），
    /// 音量键若在按键当下就震，两种输入方式会差半拍。
    ///
    /// 开关判断在 `triggerHaptic` 内部（见 `Utils/Haptics.swift`），此处不重复。
    private func pageTurnDidLand() {
        triggerHaptic(.light)
        // 页级位置在这里才真正变了（动画已贴好、VC 已换），书签按钮的
        // 「当前页是否已加书签」据此刷新。
        reportVisibleLocation()
        consumePendingAnnotationFocusIfPossible()
    }

    // MARK: - UIPageViewControllerDataSource

    /// 邻接链在 iPhone 卷曲下是**正 → 背 → 正 → 背**：
    ///
    /// ```
    ///   after(正i) = 背i        after(背i) = 正(i+1)
    ///   before(正i) = 背(i-1)   before(背i) = 正i
    /// ```
    ///
    /// UIKit 在双面模式下会朝同一方向连问两次：第一次拿到的是**正在翻的那张纸
    /// 的背面**（卷曲过程中朝上的一面），第二次才是落页目标。所以背面必须夹在
    /// 两个正面之间，而不是另起一条链。
    ///
    /// iPad 的 `.mid` 不走这套：那里 `viewControllers` 的两个元素是左右两张
    /// **不同的纸**，`after/before` 仍然是 spread 步进（`usesSheetBacks` 为 false）。
    func pageViewController(
        _ pvc: UIPageViewController,
        viewControllerBefore vc: UIViewController
    ) -> UIViewController? {
        // 背面 → 它自己的正面（同一页张往回翻一格）。
        if let back = vc as? PageBackViewController {
            return frontPage(in: back.src, at: back.pageIndex)
        }

        // `findLocation.pageArrayIndex` 与页面数组下标同口径（包含合成的扉页）。
        // 前置页数组是 [扉页, 版权页0, 版权页1, ...]，所以扉页←→版权页
        // 由通用相邻页路径处理，不会再因封面 VC 没有 location 而在首屏断链。
        if let (src, idx) = findLocation(of: vc),
           let pages = pageCache.get(src),
           pages.indices.contains(idx) {
            if let previousIndex = ChapterPageSequence.previousIndex(from: idx, pageCount: pages.count) {
                let previous = pages[previousIndex]
                return usesSheetBacks ? makeSheetBack(for: previous) : previous
            }
            // 本章首张 → 跨到上一章最后一页。idx==0 时扉页/版权页边界已由
            // 上面的数组相邻路径处理；只有首章真实首张才会落到这里。
            guard let ci = allSrcs.firstIndex(of: src), ci > 0 else { return nil }
            let prevSrc = allSrcs[ci - 1]
            // 空页数组（损坏的磁盘缓存）必须挡住：下面按 `count % 2` 推
            // `lastLeft` 会得到 -1/-2，直接下标访问会崩在翻页手势里。
            guard let prevPages = pageCache.get(prevSrc), !prevPages.isEmpty else {
                return nil
            }
            let lastLeft  = prevPages.count % 2 == 0 ? prevPages.count - 2 : prevPages.count - 1
            let lastRight = lastLeft + 1
            let target = lastRight < prevPages.count ? prevPages[lastRight] : prevPages[lastLeft]
            return usesSheetBacks ? makeSheetBack(for: target) : target
        }

        return nil
    }

    func pageViewController(
        _ pvc: UIPageViewController,
        viewControllerAfter vc: UIViewController
    ) -> UIViewController? {
        // 背面 → 下一页的正面。这是「翻过去之后落在哪」的唯一出口：
        // 章末再跨到下一章首张（邻章未排版时先加载，本次返回 nil）。
        if let back = vc as? PageBackViewController {
            guard let pages = pageCache.get(back.src) else { return nil }
            if let nextIndex = ChapterPageSequence.nextIndex(from: back.pageIndex, pageCount: pages.count) {
                return pages[nextIndex]
            }
            guard let ci = allSrcs.firstIndex(of: back.src), ci + 1 < allSrcs.count else { return nil }
            let nextSrc = allSrcs[ci + 1]
            guard let nextPages = pageCache.get(nextSrc) else {
                loadChapterAsync(src: nextSrc, priority: .userInitiated)
                return nil
            }
            return nextPages.first
        }

        if let (src, idx) = findLocation(of: vc),
           let pages = pageCache.get(src),
           pages.indices.contains(idx) {
            if usesSheetBacks {
                // 正 → 背：同一页张的背面（不是下一页）。
                return makeSheetBack(for: pages[idx])
            }
            if let nextIndex = ChapterPageSequence.nextIndex(from: idx, pageCount: pages.count) {
                return pages[nextIndex]
            }

            // 本章最后一页 → 跨到下一章第一页。
            guard let ci = allSrcs.firstIndex(of: src), ci + 1 < allSrcs.count else { return nil }
            let nextSrc = allSrcs[ci + 1]
            guard let nextPages = pageCache.get(nextSrc) else {
                loadChapterAsync(src: nextSrc, priority: .userInitiated)
                return nil
            }
            // UIPageViewController 在双页模式下会自然把该页与下一章首 spread 配对。
            return nextPages.first
        }

        // 双页模式章节末尾的空白右页：从左页推导下一章首张。
        // **必须限定 regular**：iPhone 双面模式下 `viewControllers` 也可能是两个
        // 元素，但那是正反面，`vcs[1]` 是背面而不是空白右页。
        if isRegular,
           let vcs = pvc.viewControllers, vcs.count == 2,
           vc === vcs[1],
           let (src, _) = findLocation(of: vcs[0]) {
            guard let ci = allSrcs.firstIndex(of: src), ci + 1 < allSrcs.count else { return nil }
            let nextSrc = allSrcs[ci + 1]
            guard let nextPages = pageCache.get(nextSrc) else {
                loadChapterAsync(src: nextSrc, priority: .userInitiated)
                return nil
            }
            return nextPages.first
        }

        return nil
    }

    // MARK: - UIPageViewControllerDelegate

    func pageViewController(
        _ pvc: UIPageViewController,
        didFinishAnimating finished: Bool,
        previousViewControllers: [UIViewController],
        transitionCompleted completed: Bool
    ) {
        guard completed else { return }

        // 手势已经落定：无论此前是否有程序化翻页的 completion 丢失，
        // 闩锁都必须回到可响应状态，否则音量键会永久无响应。
        isTurningPage = false

        // 兜底：若某次手势把「背面」当成了当前页（`.min` 双面下 UIKit 如何解析
        // 目标属于实现细节，见 `recoverIfLandedOnSheetBack`），先回到正面再算位置。
        if recoverIfLandedOnSheetBack() { return }

        guard let currentVC = visibleFrontController,
              let (src, pageIdx) = findLocation(of: currentVC)
        else { return }

        // 手势也可能跨章。新章同样要 pin，否则下一次预取可能把它挤出缓存。
        pageCache.pinOnly(src)

        // 手势翻页落定。放在 `savePageProgress` 之前：那是一次同步 SwiftData 写盘，
        // 震动先发出去，反馈就不必排在它后面等。
        pageTurnDidLand()

        savePageProgress(src: src, pageIndex: pageIdx)

        if src != currentSrc {
            currentSrc = src
            onChapterChange?(src)
            prefetchWindow(center: src)
            print("📖 Chapter switch → \(src) (page \(pageIdx + 1))")
        }
    }

    /// 手势落在背面上时，立刻换回同一页张的正面。
    ///
    /// 正常路径不会走到这里：`setViewControllers` 的动画落页实测都停在正面
    /// （背面只在卷曲过程中可见，转场结束就被摘掉）。但手势翻页的解析由 UIKit
    /// 内部完成，各系统版本可能不同——真出现时**宁可闪一下纸背，也不能把阅读
    /// 位置留在没有页码的 VC 上**（那会让页码、书签、进度全部停更）。
    ///
    /// - Returns: 是否接管了这次落定（true = 调用方不必再处理）。
    @discardableResult
    private func recoverIfLandedOnSheetBack() -> Bool {
        let visible = pageVC.viewControllers ?? []
        // 只有在**一张正面都没有**时才接管：`[背, 正]` 这种组合里可见页是正面，
        // 不该把它拽回上一个页张。
        guard !visible.contains(where: { findLocation(of: $0) != nil }),
              let back = visible.first as? PageBackViewController,
              let front = frontPage(in: back.src, at: back.pageIndex)
        else { return false }

        pageVC.setViewControllers([front], direction: .forward, animated: false, completion: nil)
        isTurningPage = false
        pageCache.pinOnly(back.src)
        let previousSrc = currentSrc
        currentSrc = back.src
        savePageProgress(
            src: back.src,
            pageIndex: displayProgressIndex(
                for: back.pageIndex,
                pageCount: pageCache.get(back.src)?.count ?? 1
            )
        )
        pageTurnDidLand()

        // 这里接管了 didFinishAnimating 的整条收尾路径（调用方会直接 return），
        // 所以跨章时必须自己把章节变化补上；漏掉的话目录高亮、已读记录和
        // SwiftUI 的 currentSrc 会停在上一章，而屏幕已经翻到了新章。
        if back.src != previousSrc {
            onChapterChange?(back.src)
            prefetchWindow(center: back.src)
        }
        #if DEBUG
        print("⚠️ 手势落在了页张背面，已回到正面：\(back.src) #\(back.pageIndex)")
        #endif
        return true
    }

    // MARK: - spineLocationFor

    func pageViewController(
        _ pvc: UIPageViewController,
        spineLocationFor orientation: UIInterfaceOrientation
    ) -> UIPageViewController.SpineLocation {
       // 只有 `.pageCurl` 会走到这个回调（`.scroll` 不问书脊位置）。
       // 卷曲下一律双面：iPad 的 `.mid` 本来就要求（左右两页同属一张纸），
       // iPhone 的 `.min` 靠它进入正反面模型（见 `usesSheetBacks`）。
       pvc.isDoubleSided = isCurlTurnStyle

       if !currentSrc.isEmpty, let pages = pageCache.get(currentSrc), !pages.isEmpty {
           let saved     = loadPageProgress(src: currentSrc)
           let leftIndex = ChapterPageSequence.spreadLeftIndex(for: saved, pageCount: pages.count)
               ?? min(saved, pages.count - 1)
           let safeLeft  = min(max(0, leftIndex), pages.count - 1)

           if isRegular {
               let rightVC = safeLeft + 1 < pages.count ? pages[safeLeft + 1] : makeClearVC()
                pvc.setViewControllers(
                    pageControllers(front: pages[safeLeft], right: rightVC, animated: false),
                    direction: .forward,
                    animated: false,
                    completion: nil
                )
            } else {
                // 书脊回调里的落页是**静态**的：此刻背面还上不了屏，
                // 传两张会被 `.min` 的数量校验直接拒掉（见 pageControllers）。
                pvc.setViewControllers(
                    pageControllers(front: pages[safeLeft], right: nil, animated: false),
                    direction: .forward,
                    animated: false,
                    completion: nil
                )
            }
        } else {
            let existing = pvc.viewControllers ?? []
            if isRegular {
                switch existing.count {
                case 2...:
                    pvc.setViewControllers(
                        [existing[0], existing[1]],
                        direction: .forward,
                        animated: false,
                        completion: nil
                    )
              case 1:
                  pvc.setViewControllers(
                        [existing[0], makeClearVC()],
                      direction: .forward,
                      animated: false,
                      completion: nil
                  )
              default:
                  pvc.setViewControllers(
                        [makeClearVC(), makeClearVC()],
                      direction: .forward,
                      animated: false,
                      completion: nil
                  )
                }
            } else {
                // 旋转到这里时还没有任何章：保留屏幕上那一页（没有就用空白页）。
                // `.min` 只接受一个，不多补。
                let front = existing.first { findLocation(of: $0) != nil }
                    ?? existing.first
                    ?? makeClearVC()
                pvc.setViewControllers(
                    pageControllers(front: front, right: nil, animated: false),
                    direction: .forward,
                    animated: false,
                    completion: nil
                )
            }
        }

        // 书脊回调可能保留旧页、也可能从 pageCache 重新落页。无论哪条路，
        // 页面上真正显示的章都要重新 pin 住，防止紧随其后的重排/预取把它挤掉。
        if let visible = visibleFrontController,
           let (src, _) = findLocation(of: visible) {
            pageCache.pinOnly(src)
        } else if !currentSrc.isEmpty {
            pageCache.pin(currentSrc)
        }

        // 旋转 / 尺寸变化后页面已被重新摆放，页级位置随之改变。
        reportVisibleLocation()

        return isRegular ? .mid : .min
    }

    // MARK: - 文本选中与标注菜单

    /// 在 self.view 上安装长按选中与留白点击；正文内的点按由
    /// `TextRenderView` 自己处理（见其 `tapRecognizer`）。
    /// 手势在 self.view 上而非独立 overlay——避免了 overlay 截获所有触摸
    /// 导致 UIPageViewController 翻页手势失效的问题。
    ///
    /// **必须幂等**：`setupPageVC` 会被 `rebuildPageVC` 反复调用（旋转、切尺寸类），
    /// 而手势挂在 `self.view` 上、不随 pageVC 一起销毁。此前每重建一次就再挂一个，
    /// 于是同一处正文上有 N 个长按识别器同时在跑：`.began` 里的
    /// `setPageCurlGesturesEnabled(false)` 被触发 N 次、触觉震 N 下，
    /// 而且 N 个识别器各自维护一份 start/end，选中范围会来回跳。
    private func setupSelectionGesture() {
        guard selectionGesture == nil else { return }

        let longPress = UILongPressGestureRecognizer(
            target: self,
            action: #selector(handleSelectionLongPress(_:))
        )
        longPress.minimumPressDuration = 0.45
        view.addGestureRecognizer(longPress)
        selectionGesture = longPress

        // 正文区域的点按由 TextRenderView 自己处理（命中标注 / 背景）。
        // 这里只补一个"留白、扉页、空白页"用的背景点击，保证点纸面任何位置
        // 都能切换阅读控件——与改造前 SwiftUI 层覆盖整屏的手势一致。
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleMarginTap(_:)))
        tap.delegate = self
        tap.cancelsTouchesInView = false
        view.addGestureRecognizer(tap)
        marginTapGesture = tap

        let interaction = UIEditMenuInteraction(delegate: self)
        view.addInteraction(interaction)
        editMenuInteraction = interaction
    }

    @objc private func handleSelectionLongPress(_ gesture: UILongPressGestureRecognizer) {
        let point = gesture.location(in: view)

        switch gesture.state {
        case .began:
            // 新手势开始 = 上一次手柄拖动一定已经结束（手柄命中区由
            // shouldReceive 挡掉）。清掉可能悬挂的调整态。
            isAdjustingSelection = false
            setPageCurlGesturesEnabled(false)
            // 菜单开着时也不能靠点击翻页：否则点菜单外面一下，
            // 选中没了、页也翻过去了。松手后的菜单生命周期负责恢复。
            setPageTurnTapGesturesEnabled(false)
            // 同一次抬手会同时结束长按与触发点按；不关掉点按，
            // 刚弹出的菜单会被"点空白"立刻清掉。
            setTextTapEnabled(false)
            guard let (textVC, charIdx) = hitTestText(at: point) else {
                finishSelectionAction()
                return
            }

            // 长按一律走"选句 + 弹操作菜单"。编辑已有笔记改由右侧的笔记指示器
            // 触发（见 `AnnotationMarginView.onIndicatorTap`）：长按落在标注上时
            // 读者多半只是想重新选这句话，直接弹编辑页反而挡路。

            // 长按默认选中"一句"（到句号收尾），而不是"一个逗号分句"：
            // 中文没有空格，读者长按的意图几乎总是"标下这一句"。
            // 句界判定、段落边界与无句号段落的兜底都在 SentenceRangeResolver 里。
            let initialRange = SentenceRangeResolver.sentenceRange(at: charIdx, in: textVC.chapterText)
            sharedSelectionAnchor = initialRange.location

            let state = textVC.selectionState
            state.startIndex = initialRange.location
            state.endIndex = NSMaxRange(initialRange)
            selectionSrc = findLocation(of: textVC)?.src
            activeSelection = nil

            // 走统一总闸（原来直接 new 一个 generator，绕过了「触觉反馈」开关）。
            // 只在这一处放电：进入选择模式是"状态切换"，值得一次明确的反馈；
            // `.changed` 里每跨一个字都震会变成噪音，视觉高亮本身就是连续反馈。
            triggerHaptic(.medium)

        case .changed:
            guard let selectionSrc,
                  let (textVC, charIdx) = hitTestText(at: point),
                  let location = findLocation(of: textVC),
                  location.src == selectionSrc
            else { return }

            let s = min(sharedSelectionAnchor, charIdx)
            let e = max(sharedSelectionAnchor, charIdx)
            let state = textVC.selectionState
            guard state.startIndex != s || state.endIndex != e else { return }

            state.startIndex = s
            state.endIndex = e

        case .ended:
            // 抬手才取原文：拖动期间只画选中，不做整章文本桥接。
            guard let src = selectionSrc,
                  let textVC = visibleTextController(for: src),
                  let range = textVC.selectionState.range,
                  range.length > 0,
                  let selection = makeSelection(textVC: textVC, range: range)
            else {
                finishSelectionAction()
                return
            }
            activeSelection = selection

            // 手势结束，但菜单仍占着这次选中：翻页手势保持禁用，
            // 直到菜单真正关闭（见 willDismissMenuFor）。原先在 `.ended`
            // 就恢复，读者能一边看菜单一边翻页。
            presentSelectionMenu(for: selection)
            // 抬手已经过去，再把正文点按放回来。延后一拍，
            // 避免同一次抬手被当成"点空白"。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self, !self.isAdjustingSelection else { return }
                self.setTextTapEnabled(true)
            }

        case .cancelled, .failed:
            finishSelectionAction()

        default:
            break
        }
    }

    /// 在 self.view 坐标系中查找触摸点对应的文本页与章节全局字符索引。
    private func hitTestText(at point: CGPoint) -> (TextViewControllerTest, Int)? {
        for vc in pageVC.viewControllers ?? [] {
            guard let textVC = vc as? TextViewControllerTest,
                  let rv = textVC.textRenderView else { continue }
            let local = rv.convert(point, from: view)
            if let ci = rv.characterIndex(at: local) {
                return (textVC, ci)
            }
        }
        return nil
    }

    /// 把字符区间包装成可跨层传递的选中结果（裁剪空白 + 取原文）。
    private func makeSelection(
        textVC: TextViewControllerTest,
        range: NSRange
    ) -> ReaderTextSelection? {
        guard let location = findLocation(of: textVC) else { return nil }
        let text = textVC.chapterText
        let trimmed = AnnotationResolver.trimmed(range, in: text)
        let quote = AnnotationResolver.quote(in: trimmed, text: text)
        guard trimmed.length > 0, !quote.isEmpty else { return nil }

        return ReaderTextSelection(
            src: location.src,
            range: trimmed,
            quote: quote,
            chapterTitle: titleBySrc[location.src] ?? ""
        )
    }

    private func presentSelectionMenu(for selection: ReaderTextSelection) {
        expectsSelectionMenu = false

        // 手柄拖动期间不弹菜单：等手柄抬起后的 end 再弹。
        // （双指操作时，初次长按的 ended 可能晚于手柄按下。）
        guard !isAdjustingSelection else { return }

        guard let rect = selectionRect(for: selection) else {
            finishSelectionAction()
            return
        }
        let configuration = UIEditMenuConfiguration(
            identifier: nil,
            sourcePoint: CGPoint(x: rect.midX, y: rect.minY)
        )
        guard let interaction = editMenuInteraction else {
            finishSelectionAction()
            return
        }
        interaction.presentEditMenu(with: configuration)
        presentedMenuCount &+= 1
    }

    private func visibleTextController(for src: String) -> TextViewControllerTest? {
        for vc in pageVC.viewControllers ?? [] {
            guard let textVC = vc as? TextViewControllerTest,
                  let (locationSrc, _) = findLocation(of: textVC),
                  locationSrc == src
            else { continue }
            return textVC
        }
        return nil
    }

    /// 选中区间在 self.view 坐标系里的外接矩形（菜单锚点 / 箭头定位）。
    ///
    /// 必须遍历**所有**可见页：iPad 双页下选区可能跨页，锚点页与
    /// "包含这段文字的那一页"不一定是同一张。
    private func selectionRect(for selection: ReaderTextSelection) -> CGRect? {
        var union: CGRect?

        for vc in pageVC.viewControllers ?? [] {
            guard let textVC = vc as? TextViewControllerTest,
                  let (locationSrc, _) = findLocation(of: textVC),
                  locationSrc == selection.src
            else { continue }

            for rect in textVC.rects(for: selection.range) {
                let converted = textVC.view.convert(rect, to: view)
                union = union.map { $0.union(converted) } ?? converted
            }
        }

        return union
    }

    // MARK: - 点按路由

    /// 正文区域的点按（来自 `TextRenderView`，未命中标注）。
    private func handleTextBackgroundTap() {
        // 有选中时，第一次点空白处只取消选中，不切换阅读控件——
        // 这是文本选择的通用语义，也避免菜单刚消失又弹出一堆按钮。
        if let textVC = visibleFrontController as? TextViewControllerTest,
           textVC.selectionState.range != nil {
            finishSelectionAction()
            return
        }
        onBackgroundTap?()
    }

    /// 单击标注：选中它的整段并弹出操作菜单。
    ///
    /// 两个入口分工：
    /// - 点正文里的标注 = 选中 + 菜单（高亮、添加笔记、颜色、移除……）；
    /// - 点右侧的笔记指示器 = 打开「编辑标注」页（见 `AnnotationMarginView`）。
    private func handleAnnotationTap(_ id: UUID) {
        guard let textVC = pageVC?.viewControllers?
            .compactMap({ $0 as? TextViewControllerTest })
            .first(where: { $0.annotationState.item(id: id) != nil }),
              let item = textVC.annotationState.item(id: id),
              let src = findLocation(of: textVC)?.src
        else { return }

        // 用当前正文重新取原文；取不到时退回标注自己的 quote。
        let selection = makeSelection(textVC: textVC, range: item.range)
            ?? ReaderTextSelection(
                src: src,
                range: item.range,
                quote: item.quote,
                chapterTitle: titleBySrc[src] ?? ""
            )

        // 选中整段标注，让读者看清这次操作的是哪一段。
        // 用 selection.range 而不是 item.range：前者已经裁过首尾空白，
        // 与菜单实际操作的区间保持一致。
        let state = textVC.selectionState
        state.startIndex = selection.range.location
        state.endIndex = NSMaxRange(selection.range)
        selectionSrc = src
        activeSelection = selection

        // 菜单开着时页不能翻；正文点按保留，方便直接换一条标注查看。
        setPageCurlGesturesEnabled(false)
        setPageTurnTapGesturesEnabled(false)

        triggerHaptic(.light)
        presentSelectionMenu(for: selection)
    }

    /// 留白 / 扉页 / 空白页的点按。
    @objc private func handleMarginTap(_ gesture: UITapGestureRecognizer) {
        if let textVC = visibleFrontController as? TextViewControllerTest,
           textVC.selectionState.range != nil {
            finishSelectionAction()
            return
        }
        onBackgroundTap?()
    }

    // MARK: - 选区手柄

    /// 手指按下手柄。
    ///
    /// 菜单如果正开着，先让它退场，但**不能清选区**——手柄还要继续用。
    /// 标志必须在 `dismissMenu()` 之前置位：菜单的退场完成回调会检查它。
    private func beginSelectionHandleDrag(
        _ handle: SelectionHandle,
        range: NSRange,
        in textVC: TextViewControllerTest
    ) {
        guard !isAdjustingSelection else { return }
        isAdjustingSelection = true
        selectionSrc = findLocation(of: textVC)?.src

        triggerHaptic(.light)
        if isSelectionMenuPresented {
            menuDismissedForHandleDrag = true
            editMenuInteraction?.dismissMenu()
        }

        setPageCurlGesturesEnabled(false)
        setPageTurnTapGesturesEnabled(false)
        setTextTapEnabled(false)

        // 极端时序下菜单退场可能先把选区清了：用按下瞬间的范围恢复。
        let state = textVC.selectionState
        if state.range == nil {
            state.startIndex = range.location
            state.endIndex = NSMaxRange(range)
        }
        activeSelection = nil
    }

    /// 手柄拖动到某个点（point 在 textVC.view 坐标系）。
    private func moveSelectionHandle(
        _ handle: SelectionHandle,
        to point: CGPoint,
        in textVC: TextViewControllerTest
    ) {
        guard isAdjustingSelection else { return }

        // 跨页命中：iPad 双页时手柄可以从左页拖到右页。
        let global = textVC.view.convert(point, to: view)
        guard let (targetVC, charIdx) = hitTestText(at: global),
              // 必须仍是同一章：翻页/换章后旧的字符索引对新章没有意义。
              targetVC.selectionState === textVC.selectionState
        else { return }

        let state = textVC.selectionState
        guard let range = state.range else { return }

        // 用 textStorage 的长度，不桥接整章文本：手柄拖动是高频路径。
        let textLength = targetVC.chapterLength
        guard textLength > 0 else { return }

        let index = min(max(0, charIdx), textLength - 1)
        var start = range.location
        var end = NSMaxRange(range)

        switch handle {
        case .start:
            // 起点不能越过终点，至少留一个字。
            start = min(index, end - 1)
        case .end:
            // 终点是"不包含"的上界：手指下的那个字也要选进来。
            end = max(index + 1, start + 1)
        }

        guard start >= 0, end <= textLength, start < end else { return }
        if state.startIndex != start || state.endIndex != end {
            state.startIndex = start
            state.endIndex = end
        }
    }

    /// 手柄抬起：重新算一次原文，并把菜单放回来。
    ///
    /// 这里**不**恢复翻页手势：菜单马上要回来，等它退场时再统一恢复。
    /// 否则 0.12s 的空窗里读者一划就翻页了。
    private func endSelectionHandleDrag() {
        guard isAdjustingSelection else { return }
        isAdjustingSelection = false

        // 正文点按可以恢复：让读者在菜单回来之前点一下取消。
        // 翻页手势仍保持禁用，等菜单退场再恢复。
        setTextTapEnabled(true)

        guard let src = selectionSrc,
              let textVC = visibleTextController(for: src),
              let range = textVC.selectionState.range,
              range.length > 0,
              let selection = makeSelection(textVC: textVC, range: range)
        else {
            finishSelectionAction()
            return
        }

        activeSelection = selection
        expectsSelectionMenu = true

        // 等抬手这一下过去，再把菜单放回来。期间读者若点了别处，
        // activeSelection 会被清掉，这里就不再弹。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self,
                  !self.isAdjustingSelection,
                  self.activeSelection == selection
            else { return }
            self.presentSelectionMenu(for: selection)
        }
    }

    /// 某个点是否落在可见页的选区手柄上。
    private func isPointOnSelectionHandle(_ point: CGPoint) -> Bool {
        for vc in pageVC.viewControllers ?? [] {
            guard let textVC = vc as? TextViewControllerTest else { continue }
            let local = textVC.view.convert(point, from: view)
            if textVC.containsSelectionHandle(at: local) {
                return true
            }
        }
        return false
    }

    // MARK: - UIGestureRecognizerDelegate

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldReceive touch: UITouch
    ) -> Bool {
        let point = touch.location(in: view)

        if gestureRecognizer === selectionGesture {
            // 按在手柄上时不要重新选句：手柄有自己的拖动识别器，
            // 两个长按同时跑会把选区来回重置。
            return !isPointOnSelectionHandle(point)
        }

        guard gestureRecognizer === marginTapGesture else { return true }

        // 手柄的命中区会伸进页边距；这一下必须让给手柄，
        // 否则抬手时留白点击会把刚调好的选区清掉。
        if isPointOnSelectionHandle(point) { return false }

        // 正文区域交给 `TextRenderView` 自己的点按：它在触摸链里更深，
        // 命中标注时可以先于翻页点击识别。这里只接管正文之外的留白。
        return !isPointInsideTextArea(point)
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        // 留白点击与 pageCurl 的翻页点击可以同时生效——
        // 与改造前 SwiftUI 的 simultaneousGesture 行为一致。
        guard gestureRecognizer === marginTapGesture || otherGestureRecognizer === marginTapGesture else {
            return false
        }
        return true
    }

    private func isPointInsideTextArea(_ point: CGPoint) -> Bool {
        for vc in pageVC.viewControllers ?? [] {
            guard let textVC = vc as? TextViewControllerTest,
                  let rv = textVC.textRenderView
            else { continue }
            if rv.bounds.contains(rv.convert(point, from: view)) {
                return true
            }
        }
        return false
    }

    /// 启用/禁用 pageVC 子树里的翻页点击（pageCurl 的边缘点击）。
    ///
    /// 跳过 `TextRenderView` 自己：正文点按有独立生命周期
    /// （见 `setTextTapEnabled`），不能被这里一并开关。
    private func setPageTurnTapGesturesEnabled(_ enabled: Bool) {
        guard let root = pageVC?.view else { return }

        func walk(_ node: UIView) {
            if !(node is TextRenderView) {
                for recognizer in node.gestureRecognizers ?? [] where recognizer is UITapGestureRecognizer {
                    recognizer.isEnabled = enabled
                }
            }
            node.subviews.forEach(walk)
        }
        walk(root)
    }

    /// 启用/禁用正文区域的点按（长按选中期间临时关闭）。
    private func setTextTapEnabled(_ enabled: Bool) {
        for vc in pageVC.viewControllers ?? [] {
            (vc as? TextViewControllerTest)?.setTextTapEnabled(enabled)
        }
    }

    /// 清掉当前选中（章节内所有页共享同一个 SelectionState）。
    private func clearSelection() {
        for vc in pageVC.viewControllers ?? [] {
            (vc as? TextViewControllerTest)?.selectionState.clear()
        }
        activeSelection = nil
        selectionSrc = nil
    }

    /// 一次选中交互的收尾：清选中、恢复翻页与点按手势。幂等。
    private func finishSelectionAction() {
        isAdjustingSelection = false
        expectsSelectionMenu = false
        clearSelection()
        setPageCurlGesturesEnabled(true)
        setPageTurnTapGesturesEnabled(true)
        setTextTapEnabled(true)
    }

    /// 禁用/启用翻页手势。
    ///
    /// 递归遍历而不是只看 `pageVC.gestureRecognizers`：`.scroll` 的 pan
    /// 挂在内部的 `UIScrollView` 上，不在容器自身。只关容器那一层，
    /// 读者拖动选区时页面仍会跟着滑。
    private func setPageCurlGesturesEnabled(_ enabled: Bool) {
        guard let root = pageVC?.view else { return }

        func walk(_ node: UIView) {
            for recognizer in node.gestureRecognizers ?? [] where recognizer is UIPanGestureRecognizer {
                recognizer.isEnabled = enabled
            }
            node.subviews.forEach(walk)
        }
        walk(root)
    }

    // MARK: - UIEditMenuInteractionDelegate

    func editMenuInteraction(
        _ interaction: UIEditMenuInteraction,
        targetRectFor configuration: UIEditMenuConfiguration
    ) -> CGRect {
        guard let selection = activeSelection,
              let rect = selectionRect(for: selection)
        else {
            return CGRect(origin: configuration.sourcePoint, size: .zero)
        }
        return rect
    }

    func editMenuInteraction(
        _ interaction: UIEditMenuInteraction,
        menuFor configuration: UIEditMenuConfiguration,
        suggestedActions: [UIMenuElement]
    ) -> UIMenu? {
        guard let selection = activeSelection else { return nil }

        let settings = cachedSettings
        let defaultStyle = AnnotationStyle(rawValue: settings?.defaultAnnotationStyle ?? "") ?? .highlight
        let defaultColor = AnnotationColor(rawValue: settings?.defaultHighlightColor ?? "") ?? .yellow

        // 已有标注时，菜单的勾选状态与"另一维"的默认值都跟着它走：
        // 换颜色不会把下划线变回高亮，换样式也不会丢掉原来的颜色。
        let existing = annotationState(for: selection.src).item(overlapping: selection.range)
        let currentStyle = existing?.style ?? defaultStyle
        let currentColor = existing?.color ?? defaultColor

        // 样式子菜单
        let styleMenu = UIMenu(
            title: "标注样式",
            image: UIImage(systemName: currentStyle.systemImage),
            children: AnnotationStyle.allCases.map { style in
                let action = UIAction(
                    title: style.displayName,
                    image: UIImage(systemName: style.systemImage)
                ) { [weak self] _ in
                    self?.onHighlightSelection?(selection, style, currentColor)
                    self?.finishSelectionAction()
                }
                action.state = style == currentStyle ? .on : .off
                return action
            }
        )

        // 颜色子菜单
        let colorMenu = UIMenu(
            title: "标注颜色",
            image: currentColor.menuImage(),
            children: AnnotationColor.allCases.map { color in
                let action = UIAction(
                    title: color.displayName,
                    image: color.menuImage()
                ) { [weak self] _ in
                    self?.onHighlightSelection?(selection, currentStyle, color)
                    self?.finishSelectionAction()
                }
                action.state = color == currentColor ? .on : .off
                return action
            }
        )

        // 一键按默认样式 + 默认颜色标注，省掉"展开样式子菜单再选一项"的两步。
        //
        // 选区与已有标注重叠时**不给**这一条：`addAnnotation` 对重叠选区是
        // "改写样式/颜色"而不是新增（见 ContentsPanelViewModel），标题写
        // "添加"会误导；这种时候样式/颜色子菜单已经能改，末尾还有「移除标注」。
        let addAnnotation: UIAction? = existing == nil
            ? UIAction(
                title: "添加标注",
                // 图标跟随默认样式，读者按下去之前就知道会画成高亮还是下划线。
                image: UIImage(systemName: defaultStyle.systemImage)
            ) { [weak self] _ in
                self?.onHighlightSelection?(selection, defaultStyle, defaultColor)
                self?.finishSelectionAction()
            }
            : nil

        let note = UIAction(
            // 已有笔记时这条实际是"打开编辑页"（见 BookContent 的 onNoteSelection）。
            // 编辑的指针入口已经移到右侧指示器，菜单里这条是关掉指示器后的退路，
            // 标题必须说清楚它会把原笔记一起带出来。
            title: existing?.hasNote == true ? "编辑笔记" : "添加笔记",
            image: UIImage(systemName: "note.text")
        ) { [weak self] _ in
            // 先收掉选中与菜单，再让 SwiftUI 弹 sheet：菜单还在退场时
            // 直接 present 会和它的动画抢同一个事务。
            self?.finishSelectionAction()
            // 菜单退场动画还没结束时直接 present 会和它抢同一个事务，
            // 延后一拍再交给 SwiftUI。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                self?.onNoteSelection?(selection)
            }
        }

        let copy = UIAction(
            title: "复制",
            image: UIImage(systemName: "doc.on.doc")
        ) { _ in
            UIPasteboard.general.string = selection.quote
        }

        let share = UIAction(
            title: "分享",
            image: UIImage(systemName: "square.and.arrow.up")
        ) { [weak self] _ in
            // 同上：等菜单退场后再弹分享面板。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                self?.presentShareSheet(text: selection.quote)
            }
        }

        // 分组布局：外观（样式/颜色）→ 添加标注 / 笔记与分享 → 危险操作。
        // 用 inline section 让系统自动画分隔线，而不是把动作平铺成一行行。
        let appearanceSection = UIMenu(
            options: .displayInline,
            children: [styleMenu, colorMenu]
        )
        var utilityItems: [UIMenuElement] = []
        if let addAnnotation {
            utilityItems.append(addAnnotation)
        }
        utilityItems.append(contentsOf: [note, copy, share])
        let utilitySection = UIMenu(
            options: .displayInline,
            children: utilityItems
        )

        var sections: [UIMenuElement] = [appearanceSection, utilitySection]

        // 选区与已有标注重叠时给出移除入口（Apple Books 的同一处操作）。
        if let existing {
            let remove = UIAction(
                title: "移除标注",
                image: UIImage(systemName: "trash"),
                attributes: .destructive
            ) { [weak self] _ in
                self?.onDeleteAnnotation?(existing.id)
                self?.finishSelectionAction()
            }
            sections.append(UIMenu(options: .displayInline, children: [remove]))
        }

        return UIMenu(children: sections)
    }

    func editMenuInteraction(
        _ interaction: UIEditMenuInteraction,
        willDismissMenuFor configuration: UIEditMenuConfiguration,
        animator: UIEditMenuInteractionAnimating
    ) {
        animator.addCompletion { [weak self] in
            guard let self else { return }
            self.dismissedMenuCount &+= 1

            let wasHandleDismissal = self.menuDismissedForHandleDrag
            self.menuDismissedForHandleDrag = false

            // 只要还有"正在拖手柄 / 本次退场是手柄引起 / 新菜单已排队或已呈现"
            // 中的任一种，就不能恢复翻页手势、也不能清选区。
            let keepSelection = self.isAdjustingSelection
                || wasHandleDismissal
                || self.expectsSelectionMenu
                || self.isSelectionMenuPresented

            guard !keepSelection else { return }

            self.setPageCurlGesturesEnabled(true)
            self.setPageTurnTapGesturesEnabled(true)
            self.setTextTapEnabled(true)
            self.clearSelection()
        }
    }

    private func presentShareSheet(text: String) {
        guard !text.isEmpty else { return }
        let controller = UIActivityViewController(activityItems: [text], applicationActivities: nil)
        if let popover = controller.popoverPresentationController {
            popover.sourceView = view
            popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
            popover.permittedArrowDirections = []
        }
        present(controller, animated: true)
    }

    // MARK: - 标注投影

    /// SwiftUI 侧下发全书标注快照（按版本号调用，见 Representable）。
    func updateAnnotations(_ snapshots: [AnnotationSnapshot]) {
        annotationSnapshots = snapshots

        let grouped = Dictionary(grouping: snapshots, by: { $0.src })
        for (src, state) in annotationStates {
            state.apply(grouped[src] ?? [])
        }
        consumePendingAnnotationFocusIfPossible()
    }

    /// 某章的标注投影。首次访问时按当前快照创建；`layout` 在 `makeControllers`
    /// 里 attach（同一章的每一页共享这一份）。
    private func annotationState(for src: String) -> ChapterAnnotationState {
        if let existing = annotationStates[src] { return existing }

        let state = ChapterAnnotationState()
        state.apply(annotationSnapshots.filter { $0.src == src })
        annotationStates[src] = state
        return state
    }

    /// 从笔记列表跳转后的聚焦提示。目标章可能尚未加载，先记下意图。
    func focusAnnotation(_ id: UUID) {
        pendingAnnotationFocusID = id
        consumePendingAnnotationFocusIfPossible()
    }

    private func consumePendingAnnotationFocusIfPossible() {
        guard let id = pendingAnnotationFocusID else { return }

        // `pageVC` 是 IUO，首帧布局前可能还是 nil（焦点请求可能早于 viewDidLoad 到达）。
        for vc in pageVC?.viewControllers?.compactMap({ $0 as? TextViewControllerTest }) ?? [] {
            // 必须确认标注落在**这一页**：章内有、但不在可见页时，
            // 直接 flash 会画不出任何东西，还会把 pending 清掉。
            guard vc.annotation(id: id) != nil else { continue }
            // 目标页可能刚交给 pageVC、view 还没加载：`TextRenderView` 尚未创建，
            // 直接 flash 会静默丢失。先强制加载（本来也要上屏）。
            vc.loadViewIfNeeded()
            vc.flash(annotationID: id)
            pendingAnnotationFocusID = nil
            return
        }
    }

}
