//
//  RemoteMarkdown.swift
//  Mini Read
//
//  把 `MarkdownBlock` 画出来。
//
//  行内语法（粗体、斜体、行内代码、链接）交给 `AttributedString(markdown:)`，
//  块级结构由 `MarkdownBlock` 负责——两边各做各擅长的事。
//

import SwiftUI

struct RemoteMarkdownView: View {
    private let blocks: [MarkdownBlock]

    init(_ markdown: String) {
        blocks = MarkdownBlock.parse(markdown)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(blocks) { block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block.kind {
        case .heading(let level):
            Text(inline(block.text))
                .font(level <= 2 ? .system(.headline, design: .serif) : .subheadline.weight(.semibold))
                .padding(.top, level <= 2 ? 8 : 4)
                .accessibilityAddTraits(.isHeader)

        case .paragraph:
            Text(inline(block.text))
                .font(.callout)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)

        case .bullet(let indent):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: "•")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(inline(block.text))
                    .font(.callout)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(indent) * 14)
            .accessibilityElement(children: .combine)

        case .ordered(let marker):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: "\(marker).")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(inline(block.text))
                    .font(.callout)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)

        case .quote:
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(.quaternary)
                    .frame(width: 3)
                    .accessibilityHidden(true)
                Text(inline(block.text))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .fixedSize(horizontal: false, vertical: true)

        case .code:
            Text(verbatim: block.text)
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(.tertiarySystemFill))
                )

        case .rule:
            Divider()
        }
    }

    /// 行内语法。解析失败就退化成纯文本，绝不吞字。
    private func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

#Preview {
    ScrollView {
        RemoteMarkdownView(
            """
            ## 新增
            - 支持 **跨页选区**，长按按整句选中
            - 修复 `Package.resolved` 读取失败的问题
            - 详情见 [发布页](https://github.com/piedness/Mini-Read-6/releases)

            > 本次更新需要 iOS 18.5 及以上。

            ```
            let version = "1.0.6"
            ```
            """
        )
        .padding()
    }
}
