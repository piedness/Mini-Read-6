//
//  Bookmark.swift
//  TheNewVellium
//
//  阅读书签。
//
//  ## 为什么锚点是「字符偏移」而不是页码
//  页码是排版的产物：字号、行距、版心、旋转任何一项变化都会重新分页，
//  「第 12 页」下一秒可能变成「第 9 页」。读者收藏的是**一段文字**，
//  所以书签记住的是这段文字在章节文本里的字符偏移——它只随正文内容变，
//  不随排版变。跳转时由阅读器在当前排版结果上把偏移解析回页码。
//
//  因此这里**不存页码**：存了也没有任何路径会去读它（页码改字号即失效），
//  只会变成一个看起来能用、实际会指错地方的字段。
//

import Foundation
import SwiftData

@Model
final class Bookmark {

    /// 书籍身份。与 `PageProgress` / `PaginationKey` 同口径
    /// （`bookItem.bookExtrSubdir.path`），换书不会串记录。
    var bookKey: String

    /// 章节文件相对路径，与 `SubChapter.src` 一致。
    var src: String

    /// **锚点**：本页首字符在章节文本中的偏移。跳转的唯一坐标。
    var characterOffset: Int

    /// 创建时的章节标题快照。目录重解析失败时列表仍可读。
    var chapterTitle: String

    /// 创建时该页开头的一段文字，供列表辨识。
    var preview: String

    var createdAt: Date

    init(
        bookKey: String,
        src: String,
        characterOffset: Int,
        chapterTitle: String,
        preview: String,
        createdAt: Date = .now
    ) {
        self.bookKey = bookKey
        self.src = src
        self.characterOffset = characterOffset
        self.chapterTitle = chapterTitle
        self.preview = preview
        self.createdAt = createdAt
    }
}
