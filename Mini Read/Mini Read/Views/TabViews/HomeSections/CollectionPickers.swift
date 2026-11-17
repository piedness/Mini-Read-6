//
//  CollectionPickers.swift
//  TheNewVellium
//
//  书 → 书单的选择面板。
//
//  `BookCollectionsPicker` 由书库卡片的 Add to Collection… 使用。
//  书单详情页不再提供「加书」入口，因此原来反方向的
//  `CollectionBooksPicker` 已删除。
//
//  行高、勾选符号、按下反馈和 sheet 外观收在文件底部，
//  以后若再加别的选择面板可以直接复用。
//

import SwiftUI
import SwiftData

// MARK: - 给书挑书单

/// 一本书可以同时属于多个书单（"今年想读"和"科幻"不互斥），
/// 所以这里也是多选：每一行独立打勾，点一下即写入/移出。
struct BookCollectionsPicker: View {

    let book: bookItem

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Query(sort: \BookCollection.sortIndex) private var collections: [BookCollection]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 0) {
                    if collections.isEmpty {
                        CollectionPickerPlaceholder(
                            icon: "rectangle.stack",
                            title: "No Collections",
                            message: "Create a collection from the Home screen, then add books to it."
                        )
                    } else {
                        ForEach(collections) { collection in
                            row(collection)

                            if collection.persistentModelID != collections.last?.persistentModelID {
                                Divider()
                                    .opacity(0.16)
                                    .padding(.leading, 76)
                            }
                        }
                    }
                }
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
            .navigationTitle("Add to Collection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                        .tint(.primary)
                }
            }
        }
        .collectionPickerSheetChrome()
    }

    private func row(_ collection: BookCollection) -> some View {
        let isMember = collection.contains(book)

        return Button {
            toggle(collection)
        } label: {
            HStack(spacing: 12) {
                CollectionArtwork(
                    books: CollectionCover.books(for: collection),
                    side: 44,
                    cornerRadius: 8
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text(collection.name)
                        .font(.system(.subheadline, design: .serif, weight: .semibold))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .foregroundStyle(.primary)

                    Text(collection.summaryText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                CollectionPickerCheckmark(isOn: isMember)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(CollectionPickerRowButtonStyle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isMember ? .isSelected : [])
        .accessibilityHint(
            isMember
                ? "Removes this book from \(collection.name)"
                : "Adds this book to \(collection.name)"
        )
    }

    private func toggle(_ collection: BookCollection) {
        withAnimation(toggleAnimation) {
            collection.toggle(book)
        }
        try? modelContext.save()
        triggerHaptic(.light)
    }

    private var toggleAnimation: Animation {
        reduceMotion ? .easeOut(duration: 0.15)
                     : .spring(duration: 0.28, bounce: 0.12)
    }
}

// MARK: - 共用部件

/// 勾选符号：选中是实心圆 + 勾，未选中是空心圆。
/// 选择面板共用，避免一边用 .fill、一边用 .circle 的式样分叉。
private struct CollectionPickerCheckmark: View {

    let isOn: Bool

    var body: some View {
        Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 20))
            .foregroundStyle(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
            .contentTransition(.symbolEffect(.replace))
    }
}

private struct CollectionPickerPlaceholder: View {

    let icon: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.tertiary)

            Text(title)
                .font(.system(.headline, design: .serif, weight: .semibold))

            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
        .padding(.top, 64)
    }
}

/// 整行都是热区，按下反馈铺满行宽，不用圆角。
private struct CollectionPickerRowButtonStyle: ButtonStyle {

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Color.primary.opacity(configuration.isPressed ? 0.06 : 0))
    }
}

private extension View {

    /// 选择面板共用同一套 sheet 外观：半屏起步、28 圆角、材质背景。
    func collectionPickerSheetChrome() -> some View {
        self
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(28)
            .presentationBackground(.regularMaterial)
    }
}
