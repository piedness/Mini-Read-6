//
//  BookCard.swift
//  swiftUI0907
//
//  Created by Max Piednes on 2025/9/13.
//

import SwiftUI
import SwiftData
import UIKit
import Photos


struct BookCardView: View {
    /// 尺寸策略的唯一切换点：
    ///
    /// - **固定模式**（cardSize 非 nil）：封面 scaledToFill 强制裁切进该尺寸。
    ///   使用方：Recent 横滑行（`RecentCardView`）——那里的卡片必须等高等宽才排得成一行。
    ///
    /// - **自适应模式**（cardSize == nil）：封面按**原图宽高比**呈现（aspectRatio .fit，
    ///   不裁切、不变形），宽度吃满网格列。使用方：书库网格（`BookCardFlowView`），
    ///   对齐 Apple Books 书架——不同开本的书各以自己的比例出现，同一行底部对齐。
    private let cardSize: CGSize?

    /// 封面下方是否挂「进度 + 作者」那一行。
    ///
    /// 默认开启。`RecentCardView` 传 false：它要在封面与作者之间插一行书名，
    /// 顺序是「封面 / 书名 / 进度·作者」，所以那一行由它自己摆放——
    /// 摆的是同一个 `BookProgressAuthorRow`，式样不会分叉。
    private let showsMetaRow: Bool

    let book: bookItem

    /// 固定尺寸模式：Recent 横滑行等需要等高卡片的场景。
    init(cardSize: CGSize, book: bookItem, showsMetaRow: Bool = true) {
        self.cardSize = cardSize
        self.book = book
        self.showsMetaRow = showsMetaRow
        // 角标的初始可见状态就地取好，而不是等 `onAppear` 再补：
        // 已在默认书单里的书，第一帧就该带着角标，不该空一帧、更不该弹一次。
        _isFavoriteBadgeVisible = State(initialValue: Self.isFavorite(in: book))
    }

    /// 自适应模式：封面保持原始宽高比，宽度交给布局（网格列宽）决定。
    init(book: bookItem, showsMetaRow: Bool = true) {
        self.cardSize = nil
        self.book = book
        self.showsMetaRow = showsMetaRow
        _isFavoriteBadgeVisible = State(initialValue: Self.isFavorite(in: book))
    }

    @State private var isShowFullscreen: Bool = false
    @Namespace private var bookanimation

    @State private var showDeleteConfirmation = false

    /// 「加入书单」面板。挂在卡片上而不是书架页：卡片是用户按住的那块区域，
    /// 菜单里选完立刻弹出，中间不跳页面。
    @State private var isAddingToCollection = false

    /// 元数据编辑面板（书名 / 作者 / 出版社 / 封面）。
    @State private var isEditingMetadata = false

    // MARK: 收藏角标的出场
    //
    // 角标什么时候露脸，由**两个互不相干的因素**共同决定，所以拆成两层状态：
    //
    // 1. **数据**：这本书是不是在默认书单里（`isFavorite`）。
    // 2. **场景**：现在是不是正在看这本书（`isShowFullscreen`）。
    //
    // 第一层不能直接驱动可见性。旧写法 `if isFavorite { favoriteBadge }` 让两者绑死：
    // 菜单动作一执行，`isFavorite` 就在**同一帧**翻转，角标的缩放弹入于是和菜单收起
    // 叠在一起——菜单还盖在封面上，这 0.3s 的动画整个被挡掉，用户看到的只是
    // "菜单没了，角标已经在那儿了"，观感上就是"出现得太早、来得莫名其妙"。
    // 现在数据照旧立刻变（可访问性、菜单文案都读它），可见状态晚一步跟上。
    //
    // 第二层是"让位"：点封面开书，封面 zoom 进阅读器，那枚心如果还亮着会跟着一起
    // 被推进书里，像把书架上的标记带进了正文。开书淡出、合书淡回，书架才会回到
    // 用户离开时的那一眼。

    /// 角标当前是否可见（第一层：数据）。
    @State private var isFavoriteBadgeVisible: Bool

