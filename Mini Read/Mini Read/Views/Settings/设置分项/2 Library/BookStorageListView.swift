//
//  BookStorageListView.swift
//  TheNewVellium
//
//  「存储管理 → 按书籍查看」：按占用降序列出每本书，可就地删除释放空间。
//
//  设计取舍：
//  - 占用数据由上一级扫描好传进来，本页不重复扫描。
//    全量扫描是百毫秒级的磁盘 I/O，进来一次扫一次、返回再扫一次，
//    用户只会感到卡顿，得不到任何额外信息。
//  - 删除走 `StorageCleaner.purgeBookDirectories` + `modelContext.delete`，
//    与书架删除（`BookCard.performDelete`）同一套口径：
//    先动 SwiftData，再在动画事务之外删磁盘（同步 I/O 会卡掉首帧）。
//  - 删除是不可撤销的（连阅读进度一起没了），必须二次确认，
//    而且确认文案里要把"进度也会丢"说清楚——只说"删除书籍"是不够的。
//

import SwiftUI
import SwiftData

struct BookStorageListView: View {

    /// 上一级扫描结果（已按占用降序）的本地副本。
    ///
    /// 用 @State 而不是 let 持有，是为了删除后这一行能立刻消失。
    /// 上一级持有的快照不会随之变动——它要等 `books.count` 变化才重扫，
    /// 期间列表必须自己保持一致，否则会出现"删了但还占着位置"。
    @State private var items: [BookStorageUsage]

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @Query(sort: [SortDescriptor(\bookItem.dateAdded, order: .reverse)])
    private var books: [bookItem]

    @State private var pendingDeletion: BookStorageUsage?
    @State private var isConfirmingDeletion = false

    init(usages: [BookStorageUsage]) {
        _items = State(initialValue: usages)
    }

    var body: some View {
        Group {
            if items.isEmpty {
                ContentUnavailableView(
                    "暂无书籍占用数据",
                    systemImage: "internaldrive",
                    description: Text("导入书籍后即可在这里查看每本书占用的空间。")
                )
            } else {
                List {
                    Section {
                        ForEach(items) { usage in
                            BookUsageRow(
                                usage: usage,
                                fraction: fraction(of: usage)
                            )
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    pendingDeletion = usage
                                    isConfirmingDeletion = true
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                        }
                    } header: {
                        Text("共 \(items.count) 本 · \(totalBytes.storageFormatted)")
                    } footer: {
                        Text("「原书」是导入时保留的 EPUB 原件，「内容」是解压后的正文与插图。删除会同时移除这本书的阅读进度。")
                    }
                }
            }
        }
        .modifier(CustomListModifier(title: "书籍占用"))
        .alert("删除书籍？", isPresented: $isConfirmingDeletion) {
            Button("取消", role: .cancel) { pendingDeletion = nil }
            Button("删除", role: .destructive) {
                if let usage = pendingDeletion { delete(usage) }
                pendingDeletion = nil
            }
        } message: {
            Text(confirmationMessage)
        }
    }

    // MARK: - 派生值

    private var totalBytes: Int64 {
        items.reduce(0) { $0 + $1.totalBytes }
    }

    private func fraction(of usage: BookStorageUsage) -> Double {
        guard totalBytes > 0 else { return 0 }
        return Double(usage.totalBytes) / Double(totalBytes)
    }

    private var confirmationMessage: String {
        guard let usage = pendingDeletion else { return "" }
        return "「\(usage.source.title)」及其 \(usage.totalBytes.storageFormatted) 文件将被删除，该书的阅读进度也会一并移除。此操作无法撤销。"
    }

    // MARK: - 删除

    /// 删除一本书：SwiftData 记录 + 磁盘目录。
    ///
    /// 顺序与 `BookCard.performDelete` 保持一致——先把模型删掉让 UI 立刻响应，
    /// 磁盘 I/O 放在动画事务之外，避免同步删除大目录拖垮过渡动画的首帧。
    private func delete(_ usage: BookStorageUsage) {
        guard let book = books.first(where: { $0.bookExtrSubdir.path == usage.source.key }) else {
            // 记录已经不在了（例如刚在书架删掉），只清理磁盘残留。
            withAnimation { items.removeAll { $0.id == usage.id } }
            StorageCleaner.purgeBookDirectories(usage.source)
            if items.isEmpty { dismiss() }
            return
        }

        withAnimation {
            items.removeAll { $0.id == usage.id }
            modelContext.delete(book)
        }
        try? modelContext.save()

        StorageCleaner.purgeBookDirectories(usage.source)

        if items.isEmpty { dismiss() }
    }
}

// MARK: - 单行

private struct BookUsageRow: View {
    let usage: BookStorageUsage
    let fraction: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(usage.source.title)
                    .font(.body)
                    .lineLimit(2)

                Spacer(minLength: 12)

                Text(usage.totalBytes.storageFormatted)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.secondary.opacity(0.15))
                    Capsule()
                        .fill(.blue)
                        .frame(width: max(2, CGFloat(fraction) * proxy.size.width))
                }
            }
            .frame(height: 4)
            .accessibilityHidden(true)

            HStack(spacing: 10) {
                if !usage.source.author.isEmpty {
                    Text(usage.source.author)
                }
                Text("原书 \(usage.backupBytes.storageFormatted) · 内容 \(usage.extractedBytes.storageFormatted)")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(usage.source.title)
        .accessibilityValue("占用 \(usage.totalBytes.storageFormatted)，作者 \(usage.source.author)")
        .accessibilityHint("向左滑动可删除这本书及其文件")
    }
}

// MARK: - 预览

#Preview {
    NavigationStack {
        BookStorageListView(usages: [])
    }
    .modelContainer(for: [bookItem.self, ReadingProgressRecord.self, Bookmark.self], inMemory: true)
}
