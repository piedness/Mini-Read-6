//
//  AnnotationListView.swift
//  TheNewVellium
//
//  目录面板「笔记」页签的行与空状态。
//
//  信息分工与书签行一致：章节标题回答"在哪一章"，原文回答"是哪一段"，
//  笔记摘要回答"我当时想了什么"。不显示页码——页码随字号变化，
//  写死在列表里就是一个会悄悄变错的值。
//

import SwiftUI

// MARK: - 行

struct AnnotationRow: View {

    let annotation: ReaderAnnotation
    @ObservedObject var viewModel: ContentsPanelViewModel
    var onSelected: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(color.color)
                .frame(width: 3, height: 38)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 5) {
                Text(quoteText)
                    .font(.system(size: 14, weight: .regular, design: .serif))
                    .foregroundColor(.primary.opacity(0.9))
                    .lineSpacing(3)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                if annotation.hasNote {
                    HStack(alignment: .top, spacing: 5) {
                        Image(systemName: "text.bubble")
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.top, 2)

                        Text(annotation.note)
                            .font(.system(size: 12, weight: .regular))
                            .lineSpacing(2)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundColor(.secondary)
                }

                Text(chapterTitleText)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundColor(.secondary.opacity(0.75))
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            if annotation.hasNote {
                Image(systemName: annotation.style.systemImage)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary.opacity(0.45))
                    .padding(.top, 3)
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
        .contentShape(Rectangle())
        .onTapGesture {
            triggerHaptic(.light)
            viewModel.jumpToAnnotation(annotation)
            onSelected?()
        }
        .contextMenu {
            Button(role: .destructive) {
                viewModel.removeAnnotation(id: annotation.annotationID)
            } label: {
                Label("删除标注", systemImage: "trash")
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(annotation.hasNote ? annotation.note : "")
        .accessibilityHint("跳转到这一处")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: Text("删除标注")) {
            viewModel.removeAnnotation(id: annotation.annotationID)
        }
    }

    private var color: AnnotationColor {
        AnnotationColor(rawValue: annotation.colorRaw) ?? .yellow
    }

    private var quoteText: String {
        let trimmed = annotation.quote.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "（原文已变化）" : trimmed
    }

    private var chapterTitleText: String {
        let trimmed = annotation.chapterTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "未命名章节" : trimmed
    }

    private var accessibilityLabel: String {
        let prefix = annotation.hasNote ? "笔记" : annotation.style.displayName
        return "\(prefix)：\(quoteText)。\(chapterTitleText)"
    }
}

// MARK: - 空状态

struct TOCAnnotationsEmptyView: View {

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "highlighter")
                .font(.system(size: 30, weight: .light))
                .foregroundColor(.secondary.opacity(0.45))

            Text("还没有笔记")
                .font(.system(size: 15, weight: .semibold, design: .serif))
                .foregroundColor(.primary.opacity(0.85))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 40)
        .accessibilityElement(children: .combine)
    }
}
