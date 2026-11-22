//
//  TabScreens.swift
//  TheNewVellium
//
//  三个 tab 的页面本体：Home / Library / Search。
//
//  它们被 iPad 与 iPhone 两套骨架共用，差异只有一处——`title`。
//  把「页面做什么」和「平台怎么交代位置」拆开，是因为前者必须唯一，
//  后者本来就该分叉：iPhone 有标题，iPad 没有。
//
//  `SettingsView()` 不在这里：它自己就是完整页面，两套骨架直接放进去即可。
//

import SwiftUI
import SwiftData

// MARK: - 标题策略

/// 只在 `title` 非 nil 时挂 `navigationTitle`。
///
/// 不用 `.navigationTitle("")` 表达「不要标题」：空字符串仍然占住大标题
/// 那一行的高度与收缩动画，顶部照样被拿走一截，只是看起来没字。
private struct TabNavigationTitle: ViewModifier {
    let title: String?

    func body(content: Content) -> some View {
        if let title {
            content
                .navigationTitle(title)
                .toolbarTitleDisplayMode(.large)
        } else {
            content
        }
    }
}

// MARK: - Home

/// 首页：继续读 + 阅读数据入口。
///
/// `title` 为 nil 时不设导航标题（iPad，见 `iPadOSTabs.swift` 的说明）。
/// 阅读数据是 Home 的下钻页，走 push 而不是 sheet：它有自己的范围选择与
/// 长内容，需要返回手势和滚动连续性。
struct HomeTabView: View {
    let title: String?

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.modelContext) private var modelContext

    /// 只为设置变化时刷新（背景与标题都读 `AppSettings`）。
    @Query private var settings: [AppSettings]

    @State private var showReadingStats = false

    private var appSettings: AppSettings {
        modelContext.appSettings()
    }

    private var isRegular: Bool { horizontalSizeClass == .regular }

    var body: some View {
        NavigationStack {
            Group {
                if isRegular {
                    iPadOSHomeView()
                        .appBackground(settings: appSettings, radius: 18)
                } else {
                    iPhoneOSHomeView()
                        .appBackground(settings: appSettings, radius: 44)
                }
            }
            .modifier(TabNavigationTitle(title: title))
            .toolbar {
                // Home 只有「回看自己读得怎么样」这一个动作；
                // 导入是书库的事，留给 Library（见 AppToolbar 的说明）。
                AppToolbar(
                    placement: .home,
                    onOpenReadingStats: { showReadingStats = true }
                )
            }
            .navigationDestination(isPresented: $showReadingStats) {
                // 跟随外壳的平台约定：iPhone 有标题，iPad 不设标题。
                ReadingStatsView(
                    settings: appSettings,
                    showsNavigationTitle: title != nil
                )
            }
        }
    }
}

// MARK: - Library

/// 书架底部的总数标签。
///
/// 两套书库共用同一份文案与同一条可访问性规则：图标与数字必须读成一个
/// 元素（VoiceOver 直接念 "3 Books"），否则会先念 "books.vertical.fill"
/// 再念数字。版式差异交给各自的平台文件，这里只管「说的是什么」。
struct LibraryBookCountLabel: View {
    let bookCount: Int

    /// 目前项目还没有本地化目录，先做最轻量的单/复数处理；
    /// 将来接入 String Catalog 时，把它改成
    /// `Text("^[\(bookCount) book](inflect: true)")` 即可。
    private var text: String {
        bookCount == 1 ? "1 Book" : "\(bookCount) Books"
    }

    var body: some View {
        HStack {
            Image(systemName: "books.vertical.fill")
                .font(.footnote)
                .fontDesign(.serif)
                .fontWeight(.bold)
                .foregroundStyle(.gray)
            Text(text)
                .font(.footnote)
                .fontDesign(.serif)
                .fontWeight(.bold)
                .foregroundStyle(.gray)
        }
        .accessibilityElement(children: .combine)
    }
}

/// 书库：封面网格 + 排序 + 导入入口。
///
/// 版式本身在 `iPadOSLibrary.swift` / `iPhoneOSLibrary.swift` 里分家；
/// 这里只留两件与设备无关的事——导航栈与动作项、排序的读写。
/// `title` 为 nil 时不设导航标题（iPad）。
struct LibraryTabView: View {
    let title: String?
    let onImport: () -> Void

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.modelContext) private var modelContext

    @Query(
        sort: [SortDescriptor(\bookItem.dateAdded, order: .forward)]
    ) private var items: [bookItem]

    /// 只为设置变化时刷新（排序方式与背景都读 `AppSettings`）。
    @Query private var settings: [AppSettings]

    private var appSettings: AppSettings {
        modelContext.appSettings()
    }

    private var isRegular: Bool { horizontalSizeClass == .regular }

    /// 当前排序方式。持久化在 `AppSettings.sortBy`，
    /// 与「设置 → 视图与组织 → 排序方式」是同一个值。
    private var currentSortOption: LibrarySortOption {
        LibrarySortOption(persistedValue: appSettings.sortBy)
    }

    var body: some View {
        NavigationStack {
            Group {
                if isRegular {
                    iPadOSLibraryView(sortOption: currentSortOption, bookCount: items.count)
                        .appBackground(settings: appSettings, radius: 18)
                } else {
                    iPhoneOSLibraryView(sortOption: currentSortOption, bookCount: items.count)
                        .appBackground(settings: appSettings, radius: 44)
                }
            }
            .modifier(TabNavigationTitle(title: title))
            .toolbar { appToolbar }
        }
    }

    private var appToolbar: some ToolbarContent {
        AppToolbar(
            placement: .library,
            currentSort: currentSortOption,
            onSelectSort: selectSort,
            onImport: onImport
        )
    }

    private func selectSort(_ option: LibrarySortOption) {
        appSettings.sortBy = option.rawValue
        // 排序只影响书库的呈现顺序，不参与排版，因此**不**广播
        // `.appSettingsDidChange`——那会让阅读器白白重排一次。
        try? modelContext.save()
        // 开关判断在 `triggerHaptic` 内部（见 `Utils/Haptics.swift`），此处不再重复。
        triggerHaptic(.light)
    }
}

// MARK: - Search

/// 搜索：按书名 / 作者 / 出版社过滤书库。
///
/// 搜索词由外壳持有（切换尺寸类、切换 tab 都不丢），这里只取 Binding。
struct SearchTabView: View {
    @Binding var searchText: String

    @Environment(\.modelContext) private var modelContext

    @Query(
        sort: [SortDescriptor(\bookItem.dateAdded, order: .forward)]
    ) private var items: [bookItem]

    private var trimmedQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var filteredBooks: [bookItem] {
        guard !trimmedQuery.isEmpty else { return items }
        return items.filter { book in
            book.bookTitle.localizedCaseInsensitiveContains(trimmedQuery) ||
            book.bookAuthor.localizedCaseInsensitiveContains(trimmedQuery) ||
            book.bookPublisher.localizedCaseInsensitiveContains(trimmedQuery)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if trimmedQuery.isEmpty {
                    ContentUnavailableView(
                        "Search your library",
                        systemImage: "magnifyingglass",
                        description: Text("Find books by title, author, or publisher.")
                    )
                } else if filteredBooks.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                } else {
                    ForEach(filteredBooks) { book in
                        NavigationLink {
                            BookContentView(book: book, modelContext: modelContext)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(book.bookTitle)
                                    .font(.headline)
                                Text(book.bookAuthor)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("")
            .searchable(text: $searchText, placement: .toolbar, prompt: Text("Search..."))
        }
    }
}
