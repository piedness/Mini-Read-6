//
//  ChapterHTMLParser.swift
//  TheNewVellium
//
//  EPUB 正文提取（2026-10-13 重写，修复 N1 / P0-C）。
//
//  原实现（ParseTest.swift + SWXMLHash）的两个结构性缺陷：
//  1. 只取 body 直接子节点的 <p>：<h1>-<h6>、列表、<blockquote>、
//     <div> 包裹段落（Calibre 默认输出）全部丢弃，整章判空即「书打不开」；
//  2. 用 XML 解析器读 XHTML：&nbsp;、未闭合 <br>（HTML5 常态）让解析中断，
//     章节后半内容整段丢失，且无任何错误上报。
//
//  现在：Kanna HTML 模式（依赖已在工程——目录解析就在用；libxml2 RECOVER
//  容错解析）+ 递归遍历 + 段落实模型。产出供排版（ChapterTypography）、
//  全书搜索、高亮坐标、无障碍朗读共同消费。
//
//  设计约束：
//  - 纯函数：String → ParsedChapter（段落实模型 + 目录锚点），
//    不碰文件系统/UIKit/SwiftData；
//  - Sendable：解析在后台队列进行，结果跨并发边界回传（见 MainViewController
//    loadChapterFromSource 的 withCheckedContinuation 模式）；
//  - 解析失败（非 HTML 输入）返回空结果，由调用方走既有「章节打不开」路径。
//
//  2026-11-16 增补目录锚点：EPUB 的 `chapter.xhtml#sec2` 原先被剥成章首，
//  同一文件里的多个目录项因此全部落在第一页。现在解析时顺带记下元素的
//  id/name 落在第几个块上，由排版层换算成字符偏移（见 ChapterTypography），
//  目录跳转即可落到小节而不是章首。
//

import Foundation
import Kanna

// MARK: - 段落实模型

/// 一章正文的结构化内容。
///
/// 为什么不是 `[String]`：排版需要区分标题层级（字号/加粗/段前距）、
/// 引用（缩进）、列表（悬挂缩进）、图片（NSTextAttachment）；下游的
/// 全书搜索、高亮、无障碍同样需要结构而不是一锅文字。
enum ChapterBlock: Sendable, Equatable {
    /// 标题，level 1-6 对应 <h1>-<h6>
    case heading(level: Int, text: String)
    /// 正文段落。文本可含 \n（来自 <br>，诗歌/条目换行不丢）
    case paragraph(text: String)
    /// 引用段
    case quote(text: String)
    /// 列表项
    case listItem(text: String)
    /// 图片。src 为原始 href（可能相对路径/百分号编码），由排版层解析
    case image(src: String, alt: String)
    /// 分隔线（<hr>，书籍的场景分隔）
    case separator
}

// MARK: - 目录锚点

/// EPUB 目录里 `chapter.xhtml#sec2` 的 `#sec2` 落在本章第几个块上。
///
/// 只记块下标，不记字符偏移：字符偏移要等排版（`ChapterTypography`）把块
/// 展开成正文后才算得出来，而解析层不依赖 UIKit。两者在 `ChapterRender`
/// 汇合，得到最终的 id → 字符偏移表（见 `ChapterTypography.anchorOffsets`）。
struct ChapterAnchor: Sendable, Equatable {
    /// 元素的 `id`，或 `<a name="...">` 的 `name`。已 trim，未做大小写折叠。
    let id: String
    /// 该元素子树产出的**第一个**块在 `[ChapterBlock]` 里的下标。
    let blockIndex: Int
}

/// 一次正文解析的完整产物。
///
/// `blocks` 与 `anchors` 必须同批产出：锚点的块下标只在同一份 blocks 上有效，
/// 分开解析会让两者错位（跳转落在错误的段落）。
struct ParsedChapter: Sendable {
    let blocks: [ChapterBlock]
    let anchors: [ChapterAnchor]
}

// MARK: - 解析器

enum ChapterHTMLParser {

    /// 解析一章 XHTML，返回段落实模型。空数组 = 没提取到任何内容。
    ///
    /// 不需要目录锚点的调用方用这个入口；需要锚点时用 `parseChapter(_:)`，
    /// 两者共用同一条遍历路径，不会各解析一遍。
    static func parse(_ html: String) -> [ChapterBlock] {
        parseChapter(html).blocks
    }

    /// 解析一章 XHTML，同时收集目录锚点。
    static func parseChapter(_ html: String) -> ParsedChapter {
        // Kanna HTML 模式默认 [.RECOVER, .NOERROR, .NOWARNING]：
        // 对非良构 HTML 容错恢复，而不是像 XML 解析器那样中断。
        guard let doc = try? HTML(html: html, encoding: .utf8),
              let body = doc.body
        else { return ParsedChapter(blocks: [], anchors: []) }

        var blocks: [ChapterBlock] = []
        var anchors: [ChapterAnchor] = []
        walkBlockChildren(of: body, into: &blocks, anchors: &anchors)
        return ParsedChapter(blocks: blocks, anchors: deduped(anchors))
    }

