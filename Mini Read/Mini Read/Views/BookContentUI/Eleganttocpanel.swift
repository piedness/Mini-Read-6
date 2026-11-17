import SwiftUI

// MARK: - 页签

/// 目录面板的两个页签。
///
/// 「笔记」暂不进入页签：笔记系统还是空壳（见项目审计 N11），
/// 放一个点了没内容的页签比不放更糟。
private enum TOCPanelTab: Hashable {
    case contents
    case bookmarks
}

// MARK: - 顶级优雅目录面板 (The Integrated Premium Panel)
struct ElegantTOCPanel: View {
    // 注入你设计的标准 ObservableObject ViewModel
    @ObservedObject var viewModel: ContentsPanelViewModel
    @State private var selectedTab: TOCPanelTab = .contents
    
    // ✅ 新增：章节选中回调
    var onChapterSelected: (() -> Void)? = nil
    
    var body: some View {
        VStack(spacing: 0) {
            // 顶部间距
            Spacer().frame(height: 20)
            
            // 1. 书籍元数据头部 (解耦业务数据)
            BookHeaderView(
                bookTitle: viewModel.book.bookTitle,
                author: viewModel.book.bookAuthor,
                coverURLs: viewModel.book.coverImageURLs
            )
                .padding(.horizontal, 28)
                .padding(.bottom, 20)
            
            // 2. 页签：目录 / 书签
            //
            // 书签数量直接挂在页签上：读者打开面板的第一眼就知道
            // "这本书我标了几处"，不必先切过去数一遍。
            TOCPanelTabBar(
                selection: $selectedTab,
                bookmarkCount: viewModel.bookmarks.count
            )
            .padding(.horizontal, 28)
            .padding(.bottom, 12)
            
            // 3. 核心内容区：处理加载状态与业务渲染
            if selectedTab == .contents {
                contentsSection
                    .transition(.opacity)
            } else {
                bookmarksSection
                    .transition(.opacity)
            }
        }
        // 这里刻意**不再**挂 `.animation(value: expandedChapters)`。
        //
        // 隐式动画会把任何一次展开状态变更都放大成整棵树的重排动画，
        // 而打开面板时正好还有一次滚动定位要跑：两段动画抢同一个事务，
        // 读者看到的就是"点开目录，列表先从第一章滑到当前章"。
        // 展开/折叠的动画现在只在点击处用 `withAnimation` 触发
        // （见 `ParentChapterRow`），面板打开时的自动展开保持瞬时。
        //
        // `isLoading` 同理：它只在目录解析完成时翻转一次，而那时阅读器
        // 往往还没建起来，给骨架屏加淡出只是多一次全树动画。
    }
    
    // MARK: - 目录页签
    
    @ViewBuilder
    private var contentsSection: some View {
        if viewModel.isLoading {
            // 完美接入你的 isLoading 状态：优雅的骨架屏占位
            TOCSkeletonView()
                .transition(.opacity)
        } else {
            // 使用 ScrollViewReader，让目录面板在打开时
            // 直接把当前阅读的章节摆在第一帧上（不做滚动动画）。
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(viewModel.chapters) { chapter in
                            // 一级大章行
                            ParentChapterRow(
                                chapter: chapter,
                                viewModel: viewModel,
                                onSelected: onChapterSelected
                            )
                                .id(chapter.id)
                            
                            // 优雅的自适应子章节展开
                            //
                            // 叶子章节（目录里只有它自己）不展开：父行本身就是
                            // 可跳转的章节行，再展开一条同名子行只是重复。
                            if !chapter.isLeaf && viewModel.isExpanded(chapter.id) {
                                ForEach(chapter.subChapters) { subChapter in
                                    ChildSubChapterRow(
                                        subChapter: subChapter,
                                        viewModel: viewModel,
                                        onSelected: onChapterSelected  // ✅ 透传
                                    )
                                        .id(subChapter.id)
                                        // 只做淡入淡出。
                                        //
                                        // 行本身已经跟着布局动画整体位移了，
                                        // 再叠一层 `.move(edge: .top)` 等于让同一条路径
                                        // 走两遍（布局推一次、transition 再推一次），
                                        // 视觉上就是展开瞬间"抖一下"。
                                        .transition(.opacity)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 32)
                }
                .scrollIndicators(.hidden)
                .transition(.opacity)
                // 打开面板 = 第一帧就落在当前章节。见 `positionOnOpen`。
                .onAppear { positionOnOpen(in: proxy) }
                // 首帧之后的一次校正（LazyVStack 的高度是估算的）。见下方。
                .task { await settleInitialPosition(in: proxy) }
            }
        }
    }
    