    /// 出场任务的代号。
    ///
    /// 每排一次队就 +1，任务睡醒后先比对自己的代号：对不上说明已经被后来的操作
    /// 取代（点了收藏 → 立刻取消 → 再收藏），直接退出。
    /// 比持有 `Task` 句柄更省心——不需要在每条返回路径上把句柄清干净，
    /// 也就不会出现"句柄永远不为 nil、兜底同步被永久跳过"的僵尸态。
    @State private var favoriteBadgeRevealToken = 0

    /// 看书时角标是否已经让位（第二层：场景）。
    ///
    /// 只改透明度、不改布局：卡片高度、封面开本、网格排布都不受它影响，
    /// 所以开关书不会引起书架重排。
    @State private var isFavoriteBadgeFadedForReader = false

    /// 让位/归位任务的代号，作用同 `favoriteBadgeRevealToken`：
    /// 快速开关书时，旧的"归位"任务醒来对不上号就自己退出，不会把角标提前点亮。
    @State private var favoriteBadgeReaderToken = 0

    /// 菜单收完之后再等多久才让角标露脸。
    ///
    /// 系统 context menu 的收起动画约 0.2s。取 0.24s 是让角标正好在菜单落定的
    /// 那一刻弹入——因果连得上，又不会和那一下点按脱节（≥0.4s 就会像卡了一下才补上）。
    private static let favoriteBadgeRevealDelay: Duration = .milliseconds(240)

    /// 合上书之后，等 zoom 把封面送回原位，再让角标浮出来。
    ///
    /// 阅读器的收起转场约 0.4s。若角标从 0s 就开始淡入，它整个淡入过程都被
    /// 那层正在回落的封面盖住，等封面落定，角标已经"啪"地在那儿了——
    /// 用户要的"缓缓出现"根本看不见。等 0.25s，让封面先落位，再从容淡入。
    private static let favoriteBadgeReturnDelay: Duration = .milliseconds(250)

    // MARK: 封面位图
    //
    // 封面**不在 `body` 里读盘**。旧写法把 `UIImage(contentsOfFile:)` 直接写在
    // `body` 的 `if let` 里，等于"卡片每重绘一次就重新读一遍盘、新建一张未解码的
    // UIImage"。而「存封面到相册」这条链路里卡片至少要重绘三次：菜单收起 →
    // 成功勾出现 → 1.4s 后勾消失。每次重绘都换掉图片内容，未解码的那几帧就是空白，
    // 观感正是"封面闪几下"。
    //
    // 现在：`body` 只做内存缓存查询（O(1)），真正读盘交给 `.task` 在后台做一次。
    // 复用 `CoverThumbnail`（ImageIO 降采样 + NSCache），与书单拼图、列表缩略图
    // 共用同一份缓存与同一套降采样参数，不再有第二套封面加载实现。
    @State private var coverState: CoverState = .loading

    private enum CoverState {
        case loading
        case loaded(UIImage)
        /// 文件缺失或解码失败——与"本来就没有封面"同样处理。
        case unavailable
    }

    /// 单张封面的解码预算。
    ///
    /// 网格列宽约 166pt，@3x 下 498px；取 1000 是给 zoom 转场放大留的余量，
    /// 同时把单张解码位图压在 2.7MB 左右（缓存有 96MB 字节预算兜底）。
    private static let coverPixelBudget: CGFloat = 1000

    private var coverURL: URL? { book.coverImageURLs.first }

    // MARK: 存封面的反馈
    //
    // 菜单项点下去菜单就消失了，在按钮上做动画没人看得见——
    // 反馈只能落在卡片上，而且必须区分成功与失败：
    // 旧写法 `UIImageWriteToSavedPhotosAlbum(_, nil, nil, nil)` 三个 nil，
    // 没权限、写失败、写成功全都无声，用户点完只能靠猜。

    /// 成功：封面中央闪一枚勾，1.4s 后自动淡出。
    @State private var isShowingCoverSaved = false
    @State private var isShowingCoverSaveError = false
    @State private var coverSaveErrorMessage = ""
    /// 失败原因是权限问题——只有这种才值得给一个「去设置」的出口。
    @State private var coverSaveFailureNeedsSettings = false

    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 确认弹窗用的标题快照。
    /// 走 SwiftData 删除后对象即失效，而退出转场期间 body 仍在求值——
    /// 这里提前把标题抓下来，转场过程中就不必再去读 model 属性。
    @State private var pendingDeleteTitle: String = ""

