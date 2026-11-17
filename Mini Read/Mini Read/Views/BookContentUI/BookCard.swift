//
//  BookCard.swift
//  swiftUI0907
//
//  Created by Max Piednes on 2025/9/13.
//

import SwiftUI
import SwiftData
import UIKit


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

            if showsMetaRow {
                BookProgressAuthorRow(progress: book.readingProgress, author: book.bookAuthor)
            }
        }
        // 整张卡片合成一个可访问性元素：一次划过读出
        // 「书名，阅读进度 45%，作者 某某」并提示可点按，而不是散成三块碎片。
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
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
            // 收藏放在第一条：它是这个菜单里最轻、最常用的一次操作，
            // 一下完成，不弹面板。其余"归入某个书单"才走下面的选择器。
            Button {
                toggleDefaultCollection()
            } label: {
                Label(
                    isInDefaultCollection ? "Remove from My Favorite" : "Add to My Favorite",
                    systemImage: isInDefaultCollection ? "heart.slash" : "heart"
                )
            }
            Button {
                isAddingToCollection = true
            } label: {
                Label("Add to Collection…", systemImage: "text.badge.plus")
            }
            Button {
                UIImageWriteToSavedPhotosAlbum(saveSource, nil, nil, nil)
            } label: {
                Label("Save Cover Image", systemImage: "photo.badge.arrow.down.fill")
            }
            Divider()
            Button(role: .destructive) {
                requestDelete()
            } label: {
                Label("删除", systemImage: "trash")
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
    /// 只在菜单弹出时求值——`contextMenu` 的内容闭包是懒执行的，所以书库网格
    /// 每次 body 求值都不会为每张卡片各 fetch 一次（几百本书时那是灾难）。
    private var isInDefaultCollection: Bool {
        DefaultCollection.existing(in: modelContext)?.contains(book) ?? false
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