    // MARK: - 书签页签
    
    @ViewBuilder
    private var bookmarksSection: some View {
        if viewModel.bookmarks.isEmpty {
            TOCBookmarksEmptyView()
        } else {
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(viewModel.bookmarks) { bookmark in
                        BookmarkRow(bookmark: bookmark, viewModel: viewModel) {
                            onChapterSelected?()
                        }
                    }
                    
                    // 长按删除不是自解释的手势，给一行极轻的提示；
                    // VoiceOver 侧另有命名动作，故对读屏隐藏这行。
                    Text("轻点跳转 · 长按删除")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundColor(.secondary.opacity(0.7))
                        .padding(.top, 14)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
            .scrollIndicators(.hidden)
            .transition(.opacity)
        }
    }
    
    // MARK: - 当前阅读位置定位
    
    /// 优先使用 ViewModel 已同步的选中 id；若尚未同步，则退回到 currentSrc。
    private var currentSubChapterID: UUID? {
        if let selected = viewModel.selectedSubChapterID {
            return selected
        }
        if !viewModel.currentSrc.isEmpty,
           let bySrc = viewModel.nearestSubChapterID(for: viewModel.currentSrc) {
            return bySrc
        }
        return viewModel.chapters.first?.subChapters.first?.id
    }

    /// 列表里真正承载 `id` 的那一行。
    ///
    /// 叶子章节不渲染子行（父行本身就是入口），所以滚动锚点要落在父行上；
    /// 否则 `scrollTo` 找不到目标，目录打开时会停在第一章。
    private var currentScrollTargetID: UUID? {
        guard let subID = currentSubChapterID else { return nil }
        guard let chapter = viewModel.chapter(containing: subID) else { return subID }
        return chapter.isLeaf ? chapter.id : subID
    }
    
    // MARK: - 打开时的定位

    /// 打开面板时把当前章节摆到**第一帧**上。
    ///
    /// 这里只有一条规则：**不做滚动动画**。
    ///
    /// 面板刚出现时，列表的首帧在顶部（第一章）；若这时再补一段
    /// `withAnimation { scrollTo(...) }`，读者看到的就是
    /// "每次点目录，都从第一章滑到当前章"。正确做法是让第一帧本身
    /// 就落在当前章节——用无动画事务直接落位，读者感知不到"滚动"这件事。
    ///
    /// 展开与定位必须放进**同一个**无动画事务：
    /// - 展开若带动画，列表会先当着读者的面长高，再滚过去，两段运动叠加；
    /// - 面板的插入动画（iPad 的 scale、iPhone 的 sheet 上滑）正在跑，
    ///   外层事务里带着一条弹簧曲线，不清掉它，这次定位会被那条曲线带着走。
    private func positionOnOpen(in proxy: ScrollViewProxy) {
        guard let target = currentScrollTargetID else { return }

        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            viewModel.revealCurrentChapter()
            proxy.scrollTo(target, anchor: .center)
        }
    }

    /// 首帧之后的一次校正，同样是瞬时定位。
    ///
    /// `LazyVStack` 只对已经实例化的行给得出真实高度；目标行还没排到时，
    /// `scrollTo` 只能按估算高度算偏移，章节长短差异大的书上第一次定位
    /// 可能差几行。等一次布局提交（约两帧）再落一次位——因为同样没有动画，
    /// 读者看到的是"列表本来就在这一章"，而不是第二次滑动。
    ///
    /// 用 `.task` 而不是 `DispatchQueue.main.asyncAfter`：视图消失时它会
    /// 自动取消，不会在面板已经关掉之后还去动一个失效的 `ScrollViewProxy`。
    private func settleInitialPosition(in proxy: ScrollViewProxy) async {
        guard let target = currentScrollTargetID else { return }
        try? await Task.sleep(for: .milliseconds(30))
        guard !Task.isCancelled else { return }

        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            proxy.scrollTo(target, anchor: .center)
        }
    }
}

// MARK: - 页签栏 (The Tab Layer)

