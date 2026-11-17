//
//  ChapterRender.swift
//  TheNewVellium
//
//  一章从「原始 XHTML」到「可上屏的 ChapterLayout」的共享构建路径。
//  （2026-10-14 随扉页/版权页改造新增。）
//
//  为什么抽这一层：前置页改造后，「解析 → 版权页判定 → 选排版样式」
//  这条链在三个地方各发生过一次——章加载（MainViewController
//  loadChapterFromSource）、全书页码索引（runBookPageCountIndexing）、
//  运行时探针。三处各写一遍必然漂移：索引按普通样式数页、加载按版权
//  样式数页，页码就会错位；探针验的也未必是线上那条路。这里收口成
//  唯一入口，`frontMatter` 判定随结果一起返回。
//
//  纯函数：入参出参都不碰 UIKit 控件栈与 SwiftData，可在后台队列调用；
//  产出的 ChapterLayout 在同一队列内消费，不跨并发边界传递。
//

import UIKit

enum ChapterRender {

    /// 一章的排版产物。
    struct Outcome {
        /// 可直接上屏的共享排版。版权页样式或正文样式，由 `frontMatter` 标注。
        let layout: ChapterLayout
        /// 本 layout 的源富文本（供 PaginationCache 落盘；与 layout 同文不同寿）。
        let attributedString: NSAttributedString
        /// 是否为前置页。为 true 时调用方还需在章节页数组最前面补一个
        /// 封面页 VC（扉页），它不计入 layout 的页数。
        let frontMatter: Bool
    }

    /// 解析并排版一章。返回 nil = 没提取到任何内容（调用方走既有
    /// 「章节打不开」路径）。
    ///
    /// - Parameters:
    ///   - htmlString: 章的原始 XHTML 文本。
    ///   - config: 排版配置（页尺寸/字号/边距/墨色…）。
    ///   - imageBase: 章文件所在目录，正文图片相对 href 的解析基准。
    ///   - isFirstChapter: 是否为全书第一章。版权页只可能出现在开篇，
    ///     这是防误判的总闸——中段章节提一嘴「版权所有」是正文内容。
    ///   - chapterTitle: 目录标题，作为版权页判定的支撑信号。
    static func outcome(
        htmlString: String,
        config: PaginationConfig,
        imageBase: URL,
        isFirstChapter: Bool,
        chapterTitle: String?
    ) -> Outcome? {
        let parsed = ChapterHTMLParser.parseChapter(htmlString)
        guard !parsed.blocks.isEmpty else { return nil }

        // 版心非正（上下边距之和超过页高、左右超过页宽）时，TextKit 一个
        // 字形都排不进去，`ChapterLayout.pageCount` 会是 0。旧实现把这种
        // 结果当成功缓存：页面永远是空白，还会让跨章反向翻页走进
        // `prevPages[-1]`。这里直接按"本章打不开"处理，由调用方回退；
        // 绝不产出零页 layout（用户可以在设置里把边距调到 200）。
        let usableSize = config.usableSize
        guard usableSize.width > 0, usableSize.height > 0 else {
            print("⚠️ 版心尺寸非正（\(usableSize)），拒绝排版")
            return nil
        }

        // 第一章 + 版权页特征 → 前置页排版（扉页由阅读器单独成 VC）
        let attrStr: NSMutableAttributedString
        let frontMatter: Bool
        var anchors: [String: Int] = [:]
        if isFirstChapter,
           FrontMatterDetector.isCopyrightPage(blocks: parsed.blocks, chapterTitle: chapterTitle) {
            attrStr = ChapterTypography.copyrightString(blocks: parsed.blocks, config: config)
            frontMatter = true
            // 版权页排版会丢标题、按行重排，块与文本的对应关系不再成立，
            // 因此不产出锚点：指向它的目录项退回章首即可。
        } else {
            let typography = ChapterTypography.typeset(
                blocks: parsed.blocks,
                config: config,
                imageBase: imageBase
            )
            attrStr = typography.attributedString
            // 锚点的块下标 → 字符偏移必须在这里换算：块偏移只有排版过程知道，
            // 而分页（ChapterLayout）只认字符偏移。
            anchors = ChapterTypography.anchorOffsets(
                anchors: parsed.anchors,
                blockOffsets: typography.blockOffsets,
                textLength: typography.attributedString.length
            )
            frontMatter = false
        }

        let layout = ChapterLayout(
            attributedString: attrStr,
            usableSize: usableSize,
            anchors: anchors
        )
        guard layout.pageCount > 0 else {
            print("⚠️ 排版结果为零页，拒绝作为可上屏章节")
            return nil
        }
        return Outcome(layout: layout, attributedString: attrStr, frontMatter: frontMatter)
    }
}
