//
//  BookCardFlow.swift
//  TheNewVellium
//
//  Created by piednes on 2026-04-29.
//
import SwiftUI
import SwiftData

struct BookCardFlowView: View {
    /// 排序方式。由调用方（书库页）从 `AppSettings.sortBy` 传入，
    /// 本视图不自己去读设置——它只负责呈现，排序规则收在 `LibrarySortOption`。
    ///
    /// `@Query` 的 SortDescriptor 必须是编译期常量，无法跟随运行时偏好变化，
    /// 所以顺序在内存里排（见 `orderedItems`）。
    let sortOption: LibrarySortOption

    @Query(
        sort: [ SortDescriptor(\bookItem.dateAdded, order: .reverse) ]
    ) private var items: [bookItem]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var orderedItems: [bookItem] {
        sortOption.ordered(items)
    }

    // MARK: - 过渡

    /// 卡片出现 / 消失的转场。
    /// 淡隐 + 中心缩放，不做位移：卡片增删没有方向性叙事，
    /// 加 offset 会让「从旁边滑进来」被读成布局错位。
    /// 进出共用同一组参数——换序、新增、删除三种变化必须长得一样，
    /// 否则用户会把它们理解成三套不同的机制。
    private var cardTransition: AnyTransition {
        .opacity.combined(with: .scale(scale: 0.92))
    }

    /// 网格重排的曲线，与 Home 的 Recent 横滑行（`RecentCardView.rowAnimation`）
    /// 是同一类动作，改动其一请顺手对齐另一个。
    ///
    /// 这里刻意不写 asymmetric 双时长、也不给 spring bounce：
    /// 换位是布局重排而非位移叙事，两套时长没有可感知的收益，
    /// 回弹反而会让「排序后卡片落位」显得不稳。
    private var gridAnimation: Animation {
        reduceMotion ? .easeOut(duration: 0.15)
                     : .easeOut(duration: 0.25)
    }

    // MARK: - Body

    var body: some View {
        // 参数设定：行间距、列间距。
        // 列间距从 10 放宽到 20：封面不再统一裁成 2:3，而是按原始开本呈现、
        // 宽度吃满列，窄缝会让两本大开本几乎贴在一起；
        // 20pt 约为列宽的 1/8，对齐 Apple Books 书架的沟距比例。
        let verticalPadding: CGFloat = 40
        let horizontalPadding: CGFloat = 30

        // 使用 adaptive：指定单个卡片的最小宽度，由系统根据可用宽度自动决定列数。
        // iPhone（可用约 353pt）→ 2 列、列宽约 166pt；
        // iPad（可用约 944pt）→ 5 列、列宽约 173pt，与 Apple Books 书架相当。
        let minCardWidth: CGFloat = 130

        let columns = [
            // alignment: .bottom 是比例和谐的关键：不同开本的封面高度不一，
            // 底部对齐让每本书像立在同一个书架上，顶部参差由书脊节奏自然吸收
            GridItem(.adaptive(minimum: minCardWidth), spacing: horizontalPadding, alignment: .bottom)
        ]

        LazyVGrid(columns: columns, spacing: verticalPadding) {
            ForEach(orderedItems, id: \.persistentModelID) { item in
                // 不传 cardSize = 自适应模式：封面按原图宽高比呈现，
                // 不再强制裁切进 150×225 的硬编码开本（尺寸策略见 BookCardView）。
                BookCardView(book: item)
                    .transition(cardTransition)
            }
        }
        // ⚠️ 动画必须挂在容器（所有卡片的共同祖先）上，挂在单张卡片上无效。
        // 卡片"滑到新格子"不是它自己的属性变化，而是父容器重排的结果——
        // 只有祖先节点上的 animation 才会把这次重排纳入同一个事务。
        //
        // value 取**身份数组**而不是 count：换序时总数不变，用 count 做键
        // 这一帧根本检测不到变化，排序就是纯瞬移；用身份数组才能捕获顺序差异。
        .animation(gridAnimation, value: orderedItems.map(\.persistentModelID))
    }
}

// MARK: - 预览

#Preview {
    BookCardFlowView(sortOption: .dateAddedNew)
        .modelContainer(for: [bookItem.self, Bookmark.self, BookCollection.self], inMemory: true)
}
