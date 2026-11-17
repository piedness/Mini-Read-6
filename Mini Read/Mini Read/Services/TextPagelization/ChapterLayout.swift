import UIKit

// MARK: - ChapterLayout

/// 一章的共享排版对象：一个 NSTextStorage + 一个 NSLayoutManager，挂载多个 NSTextContainer。
///
/// 每个 container 对应一"页"，它们共享同一份底层文本和同一次排版计算。
/// 这样某一行是不是段落的真正末行，是在全章范围内一次性判定的，
/// 而不是在切出来的孤立片段里各自为战。
///
/// 在共享 layout 架构下，首行缩进由 TextKit 天然正确处理：
/// firstLineHeadIndent 仅作用于每个段落的真正第一行（跟在 \n 之后的那个字符位置）。
/// 段落跨页延续到下一页时，延续行不是段落首行，因此不会错误地应用缩进。
final class ChapterLayout {

    let textStorage: NSTextStorage
    let layoutManager: NSLayoutManager
    private(set) var pageContainers: [NSTextContainer] = []

    /// 目录锚点：EPUB 里的元素 id → 它在整章文本中的字符偏移。
    ///
    /// 与分页结果同寿：偏移是**本章当前排版**下的坐标，换字号/尺寸后
    /// 由新一次排版重新产出（缓存键含配置摘要，不会读到旧偏移）。
    /// 空表 = 这一章没有可用锚点（无 id、或缓存来自旧版本）。
    let anchors: [String: Int]

    /// 创建整章的共享排版对象
    /// - Parameters:
    ///   - attributedString: 整章的完整富文本（已应用所有字体、间距、缩进等属性）
    ///   - usableSize: 单页可用文字区域尺寸（= 页面尺寸 - 四边 margin）
    ///   - anchors: 目录锚点表，见 `anchors`
    init(attributedString: NSAttributedString, usableSize: CGSize, anchors: [String: Int] = [:]) {
        textStorage = NSTextStorage(attributedString: attributedString)
        layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        self.anchors = anchors

        var consumed = 0
        while consumed < layoutManager.numberOfGlyphs {
            let container = NSTextContainer(size: usableSize)
            container.lineFragmentPadding = 0
            layoutManager.addTextContainer(container)
            let glyphRange = layoutManager.glyphRange(for: container)
            guard glyphRange.length > 0 else { break }
            pageContainers.append(container)
            consumed = NSMaxRange(glyphRange)
        }
    }

    var pageCount: Int { pageContainers.count }
}

// MARK: - SelectionState

/// 章节全局选中状态，同一 ChapterLayout 的所有 TextRenderView 共享此实例。
/// startIndex / endIndex 是章节全局字符坐标（基于共享 NSTextStorage）。
final class SelectionState {
    var startIndex: Int? { didSet { if oldValue != startIndex { notifyChange() } } }
    var endIndex: Int?   { didSet { if oldValue != endIndex   { notifyChange() } } }

    /// 本章每一页的观察者（`TextRenderView`）。
    ///
    /// 这里曾经是一个 `onChange: (() -> Void)?` 闭包，每个 TextRenderView 在
    /// init 里各赋一次值——**最后建出来的那一页把前面所有页的闭包都盖掉了**。
    /// 双页模式下选中一段跨页文字时，只有一页重绘，另一页的选区停在原地不动，
    /// 读者会以为选中范围只有半屏。改成章内多播；弱引用表保证页面被 LRU
    /// 淘汰后自动退出，不需要手动反注册。
    private let observers = NSHashTable<AnyObject>.weakObjects()

    func addObserver(_ observer: AnyObject) {
        observers.add(observer)
    }

    private func notifyChange() {
        for observer in observers.allObjects {
            (observer as? TextRenderView)?.setNeedsDisplay()
        }
    }

    var range: NSRange? {
        guard let s = startIndex, let e = endIndex, s != e else { return nil }
        return NSRange(location: min(s, e), length: abs(e - s))
    }

    func clear() { startIndex = nil; endIndex = nil }
}

// Attach shared selection state to ChapterLayout
extension ChapterLayout {
    private static var selectionStateKey: UInt8 = 0
    var selectionState: SelectionState {
        if let existing = objc_getAssociatedObject(self, &Self.selectionStateKey) as? SelectionState {
            return existing
        }
        let state = SelectionState()
        objc_setAssociatedObject(self, &Self.selectionStateKey, state, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return state
    }
}

// MARK: - 字符坐标 ↔ 页坐标
//
// 书签锚点用**字符偏移**保存（跨字号/旋转稳定），而阅读器只认页下标。
// 两个方向都要能换算，且必须只用本类的排版结果——它是当前分页的唯一真值。

extension ChapterLayout {

    /// 某一页在章节文本中的字符范围。索引越界或空页返回 nil。
    func characterRange(forPage index: Int) -> NSRange? {
        guard pageContainers.indices.contains(index) else { return nil }
        let glyphRange = layoutManager.glyphRange(for: pageContainers[index])
        guard glyphRange.length > 0 else { return nil }
        return layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
    }

    /// 某一页首字符的章节全局偏移。
    func characterOffset(forPage index: Int) -> Int? {
        characterRange(forPage: index)?.location
    }

    /// 目录锚点 → 章节全局字符偏移。
    ///
    /// 找不到时返回 nil，由调用方退回章首（旧缓存 / 坏书的 fragment 对不上
    /// 正文 id 时，这是唯一不会跳错的选择）。
    ///
    /// 大小写不敏感只作兜底：HTML 规范里 id 是大小写敏感的，先按原文精确
    /// 匹配；部分书的 nav fragment 与正文 id 只差大小写，多这一步能救回来，
    /// 又不会影响规范书。
    func characterOffset(forAnchor anchorID: String) -> Int? {
        guard !anchorID.isEmpty, !anchors.isEmpty else { return nil }
        if let exact = anchors[anchorID] { return exact }

        let lowered = anchorID.lowercased()
        return anchors.first { $0.key.lowercased() == lowered }?.value
    }

    /// 字符偏移落在哪一页——书签跳转的解析入口。
    ///
    /// 偏移越界（正文变短了）时夹到最后一页，而不是返回 nil 让调用方
    /// 退化成章首：读者点了书签却回到章首，比回到章节末尾更像"丢了"。
    func pageIndex(forCharacterOffset offset: Int) -> Int? {
        guard !pageContainers.isEmpty else { return nil }
        let length = textStorage.length
        guard length > 0 else { return nil }

        let clamped = min(max(0, offset), length - 1)
        let glyphIndex = layoutManager.glyphIndexForCharacter(at: clamped)

        for (index, container) in pageContainers.enumerated() {
            let glyphRange = layoutManager.glyphRange(for: container)
            if glyphRange.length > 0, NSLocationInRange(glyphIndex, glyphRange) {
                return index
            }
        }
        return pageContainers.count - 1
    }

    /// 某一页的纯文本（保留原始换行，由调用方决定如何折叠）。
    ///
    /// `maxLength` 供"只要页首一小段"的场合（书签预览）使用：
    /// `textStorage.string` 每次访问都要把整章文本桥接出来，一章几十万字时
    /// 为了取 90 个字而复制整章并不划算。
    func text(forPage index: Int, maxLength: Int? = nil) -> String? {
        guard let range = characterRange(forPage: index), range.length > 0 else { return nil }

        let length = maxLength.map { min($0, range.length) } ?? range.length
        guard length > 0, NSMaxRange(range) <= textStorage.length else { return nil }

        return (textStorage.string as NSString)
            .substring(with: NSRange(location: range.location, length: length))
    }
}