/// 目录 / 书签切换器。
///
/// 用自绘胶囊而不是系统 `.segmented`：面板整体是衬线字 + 半透明材质的手工风格，
/// 系统分段控件的字重与圆角在这里会显得格格不入。
/// 但无障碍语义仍按系统规范补齐（`.isSelected` + 计数进标签），不牺牲读屏体验。
///
/// 选中态只做**透明度过渡**，不做滑动指示器：指示器横移属于位置动画，
/// 本工程无法在交付前做视觉验收的那类动效一律先不上（与全局动效基线一致）。
private struct TOCPanelTabBar: View {
    @Binding var selection: TOCPanelTab
    let bookmarkCount: Int
    
    var body: some View {
        HStack(spacing: 0) {
            segment(.contents, title: "目录", count: nil)
            segment(.bookmarks, title: "书签", count: bookmarkCount)
        }
        .padding(4)
        .background(
            Capsule(style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
    }
    
    private func segment(_ tab: TOCPanelTab, title: String, count: Int?) -> some View {
        let isSelected = selection == tab
        return Button {
            guard selection != tab else { return }
            triggerHaptic(.light)
            withAnimation(.easeOut(duration: 0.18)) {
                selection = tab
            }
        } label: {
            HStack(spacing: 5) {
                Text(title)
                    .font(.system(size: 14, weight: isSelected ? .semibold : .regular, design: .serif))
                
                if let count, count > 0 {
                    Text("\(count)")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundColor(isSelected ? .primary.opacity(0.55) : .secondary.opacity(0.8))
                }
            }
            .foregroundColor(isSelected ? .primary : .secondary)
            .frame(maxWidth: .infinity)
            .frame(height: 32)
            .background(
                Capsule(style: .continuous)
                    .fill(isSelected ? Color.primary.opacity(0.10) : Color.clear)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(count.map { "\(title)，\($0) 个" } ?? title)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - 一级大章视图 (The Architectural Layer)
private struct ParentChapterRow: View {
    let chapter: Chapter
    @ObservedObject var viewModel: ContentsPanelViewModel
    var onSelected: (() -> Void)? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var isExpanded: Bool { viewModel.isExpanded(chapter.id) }
    var isLeaf: Bool { chapter.isLeaf }
    var isCurrent: Bool {
        guard isLeaf, let sub = chapter.subChapters.first else { return false }
        return viewModel.isSelected(sub.id)
    }

    /// 展开/折叠的曲线。
    ///
    /// 动画只在这一处点击里用 `withAnimation` 触发，不再给整棵树挂隐式动画
    /// （见 `ElegantTOCPanel.body`）。这样"打开面板时的自动展开"与
    /// "读者手动点开一章"走的是两条不同的路径：前者瞬时、后者有手感。
    /// reduceMotion 下直接关掉：这是纯装饰性的布局动画，不是位置变化的必要线索。
    private var expansionAnimation: Animation? {
        reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.86)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            // 大章编号指示
            Text(String(format: "%02d", chapter.number))
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundColor(.secondary.opacity(0.4))
                .frame(minWidth: 24, alignment: .leading)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            
            // 大章标题
            Text(chapter.title)
                .font(.system(size: 17, weight: .bold, design: .serif))
                .foregroundColor(isCurrent ? .accentColor : .primary.opacity(0.9))
                .lineLimit(1)
            
            Spacer()
            
            // 进度可视化：微型环形进度条
            if chapter.readingProgress > 0 {
                TOCMiniProgressRing(progress: chapter.readingProgress)
                    .frame(width: 14, height: 14)
            }
            
            // 极简折叠指示器（放弃粗暴的传统 Chevron，改用优雅的 90° 旋转几何线条）
            // 叶子章节没有可折叠内容，不给指示器——它点下去是"跳转"，不是"展开"。
            if !isLeaf {
                Circle()
                    .fill(isExpanded ? Color.primary.opacity(0.1) : Color.clear)
                    .frame(width: 24, height: 24)
                    .overlay(
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.secondary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    )
            }
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 16)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("第\(chapter.number)章 \(chapter.title)")
        .accessibilityValue(accessibilityValue)
        .accessibilityHint(isLeaf ? "跳转到这一章" : "")
        .accessibilityAddTraits(.isButton)
        .onTapGesture {
            // 走统一总闸（原来直接 new 一个 generator，绕过了「触觉反馈」开关）
            triggerHaptic(.light)

            if isLeaf, let sub = chapter.subChapters.first {
                // 叶子章节：整行就是入口，点了直接跳。
                viewModel.selectSubChapter(sub.id)
                onSelected?()
                return
            }

            // 完美绑定你的 ViewModel 展开/折叠 Intent。
            // 动画挂在这里而不是整棵树上：只有读者亲手点的那一下才有过渡，
            // 打开面板时的自动展开保持瞬时（否则会先长高、再滚动）。
            withAnimation(expansionAnimation) {
                viewModel.toggleChapter(chapter.id)
            }
        }
    }

    private var accessibilityValue: String {
        if isLeaf {
            return isCurrent ? "当前阅读" : ""
        }
        return isExpanded ? "已展开" : "已折叠"
    }
}

// MARK: - 二级子章节视图 (The Literal Fluid Journey)
private struct ChildSubChapterRow: View {
    let subChapter: SubChapter
    @ObservedObject var viewModel: ContentsPanelViewModel
    var onSelected: (() -> Void)? = nil  // ✅ 新增
    
    var isSelected: Bool { viewModel.isSelected(subChapter.id) }

    /// 深层目录被拍平到同一列表后，靠缩进保留「谁属于谁」。
    /// 最多再加 3 级（36pt）：再深就不是目录，是排版噪声了。
    private var depthIndent: CGFloat {
        CGFloat(min(max(subChapter.depth - 1, 0), 3)) * 12
    }
    
    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            // 核心美学 1：黄金分割缩进 (24pt)，视线自然流向子层级
            Spacer().frame(width: 24 + depthIndent)
            
            // 子章节小标题/小章节号
            // 深层编号会到 1.2.3 这样的宽度，给一个可增长的最小宽度而不是死宽，
            // 免得数字被截成「1.2…」。
            Text(subChapter.number)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundColor(isSelected ? .accentColor : .secondary.opacity(0.6))
                .frame(minWidth: 28, alignment: .leading)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            
            // 子章节正文标题
            Text(subChapter.title)
                .font(.system(size: 15, weight: isSelected ? .semibold : .regular, design: .serif))
                .foregroundColor(isSelected ? .accentColor : .primary.opacity(0.85))
                .lineSpacing(4)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true) // 健壮性：支持长标题自然换行
            
            Spacer()
            
            // 核心美学 2：状态指示器。已读是极简浅灰钩，当前读是品牌高亮圆点，未读留白
            if isSelected {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 6, height: 6)
            } else if subChapter.isRead {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary.opacity(0.4))
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
        // 核心美学 3：去掉硬分割线，当前选中的章节使用超低饱和度品牌色气泡包裹
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? Color.gray.opacity(0.06) : Color.clear)
                .padding(.leading, 32 + depthIndent) // 气泡背景同样遵循缩进美学
        )
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(subChapter.number) \(subChapter.title)")
        .accessibilityValue(isSelected ? "当前阅读" : (subChapter.isRead ? "已读" : ""))
        .accessibilityAddTraits(.isButton)
        .onTapGesture {
            // 跳转章节 = 阅读位置发生变化，与翻页同一量级的反馈，所以同样是 .light。
            // （原先这里是一段注释掉的 `haptic.notify(.success)`——
            //  `UIImpactFeedbackGenerator` 上并没有 `notify` 方法，本就跑不起来。）
            triggerHaptic(.light)
            // 完美绑定你的 ViewModel 选中更新 Intent
            viewModel.selectSubChapter(subChapter.id)
            onSelected?()  // ✅ 触发回调
        }
    }
}

