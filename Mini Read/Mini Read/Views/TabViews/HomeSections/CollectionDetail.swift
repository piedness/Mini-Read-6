//
//  CollectionDetail.swift
//  TheNewVellium
//
//  Created by piednes on 2026-10-25.
//

import SwiftUI
import SwiftData

// MARK: - 书单详情

/// 书单详情：这个书单里有什么书，点一本就读。
///
/// 轻量页头交代当前书单与数量，书籍行显示封面、书名、作者和进度。
/// 改名 / 删除 / 换封面走货架卡片的 contextMenu；添加成员走书库卡片，
/// 移除当前成员走书籍行尾菜单，不影响书库中的原书。
///
/// 点行从封面 zoom 进阅读器：`matchedTransitionSource` 挂在封面上，
/// `navigationTransition(.zoom)` 挂在阅读页，与书库卡片同一套转场语汇。
/// 两种呈现都有显式关闭按钮；FlipTransition 分支也可点卡片外遮罩关闭。
struct CollectionDetailView: View {

    let collection: BookCollection
    /// 翻面分支必须走自定义反向转场；Reduce Motion 全屏分支由环境 dismiss 关闭。
    var onClose: (() -> Void)? = nil

    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) private var dismiss

    @State private var readingBook: bookItem?

    /// FlipTransition 展开约 0.5 秒。静默窗比它略短一点，最后几帧的点击
    /// 仍由 `hasTransitionSettled` 兜住，不会穿透成「刚点书单就打开一本书」。
    @State private var hasTransitionSettled = false
    @State private var settleTask: Task<Void, Never>?

    @Namespace private var readerZoom

    private static let transitionSettleDelay: TimeInterval = 0.45

    /// 行封面。50×75 是标准 2:3 书衣开本；比旧行大一圈——封面是 zoom 转场的
    /// 源头，起点大一点，「从封面展开成阅读页」的空间感才出得来。
    private static let coverSize = CGSize(width: 50, height: 75)

    private var detailAnimation: Animation {
        reduceMotion ? .easeOut(duration: 0.12) : .easeOut(duration: 0.22)
    }

    // MARK: - Body

    var body: some View {
        let books = collection.displayBooks

        return VStack(spacing: 0) {
            header

            Divider()
                .opacity(0.16)
                .padding(.horizontal, 16)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if books.isEmpty {
                        emptyState
                    } else {
                        rows(books)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 4)
                .padding(.bottom, 14)
                // 成员变化由容器统一驱动；用身份数组而不是 count，保持与书架一致。
                .animation(detailAnimation, value: books.map(\.persistentModelID))
            }
            .scrollIndicators(.hidden)
        }
        // 全屏分支限制阅读宽度：iPad 上把 1000pt 宽的书单页拉成一行长标题很难读。
        .frame(maxWidth: 640, maxHeight: .infinity, alignment: .top)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear(perform: scheduleTransitionSettle)
        .onDisappear(perform: handleDisappear)
        .fullScreenCover(item: $readingBook) { book in
            BookContentView(book: book, modelContext: modelContext)
                // 与书库卡片同一套 zoom 语汇：从这一行的封面长到阅读页，
                // 而不是从屏幕底部推上来一个与上下文无关的阅读器。
                .navigationTransition(.zoom(sourceID: book.persistentModelID, in: readerZoom))
        }
    }

    // MARK: - 页头

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(collection.name)
                    .font(.title3)
                    .fontDesign(.serif)
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                Text(collection.summaryText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Color.primary.opacity(0.08)))
                    // 视觉圆形保持轻巧，实际命中区域扩到 HIG 建议的 44×44。
                    .padding(7)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close Collection")
            .accessibilityHint("Returns to your collections")
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    // MARK: - 行

    private func rows(_ books: [bookItem]) -> some View {
        ForEach(Array(books.enumerated()), id: \.element.persistentModelID) { index, book in
            VStack(spacing: 0) {
                row(book)

                if index < books.count - 1 {
                    Divider()
                        .opacity(0.5)
                        // 对齐书名左缘：容器/行内边距 + 封面宽度 + 封面与文字间距。
                        .padding(.leading, Self.coverSize.width + 28)
                }
            }
            .transition(.opacity.combined(with: .scale(scale: 0.85)))
        }
    }

    /// 一行书：封面 + 书名，整行可点。
    ///
    /// `matchedTransitionSource` 挂在**封面**上而不是行上：点行任意位置都能打开，
    /// 但 zoom 永远从封面出发——封面才是用户眼里「这本书的脸」。
    private func row(_ book: bookItem) -> some View {
        // 打开书籍与行尾菜单必须是兄弟控件：嵌套 Button/Menu 会争抢同一次点击。
        HStack(spacing: 4) {
            Button {
                open(book)
            } label: {
                HStack(spacing: 12) {
                    CoverThumbnailView(
                        url: book.coverImageURLs.first,
                        size: Self.coverSize,
                        cornerRadius: 5
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
                    }
                    .matchedTransitionSource(id: book.persistentModelID, in: readerZoom)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(book.bookTitle)
                            .font(.system(.subheadline, design: .serif, weight: .semibold))
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .foregroundStyle(.primary)

                        BookProgressAuthorRow(
                            progress: book.readingProgress,
                            author: book.bookAuthor
                        )
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(CollectionRowButtonStyle(reduceMotion: reduceMotion))
            .accessibilityHint("Opens this book")

            Menu {
                Button(role: .destructive) {
                    remove(book)
                } label: {
                    Label("Remove from Collection", systemImage: "minus.circle")
                }
                .accessibilityHint("Removes this book from the collection, not from your library")
            } label: {
                Image(systemName: "ellipsis")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .menuIndicator(.hidden)
            .accessibilityLabel("More actions for \(book.bookTitle)")
            .accessibilityHint("Shows collection actions")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        // 转场未落定前，书籍与菜单都不接点击，避免最后一帧误触。
        .allowsHitTesting(hasTransitionSettled)
    }

    // MARK: - 空态

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "books.vertical")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(.tertiary)
                .frame(width: 56, height: 56)
                .background(Circle().fill(Color.primary.opacity(0.05)))

            VStack(spacing: 3) {
                Text("No Books Yet")
                    .font(.system(.headline, design: .serif, weight: .semibold))

                Text("Use Add to Collection on any book to bring it here.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12)
        .padding(.vertical, 34)
    }

    // MARK: - 动作

    private func close() {
        if let onClose {
            onClose()
        } else {
            dismiss()
        }
    }

    private func open(_ book: bookItem) {
        guard hasTransitionSettled else { return }
        readingBook = book
    }

    private func remove(_ book: bookItem) {
        // 只解除当前书单关系，不删除 bookItem；列表动画由行容器的身份变化驱动。
        guard collection.contains(book) else { return }
        collection.remove(book)
        try? modelContext.save()
        triggerHaptic(.light)
    }

    // MARK: - 生命周期

    private func scheduleTransitionSettle() {
        settleTask?.cancel()
        hasTransitionSettled = false

        guard !reduceMotion else {
            hasTransitionSettled = true
            return
        }

        settleTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(Self.transitionSettleDelay))
            guard !Task.isCancelled else { return }
            hasTransitionSettled = true
        }
    }

    private func handleDisappear() {
        settleTask?.cancel()
        settleTask = nil
        hasTransitionSettled = false
    }
}

// MARK: - 按钮式样

/// 行：按下时铺一层极淡的底色并轻微内缩，像纸张被指尖压了一下。
private struct CollectionRowButtonStyle: ButtonStyle {

    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .animation(.spring(duration: 0.22, bounce: 0), value: configuration.isPressed)
    }
}
