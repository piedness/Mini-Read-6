//
//  AnnotationEditorView.swift
//  TheNewVellium
//
//  笔记编辑器：新建与编辑共用一份表单。
//
//  设计取向：
//  - 原文在上、输入在下——读者先确认"标的是哪一段"，再写想法；
//  - 颜色/样式就地可改，不需要退回菜单重选；
//  - 取消不写库，完成才提交；新建时自动聚焦键盘。
//

import SwiftUI

struct AnnotationEditorView: View {

    let draft: AnnotationDraft
    var onSave: (AnnotationDraft) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var note: String
    @State private var style: AnnotationStyle
    @State private var color: AnnotationColor
    @FocusState private var noteFocused: Bool

    init(
        draft: AnnotationDraft,
        onSave: @escaping (AnnotationDraft) -> Void
    ) {
        self.draft = draft
        self.onSave = onSave
        _note = State(initialValue: draft.note)
        _style = State(initialValue: draft.style)
        _color = State(initialValue: draft.color)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    quoteCard
                    noteEditor
                    colorSection
                    styleSection
                }
                .padding(.horizontal, 20)
                .padding(.top, 10)
                .padding(.bottom, 28)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle(draft.isNew ? "添加笔记" : "编辑标注")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { save() }
                        .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        // 有未保存的改动时不允许下滑关闭：笔记是读者手写的，误触丢内容
        // 比"必须点一下取消"更糟。取消/完成仍在导航栏里。
        .interactiveDismissDisabled(hasUnsavedChanges)
        .task {
            guard draft.autoFocus else { return }
            // 等 sheet 的上滑转场落定再聚焦，否则键盘会和转场抢同一段动画。
            try? await Task.sleep(for: .milliseconds(320))
            guard !Task.isCancelled else { return }
            noteFocused = true
        }
    }

    // MARK: - 原文

    private var quoteCard: some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(color.color)
                .frame(width: 3)

            VStack(alignment: .leading, spacing: 6) {
                Text(draft.quote)
                    .font(.system(size: 15, weight: .regular, design: .serif))
                    .foregroundColor(.primary.opacity(0.9))
                    .lineSpacing(4)
                    .lineLimit(6)
                    .fixedSize(horizontal: false, vertical: true)

                if !chapterTitleText.isEmpty {
                    Text(chapterTitleText)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("原文：\(draft.quote)")
    }

    private var chapterTitleText: String {
        draft.chapterTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 笔记输入

    private var noteEditor: some View {
        ZStack(alignment: .topLeading) {
            if note.isEmpty {
                Text("写下你的想法…")
                    .font(.system(size: 15))
                    .foregroundColor(.secondary.opacity(0.55))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 8)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }

            TextEditor(text: $note)
                .font(.system(size: 15))
                .lineSpacing(4)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 132)
                .focused($noteFocused)
                .accessibilityLabel("笔记内容")
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
        )
    }

    // MARK: - 颜色

    private var colorSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("颜色")

            HStack(spacing: 14) {
                ForEach(AnnotationColor.allCases) { item in
                    Button {
                        color = item
                        triggerHaptic(.light)
                    } label: {
                        Circle()
                            .fill(item.color)
                            .frame(width: 28, height: 28)
                            .overlay(
                                Circle()
                                    .strokeBorder(
                                        Color.primary.opacity(color == item ? 0.55 : 0),
                                        lineWidth: 2
                                    )
                                    .padding(-3)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(item.displayName)
                    .accessibilityAddTraits(color == item ? [.isButton, .isSelected] : .isButton)
                }

                Spacer(minLength: 0)
            }
        }
    }

    // MARK: - 样式

    private var styleSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("样式")

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(AnnotationStyle.allCases) { item in
                        Button {
                            style = item
                            triggerHaptic(.light)
                        } label: {
                            Label(item.displayName, systemImage: item.systemImage)
                                .font(.system(size: 12, weight: .medium))
                                .padding(.horizontal, 11)
                                .padding(.vertical, 7)
                                .foregroundColor(style == item ? .primary : .secondary)
                                .background(
                                    Capsule(style: .continuous)
                                        .fill(style == item ? Color.primary.opacity(0.10) : Color.clear)
                                )
                                .overlay(
                                    Capsule(style: .continuous)
                                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                                )
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(style == item ? [.isButton, .isSelected] : .isButton)
                    }
                }
                .padding(.vertical, 1)
            }
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(.secondary)
            .textCase(nil)
    }

    // MARK: - 提交

    private var hasUnsavedChanges: Bool {
        note != draft.note || style != draft.style || color != draft.color
    }

    private func save() {
        var updated = draft
        updated.note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.style = style
        updated.color = color
        onSave(updated)
        dismiss()
    }
}