    var body: some View {
        // 无封面兜底：占位图走同一条卡片路径，行为（含保存、删除）与真实封面一致。
        // 位图尚未到位时传 nil，卡片画一块同开本的骨架（见 `sizedCover`）。
        coverCard(displayedCover.map(Image.init(uiImage:)))
            .task(id: coverURL) { await loadCover() }
            .alert("删除「\(pendingDeleteTitle)」？", isPresented: $showDeleteConfirmation) {
                Button("删除", role: .destructive) { performDelete() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("这本书将从你的书库中移除。")
            }
            // 刻意挂在 `body` 这一层、而不是 `coverCard` 里：
            // 「加入书单」的 sheet 挂在卡片 VStack 上，两个 sheet 修饰器落在同一节点时
            // SwiftUI 只会保留最后一个。分挂两处，两个面板各自都能正常弹出。
            .sheet(isPresented: $isEditingMetadata) {
                BookMetadataLibraryView(initialBook: book)
            }
    }

    // MARK: - 封面加载

    /// 当前该显示的封面位图。
    ///
    /// 三条来源按优先级：已加载的结果 → 内存缓存命中 → 占位图。
    /// **三条都不碰磁盘**，所以卡片重绘多少次都不会再出现空白帧；
    /// 首帧就能命中缓存，也不会闪一下占位图。
    private var displayedCover: UIImage? {
        switch coverState {
        case .loaded(let image):
            return image
        case .unavailable:
            return UIImage(named: "coverTest1")
        case .loading:
            guard let coverURL else { return UIImage(named: "coverTest1") }
            return CoverThumbnail.cachedNatural(url: coverURL, maxPixel: Self.coverPixelBudget)
        }
    }

    /// 封面开本（宽 / 高）。
    ///
    /// 图还没到位时也要给出正确比例：骨架与真封面形状一致，图一到位才不会
    /// 引起整行高度跳动。所以未加载时读文件头（只解析尺寸、不解码像素）。
    private var coverAspect: CGFloat {
        if case .loaded(let image) = coverState { return naturalAspect(of: image) }
        guard let coverURL, let aspect = CoverThumbnail.aspect(url: coverURL) else {
            return 2.0 / 3.0
        }
        return aspect
    }

    /// 读一次盘，把封面位图放进 `@State`。之后所有重绘都只读这份状态。
    private func loadCover() async {
        guard let coverURL else {
            coverState = .unavailable
            return
        }

        let budget = Self.coverPixelBudget

        // 内存命中（切回书库、横竖屏切换、卡片被复用）直接上屏，不走后台任务
        if let hit = CoverThumbnail.cachedNatural(url: coverURL, maxPixel: budget) {
            coverState = .loaded(hit)
            return
        }

        let loaded = await Task.detached(priority: .userInitiated) {
            CoverThumbnail.natural(url: coverURL, maxPixel: budget)
        }.value

        // `.task(id:)` 在封面被替换时会取消旧任务：别让旧图盖掉新图
        guard !Task.isCancelled else { return }
        coverState = loaded.map(CoverState.loaded) ?? .unavailable
    }

    // MARK: - 封面卡片

    /// 尺寸策略 + 精装质感 + 封面下方元信息 + 打开阅读器 + 上下文菜单。
    /// 真实封面、占位图、加载骨架共用同一条路径，两种模式的行为不会再漂移。
    private func coverCard(_ image: Image?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sizedCover(image)
                .premiumHardcoverStyle()
                .matchedTransitionSource(id: "bookContent", in: bookanimation)
                // 封面本身没有文字可念，显式给书名，VoiceOver 才不会读出一片空白
                .accessibilityLabel(book.bookTitle)
                .overlay(alignment: .topTrailing) {
                    if isFavoriteBadgeVisible {
                        favoriteBadge
                            .opacity(isFavoriteBadgeFadedForReader ? 0 : 1)
                    }
                }
                // 存封面的成功反馈：菜单已关闭，所以画在封面上才看得见。
                .overlay {
                    ZStack {
                        if isShowingCoverSaved {
                            coverSavedBadge
                        }
                    }
                    .animation(
                        reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.66),
                        value: isShowingCoverSaved
                    )
                }

            if showsMetaRow {
                BookProgressAuthorRow(progress: book.readingProgress, author: book.bookAuthor)
            }
        }
        .padding(5)
        // 整张卡片合成一个可访问性元素：一次划过读出
        // 「书名，阅读进度 45%，作者 某某」并提示可点按，而不是散成三块碎片。
        .accessibilityElement(children: .combine)
        .accessibilityValue(isFavorite ? "已收藏" : "")
        .accessibilityAddTraits(.isButton)
        .task(id: isShowingCoverSaved) {
            // 勾号是"一次性"反馈，留在封面上会变成第二个常驻图标，反而看不懂。
            guard isShowingCoverSaved else { return }
            try? await Task.sleep(for: .seconds(1.4))
            isShowingCoverSaved = false
        }
        .onChange(of: isFavorite) { _, favorite in
            syncFavoriteBadge(to: favorite)
        }
        // 开书/合书：角标让位与归位。`isShowFullscreen` 在点封面那一刻就翻 true、
        // 在阅读器 dismiss 的那一刻翻回 false，正好是两段转场的起点。
        .onChange(of: isShowFullscreen) { _, isPresented in
            syncFavoriteBadgeForReader(isPresented: isPresented)
        }
        .onAppear {
            // 兜底：卡片被复用或重新上屏时，数据可能已经在别处改过、而这里没收到
            // onChange。首帧不会闪——`init` 已经按同一判据取好了初始值，
            // 这里通常是一次等值赋值，什么都不会发生。
            isFavoriteBadgeVisible = isFavorite
        }
        .alert("无法存储封面", isPresented: $isShowingCoverSaveError) {
            if coverSaveFailureNeedsSettings {
                Button("去设置") { openSystemSettings() }
            }
            Button("好", role: .cancel) {}
        } message: {
            Text(coverSaveErrorMessage)
        }
        .onTapGesture {
            isShowFullscreen.toggle()
        }
        .fullScreenCover(isPresented: $isShowFullscreen) {
            BookContentView(book: book, modelContext: modelContext)
                .navigationTransition(.zoom(sourceID: "bookContent", in: bookanimation))
        }
        // 与书单详情页的加书面板同一套组件，方向相反：这里挑书单，那里挑书。
        .sheet(isPresented: $isAddingToCollection) {
            BookCollectionsPicker(book: book)
        }
        .contextMenu {
            // 菜单分四组，节奏对齐 Apple Books：主操作横排 → 编辑 → 导出 → 删除。
            //
            // 前两条走 `ControlGroup`：菜单里的 ControlGroup 会渲染成**横排的大图标按钮**
            // （就是参考图顶部 Share / Want to Read 那一行）。收藏和加书单是这里最常用的
            // 两个动作，值得占据这一行，而不是和其它项一样挤成一行文字。
            ControlGroup {
                Button {
                    toggleDefaultCollection()
                } label: {
                    Label(
                        isFavorite ? "Unfavorite" : "Favorite",
                        systemImage: isFavorite ? "heart.slash" : "heart"
                    )
                }


                Button {
                    isAddingToCollection = true
                } label: {
                    Label("Add to Collection", systemImage: "text.badge.plus")
                }
            }
            
            Button {
                saveCoverToPhotos()
            } label: {
                Label("Save Cover", systemImage: "photo.badge.arrow.down.fill")
            }

            Button {
                isEditingMetadata = true
            } label: {
                Label("Edit", systemImage: "square.and.pencil")
            }

            Divider()

            Button(role: .destructive) {
                requestDelete()
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    /// 尺寸策略：
    /// - 固定模式：scaledToFill + 显式 frame，裁切成统一开本（旧行为，保持不变）。
    /// - 自适应模式：resizable + aspectRatio(.fit)——LazyVGrid 只约束列宽、不约束高，
    ///   于是封面宽度吃满列、高度按原图比例自然得出，整行底部对齐
    ///   （配合 GridItem 的 alignment: .bottom）。
    ///
    /// 位图为 `nil`（还没加载出来）时画一块**同开本**的骨架，而不是留空或临时
    /// 换成 2:3：形状与最终封面一致，图一到位不会引起整行重排。
    ///
    /// 这里**不裁圆角、不加阴影**：两者都由 `premiumHardcoverStyle()` 统一提供
    /// （见 `coverCard`）。两处各写一份，就会出现「10pt 裁切套着 4pt 书槽」
    /// 和两层影叠加的问题。
    @ViewBuilder
    private func sizedCover(_ image: Image?) -> some View {
        if let size = cardSize {
            coverContent(image)
                .scaledToFill()
                .frame(width: size.width, height: size.height)
        } else {
            coverContent(image)
                .aspectRatio(coverAspect, contentMode: .fit)
        }
    }

    @ViewBuilder
    private func coverContent(_ image: Image?) -> some View {
        if let image {
            image.resizable()
        } else {
            ZStack {

                // 纯色块，圆角交给 `premiumHardcoverStyle()` 裁：
                // 占位块自己再写一个半径，改精装圆角时就会漏改这一处。
                Rectangle()
                    .fill(.ultraThinMaterial)

                // 图形只在**确实没有封面**时出现：加载中画图标会闪一下，
                // 反而更像故障。
                if isCoverUnavailable {
                    Image(systemName: "book.closed")
                        .font(.system(size: 24, weight: .light))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    /// 封面确定取不到了（文件缺失 / 解码失败），不是"还在加载"。
    private var isCoverUnavailable: Bool {
        if case .unavailable = coverState { return true }
        return false
    }

    /// 原图宽高比。异常数据（宽或高为 0）回退到 2:3 的常规书衣开本。
    private func naturalAspect(of image: UIImage) -> CGFloat {
        guard image.size.width > 0, image.size.height > 0 else { return 2.0 / 3.0 }
        return image.size.width / image.size.height
    }

    // MARK: - 收藏（默认书单）

    /// 这本书在不在「my favorite」里。
    ///
    /// 走反向关系（书 → 所属书单），**不再** fetch 默认书单：
    /// `DefaultCollection.existing(in:)` 是一次全库查询，原先只在 `contextMenu` 的懒闭包里
    /// 求值才安全；现在角标要画在 `body` 里，每张卡片每次重绘都 fetch 一次会拖垮书库网格。
    /// 关系遍历是 O(该书所属书单数)，通常 0–3 条。
    ///
    /// 关系变更的观察已实测：从 `collection.books` 一侧增删，`book.collections` 的
    /// `withObservationTracking` 回调会触发，所以角标能跟着状态出现/消失。
    /// （出现要晚一步才上屏，那是 `syncFavoriteBadge(to:)` 的时机策略，与本判据无关。）
    private var isFavorite: Bool {
        Self.isFavorite(in: book)
    }

    /// 「这本书在默认书单里」的唯一判据。
    ///
    /// 抽成 static 是为了让 `init` 也能用它取角标的初始可见状态——
    /// 否则 `init` 里得再写一遍 `book.collections.contains { $0.isDefault }`，
    /// 两处判据一旦分叉，角标和菜单文案就会互相打脸。
    private static func isFavorite(in book: bookItem) -> Bool {
        book.collections.contains { $0.isDefault }
    }

    /// 一下加入 / 移出默认书单。
    ///
    /// 用 `ensure` 而不是 `existing`：万一默认书单被清掉（清库、迁移），
    /// 这条菜单也不该变成空操作——当场补一个再把书放进去。
    private func toggleDefaultCollection() {
        let collection = DefaultCollection.ensure(in: modelContext)
        let wasMember = collection.contains(book)

        withAnimation(reduceMotion ? .easeOut(duration: 0.15)
                                   : .spring(duration: 0.35, bounce: 0.12)) {
            if wasMember {
                collection.remove(book)
            } else {
                collection.add(book)
            }
        }
        try? modelContext.save()
        triggerHaptic(.light)
    }

    // MARK: - 角标

    /// 让角标的可见状态跟上数据状态，出场时机就在这里定。
    ///
    /// - **收藏**：延后 `favoriteBadgeRevealDelay` 再弹。菜单收起要 0.2s 左右，
    ///   同一帧插入的话入场动画会被菜单的淡出整个盖住（详见文件上方注释）。
    /// - **取消收藏**：立刻消失，不等。移除的反馈就是"它不在了"，
    ///   拖半秒反而像点了没反应。
    ///
    /// 用 `Task` 而不是 `DispatchQueue.main.asyncAfter`：后者没法作废，
    /// 快速连点时会留下一个到点就把角标点亮、却和当前状态对不上的旧任务。
    private func syncFavoriteBadge(to favorite: Bool) {
        // 作废所有在途的出场任务（代号一变，它们醒来就对不上号）
        favoriteBadgeRevealToken &+= 1
        let token = favoriteBadgeRevealToken

        guard favorite else {
            withAnimation(badgeDismissAnimation) {
                isFavoriteBadgeVisible = false
            }
            return
        }

        // 已经亮着（例如从「加入书单」面板里改了归属又回来）就不必再排一次队
        guard !isFavoriteBadgeVisible else { return }

        Task { @MainActor in
            try? await Task.sleep(for: Self.favoriteBadgeRevealDelay)
            // 睡醒先验票：这期间用户可能又切了一次
            guard token == favoriteBadgeRevealToken else { return }
            withAnimation(badgeRevealAnimation) {
                isFavoriteBadgeVisible = true
            }
        }
    }

    /// 出场：与原来的弹入曲线一致，只是晚一步。
    private var badgeRevealAnimation: Animation? {
        reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.62)
    }

    /// 退场：短促淡出，不用弹簧。它是在"撤销"，不该有庆祝感。
    private var badgeDismissAnimation: Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.16)
    }

    // MARK: 看书时让位

    /// 开书让位 / 合书归位。
    ///
    /// 和 `syncFavoriteBadge(to:)` 是两套独立状态，互不覆盖：
    /// - 那个管"这本书是不是收藏"（数据），出场带一点弹性，是"记下了"的语气；
    /// - 这个管"现在是不是在看书"（场景），**只动透明度**——不位移、不缩放。
    ///   翻书时书架上的装饰不该有任何动作来抢注意力，淡进淡出是最安静的做法。
    ///
    /// 合书这一侧要等：收起转场约 0.4s，封面正盖在卡片上方往回落，
    /// 角标若从 0s 就开始淡入，整个淡入过程都在那层封面底下，等于白淡。
    /// 等 0.25s 让封面先落位，再花 0.5s 缓缓浮出来。
    private func syncFavoriteBadgeForReader(isPresented: Bool) {
        favoriteBadgeReaderToken &+= 1
        let token = favoriteBadgeReaderToken

        guard !isPresented else {
            // 开书：立刻开始淡出，赶在 zoom 把封面推走之前退干净。
            withAnimation(badgeFadeOutForReaderAnimation) {
                isFavoriteBadgeFadedForReader = true
            }
            return
        }

        Task { @MainActor in
            try? await Task.sleep(for: Self.favoriteBadgeReturnDelay)
            // 这期间又开了一次书？那这次归位就作废
            guard token == favoriteBadgeReaderToken else { return }
            withAnimation(badgeReturnForReaderAnimation) {
                isFavoriteBadgeFadedForReader = false
            }
        }
    }

    /// 让位：比转场略快，封面被推走时角标已经淡干净。
    private var badgeFadeOutForReaderAnimation: Animation {
        reduceMotion ? .easeOut(duration: 0.2) : .easeOut(duration: 0.3)
    }

    /// 归位：慢、匀，是"浮回来"而不是"弹回来"。
    ///
    /// 这一层即便开了「减弱动态效果」也保留淡入——透明度变化不是前庭刺激，
    /// 不属于该系统设置要压制的那类动效，只是把时长压短。
    private var badgeReturnForReaderAnimation: Animation {
        reduceMotion ? .easeOut(duration: 0.2) : .easeInOut(duration: 0.5)
    }

    /// 收藏角标：白心 + 半透明黑底。
    ///
    /// 不用 `heart.fill` 原色（红/粉）：封面本身可能是任何颜色，纯色心形在红封面上会糊掉。
    /// 深色圆底 + 白色图形在任何封面上都有稳定对比度，也不会抢走封面的主角位置。
    private var favoriteBadge: some View {
        Image(systemName: "heart.fill")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.white)
            .padding(5)
            .background(.black.opacity(0.45), in: Circle())
            .padding(6)
            .transition(.scale(scale: 0.4).combined(with: .opacity))
            // 状态已经并进卡片朗读（accessibilityValue），这里不必再念一遍"心形"
            .accessibilityHidden(true)
    }

    /// 存封面的成功回执：封面正中的勾，1.4s 后自动淡出（见 `coverCard` 里的 `.task`）。
    private var coverSavedBadge: some View {
        Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 32, weight: .semibold))
            .symbolRenderingMode(.palette)
            .foregroundStyle(.white, .black.opacity(0.5))
            .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
            .transition(.scale(scale: 0.7).combined(with: .opacity))
            .accessibilityHidden(true)
    }

