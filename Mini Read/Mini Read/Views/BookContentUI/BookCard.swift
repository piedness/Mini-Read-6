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
    }

    /// 自适应模式：封面保持原始宽高比，宽度交给布局（网格列宽）决定。
    init(book: bookItem, showsMetaRow: Bool = true) {
        self.cardSize = nil
        self.book = book
        self.showsMetaRow = showsMetaRow
    }

    @State private var isShowFullscreen: Bool = false
    @Namespace private var bookanimation

    @State private var showDeleteConfirmation = false

    /// 「加入书单」面板。挂在卡片上而不是书架页：卡片是用户按住的那块区域，
    /// 菜单里选完立刻弹出，中间不跳页面。
    @State private var isAddingToCollection = false

    /// 元数据编辑面板（书名 / 作者 / 出版社 / 封面）。
    @State private var isEditingMetadata = false

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
        Group {
            if let firstURL = book.coverImageURLs.first,
               let uiImage = UIImage(contentsOfFile: firstURL.path) {
                coverCard(Image(uiImage: uiImage), saveSource: uiImage)
            } else if let placeholder = UIImage(named: "coverTest1") {
                // 无封面兜底：占位图走同一条卡片路径，行为（含保存、删除）与真实封面一致
                coverCard(Image(uiImage: placeholder), saveSource: placeholder)
            }
        }
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

    // MARK: - 封面卡片

    /// 尺寸策略 + 精装质感 + 封面下方元信息 + 打开阅读器 + 上下文菜单。
    /// 真实封面与占位图共用同一条路径，两种模式的行为不会再漂移。
    private func coverCard(_ image: Image, saveSource: UIImage) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sizedCover(image, of: saveSource)
                .premiumHardcoverStyle()
                .matchedTransitionSource(id: "bookContent", in: bookanimation)
                // 封面本身没有文字可念，显式给书名，VoiceOver 才不会读出一片空白
                .accessibilityLabel(book.bookTitle)
                // 收藏角标。既是"刚才那一下生效了"的即时反馈，也是长期可见的状态——
                // 没有它的话，用户点完 Favorite 从书架上完全看不出区别。
                .overlay(alignment: .topTrailing) {
                    if isFavorite {
                        favoriteBadge
                    }
                }
                .animation(
                    reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.62),
                    value: isFavorite
                )
                // 存封面的成功反馈：菜单已关闭，所以画在封面上才看得见。
                .overlay {
                    if isShowingCoverSaved {
                        coverSavedBadge
                    }
                }

            if showsMetaRow {
                BookProgressAuthorRow(progress: book.readingProgress, author: book.bookAuthor)
            }
        }
        // 整张卡片合成一个可访问性元素：一次划过读出
        // 「书名，阅读进度 45%，作者 某某」并提示可点按，而不是散成三块碎片。
        .accessibilityElement(children: .combine)
        .accessibilityValue(isFavorite ? "已收藏" : "")
        .accessibilityAddTraits(.isButton)
        .task(id: isShowingCoverSaved) {
            // 勾号是"一次性"反馈，留在封面上会变成第二个常驻图标，反而看不懂。
            guard isShowingCoverSaved else { return }
            try? await Task.sleep(for: .seconds(1.4))
            withAnimation(.easeOut(duration: 0.25)) {
                isShowingCoverSaved = false
            }
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
                saveCoverToPhotos(saveSource)
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
    private func sizedCover(_ image: Image, of source: UIImage) -> some View {
        Group {
            if let size = cardSize {
                image
                    .resizable()
                    .scaledToFill()
                    .frame(width: size.width, height: size.height)
            } else {
                image
                    .resizable()
                    .aspectRatio(naturalAspect(of: source), contentMode: .fit)
            }
        }
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
    /// `withObservationTracking` 回调会触发，所以角标能跟着动画即时出现/消失。
    private var isFavorite: Bool {
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
    /// 2. `performChanges` 的回调里拿成功/失败——旧实现传了三个 `nil`，成功失败都无声；
    /// 3. 成功画勾 + 成功触觉，失败弹 alert（权限问题额外给「去设置」）。
    private func saveCoverToPhotos(_ image: UIImage) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            Task { @MainActor in
                guard status == .authorized || status == .limited else {
                    presentCoverSaveFailure(
                        "没有相册写入权限。请到「设置 → 隐私与安全性 → 照片」里允许本 App 添加照片。",
                        needsSettings: true
                    )
                    return
                }

                PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.creationRequestForAsset(from: image)
                } completionHandler: { success, error in
                    Task { @MainActor in
                        guard success else {
                            presentCoverSaveFailure(
                                error?.localizedDescription ?? "无法把封面写入相册。",
                                needsSettings: false
                            )
                            return
                        }

                        triggerNotificationHaptic(.success)
                        withAnimation(reduceMotion ? .easeOut(duration: 0.15)
                                                   : .spring(response: 0.32, dampingFraction: 0.66)) {
                            isShowingCoverSaved = true
                        }
                    }
                }
            }
        }
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
