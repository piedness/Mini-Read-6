//
//  RecentCardView.swift
//  vellium1218
//

import SwiftUI
import SwiftData

// MARK: - Sort Model

enum BookSortOrder: String, CaseIterable {
    case recent     = "Recently Opened"
    case progress   = "Progress"

    var icon: String {
        switch self {
        case .recent:   return "clock"
        case .progress: return "chart.bar"
        }
    }
}

// MARK: - Book Model

struct RecentBook: Identifiable {
    let id: PersistentIdentifier
    let book: bookItem

    /// 标题 / 作者的快照。
    /// 删除生效后模型对象即失效，但退出转场期间这张卡片还要继续渲染若干帧——
    /// 用快照绘制，转场过程中就不必再去读 model 属性（SwiftData deleted-object 风险）。
    let title: String
    let author: String

    let progress: Double        // 0.0 ~ 1.0
    let lastOpened: Date
}

// MARK: - View

struct RecentCardView: View {
    // 160/240 = 2/3
    let cardSize = CGSize(width: 130, height: 130 * 1.5)

    /// 卡片增删的转场。Reduce Motion 开启时退化为短促淡出，不做位移感的弹性。
    private var rowAnimation: Animation {
        reduceMotion ? .easeOut(duration: 0.15)
                     : .spring(duration: 0.45, bounce: 0.18)
    }

    @Query private var books: [bookItem]
    @State private var recentPop: Bool = false
    @State private var sortOrder: BookSortOrder = .recent
    @State private var sortAscending: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Namespace private var namespace

    // ── Raw data ──────────────────────────────────────────────────────────────

    /// Recent 的准入条件只有一条：真正打开过（留下 `lastOpenedAt`）。
    /// 导入但从未打开的书不算，因此该数组为空时 body 会把整个模块隐藏。
    private var realRecentBooks: [RecentBook] {
        // 进度取 `bookItem.readingProgress`（已读子章节 / 全书子章节总数）。
        // 旧实现拿"本书已读数 / 全库最多的已读数"当进度——那是个跨书的相对值，
        // 读得最多的那本永远 100%，其余按它的比例缩水，既不是这本书的进度，
        // 也会随着书库增删而漂移。
        return books.compactMap { book in
            guard let lastOpened = book.lastOpenedAt else { return nil }
            return RecentBook(
                id: book.persistentModelID,
                book: book,
                title: book.bookTitle,
                author: book.bookAuthor,
                progress: book.readingProgress ?? 0,
                lastOpened: lastOpened
            )
        }
    }

    // ── Derived ───────────────────────────────────────────────────────────────
    private var sortedBooks: [RecentBook] {
        let sorted: [RecentBook]
        switch sortOrder {
        case .recent:   sorted = realRecentBooks.sorted { $0.lastOpened > $1.lastOpened }
        case .progress: sorted = realRecentBooks.sorted { $0.progress   > $1.progress   }
        }
        return Array((sortAscending ? sorted.reversed() : sorted).prefix(12))
    }

    // ── Body ──────────────────────────────────────────────────────────────────

    /// 没有任何「打开过」的书时，整个 Recent 模块（含标题栏）不渲染。
    ///
    /// 这里必须返回 `EmptyView`，而不是渲染一个零高度的容器：实测 SwiftUI 的
    /// VStack 会为零高度的**真实**子视图照常插入 spacing（spacing=50 时留下 100pt
    /// 空隙），而 `EmptyView` 分支会被布局完全剪掉（只留 50pt）。若写成后者，
    /// 隐藏 Recent 后下方 Collections 上方会凭空多出一截间距。
    @ViewBuilder
    var body: some View {
        if sortedBooks.isEmpty {
            EmptyView()
        } else {
            VStack(spacing: 0) {
                sectionHeader
                    
                    
                horizontalScrollBooks
                    .scrollClipDisabled()
                    .padding(.top, 20)
            }
        }
    }

    // MARK: - Header