    // MARK: - 存封面到相册

    /// 把封面写进系统相册，并把结果变成看得见的反馈。
    ///
    /// 三步都要：
    /// 1. **显式请求 add-only 权限**——没权限时直接写会静默失败，用户只会觉得"点了没反应"；
    /// 2. `performChanges` 的结果决定成功还是失败——旧实现传了三个 `nil`，成功失败都无声；
    /// 3. 成功画勾 + 成功触觉，失败弹 alert（权限问题额外给「去设置」）。
    ///
    /// 写进相册的是**原图**，不是网格里那张降采样缩略图：用户点"存储封面"
    /// 要的是一张能用的图，给他一张 1000px 的缩略图等于给了一张糊图。
    private func saveCoverToPhotos() {
        Task {
            guard let image = await fullSizeCover() else {
                presentCoverSaveFailure("找不到这本书的封面文件，无法保存。", needsSettings: false)
                return
            }

            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else {
                presentCoverSaveFailure(
                    "没有相册写入权限。请到「设置 → 隐私与安全性 → 照片」里允许本 App 添加照片。",
                    needsSettings: true
                )
                return
            }

            do {
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.creationRequestForAsset(from: image)
                }
            } catch {
                let message = error.localizedDescription
                presentCoverSaveFailure(message.isEmpty ? "无法把封面写入相册。" : message,
                                        needsSettings: false)
                return
            }

            triggerNotificationHaptic(.success)
            // 动画交给封面上的 `.animation(value:)`，这里只改状态：
            // 用 `withAnimation` 会把整张卡片（含离屏合成的精装层）拖进同一事务。
            isShowingCoverSaved = true
        }
    }

    /// 相册用的原图。
    ///
    /// 后台只读字节（`Data` 是 Sendable，`UIImage` 不是），回到主线程再建壳：
    /// `UIImage(data:)` 是懒解码，真正的解码发生在 `performChanges` 自己的队列上，
    /// 不会把几十毫秒的解码压在主线程。
    private func fullSizeCover() async -> UIImage? {
        guard let coverURL else {
            // 没有封面文件的兜底书：存的就是卡片上那张占位图
            return UIImage(named: "coverTest1")
        }

        let data = await Task.detached(priority: .userInitiated) {
            try? Data(contentsOf: coverURL, options: .mappedIfSafe)
        }.value

        guard let data else { return nil }
        return UIImage(data: data)
    }

    private func presentCoverSaveFailure(_ message: String, needsSettings: Bool) {
        triggerNotificationHaptic(.error)
        coverSaveErrorMessage = message
        coverSaveFailureNeedsSettings = needsSettings
        isShowingCoverSaveError = true
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    // MARK: - 删除

    private func requestDelete() {
        pendingDeleteTitle = book.bookTitle
        showDeleteConfirmation = true
    }

    private func performDelete() {
        // 先把待清理的目录抓在手里：删除生效后对象即失效，别在动画块里访问它
        let dirs = [book.bookExtrSubdir, book.bookBackupdir, book.resourceBaseURL]

        // 关键：删除必须落在一个带动画的事务里。
        // 否则 modelContext.delete 只触发 @Query 刷新，视图一帧重绘、卡片瞬间消失，
        // 下面的 Collections 是被"瞬移"顶上来的，而不是滑上来的。
        // （书库网格里这条曲线会被 BookCardFlowView 容器上的 .animation(value:) 覆盖，
        // 这里保留是为了 Recent 横滑行等没有容器动画的场景。）
        withAnimation(reduceMotion ? .easeOut(duration: 0.15)
                                   : .spring(duration: 0.45, bounce: 0.15)) {
            modelContext.delete(book)
            try? modelContext.save()
        }

        // 删除已提交，先给一次明确反馈，再去做磁盘清理。
        // 位置刻意在 `withAnimation` 之后、`removeItem` 之前：
        // 前者是"撤销不了"的那一刻，后者是同步 I/O（可能要等一会儿），
        // 反馈不该排在那段 I/O 后面等。用 `.medium` 而非 warning——
        // 用户已经在确认弹窗里点过「删除」了，这里要表达的是"完成了"，
        // 不是"危险"。
        triggerHaptic(.medium)

        // 磁盘清理放在动画事务之外：FileManager 删除是同步 I/O，
        // 卡在动画块里会拖慢转场的第一帧，观感上就是"顿一下"。
        for dir in dirs {
            try? FileManager.default.removeItem(at: dir)
        }
    }
}

