//
//  FrontMatter.swift
//  TheNewVellium
//
//  前置页（版权页）检测（2026-10-14 随「扉页 + 版权页」改造新增）。
//
//  纸质书的开篇结构：扉页（书名/作者）→ 版权页 → 正文。EPUB 的版权页
//  通常是全书最短的一章（版权申明 / Copyright / ISBN / CIP 数据），
//  读者打开一本书却先看到一页密字，是电子书最常被抱怨的开场。
//
//  本文件只做纯函数判定（String → Bool），不排版、不碰 UIKit；
//  排版在 `ChapterTypography.copyrightString`，两者经
//  `ChapterRender.outcome` 收口成唯一入口，防止「按普通样式数页、
//  按版权样式渲染」这类口径漂移。
//
//  设计约束（误判的代价是不丢内容地多走两页，漏判的代价是回到旧体验，
//  因此判定从紧，且只在全书第一章上调用——见 `ChapterRender.outcome` 的
//  `isFirstChapter` 总闸）：
//  - 硬信号：© / Copyright / 版权 字样、ISBN、CIP 在版编目、
//    「书名：xxx」这类版权页惯有元数据、或目录标题本身就是「版权/copyright」；
//  - 支撑信号：出版/印刷/发行 等出版信息、CIP、目录标题提示；
//  - 长度约束：版权页是全书最短的页面之一，超过 1200 个非空白字符
//    一律按普通章节处理（防止中篇正文里提了一嘴「版权所有」被误判）。
//

import Foundation

// MARK: - 版权页检测

enum FrontMatterDetector {

    /// 版权页非空白字符的长度上限。
    ///
    /// 1200 约等于一屏密字：正常版权页（中文 CIP 数据 + ISBN + 印次）
    /// 通常在 500 字以内；超过这个长度的第一章按正文处理更安全。
    static let maxCompactLength = 1200

    /// 版权页惯有的出版系关键词（只作支撑信号，单独出现不判定）。
    /// 中英双语：英文版权页的支撑信号是 Published/Printed/All rights reserved，
    /// 漏掉它们会让「© + ISBN」齐全的纯英文版权页判不出来。
    private static let publishingKeywords = [
        "出版", "印刷", "发行", "出版社",
        "published", "press", "printed", "all rights reserved",
    ]

    /// 判定一章**正文**文本是否为版权页。
    ///
    /// - Parameters:
    ///   - text: 一章的正文纯文本（不含页面自带标题——见 `contentText` 的说明）。
    ///   - chapterTitle: 目录里这一章的标题，作为支撑信号。
    ///     大量 EPUB 的版权页在目录里就叫「版权申明 / Copyright」。
    static func isCopyrightPage(text: String, chapterTitle: String?) -> Bool {
        // 长度是前置条件：长章节直接出局，后面的关键词都不用看
        let whitespace = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{00A0}"))
        let compactCount = text.unicodeScalars.filter { !whitespace.contains($0) }.count
        guard compactCount <= maxCompactLength else { return false }

        let lowered = text.lowercased()

        // ── 硬信号（只从正文内容里找）──
        let hasCopyrightMark = lowered.contains("copyright")
            || text.contains("\u{00A9}")            // ©
            || text.contains("\u{24D8}")            // ⓘ
            || text.contains("版权")
        let hasISBN = lowered.contains("isbn")
        let hasCIP = text.contains("在版编目")
        // 「书名：xxx」+「作者/出版」是 Calibre 版权信息页的标准结构
        let hasBookMeta = text.contains("书名") && (hasPublishingInfo(lowered) || text.contains("作者"))

        guard hasCopyrightMark || hasISBN || hasCIP || hasBookMeta else { return false }

        // ── 支撑信号 ──
        // 目录标题只作支撑、绝不当硬信号：中段章节挂了个「版权」标题但内容
        // 是正文的情况不能误判；真正的版权页内容本身就带 ©/版权/ISBN。
        // 这也让「解析路径」与「缓存命中路径」（后者拿到的是排版后文本，
        // 标题已被剔除）对同一章永远给出同一判定——否则冷启动前后
        // 前置页页数差一页扉页，正文页码会错位。
        return hasPublishingInfo(lowered) || hasCIP || hasBookMeta || isTitleHint(chapterTitle)
    }

