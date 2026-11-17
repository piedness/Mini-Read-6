//
//  Item.swift
//  projectHelper
//
//  Created by Max Piednes on 2025/4/19.
//


import Foundation
import SwiftData

@Model
final class bookItem {
    var bookExtrSubdir: URL
    var bookBackupdir: URL
    var resourceBaseURL: URL
    
    @Attribute var dateAdded: Date
    var bookTitle: String
    var bookAuthor: String
    var bookPublisher: String
    var coverImageURLs: [URL]

    // ── 新增 ──────────────────────────────────────────
    /// 上次阅读到的子章节 src（用于还原阅读位置）
    var lastReadSrc: String?
    /// 上次打开时间（可用于书架排序）
    var lastOpenedAt: Date?
    /// 每个子章节的阅读记录，级联删除
    @Relationship(deleteRule: .cascade)
    var progressRecords: [ReadingProgressRecord] = []

    /// 书签，级联删除。
    ///
    /// 与 `progressRecords` 同一套写法：单向 to-many + cascade。挂在书上而不是
    /// 只靠 `bookKey` 字符串关联，删书时书签才会跟着走——否则全工程五个删除
    /// 入口（书架卡片 / Tabs / 存储列表 / 目录监视 / 一键清除）都得各写一次清理，
    /// 漏一个就留下一批指向不存在的书。
    @Relationship(deleteRule: .cascade)
    var bookmarks: [Bookmark] = []

    /// 所属书单（多对多）。
    ///
    /// 反向关系的声明在 `BookCollection.books` 上（那边带 `inverse:`），这里只是
    /// 被动的一端，所以不写 `@Relationship`。两处都写 `inverse:` 会互相指认，
    /// 是 SwiftData 里典型的建模错误。
    ///
    /// 删除规则由对面决定为 `.nullify`：删掉一本书，它从所有书单里消失，
    /// 但书单本身留着——用户丢的是一本书，不是一个阅读计划。
    var collections: [BookCollection] = []

    /// 全书子章节总数——进度百分比的**分母**。
    ///
    /// `progressRecords` 只在 `markSubChapterRead` 时 insert，里面每条都是已读的，
    /// 所以它自己给不出分母；没有分母就无从谈百分比。总数由阅读器首次解析目录时
    /// 回填（`ContentsPanelViewModel.loadEPUBAsync`），之后书架无需再碰 EPUB 就能算进度。
    ///
    /// `0` = 尚未统计（导入了但没打开过），此时 `readingProgress` 返回 nil 而不是 0：
    /// 把"没统计"和"没开始读"混为一谈，会让书架给一本刚导入的书盖上 0% 的戳。
    var totalChapterCount: Int = 0

    /// 导入时计算的 .epub 内容 SHA-256——书库去重键。
    ///
    /// 判重看内容而不是文件名：同名不同书、同书改后缀都骗不过哈希；
    /// 反过来同一本书换文件名也不会被误杀。空串 = 2026-10-13 之前导入的老书
    /// （无哈希可查，不参与判重，避免误伤）。
    var importHash: String = ""
    // ──────────────────────────────────────────────────

    init(
        dateAdded: Date = .now,
        bookExtrSubdir: URL,
        bookBackupdir: URL,
        resourceBaseURL: URL,
        bookTitle: String,
        bookAuthor: String,
        bookPublisher: String,
        coverImageURLs: [URL],
        importHash: String = ""
    ) {
        self.dateAdded = dateAdded
        self.bookExtrSubdir = bookExtrSubdir
        self.bookBackupdir = bookBackupdir
        self.resourceBaseURL = resourceBaseURL
        self.bookTitle = bookTitle
        self.bookAuthor = bookAuthor
        self.bookPublisher = bookPublisher
        self.coverImageURLs = coverImageURLs
        self.importHash = importHash
    }
}


// MARK: - 阅读进度

extension bookItem {

    /// 阅读进度 0.0~1.0（已读子章节数 / 全书子章节总数）。
    ///
    /// 全工程进度的唯一真值——书架、排序、统计都从这里取，避免各写一份口径。
    /// 返回 `nil` 表示**分母未知**（书还没被打开统计过），调用方应当按"不显示"处理，
    /// 而不是当成 0。
    var readingProgress: Double? {
        guard totalChapterCount > 0 else { return nil }
        let readCount = progressRecords.filter(\.isRead).count
        // 目录可能缩水（重导入了另一版 EPUB），已读条数超出总数时夹到 100%，
        // 否则书架上会出现 120% 这种自相矛盾的数字。
        return min(1.0, Double(readCount) / Double(totalChapterCount))
    }
}

/// 以 src 路径为 key，记录每个子章节的阅读状态
@Model
final class ReadingProgressRecord {
    /// 稳定的业务主键：SubChapter.src（跨 App 启动不变）
    var src: String
    var isRead: Bool
    var readAt: Date?

    init(src: String) {
        self.src = src
        self.isRead = false
        self.readAt = nil
    }
}