// MARK: - 封面下方的一行：阅读进度 + 作者

/// 封面正下方那一行：阅读进度百分数与作者并列，只占一行的高度。
///
/// 设计取舍：
/// - **只占一行**。书架是扫视场景，每多一行文字就把封面推远一寸、削弱"书墙"的节奏。
/// - **进度靠字重区分，不靠色块**。加底色胶囊会在封面上多出一个视觉锚点，抢走主角；
///   而且胶囊在浅色/深色模式下都要单独调对比度，收益不抵维护成本。
/// - **没读过的书不显示百分数**，改用一个主题色圆点占位。书架里未读的书是多数，
///   给每本都盖一个 0% 是纯噪音；但完全留白又会让这一行看起来像"坏了/没加载出来"。
///   一颗 6pt 的点既说明了"这本书还没开始"，又和目录面板里"当前阅读"的指示点
///   是同一套视觉语汇（`Eleganttocpanel` 里也是 6pt 主题色圆点）。
struct BookProgressAuthorRow: View {
    /// 阅读进度 0.0~1.0。`nil` 表示分母未知（书还没打开统计过），视同未读。
    let progress: Double?

    let author: String

    /// 与目录面板的"当前阅读"指示点同尺寸。
    private let dotDiameter: CGFloat = 6

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            if showsProgress {
                Text(percentText)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                    // 百分数绝不被压缩或截断——空间不够时先牺牲作者名。
                    .fixedSize()
            } else {
                Circle()
                    // 用 ShapeStyle.tint 而不是 Color.accentColor：
                    // 后者只认 Assets 里的 AccentColor，不跟随用户在
                    // 「个性化」里选的 appTintColorHex（那个是通过 .tint() 下发的）。
                    .fill(.tint)
                    .frame(width: dotDiameter, height: dotDiameter)
                    // 圆点比文字行高矮得多，给足水平留白免得贴在作者名上；
                    // 左侧补 1pt，让圆心大致落在百分数字形的视觉中线上。
                    .padding(.leading, 1)
                    .padding(.trailing, 2)
            }

            Text(author)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                // 吃掉剩余宽度，让整行左对齐到封面左边缘；
                // 不给这个 maxWidth，HStack 会按内容宽度收缩，行高虽不变但截断时机不对。
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        // 同行文字同为 .caption，中线即基线；统一用 .center 是为了让没有基线的
        // 圆点也能稳稳落在行中，不必去猜 firstTextBaseline 会给它按哪个边对齐。
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    // MARK: - 内容

    /// 只有真正读过的书才值得占这一行的前段。
    private var showsProgress: Bool {
        guard let progress else { return false }
        return progress > 0
    }

    private var percentText: String {
        guard let progress else { return "" }
        let clamped = min(max(progress, 0), 1)
        // 读过但不足 1% 时向上取到 1%：否则会显示一个自相矛盾的 "0%"。
        return "\(max(1, Int((clamped * 100).rounded())))%"
    }

    private var accessibilityText: String {
        guard showsProgress else { return "未读，作者 \(author)" }
        return "阅读进度 \(percentText)，作者 \(author)"
    }
}