    private var sectionHeader: some View {
        HStack(alignment: .center) {
            Text("Recent")
                .font(.title2)
                .fontDesign(.serif)
                .bold()

            
            Spacer()
            
            Menu {
                sortMenu
            } label: {
                Image(systemName: "ellipsis")
                    .font(.subheadline)
                    .fontDesign(.serif)
                    .fontWeight(.bold)
                    .foregroundStyle(.white)
                    .padding(12)
                    .glassSurface(.regular, in: .rect(cornerRadius: 20))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: sortOrder)
        
    }

    // MARK: - Sort Menu (Popover content)

    private var sortMenu: some View {
        VStack(alignment: .leading, spacing: 0) {

            // ── Section title ──
            Text("Sort by")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding()

            Divider().padding(.horizontal, 8)

            // ── Sort options ──
            ForEach(BookSortOrder.allCases, id: \.self) { option in
                sortRow(option)
            }

            Divider().padding(.horizontal, 8)

            // ── Ascending / Descending ──
            Button {
                withAnimation(.spring(duration: 0.25)) {
                    sortAscending.toggle()
                    recentPop.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: sortAscending ? "arrow.up" : "arrow.down")
                        .frame(width: 20)
                        .foregroundStyle(.primary)
                    Text(sortAscending ? "Ascending" : "Descending")
                        .font(.system(size: 15))
                        .foregroundStyle(.primary)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
            }
            .buttonStyle(.plain)
        }
        .padding(.bottom, 4)
    }

    private func sortRow(_ option: BookSortOrder) -> some View {
        Button {
            withAnimation(.spring(duration: 0.3)) {
                sortOrder = option
            }
            recentPop = false
        } label: {
            HStack(spacing: 10) {
                Image(systemName: option.icon)
                    .frame(width: 20)
                    .foregroundStyle(sortOrder == option ? .tint : .tint)

                Text(option.rawValue)
                    .font(.system(size: 15))
                    .foregroundStyle(.primary)

                Spacer()

                if sortOrder == option {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.tint)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Horizontal Scroll

    private var horizontalScrollBooks: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            // 两个分支放在同一个容器里：容器不随分支切换而销毁，
            // 动画才能覆盖"最后一本被删掉 → 切换成空状态"这个结构变化。
            ZStack(alignment: .leading) {

                HStack(spacing: 20) {
                    ForEach(sortedBooks) { book in
                        bookItem(book: book)
                            .transition(
                                .asymmetric(
                                    insertion: .opacity.combined(with: .scale(scale: 0.94)),
                                    removal:   .opacity.combined(with: .scale(scale: 0.90))
                                )
                            )
                    }
                }
                
            }
            // ⚠️ 动画必须挂在两个分支的共同祖先上。
            // 原先挂在 HStack 上：最后一本被删掉时那个 HStack 连同 animation 修饰符
            // 一起被销毁，"有书 → 空状态"这一帧的结构切换就完全没有动画，
            // 高度一帧塌陷、下面的 Collections 直接瞬移。
            // 现在两个分支同构（占位卡与真实卡片等高），叠加上这层动画后是干净的交叉淡入淡出。
            .animation(rowAnimation, value: sortedBooks.map(\.id))
        }
    }

    // MARK: - Book Item

    private func bookItem(book: RecentBook) -> some View {
        let w = cardSize.width
        let h = cardSize.height

        return VStack(alignment: .leading, spacing: 8) {
            // 卡片自己那一行元信息关掉：这里书名要排在作者上方，
            // 同一行由下面摆放（同一个 BookProgressAuthorRow，式样不分叉）。
            BookCardView(cardSize: CGSize(width: w, height: h),
                         book: book.book,
                         showsMetaRow: false)
                .frame(width: w, height: h)

            // 元数据与进度紧密结合 (接近法则)
            VStack(alignment: .leading, spacing: 4) {
                Text(book.title)
                    .font(.system(.subheadline, design: .serif, weight: .semibold))
                    .lineLimit(1)
                    .foregroundColor(.primary)

                BookProgressAuthorRow(progress: book.progress, author: book.author)
            }
            .padding(.horizontal, 4)
        }
        .frame(width: w)
    }


    // MARK: - Helpers

    private var metaIcon: String {
        switch sortOrder {
        case .recent:   return "clock.badge"
        case .progress: return "chart.bar"
        }
    }

    private func metaLabel(for book: RecentBook) -> String {
        switch sortOrder {
        case .recent:
            let mins = Int(-book.lastOpened.timeIntervalSinceNow / 60)
            if mins < 60 { return "\(mins)m ago" }
            let hrs = mins / 60
            if hrs < 24 { return "\(hrs)h ago" }
            return "\(hrs / 24)d ago"
        case .progress:
            return "\(Int(book.progress * 100))%"
        }
    }

    private func progressColor(for progress: Double) -> Color {
        switch progress {
        case 0.75...: return .green.opacity(0.8)
        case 0.4...:  return .blue.opacity(0.7)
        default:      return .white.opacity(0.4)
        }
    }
}


/// 遵循 Apple Books 规范的极致阅读进度指示器
struct BooksProgressIndicator: View {
    /// 阅读进度，范围 0.0 到 1.0
    var progress: Double
    
    // 进度条高度，Apple Books 通常非常纤细，保持在 3-4pt，做到克制
    private let trackHeight: CGFloat = 4.0
    
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                // 背景轨道 (Track)
                // 使用 .secondary 语义色并降低透明度，完美适配深浅色模式
                Capsule()
                    .fill(Color.secondary.opacity(0.15))
                    .frame(height: trackHeight)
                
                // 进度填充 (Fill)
                // 确保进度值在 0-1 之间，防止 UI 溢出或崩溃
                Capsule()
                    .fill(Color.primary) // 在阅读器中，极致的对比度通常使用 Primary 黑/白
                    .frame(
                        width: max(0, geometry.size.width * CGFloat(min(max(progress, 0), 1))),
                        height: trackHeight
                    )
            }
            // 多尔蒂门槛：使用带有物理惯性的 Spring 动画，反馈迅速且自然
            .animation(.spring(response: 0.35, dampingFraction: 0.85, blendDuration: 0), value: progress)
        }
        .frame(height: trackHeight)
        // 增加 Accessibility 支持，体现顶级开发者的专业素养
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("阅读进度")
        .accessibilityValue("\(Int(progress * 100))%")
    }
}