    /// 段落实模型入口：只取**正文内容**文本后走文本判定。
    static func isCopyrightPage(blocks: [ChapterBlock], chapterTitle: String?) -> Bool {
        isCopyrightPage(text: contentText(blocks), chapterTitle: chapterTitle)
    }

    /// 目录标题是否点名版权页（支撑信号）。
    private static func isTitleHint(_ title: String?) -> Bool {
        guard let title else { return false }
        return isCopyrightTitle(title)
    }

    /// 判定目录标题是否点名这是版权页。
    static func isCopyrightTitle(_ title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let lowered = trimmed.lowercased()
        return lowered.contains("版权") || lowered.contains("copyright") || lowered.contains("colophon")
    }

    // MARK: 版权页排版共用的行级判定

    /// 是否为需要强调的关键行（©/版权/Copyright/ISBN/书名 等）。
    /// 版权页排版据此分墨色与字号层级。
    static func isKeyLine(_ line: String) -> Bool {
        line.contains("\u{00A9}") || line.contains("\u{24D8}") || line.contains("版权")
            || line.lowercased().contains("copyright")
            || line.lowercased().contains("isbn")
            || line.contains("书名")
    }

    /// 是否为中文版权页（决定版权页整体居中还是左对齐）：
    /// 中文版权页惯例居中，英文版权页惯例左对齐。
    ///
    /// 判定按**行**而不是字符占比：版权页里 ISBN / 网址 / 印次数字
    /// 大量 ASCII 会稀释总字符占比（一页 30% 中文字符的典型中文版权页
    /// 会被误判成英文页）；而「含有中文的行占比」不受影响——
    /// 中文版权页几乎每行都有中文，英文版权页则一行都没有。
    static func predominantlyCJK(_ text: String) -> Bool {
        let lines = text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return false }

        let linesWithCJK = lines.filter { line -> Bool in
            line.unicodeScalars.contains { scalar in
                switch scalar.value {
                case 0x4E00...0x9FFF,   // CJK 统一表意文字
                     0x3400...0x4DBF,   // 扩展 A
                     0xF900...0xFAFF:   // 兼容表意文字
                    return true
                default:
                    return false
                }
            }
        }
        return Double(linesWithCJK.count) / Double(lines.count) >= 1.0 / 3.0
    }

    // MARK: 私有

    private static func hasPublishingInfo(_ lowered: String) -> Bool {
        publishingKeywords.contains { lowered.contains($0) }
    }

    // MARK: 文本提取

    /// **检测专用**的正文文本：剔除 heading 块。
    ///
    /// 为什么标题不进检测语料：版权类标题（「版权申明」）本身就是强关键词，
    /// 计入它等于让标题绕过硬信号——中段章节挂个版权标题就会被误判；
    /// 更糟的是排版路径会剔除版权标题（见 `ChapterTypography.copyrightString`），
    /// 缓存命中路径拿到的文本里没有它，两条路就会对同一章给出不同判定。
    /// 只认正文内容，两条路的语料天然一致。
    static func contentText(_ blocks: [ChapterBlock]) -> String {
        blocks.map { block -> String in
            switch block {
            case .paragraph(let text), .quote(let text), .listItem(let text):
                return text
            case .image(_, let alt):
                return alt
            case .separator, .heading:
                return ""
            }
        }
        .joined(separator: "\n")
    }

    /// 全量文本（含标题），供版权页排版判断整体文字属性（中英对齐）使用。
    static func plainText(_ blocks: [ChapterBlock]) -> String {
        blocks.map { block -> String in
            switch block {
            case .heading(_, let text), .paragraph(let text), .quote(let text), .listItem(let text):
                return text
            case .image(_, let alt):
                return alt
            case .separator:
                return ""
            }
        }
        .joined(separator: "\n")
    }
}
