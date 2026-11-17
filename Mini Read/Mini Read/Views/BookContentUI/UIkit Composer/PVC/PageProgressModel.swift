import SwiftData
import Foundation

// MARK: - PageProgress

/// 页级阅读进度记录
///
/// 每本书的每个 src（章节文件路径）对应一条记录，存储用户最后阅读到的位置。
/// 与 bookItem 上的 lastReadSrc 配合使用：
///   - lastReadSrc：记录上次读到哪个章节
///   - PageProgress：记录该章节内的位置（页号 + 字符锚点）
///
/// ## 为什么同时存页号和字符偏移
/// 页号是排版的产物：字号、行距、版心、旋转任何一项变化都会重新分页，
/// 「第 12 页」下一秒就指向另一段文字。只按页号恢复，读者改完字号再冷启动
/// 就会落在别处——而且他自己并没有翻过页，看起来像"进度丢了"。
///
/// `characterOffset` 只随正文内容变，不随排版变。恢复时由 `ChapterLayout`
/// 在**当前**分页结果上把偏移反解回页下标（与书签同一套坐标）。
/// `pageIndex` 仍然保留：它是锚点缺失时的兜底，也是阅读数据等只读消费方的
/// 现有口径，不能删。
@Model
final class PageProgress {

    /// 当前书籍的稳定 key，避免不同 EPUB 中相同 src 串进度。
    var bookKey: String = ""

    /// 章节文件路径，与 SubChapter.src 保持一致
    var src: String

    /// 最后阅读的页索引（0-based，对应章节页面数组下标；双页模式下是左页下标）。
    /// 普通章节数组与 ChapterLayout 页一一对应；若本章含合成扉页，扉页占 index 0，
    /// 后续版权页整体顺延一位。
    var pageIndex: Int

    /// 最后更新时间，供排序 / 调试使用
    var updatedAt: Date

    init(bookKey: String, src: String, pageIndex: Int) {
        self.bookKey   = bookKey
        self.src       = src
        self.pageIndex = pageIndex
        self.updatedAt = .now
    }
}
