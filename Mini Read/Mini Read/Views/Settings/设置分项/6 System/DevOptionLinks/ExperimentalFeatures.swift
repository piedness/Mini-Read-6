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

    /// 书籍数据总占用（解压 + 备份 + 分页缓存），进入页面时后台算一次。
    @State private var bookDataBytes: Int64 = 0

    /// 挂在书外、按 `bookKey` 关联的派生记录条数（页级进度 + 阅读时长）。
    ///
    /// 原先这里是两个全表 `@Query`。`PageProgress` 是"每书每章一行"，
    /// 千本书就是十万级对象，只为了判空和全删，却会在本页存活期间一直驻留内存。
    /// 现在判空用 `fetchCount`（SQL COUNT，不物化对象），删除在操作内部重新 fetch。
    @State private var derivedRecordCount = 0

    @State private var isMeasuring = true
    @State private var isPurging = false
    @State private var isConfirmingPurge = false
    @State private var resultMessage: String?

    /// 测量代次。清除开始时递增，用来作废在途的旧测量结果。
    @State private var measureID = 0

    var body: some View {
        List {
            Section {
                FunctionTestView()
            } header: {
                Text("解析调试")
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
                // 刻意不用 `isMeasuring` 挡按钮。
                //
                // 体积扫描只是给确认框一个数字，让一次可能要跑几秒的全盘统计决定
                // "能不能删"是本末倒置——书库越大扫得越久，按钮就一直灰着，看起来像坏了。
                // 真正的前置条件只有"确实有东西可删"（`hasBookData`）；
                // 空库只剩残留的场景，会在扫描结束后自行解锁。
                .disabled(isPurging || !hasBookData)

                if let resultMessage {
                    Text(resultMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("危险操作")
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
        let size = isMeasuring ? "体积统计中" : "释放约 \(bookDataBytes.storageFormatted)"
        return "将清除 \(target)，\(size)。阅读进度、阅读时长与排版缓存会一并清空；导入的字体、App 背景图与设置保留。此操作无法撤销。"
    }

    /// 清除对象不只有书库记录：上次部分清理失败留下的文件、缓存和
    /// 孤儿阅读记录，也必须允许用户从这个入口继续清完。
    ///
    /// 判定必须与清理口径一致：
    /// - 书籍 / 派生记录走库里的真实条数（`@Query` + `fetchCount`）；
    /// - 磁盘占用走 `bookDataBytes()`，它**不跳过隐藏文件**——清理是整目录删除，
    ///   隐藏文件也会被带走；统计若跳过它们，就会出现"只剩隐藏文件 → 统计为 0
    ///   → 按钮永久变灰"的死角。
    private var hasBookData: Bool {
        !books.isEmpty || derivedRecordCount > 0 || bookDataBytes > 0
    }

    // MARK: - 统计

    @MainActor
    private func measure() async {
        measureID &+= 1
        let id = measureID
        isMeasuring = true
        // 只有"最新那次"测量有权收尾：否则一轮旧测量会把新一轮的
        // `isMeasuring` 提前按掉，按钮在数字还没到位时就被解锁。
        defer { if id == measureID { isMeasuring = false } }

        let bytes = await Task.detached(priority: .utility) {
            StorageCleaner.bookDataBytes()
        }.value

        // 期间若已开始清除（或又发起了新一轮测量），这次结果就是过期的：
        // 它会把清除后的 0 覆盖回清除前的大数字。
        guard id == measureID else { return }

        bookDataBytes = bytes
        derivedRecordCount = derivedRecordCountNow()
    }

    /// 派生记录的条数。COUNT 走 SQL，不把十万级对象读进内存。
    private func derivedRecordCountNow() -> Int {
        let pages = (try? modelContext.fetchCount(FetchDescriptor<PageProgress>())) ?? 0
        let sessions = (try? modelContext.fetchCount(FetchDescriptor<ReadingSession>())) ?? 0
        return pages + sessions
    }

    // MARK: - 清除

    /// 一键清除的执行体。顺序是刻意的：
    /// 1. 先成功保存 SwiftData 删除；保存失败则回滚，绝不能继续删磁盘；
    /// 2. 主线程只清内存缓存，磁盘统一由一条后台任务删除并复测；
    /// 3. 根据实际剩余占用展示结果，部分失败时保留入口供用户重试。
    @MainActor
    private func purgeAllBookData() async {
        // 进程级互斥，不能只看视图状态：本页被返回手势 pop 掉之后 `@State` 就没了，
        // 而那条 `Task` 还在跑；再进来会拿到 `isPurging == false` 的新实例，
        // 用户能再点一次，两条清盘任务并发，复测出来的数字互相覆盖。
        guard !PurgeGate.isRunning else {
            resultMessage = "正在清除，请稍候。"
            return
        }
        guard hasBookData else {
            resultMessage = "没有需要清除的书籍数据。"
            return
        }

        PurgeGate.isRunning = true
        isPurging = true
        resultMessage = nil
        // 作废在途的体积测量：它稍后返回时会把清盘后的 0 覆盖成清除前的旧数字。
        measureID &+= 1
        defer {
            isPurging = false
            isMeasuring = false
            PurgeGate.isRunning = false
        }

        // 批量删除放在**独立上下文**里做，而不是 mainContext。
        //
        // `modelContext.delete()` 会立刻把对象标记为已删除，但 SwiftUI 的 `@Query`
        // 要到下一次刷新才会把它们移出结果集。这个窗口里只要还有一个活着的视图
        // 重新求值并读了某本书的属性（书架卡片、书单封面、统计卡都会），
        // SwiftData 就以 "model instance was invalidated" 直接终止进程。
        // 删一本书时窗口只有一帧，**一次删光整个书库时整个首页都站在窗口里**——
        // 这正是「点全部清除就闪退」的成因。
        //
        // 换到独立上下文后，主上下文里的对象一直有效，直到后台 save 触发合并
        // （与 `@Query` 刷新同一时刻）才一起失效；顺带把主线程从批量删除里解放出来。
        var deletedCount = 0
        do {
            let container = modelContext.container
            deletedCount = try await Task.detached(priority: .userInitiated) { () -> Int in
                let context = ModelContext(container)
                // 用上下文内部的 fresh fetch，而不是视图里的 `@Query` 快照：
                // 快照可能滞后（别的入口刚删过书），也可能漏掉快照之后新插入的行
                // ——那会删掉文件却留下记录。
                let allBooks = try context.fetch(FetchDescriptor<bookItem>())
                let count = allBooks.count
                allBooks.forEach { context.delete($0) }
                try Self.deleteDerivedRecords(in: context)
                try context.save()
                return count
            }.value
        } catch {
            // 独立上下文失败时主上下文压根没被改动过，不需要 rollback，
            // 也不会波及别处未提交的改动。
            resultMessage = "清除失败，书库数据未更改。请重试。"
            print("❌ [ExperimentalFeatures] 批量删除失败：\(error)")
            await measure()
            return
        }

        PaginationCache.shared.invalidateMemory()

        let outcome = await Task.detached(priority: .utility) {
            StorageCleaner.purgeAllBookDataOnDisk()
        }.value

        bookDataBytes = outcome.remaining
        derivedRecordCount = 0

        if outcome.remaining == 0 {
            triggerNotificationHaptic(.success)
            resultMessage = deletedCount > 0
                ? "已删除 \(deletedCount) 本书及相关数据，释放 \(outcome.freed.storageFormatted)。"
                : "已清除残留书籍数据，释放 \(outcome.freed.storageFormatted)。"
        } else {
            triggerNotificationHaptic(.error)
            resultMessage = "书籍记录已清除，但仍有 \(outcome.remaining.storageFormatted) 的文件或缓存未能删除。请重试。"
        }
    }

    /// 清掉挂在书上的派生记录。
    ///
    /// `ReadingProgressRecord` 与 `Bookmark` 由 `bookItem` 的 cascade 规则自动带走，
    /// 但 `PageProgress`（页级位置）和 `ReadingSession`（阅读时长）是用 `bookKey`
    /// 字符串关联的，没有级联关系，不手动删就会留下一批指向不存在书籍的孤儿记录
    /// ——阅读统计会凭空多出已删书的时长。
    ///
    /// 静态方法：它要能跑在批量删除所用的独立上下文上，不能绑死 mainContext。
    private static func deleteDerivedRecords(in context: ModelContext) throws {
        for progress in try context.fetch(FetchDescriptor<PageProgress>()) {
            context.delete(progress)
        }
        for session in try context.fetch(FetchDescriptor<ReadingSession>()) {
            context.delete(session)
        }
    }
}

// MARK: - 进程级互斥

/// 「清除所有书籍数据」的全局闸门。
///
/// 这个动作本来就是单例语义（清的是整库），互斥也应当在进程级而不是视图级：
/// 视图会被销毁重建，正在跑的清盘任务不会。
@MainActor
private enum PurgeGate {
    static var isRunning = false
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
