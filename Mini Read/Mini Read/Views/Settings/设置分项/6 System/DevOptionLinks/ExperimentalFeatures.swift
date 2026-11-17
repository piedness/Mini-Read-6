//
//  ExperimentalFeatures.swift
//  TheNewVellium
//
//  「设置 → 性能优化 → 实验性功能」的落地页。
//
//  原先这里是一个内联 List 里孤零零挂一个 `FunctionTestView`，没有分组、
//  没有说明，加东西只能继续往下堆。抽成独立 View 之后，
//  解析调试与危险操作分属两个 Section，破坏性动作才有地方写清后果。
//
//  本页整体位于「调试」区域内：这里的按钮不做用户级产品化包装，
//  但**破坏性操作依然必须二次确认**——调试入口不等于免责声明。
//

import SwiftUI
import SwiftData

struct ExperimentalFeaturesView: View {

    @Environment(\.modelContext) private var modelContext

    @Query(sort: [SortDescriptor(\bookItem.dateAdded, order: .reverse)])
    private var books: [bookItem]

    // 这两类记录用 bookKey 关联，没有书籍级联删除。直接观察查询结果，
    // 既能让空书库下的孤儿记录也可清除，也不必在删除时吞掉 fetch 错误。
    @Query private var pageProgresses: [PageProgress]
    @Query private var readingSessions: [ReadingSession]

    /// 书籍数据总占用（解压 + 备份 + 分页缓存），进入页面时后台算一次。
    @State private var bookDataBytes: Int64 = 0
    @State private var isMeasuring = true

    @State private var isPurging = false
    @State private var isConfirmingPurge = false
    @State private var resultMessage: String?

    var body: some View {
        List {
            Section {
                FunctionTestView()
            } header: {
                Text("解析调试")
            } footer: {
                Text("按当前书库逐本重新解析 EPUB，用于验证 container / OPF / 目录的解析结果。")
            }

            Section {
                HStack {
                    Text("当前书库")
                    Spacer()
                    Text(statusText)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("当前书库")
                .accessibilityValue(statusText)

                Button(role: .destructive) {
                    isConfirmingPurge = true
                } label: {
                    HStack {
                        Text("清除所有书籍数据")
                        Spacer()
                        if isPurging { ProgressView() }
                    }
                }
                .disabled(isMeasuring || isPurging || !hasBookData)

                if let resultMessage {
                    Text(resultMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("危险操作")
            } footer: {
                Text("删除全部书籍及其文件、阅读进度、阅读时长与排版缓存。导入的字体、App 背景图、头像和设置不受影响。此操作无法撤销。")
            }
        }
        .modifier(CustomListModifier(title: "实验性功能"))
        .task { await measure() }
        .alert("清除所有书籍数据？", isPresented: $isConfirmingPurge) {
            Button("取消", role: .cancel) { }
            Button("全部清除", role: .destructive) { Task { await purgeAllBookData() } }
        } message: {
            Text(confirmationMessage)
        }
    }

    // MARK: - 文案

    private var statusText: String {
        guard !isMeasuring else { return "统计中…" }
        return "\(books.count) 本 · \(bookDataBytes.storageFormatted)"
    }

    /// 确认框要把后果说全：删了几本、多大、连带丢什么、不丢什么。
    /// 只写一句"确定删除吗"对这个量级的破坏是不够的。
    private var confirmationMessage: String {
        let target = books.isEmpty ? "残留书籍数据" : "\(books.count) 本书及其相关数据"
        return "将清除 \(target)，释放约 \(bookDataBytes.storageFormatted)。阅读进度、阅读时长与排版缓存会一并清空；导入的字体、App 背景图与设置保留。此操作无法撤销。"
    }

    /// 清除对象不只有书库记录：上次部分清理失败留下的文件、缓存和
    /// 孤儿阅读记录，也必须允许用户从这个入口继续清完。
    private var hasBookData: Bool {
        !books.isEmpty || bookDataBytes > 0 || !pageProgresses.isEmpty || !readingSessions.isEmpty
    }

    // MARK: - 统计

    @MainActor
    private func measure() async {
        isMeasuring = true
        bookDataBytes = await Task.detached(priority: .utility) {
            StorageCleaner.bookDataBytes()
        }.value
        isMeasuring = false
    }

    // MARK: - 清除

    /// 一键清除的执行体。顺序是刻意的：
    /// 1. 先成功保存 SwiftData 删除；保存失败则回滚，绝不能继续删磁盘；
    /// 2. 主线程只清内存缓存，磁盘统一由一条后台任务删除并复测；
    /// 3. 根据实际剩余占用展示结果，部分失败时保留入口供用户重试。
    @MainActor
    private func purgeAllBookData() async {
        guard !isMeasuring, !isPurging, hasBookData else { return }
        let count = books.count

        isPurging = true
        resultMessage = nil
        defer { isPurging = false }

        withAnimation {
            books.forEach { modelContext.delete($0) }
            deleteDerivedRecords()
        }

        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            resultMessage = "清除失败，书库数据未更改。请重试。"
            print("❌ [ExperimentalFeatures] 保存全量清除失败：\(error)")
            return
        }

        PaginationCache.shared.invalidateMemory()

        let outcome = await Task.detached(priority: .utility) { () -> (freed: Int64, remaining: Int64) in
            let freed = StorageCleaner.purgeAllBookDataOnDisk()
            return (freed, StorageCleaner.bookDataBytes())
        }.value

        bookDataBytes = outcome.remaining
        if outcome.remaining == 0 {
            resultMessage = count > 0
                ? "已删除 \(count) 本书及相关数据，释放 \(outcome.freed.storageFormatted)。"
                : "已清除残留书籍数据，释放 \(outcome.freed.storageFormatted)。"
        } else {
            resultMessage = "书籍记录已清除，但仍有 \(outcome.remaining.storageFormatted) 的文件或缓存未能删除。请重试。"
        }
    }

    /// 清掉挂在书上的派生记录。
    ///
    /// `ReadingProgressRecord` 由 `bookItem` 的 cascade 规则自动带走，
    /// 但 `PageProgress`（页级位置）和 `ReadingSession`（阅读时长）是
    /// 用 `bookKey` 字符串关联的，没有级联关系，不手动删就会留下一批
    /// 指向不存在书籍的孤儿记录——阅读统计会凭空多出已删书的时长。
    private func deleteDerivedRecords() {
        pageProgresses.forEach { modelContext.delete($0) }
        readingSessions.forEach { modelContext.delete($0) }
    }
}

// MARK: - 预览

#Preview {
    NavigationStack {
        ExperimentalFeaturesView()
    }
    .modelContainer(
        for: [bookItem.self, ReadingProgressRecord.self, PageProgress.self, ReadingSession.self, AppSettings.self, Bookmark.self],
        inMemory: true
    )
}
