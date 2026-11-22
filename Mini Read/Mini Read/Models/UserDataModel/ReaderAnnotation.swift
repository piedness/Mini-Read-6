//
//  ReaderAnnotation.swift
//  TheNewVellium
//
//  一处高亮 / 一条笔记。
//
//  ## 锚点为什么是「章内字符区间 + 原文引用」
//  与 `Bookmark` 同一条理由：页码是排版的产物，字号、行距、版心、旋转任何一项
//  变化都会重新分页，「第 12 页」下一秒就可能指向另一段文字。读者标注的是
//  **一段文字**，所以这里存这段文字在章节正文里的字符区间——它只随正文内容变，
//  不随排版变。跳转与绘制时由 `ChapterLayout` 在当前排版结果上把偏移解析回页码。
//
//  额外存一份 `quote`：书被重新导入、排版内容模型升级后，旧偏移可能落在
//  另一个字上。此时在章内按原文重新搜索一次（见 `AnnotationResolver`），
//  比静默把高亮画到错的地方要好。两者都对不上时这条记录仍留在库里与列表里，
//  只是不再绘制——读者丢的是高亮，不该连"我曾经标过这里"都一起消失。
//
//  ## 为什么不把标注写进 NSTextStorage
//  共享 `NSTextStorage` 上的每一次属性编辑都会让 `NSLayoutManager` 对整段区间
//  失效：三十万字的章节会卡一下；换字号重排、冷启动读磁盘缓存后属性又全部消失。
//  所以标注是**模型驱动的绘制**：正文文本保持纯净，标注在 `TextRenderView.draw`
//  里按页求交后画上去。代价是几十行绘制代码，换来的是重排不丢、透明度实时生效、
//  样式可扩展（波浪线、边注指示器）。
//

import Foundation
import SwiftData

// MARK: - 模型

@Model
final class ReaderAnnotation {

    /// 稳定业务 id。不用 `persistentModelID` 做对外身份：
    /// 导出、分享、跨层快照都需要一个与存储实现无关的标识。
    var annotationID: UUID = UUID()

    /// 书籍身份。与 `Bookmark` / `PageProgress` 同口径（`bookExtrSubdir.path`）。
    var bookKey: String = ""

    /// 章节文件相对路径，与 `SubChapter.src` 一致。
    var src: String = ""

    /// 锚点：本段首字符在章节文本中的偏移。
    var charStart: Int = 0

    /// 锚点长度（UTF-16，与 `NSRange` 同口径）。
    var charLength: Int = 0

    /// 选中时的原文快照。重锚定与列表展示都用它。
    var quote: String = ""

    /// 笔记正文。空串 = 纯高亮。
    var note: String = ""

    /// `AnnotationStyle.rawValue`
    var styleRaw: String = AnnotationStyle.highlight.rawValue

    /// `AnnotationColor.rawValue`
    var colorRaw: String = AnnotationColor.yellow.rawValue

    /// 创建时的章节标题快照。目录重解析失败时列表仍可读。
    var chapterTitle: String = ""

    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    init(
        bookKey: String,
        src: String,
        charStart: Int,
        charLength: Int,
        quote: String,
        note: String = "",
        style: AnnotationStyle = .highlight,
        color: AnnotationColor = .yellow,
        chapterTitle: String = "",
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.annotationID = UUID()
        self.bookKey = bookKey
        self.src = src
        self.charStart = charStart
        self.charLength = charLength
        self.quote = quote
        self.note = note
        self.styleRaw = style.rawValue
        self.colorRaw = color.rawValue
        self.chapterTitle = chapterTitle
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// MARK: - 样式解析

extension ReaderAnnotation {

    var style: AnnotationStyle {
        AnnotationStyle(rawValue: styleRaw) ?? .highlight
    }

    var color: AnnotationColor {
        AnnotationColor(rawValue: colorRaw) ?? .yellow
    }

    var range: NSRange {
        NSRange(location: charStart, length: charLength)
    }

    var hasNote: Bool {
        !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 跨层快照。UIKit 绘制层只吃值类型，不碰 SwiftData 对象
    /// （fault、上下文线程、生命周期都不该出现在每帧的 draw 里）。
    var snapshot: AnnotationSnapshot {
        AnnotationSnapshot(
            id: annotationID,
            src: src,
            range: range,
            quote: quote,
            note: note,
            style: style,
            color: color
        )
    }
}

// MARK: - 快照

/// 一处标注在 UI 层的不可变表示。
struct AnnotationSnapshot: Identifiable, Equatable {

    let id: UUID
    let src: String
    let range: NSRange
    let quote: String
    let note: String
    let style: AnnotationStyle
    let color: AnnotationColor
}

// MARK: - 聚焦请求

/// 从笔记列表跳转到某一处标注后的「闪一下」请求。
///
/// 用独立 token 而不是直接传 id：读者连续点同一条笔记两次，第二次也必须
/// 重新触发聚焦——只比较 id 会把第二次当成"没有变化"而吞掉。
struct AnnotationFocusRequest: Equatable {
    let id: UUID
    let annotationID: UUID
}

// MARK: - 编辑草稿

/// 笔记编辑器的输入/输出。新建与编辑共用一份结构，
/// 避免"新建走一套字段、编辑走另一套"的漂移。
struct AnnotationDraft: Identifiable {

    let id = UUID()

    /// nil = 新建。
    var annotationID: UUID?
    var src: String
    var range: NSRange?
    var quote: String
    var chapterTitle: String
    var note: String
    var style: AnnotationStyle
    var color: AnnotationColor

    var isNew: Bool { annotationID == nil }

    /// 新建笔记时自动聚焦输入框；从列表打开已有笔记时不抢焦点。
    var autoFocus: Bool

    init(
        annotation: ReaderAnnotation,
        autoFocus: Bool = false
    ) {
        self.annotationID = annotation.annotationID
        self.src = annotation.src
        self.range = annotation.range
        self.quote = annotation.quote
        self.chapterTitle = annotation.chapterTitle
        self.note = annotation.note
        self.style = annotation.style
        self.color = annotation.color
        self.autoFocus = autoFocus
    }

    init(
        selection: ReaderTextSelection,
        style: AnnotationStyle,
        color: AnnotationColor,
        note: String = ""
    ) {
        self.annotationID = nil
        self.src = selection.src
        self.range = selection.range
        self.quote = selection.quote
        self.chapterTitle = selection.chapterTitle
        self.note = note
        self.style = style
        self.color = color
        self.autoFocus = true
    }
}