// MARK: - 书签行

/// 一条书签。
///
/// 三行信息的分工：章节标题回答"在哪一章"，正文片段回答"是哪一段"。
/// **不显示页码**：页码随字号变化，写死在列表里就是一个会悄悄变错的值；
/// 而读者凭片段认段落，比凭数字认位置可靠得多。
private struct BookmarkRow: View {
    let bookmark: Bookmark
    @ObservedObject var viewModel: ContentsPanelViewModel
    var onSelected: (() -> Void)? = nil
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "bookmark.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.accentColor.opacity(0.85))
                .frame(width: 16)
                .padding(.top, 3)   // 与标题首行的视觉中线对齐
            
            VStack(alignment: .leading, spacing: 5) {
                Text(chapterTitleText)
                    .font(.system(size: 15, weight: .semibold, design: .serif))
                    .foregroundColor(.primary.opacity(0.9))
                    .lineLimit(1)
                
                Text(previewText)
                    .font(.system(size: 13, weight: .regular, design: .serif))
                    .foregroundColor(.secondary)
                    .lineSpacing(3)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            
            Spacer(minLength: 0)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
        .contentShape(Rectangle())
        .onTapGesture {
            triggerHaptic(.light)
            viewModel.jumpToBookmark(bookmark)
            onSelected?()
        }
        .contextMenu {
            Button(role: .destructive) {
                viewModel.removeBookmark(bookmark)
            } label: {
                Label("删除书签", systemImage: "trash")
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("书签：\(chapterTitleText)")
        .accessibilityValue(previewText)
        .accessibilityHint("跳转到这一页")
        .accessibilityAddTraits(.isButton)
        // 读屏用户没有"长按"这个概念，用命名动作给出同一条删除路径。
        .accessibilityAction(named: Text("删除书签")) {
            viewModel.removeBookmark(bookmark)
        }
    }
    
    private var chapterTitleText: String {
        let trimmed = bookmark.chapterTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "未命名章节" : trimmed
    }
    
    private var previewText: String {
        bookmark.preview.isEmpty ? "这一页没有可预览的文字" : bookmark.preview
    }
}

// MARK: - 书签空状态

private struct TOCBookmarksEmptyView: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "bookmark")
                .font(.system(size: 30, weight: .light))
                .foregroundColor(.secondary.opacity(0.45))
            
