//
//  MarkdownBlock.swift
//  Mini Read
//
//  GitHub 上的发布说明是 Markdown。这里实现一个**够用就好**的
//  块级解析器：标题、段落、列表、引用、代码块、分隔线。
//
//  为什么不用第三方 Markdown 库：这一页只需要「能读」，不需要「能编辑」。
//  为几十行渲染逻辑再引一个依赖，会让 App 的许可证列表和包体积都多一项负担。
//
//  为什么不把整段丢给 `AttributedString(markdown:)`：它只处理**行内**语法，
//  标题、列表这些块级结构会被压成一坨。所以这里先切块，再对每块做行内解析。
//
//  解析逻辑与渲染分开（本文件不 import SwiftUI）：它是纯函数，可以单独跑测试，
//  也不必为了改一行样式而重新审视解析规则。
//

import Foundation

struct MarkdownBlock: Identifiable, Sendable {
    enum Kind: Sendable, Equatable {
        case heading(level: Int)
        case paragraph
        case bullet(indent: Int)
        case ordered(marker: String)
        case quote
        case code
        case rule
    }

    let id: Int
    let kind: Kind
    let text: String

    /// 按行切块。刻意不追求完整 CommonMark——只覆盖 GitHub 上真实出现的写法。
    static func parse(_ markdown: String) -> [MarkdownBlock] {
        let normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        var blocks: [MarkdownBlock] = []
        var paragraphLines: [String] = []
        var codeLines: [String] = []
        var isInCodeBlock = false

        func append(_ kind: Kind, _ text: String) {
            guard !text.isEmpty else { return }
            blocks.append(MarkdownBlock(id: blocks.count, kind: kind, text: text))
        }

        func flushParagraph() {
            guard !paragraphLines.isEmpty else { return }
            append(.paragraph, paragraphLines.joined(separator: " "))
            paragraphLines.removeAll()
        }

        func flushCode() {
            guard !codeLines.isEmpty else { return }
            append(.code, codeLines.joined(separator: "\n"))
            codeLines.removeAll()
        }

        for rawLine in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // 代码围栏：内部内容原样保留，不做任何行内解析。
            if trimmed.hasPrefix("```") {
                if isInCodeBlock {
                    flushCode()
                    isInCodeBlock = false
                } else {
                    flushParagraph()
                    isInCodeBlock = true
                }
                continue
            }
            if isInCodeBlock {
                codeLines.append(line)
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                continue
            }

            if let heading = headingBlock(trimmed) {
                flushParagraph()
                append(heading.kind, heading.text)
                continue
            }

            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushParagraph()
                append(.rule, " ")
                continue
            }

            if trimmed.hasPrefix(">") {
                flushParagraph()
                let text = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
                append(.quote, text)
                continue
            }

            if let bullet = bulletBlock(line) {
                flushParagraph()
                append(bullet.kind, bullet.text)
                continue
            }

            if let ordered = orderedBlock(trimmed) {
                flushParagraph()
                append(ordered.kind, ordered.text)
                continue
            }

            paragraphLines.append(trimmed)
        }

        flushParagraph()
        flushCode()
        return blocks
    }

    private static func headingBlock(_ line: String) -> (kind: Kind, text: String)? {
        var level = 0
        for character in line {
            if character == "#" { level += 1 } else { break }
        }
        guard (1...6).contains(level) else { return nil }

        let rest = line.dropFirst(level)
        guard rest.first == " " else { return nil }

        let text = rest.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return (.heading(level: level), text)
    }

    private static func bulletBlock(_ line: String) -> (kind: Kind, text: String)? {
        let indent = line.prefix { $0 == " " }.count / 2
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        for marker in ["- ", "* ", "+ "] where trimmed.hasPrefix(marker) {
            let text = String(trimmed.dropFirst(marker.count))
            guard !text.isEmpty else { return nil }
            return (.bullet(indent: indent), text)
        }
        return nil
    }

    private static func orderedBlock(_ line: String) -> (kind: Kind, text: String)? {
        let digits = line.prefix { $0.isNumber }
        guard !digits.isEmpty else { return nil }
        let rest = line.dropFirst(digits.count)
        guard rest.hasPrefix(". ") else { return nil }

        let text = String(rest.dropFirst(2))
        guard !text.isEmpty else { return nil }
        return (.ordered(marker: String(digits)), text)
    }
}
