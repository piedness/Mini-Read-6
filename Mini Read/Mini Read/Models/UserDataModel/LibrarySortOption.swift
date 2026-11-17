//
//  LibrarySortOption.swift
//  TheNewVellium
//
//  书库排序方式的唯一定义处。
//
//  `AppSettings.sortBy` 存的是字符串，之前它没有任何消费者——
//  「设置 → 视图与组织 → 排序方式」选了没反应，`BookCardFlowView` 里
//  写死按 `dateAdded` 倒序。本文件把字符串升格为枚举：
//  rawValue 与 `AppSettings.sortBy` 一一对应，菜单和网格共用同一份
//  选项列表与同一套比较逻辑，不会再出现"UI 有八项、实际只有一种顺序"。
//
//  放在 Models 而不是某个 View 里，是因为排序是书库的领域规则，
//  不是某个控件的显示细节——工具栏菜单和书架网格都得用它。
//

import Foundation
import SwiftData

enum LibrarySortOption: String, CaseIterable, Identifiable {

    case recentlyRead       = "recentlyRead"
    case dateAddedNew       = "dateAddedNew"
    case dateAddedOld       = "dateAddedOld"
    case titleAZ            = "titleAZ"
    case titlePinyin        = "titlePinyin"
    case author             = "author"
    case progressUnread     = "progressUnread"
    case progressCompleted  = "progressCompleted"

    // MARK: - 兜底

    /// 持久化值不认识时（旧数据 / 手改 / 将来删选项）回退到这一项。
    ///
    /// 取「添加时间（最新）」而不是「最近阅读」：前者是可从 `dateAdded`
    /// 无条件算出的稳定顺序，后者对没打开过的书没有意义。
    static let fallback: LibrarySortOption = .dateAddedNew

    /// 从持久化字符串还原，认不出来就回退，绝不返回 nil——
    /// 排序方式没有"空"这种状态，书库永远得有个顺序。
    init(persistedValue: String) {
        self = LibrarySortOption(rawValue: persistedValue) ?? .fallback
    }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recentlyRead:      return "最近阅读"
        case .dateAddedNew:      return "添加时间（最新）"
        case .dateAddedOld:      return "添加时间（最早）"
        case .titleAZ:           return "书名（A-Z）"
        case .titlePinyin:       return "书名（拼音）"
        case .author:            return "作者"
        case .progressUnread:    return "进度（未读优先）"
        case .progressCompleted: return "进度（已完成优先）"
        }
    }

    // MARK: - 排序

    /// 返回按本选项排好的新数组。调用方负责在 SwiftData 结果之外做这一步：
    /// `@Query` 的 SortDescriptor 必须是编译期常量，没法跟着运行时偏好变，
    /// 所以这里在内存里排——书库是千本量级，成本可以忽略。
    func ordered(_ books: [bookItem]) -> [bookItem] {
        switch self {
        case .recentlyRead:
            // 打开过的按最近打开时间倒序在前；没打开过的整体排在后半段，
            // 段内仍按添加时间倒序，避免顺序完全随机。
            return books.sorted { lhs, rhs in
                switch (lhs.lastOpenedAt, rhs.lastOpenedAt) {
                case (let l?, let r?): return l > r
                case (_?, nil):        return true
                case (nil, _?):        return false
                case (nil, nil):       return lhs.dateAdded > rhs.dateAdded
                }
            }

        case .dateAddedNew:
            return books.sorted { $0.dateAdded > $1.dateAdded }

        case .dateAddedOld:
            return books.sorted { $0.dateAdded < $1.dateAdded }

        case .titleAZ:
            return books.sorted { lhs, rhs in
                lhs.bookTitle.localizedStandardCompare(rhs.bookTitle) == .orderedAscending
            }

        case .titlePinyin:
            return books.sorted { lhs, rhs in
                lhs.bookTitle.compare(
                    rhs.bookTitle,
                    options: [.caseInsensitive, .diacriticInsensitive],
                    locale: Self.chineseLocale
                ) == .orderedAscending
            }

        case .author:
            // 同一作者下再按书名排，否则同作者的书顺序不定，每次刷新都在跳。
            return books.sorted { lhs, rhs in
                let byAuthor = lhs.bookAuthor.localizedStandardCompare(rhs.bookAuthor)
                if byAuthor != .orderedSame { return byAuthor == .orderedAscending }
                return lhs.bookTitle.localizedStandardCompare(rhs.bookTitle) == .orderedAscending
            }

        case .progressUnread:
            // 未读优先 = 进度升序。阅读进度为 0 的书（含从未打开过的）排最前。
            // 进度统一取 `bookItem.readingProgress`——旧口径是「已读数 / 记录总数」，
            // 而记录只在标记已读时才 insert，分母恒等于分子，任何读过一本的书都是 100%，
            // 排序结果实为"没分档"。
            return books.sorted { ($0.readingProgress ?? 0) < ($1.readingProgress ?? 0) }

        case .progressCompleted:
            return books.sorted { ($0.readingProgress ?? 0) > ($1.readingProgress ?? 0) }
        }
    }

    /// zh_Hans_CN 的默认 collation 即拼音序，不需要自己引拼音表。
    private static let chineseLocale = Locale(identifier: "zh_Hans_CN")
}
