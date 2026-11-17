//
//  AppToolbar.swift
//  TheNewVellium
//
//  首页 / 书库的导航栏动作项。
//
//  历史：这里原先是挂在 TabView 上的 overlay 浮层。overlay 不参与布局，
//  于是「滚动内容从按钮底下穿过去」是常态——统计卡的玻璃、Recent /
//  Collections 标题栏右端的玻璃按钮都会从按钮底下滑过，两层玻璃叠在
//  一起；滚动指示器 inset、命中测试、VoiceOver 顺序也都得自己补。
//
//  现在交回系统导航栏，由 `.toolbar` 承载：
//  - 内容滚到栏下时由系统给出 scroll edge effect，不会「文字透过玻璃」；
//  - 大标题随滚动收缩成 inline，顶部始终有一条稳定的 chrome；
//  - 安全区、滚动指示器 inset、命中测试、VoiceOver 顺序、iPad 边距
//    全部由系统负责，不再有第二份真值。
//
//  两种形态：
//  - Home：只有「阅读数据」。Home 是"继续读"的地方，它的唯一动作是
//    「回看自己读得怎么样」，导入是书库的事，留给 Library。
//  - Library：排序 + 导入。排序是书库的呈现偏好，导入是书库的进书口。
//
//  排序写入 `AppSettings.sortBy`，与「设置 → 视图与组织 → 排序方式」
//  共用同一个持久化字段——两处改的是同一份真值，不会互相打架。
//

import SwiftUI

struct AppToolbar: ToolbarContent {

    /// 工具栏出现的页面。决定它有几个按钮。
    enum Placement {
        case home
        case library
    }

    let placement: Placement

    // 下面四项里，前三项只有 `.library` 会读。给默认值的理由很实际：
    // `.home` 造工具栏时不该被迫写一排空闭包——那会把「Home 没有排序」
    // 这个事实糊掉，也给了「Home 也有排序」的错觉。
    let currentSort: LibrarySortOption
    let onSelectSort: (LibrarySortOption) -> Void
    let onImport: () -> Void
    let onOpenReadingStats: () -> Void

    init(
        placement: Placement,
        currentSort: LibrarySortOption = .fallback,
        onSelectSort: @escaping (LibrarySortOption) -> Void = { _ in },
        onImport: @escaping () -> Void = {},
        onOpenReadingStats: @escaping () -> Void = {}
    ) {
        self.placement = placement
        self.currentSort = currentSort
        self.onSelectSort = onSelectSort
        self.onImport = onImport
        self.onOpenReadingStats = onOpenReadingStats
    }

    var body: some ToolbarContent {
        if placement == .home {
            ToolbarItem(placement: .topBarTrailing) {
                ReadingStatsButton(action: onOpenReadingStats)
            }
        } else {
            // 先声明排序、后声明导入：导航栏按声明顺序从左到右排，
            // 于是导入恒在最右——主操作的位置不随 tab 变化而移动。
            ToolbarItem(placement: .topBarTrailing) {
                sortMenu
            }

            // 把「排序」和「导入」拆成两个独立的玻璃胶囊。
            //
            // 两个默认值都不能省：
            // - `.fixed`：`.flexible` 只在有多余空间时才占宽，导航栏右区贴合
            //   内容、没有余量，弹性空白会塌成 0，看起来就像没写。
            // - `placement: .topBarTrailing`：`.automatic` 不落在 trailing 区，
            //   系统不会把它插到这两个 item 之间。
            //
            // `ToolbarSpacer` 是 iOS 26 才有的 API：Liquid Glass 会把相邻的
            // 工具栏项并进同一颗胶囊，需要它才能分开。iOS 18 没有胶囊合并，
            // 两个按钮本来就是各自独立、按系统间距排列——旧系统上不写这一段，
            // 布局语义反而正好一致。
            if #available(iOS 26.0, *) {
                ToolbarSpacer(.fixed, placement: .topBarTrailing)
            }

            ToolbarItem(placement: .topBarTrailing) {
                importButton
            }
        }
    }

    // MARK: - 导入

    private var importButton: some View {
        Button(action: onImport) {
            // Label 在导航栏里只画图标，但 VoiceOver 读的是 "Import Book"，
            // 不会像裸的 plus 图标那样只念一个 "Add"。
            Label("Import Book", systemImage: "plus")
        }
        .accessibilityHint("Adds an EPUB file to your library")
    }

    // MARK: - 排序

    private var sortMenu: some View {
        Menu {
            // Picker 放进 Menu 后渲染成一组带勾选的菜单项，
            // 勾选态由系统按 selection 维护，不用自己画 checkmark
            // （自己画还要处理图标占位导致的文字错位）。
            Picker("Sort by", selection: sortBinding) {
                ForEach(LibrarySortOption.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Label("Sort", systemImage: "ellipsis")
        }
        .accessibilityHint("Chooses how books are ordered in your library")
    }

    /// 把「当前值 + 回调」包成 Binding，好让 Picker 自己维护勾选态。
    /// 不用 @Binding 传入是因为设置实例的唯一入口是 `ModelContext.appSettings()`，
    /// 它是方法不是属性，做不出稳定的 Binding。
    private var sortBinding: Binding<LibrarySortOption> {
        Binding(
            get: { currentSort },
            set: { onSelectSort($0) }
        )
    }
}

// MARK: - 阅读数据入口

/// 首页右上角唯一的动作项：进入阅读数据详情页。
///
/// 只画一个图表图标，不画头像——这一页回答的是「读得怎么样」，
/// 头像属于设置里的账户页（`ProfileView`）。两个入口如果长得一样，
/// 用户点进去之前就分不清自己要去哪。
private struct ReadingStatsButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("阅读数据", systemImage: "chart.bar.xaxis")
        }
        .accessibilityHint("查看阅读时长、习惯与书籍统计")
    }
}
