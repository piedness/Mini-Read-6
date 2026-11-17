//
//  ReaderLocation.swift
//  TheNewVellium
//
//  「当前可见页」的位置快照。
//
//  UIKit 阅读器与 SwiftUI 外壳之间此前只有章节级位置（`currentSrc`），
//  页级信息（第几页、这一页从哪个字符开始）从未离开过阅读器。书签需要它，
//  于是有了这份快照：阅读器在每次可见页变化时上报，上层据此维护
//  「这一页是否已加书签」以及新增书签的锚点。
//
//  只依赖 Foundation：书签的「算不算同一页」判定放在这里，可以脱离 UIKit
//  用运行时探针覆盖边界情况（见 vellium-dev Skill 的探针手法）。
//

import Foundation

struct ReaderLocation: Equatable, Sendable {

    let src: String

    /// 本页首字符在章节文本中的偏移。书签锚点就用它。
    let pageStartOffset: Int

    /// 本页字符数。0 表示这一页没有可锚定的文字（空页）。
    let pageLength: Int

    let chapterTitle: String?

    /// 本页开头的一段文字，折叠空白后截断。
    let preview: String

    /// 是否可以作为书签锚点。空页（无文字）不应写书签。
    var isAnchorable: Bool { pageLength > 0 }

    /// 某个书签锚点是否落在本页范围内。
    ///
    /// 用「区间包含」而不是「偏移相等」：加过书签再改字号，一页会被拆成两页，
    /// 锚点会落到后一页的首字符上——它指的还是同一段文字，读者翻到那一页
    /// 就该看到「已加书签」，而不是发现自己"丢了"书签又加了一遍。
    func contains(characterOffset offset: Int) -> Bool {
        guard pageLength > 0 else { return false }
        return offset >= pageStartOffset && offset < pageStartOffset + pageLength
    }

    /// 折叠空白并截断，作为书签列表的预览文字。
    ///
    /// 折叠是必要的：`NSTextStorage` 里的换行与缩进会原样带出来，
    /// 两行预览里塞满空白等于什么都没显示。`whitespacesAndNewlines`
    /// 覆盖全角空格（U+3000），中文排版里的段首缩进才会被吃掉。
    static func makePreview(from raw: String, limit: Int = 90) -> String {
        let collapsed = raw
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        guard collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…"
    }
}