            Text("还没有书签")
                .font(.system(size: 15, weight: .semibold, design: .serif))
                .foregroundColor(.primary.opacity(0.85))
            
            Text("阅读时轻点纸面调出控件，再点书签按钮，即可把当前页加入书签。")
                .font(.system(size: 12, weight: .regular))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 40)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - 微型环形进度条 (Micro Metrics)
private struct TOCMiniProgressRing: View {
    let progress: Double
    
    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.15), lineWidth: 2)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(Color.primary.opacity(0.6), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

// MARK: - 书籍元数据头部
private struct BookHeaderView: View {
    let bookTitle: String
    let author: String
    let coverURLs: [URL]

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            BookCoverArtworkView(urls: coverURLs)
                .frame(width: BookCoverArtworkView.size.width, height: BookCoverArtworkView.size.height)

            VStack(alignment: .leading, spacing: 5) {
                Text(bookTitle)
                    .font(.system(size: 18, weight: .bold, design: .serif))
                    .foregroundColor(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                Text(authorDisplayName)
                    .font(.system(size: 13, weight: .regular, design: .default))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("《\(bookTitle)》")
        .accessibilityValue("作者：\(authorDisplayName)")
    }

    private var authorDisplayName: String {
        let trimmed = author.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "未知作者" : trimmed
    }
}

// MARK: - 书籍封面小图（异步加载，避免打开目录时阻塞主线程）
private struct BookCoverArtworkView: View {
    let urls: [URL]

    @State private var uiImage: UIImage?
    @State private var loadedURL: URL?

    /// 与头部文本行高匹配的紧凑封面尺寸（接近 Apple Books 的 3:4 书封比例）
    static let size = CGSize(width: 52, height: 70)

    var body: some View {
        Group {
            if let uiImage {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
            } else {
                placeholder
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.12), radius: 5, x: 0, y: 2)
        .task(id: urls.first) {
            await loadCover()
        }
    }

    private var placeholder: some View {
        ZStack {
            Color(UIColor.secondarySystemBackground)
            Image(systemName: "book.closed.fill")
                .font(.system(size: 20, weight: .medium))
                .foregroundColor(.secondary)
        }
    }

    private func loadCover() async {
        guard let url = urls.first else {
            uiImage = nil
            loadedURL = nil
            return
        }
        guard loadedURL != url else { return }

        // 解码工作放到后台线程，目录面板打开时保持流畅。
        let image = await Task.detached(priority: .userInitiated) {
            UIImage(contentsOfFile: url.path)
        }.value

        guard !Task.isCancelled else { return }
        uiImage = image
        loadedURL = url
    }
}

// MARK: - 精美骨架屏加载占位 (Premium Skeleton)
private struct TOCSkeletonView: View {
    @State private var animate = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            ForEach(0..<4) { _ in
                VStack(alignment: .leading, spacing: 12) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.secondary.opacity(0.1))
                        .frame(width: 120, height: 18)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.secondary.opacity(0.06))
                        .frame(maxWidth: .infinity)
                        .frame(height: 14)
                }
            }
        }
        .padding(32)
        .opacity(animate ? 0.6 : 1.0)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                animate = true
            }
        }
    }
}