    // MARK: 锚点收集

    /// 登记元素自身的 `id` / `<a name>`。
    ///
    /// 必须在元素产出块**之前**调用：此刻 `blocks.count` 正好是这棵子树
    /// 将要产出的第一个块的下标。子树一个块都不产出时（空的 `<a id>`、
    /// 纯图片的 `<div id>`），这个下标自然落到后面第一个有内容的块上——
    /// 正是"跳到最近的后继内容"这一期望语义，不需要额外的向前/向后搜索。
    private static func captureAnchors(
        of element: Kanna.XMLElement,
        into anchors: inout [ChapterAnchor],
        at blockIndex: Int
    ) {
        if let id = element["id"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !id.isEmpty {
            anchors.append(ChapterAnchor(id: id, blockIndex: blockIndex))
        }
        // EPUB2 常见的 `<a name="chapter1"></a>`：HTML5 仍允许，nav 里也常指向它。
        if (element.tagName ?? "").lowercased() == "a",
           let name = element["name"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty {
            anchors.append(ChapterAnchor(id: name, blockIndex: blockIndex))
        }
    }

    /// 同一章里重复的 id 只保留**首次**出现——浏览器解析 fragment 也是这个规则。
    private static func deduped(_ anchors: [ChapterAnchor]) -> [ChapterAnchor] {
        var seen = Set<String>()
        return anchors.filter { seen.insert($0.id).inserted }
    }

    // MARK: 块级遍历

    /// 不产出内容的标签：head/脚本/样式/元信息。
    /// 出现在 body 里也一律跳过（坏 EPUB 里 <style> 漏进 body 不罕见）。
    private static let skipTags: Set<String> = [
        "script", "style", "head", "noscript", "template", "title", "meta", "link", "base"
    ]

    /// 行内标签：其文本并入所在块的文字流，不单独成块。
    private static let inlineTags: Set<String> = [
        "a", "span", "sup", "sub", "b", "i", "em", "strong", "u", "s", "strike",
        "small", "big", "code", "kbd", "samp", "var", "cite", "abbr", "dfn",
        "font", "mark", "ruby", "rt", "rp", "bdi", "bdo", "wbr", "time", "label"
    ]

    private static func walkBlockChildren(
        of element: Kanna.XMLElement,
        into blocks: inout [ChapterBlock],
        anchors: inout [ChapterAnchor]
    ) {
        // Kanna 的 children 只含元素节点（类型过滤 XML_ELEMENT_NODE），
        // 块级分类天然安全，不会被散落的空白文本节点干扰。
        for child in element.children {
            let tag = (child.tagName ?? "").lowercased()
            guard !skipTags.contains(tag) else { continue }

            // 锚点先登记再遍历子树：见 `captureAnchors` 的说明。
            captureAnchors(of: child, into: &anchors, at: blocks.count)

            switch tag {
            case "h1", "h2", "h3", "h4", "h5", "h6":
                let level = Int(tag.dropFirst()) ?? 3
                let text = inlineText(of: child)
                if !text.isEmpty { blocks.append(.heading(level: level, text: text)) }

            case "p":
                emitTextContainer(child, into: &blocks, anchors: &anchors)

            case "blockquote":
                // 块引用里通常还嵌 <p>：先递归，再把产出的段落改判为引用。
                let start = blocks.count
                walkBlockChildren(of: child, into: &blocks, anchors: &anchors)
                for i in start..<blocks.count {
                    if case .paragraph(let t) = blocks[i] { blocks[i] = .quote(text: t) }
                }

            case "li":
                emitTextContainer(child, into: &blocks, anchors: &anchors, asListItem: true)

            case "ul", "ol", "dl":
                walkBlockChildren(of: child, into: &blocks, anchors: &anchors)   // li/dt/dd 各成块

            case "hr":
                blocks.append(.separator)

            case "img":
                let src = child["src"] ?? ""
                if !src.isEmpty {
                    blocks.append(.image(src: src, alt: child["alt"] ?? ""))
                }

            default:
                // div/section/article/figure/table/tr/td… 以及一切未知容器：
                // 叶子节点（无元素子节点）当段落；有块级子节点则递归。
                if child.children.isEmpty {
                    emitTextContainer(child, into: &blocks, anchors: &anchors)
                } else {
                    walkBlockChildren(of: child, into: &blocks, anchors: &anchors)
                }
            }
        }
    }

    // MARK: 文本容器（p / li / 叶子 div / td）

    /// 按**文档顺序**收集一个块级元素的内容：文字、<br> 换行、行内元素文本、
    /// 以及中途出现的图片（图片前后的文字分别成块，顺序不丢）。
    ///
    /// 顺序遍历靠 `xpath("node()")`：Kanna 的 `children` 只返回元素节点，
    /// 而 node() 节点集不过滤类型，文本节点与元素节点按文档顺序混排。
    /// （XPathObject 的 nodeSetValue 是 Kanna 内部级，只能走其公开的
    /// Sequence 迭代——count 为 0 时迭代自然为空。）
    private static func emitTextContainer(
        _ element: Kanna.XMLElement,
        into blocks: inout [ChapterBlock],
        anchors: inout [ChapterAnchor],
        asListItem: Bool = false
    ) {
        var buffer = ""

        func flush() {
            let text = normalizedText(buffer)
            buffer = ""
            guard !text.isEmpty else { return }
            blocks.append(asListItem ? .listItem(text: text) : .paragraph(text: text))
        }

        for node in element.xpath("node()") {
            let tag = node.tagName ?? ""

            // 行内锚点（`<p><a id="fn1"></a>…`）：段落还没 flush，此刻的
            // `blocks.count` 就是这一段的块下标，直接登记即可。锚点落在
            // 段落中间时也归到段首——同一页内的几字偏差不影响跳转落页。
            if tag != "text", tag != "comment", tag != "cdata-section" {
                captureAnchors(of: node, into: &anchors, at: blocks.count)
            }

            switch tag {
            case "text":
                buffer += node.text ?? ""
            case "br":
                buffer += "\n"
            case "img":
                // 图片前先结算已有文字，保持图文顺序
                flush()
                if let src = node["src"], !src.isEmpty {
                    blocks.append(.image(src: src, alt: node["alt"] ?? ""))
                }
            case "comment", "cdata-section":
                break                        // HTML 注释不进入正文
            case "script", "style", "head", "noscript", "template", "title", "meta", "link", "base":
                break                        // 漏进容器的非正文标签
            default:
                if inlineTags.contains(tag) {
                    // 行内元素：xmlNodeGetContent 会拼接其全部后代文本
                    // （实体已解码、<sup>(3)</sup> 这样的注音并入正文）。
                    buffer += node.text ?? ""
                } else {
                    // 容器里嵌块级元素（<p> 里的 <div>、<blockquote> 等）：
                    // 先结算文字，再把块级内容交回块级遍历。
                    flush()
                    walkBlockChildren(of: node, into: &blocks, anchors: &anchors)
                }
            }
        }
        flush()
    }

    /// 标题等纯文本块的文字收集：逻辑同 emitTextContainer，但不产图片块、
    /// 不需要 listItem 语义。
    private static func inlineText(of element: Kanna.XMLElement) -> String {
        var out = ""
        for node in element.xpath("node()") {
            let tag = node.tagName ?? ""
            switch tag {
            case "text":      out += node.text ?? ""
            case "br":        out += "\n"
            case "img":       break                 // 标题里的图片不留占位
            case "comment", "cdata-section": break
            case "script", "style", "head", "noscript", "template", "title", "meta", "link", "base": break
            default:
                if inlineTags.contains(tag) { out += node.text ?? "" }
                else { out += node.text ?? "" }
            }
        }
        return normalizedText(out)
    }

    // MARK: 文本清洗

    /// 规范化块文本：
    /// 1. 删 EPUB 常见的零宽字符（ZWSP/BOM/软连字）——TextKit 会把它们
    ///    渲染成方框或莫名的空隙，HTML 里本是不可见排版噪声；
    /// 2. ASCII 空白（空格/制表/回车/换页）折叠为单个空格，**保留 \n**
    ///    （\n 来自 <br>，是诗歌与条目换行的证据）；
    /// 3. 去掉每行首尾空白（源码缩进）与纯空行；
    /// 4. 首尾 trim。
    /// nbsp（&nbsp;）**不折叠**——遵循 HTML 语义，它是不可断行空格。
    static func normalizedText(_ raw: String) -> String {
        // 删 EPUB 常见的零宽字符（ZWSP/BOM/软连字）——TextKit 会把它们渲染成
        // 方框或莫名的空隙，HTML 里本是看不见的排版噪声。
        let cleaned = raw.replacingOccurrences(
            of: "[\u{200B}\u{200C}\u{200D}\u{FEFF}\u{00AD}]",
            with: "",
            options: .regularExpression
        )

        let lines = cleaned.components(separatedBy: "\n").map { line -> String in
            // 折叠 ASCII 空白（空格/制表/回车/垂直制表/换页）；\n 已在components层保留，
            // nbsp（&nbsp;）不折叠——HTML 语义里它是不可断行空格。
            let collapsed = line.replacingOccurrences(
                of: "[ \t\r\u{000B}\u{000C}]+",
                with: " ",
                options: .regularExpression
            )
            return collapsed.trimmingCharacters(in: .whitespaces)
        }
        // 丢掉纯空行（标签间空白造成的空 <p>、连续 <br>）
        let kept = lines.filter { !$0.isEmpty }
        return kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
