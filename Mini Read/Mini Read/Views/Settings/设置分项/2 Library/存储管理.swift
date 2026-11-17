//
//  存储管理.swift
//  vellium1218
//
//  Created by Max Piednes on 2026/2/16.
//
//  重写说明（存储功能补全）：
//  原页面三处控件是空壳——"清除缓存"没有实现、缓存占用是写死的 "245MB"、
//  "清除设置历史记录"既没实现、语义也不对（多行 AppSettings 是历史脏数据，
//  不是"历史记录"）。
//
//  现在这一页回答三个问题，这也是 iOS「设置 → 通用 → 储存空间」的骨架：
//    1. 空间去哪了？   —— 设备容量条 + 六类占用明细 + 按书排行
//    2. 能释放多少？   —— 分页缓存、孤儿残留，各自给出实时体积
//    3. 谁来释放？     —— 手动按钮 + 「自动清理」开关真正生效
//
//  所有体积都来自 `StorageAnalyzer` 的真实扫描，页面里没有任何硬编码数字。
//  扫描是同步 I/O，统一丢到 `Task.detached(priority: .utility)`，
//  主线程只负责渲染，书库再大也不会卡住设置页。
//

import SwiftUI
import SwiftData

// MARK: - 分类展示元数据

/// 展示属性放在视图层，`StorageAnalyzer` 保持纯 Foundation。
extension StorageCategory {

    var displayName: String {
        switch self {
        case .books:     return "原书文件"
        case .extracted: return "书籍内容"
        case .cache:     return "分页缓存"
        case .fonts:     return "导入字体"
        case .media:     return "背景与头像"
        case .database:  return "阅读数据"
        }
    }

    var systemImage: String {
        switch self {
        case .books:     return "doc.zipper"
        case .extracted: return "book.closed"
        case .cache:     return "clock.arrow.circlepath"
        case .fonts:     return "textformat"
        case .media:     return "photo"
        case .database:  return "cylinder"
        }
    }

    var tint: Color {
        switch self {
        case .books:     return .blue
        case .extracted: return .indigo
        case .cache:     return .orange
        case .fonts:     return .purple
        case .media:     return .pink
        case .database:  return .teal
        }
    }

    /// 行下方的灰字说明，解释"这是什么、删了会怎样"。
    var caption: String {
        switch self {
        case .books:
            return "导入时保留的 EPUB 原件，删除书籍时会一并移除。"
        case .extracted:
            return "解压后的正文与插图，阅读必需，无法单独清理。"
        case .cache:
            return "排版结果缓存，用于秒开已读章节。删除后重新翻页会自动重建。"
        case .fonts:
            return "你导入的字体文件，可在「文字排版 → 字体」中管理。"
        case .media:
            return "App 背景图历史与个人头像。"
        case .database:
            return "书籍信息、阅读进度与设置所在的数据库文件。"
        }
    }
}

// MARK: - 主视图

// 存储管理
struct StorageSettingsView: View {
    @Bindable var settings: AppSettings

    @Environment(\.modelContext) private var modelContext
    @Query(sort: [SortDescriptor(\bookItem.dateAdded, order: .reverse)])
    private var books: [bookItem]
    @Query private var allSettings: [AppSettings]

    // ── 扫描 ────────────────────────────────────────────────
    @State private var report: StorageReport?
    @State private var isScanning = false

    // ── 破坏性操作的二次确认 ────────────────────────────────
    @State private var isConfirmingCachePurge = false
    @State private var isConfirmingOrphanPurge = false

    /// 清理结果的即时反馈；下一次扫描时清空，不长期占位。
    @State private var freedMessage: String?

    /// 自动清理只在本次进入页面时触发一次。
    /// 不设闸会变成「扫描 → 清理 → 重扫 → 又超限 → 再清理」的死循环。
    @State private var didAutoClean = false

    var body: some View {
        List {
            overviewSection
            breakdownSection
            booksSection
            cacheSection
            maintenanceSection
            storageLocationSection
            configurationSection

            if settings.developerMode {
                developerSection
            }
        }
        .modifier(CustomListModifier(title: "存储管理"))
        .refreshable { await scan() }
        .task { await scan() }
        // 书库增减会让已经算好的快照立刻过期：在「按书籍查看」里删掉一本书后
        // 返回本页，占用数字必须已经更新，而不是停在删除前的旧值。
        .onChange(of: books.count) { _, _ in
            freedMessage = nil
            Task { await scan() }
        }
        .onDisappear(perform: persistSettings)
        .alert("清除分页缓存？", isPresented: $isConfirmingCachePurge) {
            Button("取消", role: .cancel) { }
            Button("清除", role: .destructive) { Task { await purgeCache() } }
        } message: {
            Text("将删除 \(currentCacheBytes.storageFormatted) 排版缓存。下次打开这些章节时会重新计算，阅读进度与书籍不受影响。")
        }
        .alert("清理残留文件？", isPresented: $isConfirmingOrphanPurge) {
            Button("取消", role: .cancel) { }
            Button("清理", role: .destructive) { Task { await purgeOrphans() } }
        } message: {
            Text("这些文件在磁盘上存在，但书库里已没有对应书籍。删除后无法恢复，你的书籍与阅读进度不受影响。")
        }
    }

    // MARK: - 概览

    @ViewBuilder
    private var overviewSection: some View {
        Section {
            if let report {
                StorageCapacityBar(
                    appBytes: report.appBytes,
                    device: report.device
                )
                .listRowInsets(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
            } else {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("正在扫描存储占用…")
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("存储概览")
        } footer: {
            if let freedMessage {
                Text(freedMessage)
            }
        }
    }

    // MARK: - 分类明细

    @ViewBuilder
    private var breakdownSection: some View {
        Section {
            ForEach(StorageCategory.allCases) { category in
                StorageCategoryRow(
                    category: category,
                    bytes: report?.bytes(for: category),
                    fraction: fraction(of: category)
                )
            }
        } header: {
            Text("占用明细")
        } footer: {
            Text("统计的是磁盘实际占用，与系统设置中显示的本 App 体积一致。")
        }
    }

    // MARK: - 书籍

    @ViewBuilder
    private var booksSection: some View {
        Section {
            if isScanning && report == nil {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("正在统计 \(books.count) 本书…")
                        .foregroundStyle(.secondary)
                }
            } else {
                NavigationLink {
                    BookStorageListView(usages: report?.books ?? [])
                } label: {
                    HStack {
                        Text("按书籍查看")
                        Spacer()
                        Text((report?.books.reduce(0) { $0 + $1.totalBytes } ?? 0).storageFormatted)
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(report == nil)
            }
        } header: {
            Text("书籍")
        } footer: {
            Text("共 \(books.count) 本。在这里删除书籍会同时移除它的文件与阅读进度。")
        }
    }

    // MARK: - 缓存

    private var cacheSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("缓存大小上限")
                    Spacer()
                    Text("\(settings.cacheSizeLimit) MB")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(
                    value: Binding(
                        get: { Double(settings.cacheSizeLimit) },
                        set: { settings.cacheSizeLimit = Int($0) }
                    ),
                    in: 100...2000,
                    step: 100
                )
                .accessibilityLabel("缓存大小上限")
                .accessibilityValue("\(settings.cacheSizeLimit) 兆字节")
            }

            Stepper("预加载页数：\(settings.preloadPages)", value: $settings.preloadPages, in: 0...20)

            Picker("图片缓存质量", selection: $settings.imageCacheQuality) {
                Text("原图").tag("original")
                Text("高质量").tag("high")
                Text("标准").tag("standard")
                Text("低质量").tag("low")
            }

            Toggle("空间不足时自动清理", isOn: $settings.autoCleanCache)

            Button(role: .destructive) {
                isConfirmingCachePurge = true
            } label: {
                HStack {
                    Text("清除缓存")
                    Spacer()
                    Text(currentCacheBytes.storageFormatted)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .disabled(isScanning || currentCacheBytes == 0)
        } header: {
            Text("缓存设置")
        } footer: {
            cacheFooter
        }
    }

    @ViewBuilder
    private var cacheFooter: some View {
        if isOverCacheLimit {
            Text("当前缓存已超过设定的 \(settings.cacheSizeLimit) MB 上限。关闭「空间不足时自动清理」可保留缓存以加快翻页。")
        } else {
            Text("缓存用于加速已读章节的重新打开，不会保存你的阅读进度。调低上限会在空间紧张时更早触发清理。")
        }
    }

    // MARK: - 维护

    @ViewBuilder
    private var maintenanceSection: some View {
        Section {
            if let orphans = report?.orphans, !orphans.isEmpty {
                Button(role: .destructive) {
                    isConfirmingOrphanPurge = true
                } label: {
                    HStack {
                        Text("清理残留文件")
                        Spacer()
                        Text("\(orphans.count) 项 · \((report?.orphanBytes ?? 0).storageFormatted)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                .disabled(isScanning)
            } else {
                HStack {
                    Text("残留文件")
                    Spacer()
                    Text(isScanning ? "扫描中…" : "无")
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("维护")
        } footer: {
            Text("残留文件是磁盘上存在、但书库里已没有对应书籍的数据，通常来自导入中断或被强制退出的删除操作。")
        }
    }

    // MARK: - 配置数据

    private var configurationSection: some View {
        Section {
            InfoRow(title: "设置记录条数", value: "\(allSettings.count)")

            if allSettings.count > 1 {
                Button("修复重复记录") { repairSettingsRows() }
            }
        } header: {
            Text("配置数据")
        } footer: {
            Text(allSettings.count > 1
                 ? "检测到 \(allSettings.count) 条设置记录（正常应为 1 条）。这是早期版本留下的脏数据，修复后只保留你真正改动过的那一条。"
                 : "设置只有一份记录，占用可忽略不计。")
        }
    }

    // MARK: - 存储位置

    /// 告诉用户数据落在哪。
    ///
    /// 这一节原本只挂了一个面向开发者的目录浏览器，对普通用户没有任何信息量。
    /// 现在给出真实路径；调试入口收进「开发者模式」，避免误导用户去手动删文件。
    private var storageLocationSection: some View {
        Section {
            InfoRow(title: "书籍与资源", value: "Documents/EpubReader")
            InfoRow(title: "缓存", value: "Library/Caches")
            InfoRow(title: "字体与数据库", value: "Library/Application Support")
        } header: {
            Text("存储位置")
        } footer: {
            Text("数据保存在本机 App 沙盒内，会随设备备份一同备份；缓存目录不参与备份，系统空间紧张时也可能自行清空。")
        }
    }

    // MARK: - 开发者

    private var developerSection: some View {
        Section {
            AppDirectoryMonitorView()
        } header: {
            Text("目录浏览器")
        } footer: {
            Text("仅在「系统设置 → 开发者模式」开启时显示。")
        }
    }

    // MARK: - 派生值

    private var currentCacheBytes: Int64 {
        report?.bytes(for: .cache) ?? 0
    }

    private var isOverCacheLimit: Bool {
        currentCacheBytes > Int64(settings.cacheSizeLimit) * 1_000_000
    }

    /// 该分类占 App 总占用的比例，用于行内细条；无数据时按 0 处理。
    private func fraction(of category: StorageCategory) -> Double {
        guard let total = report?.appBytes, total > 0 else { return 0 }
        return Double(report?.bytes(for: category) ?? 0) / Double(total)
    }

    // MARK: - 扫描
    //
    // 下面几个方法都标了 @MainActor：它们要读 `@Query` 的 books、
    // 写 @State，且 `PaginationCache.shared.invalidateAll()` 动的是
    // 非线程安全的内存字典。磁盘 I/O 那一段已经单独丢进 detached task，
    // 主线程上只剩赋值与 UI 状态切换。

    @MainActor
    private func scan() async {
        // 清理完成后会立刻重扫，此时上一轮可能还在跑；并发扫描没有意义，
        // 只是让同一批目录被枚举两次。
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }

        // bookItem 不是 Sendable，先在主线程降维成可跨线程的值类型。
        let sources = books.map {
            BookStorageSource(
                key: $0.bookExtrSubdir.path,
                title: $0.bookTitle,
                author: $0.bookAuthor,
                backupURL: $0.bookBackupdir,
                extractedURL: $0.bookExtrSubdir
            )
        }

        let result = await Task.detached(priority: .utility) {
            StorageAnalyzer.analyze(books: sources)
        }.value

        report = result
        await autoCleanIfNeeded(report: result)
    }

    /// 「空间不足时自动清理」的实际执行点。
    ///
    /// 触发条件是两项取并集：缓存超过用户设定的上限，或设备可用空间不足 1 GB。
    /// 缓存是可重建资产，静默清理符合系统对 Caches 目录的约定，
    /// 不需要为它打断用户；但仍然要把结果写进 `freedMessage`，
    /// 否则用户只会看到数字自己变小，不知道发生了什么。
    @MainActor
    private func autoCleanIfNeeded(report: StorageReport) async {
        guard settings.autoCleanCache, !didAutoClean else { return }

        let cacheBytes = report.bytes(for: .cache)
        let deviceIsTight = (report.device?.availableBytes ?? .max) < 1_000_000_000
        guard cacheBytes > 0, cacheBytes > Int64(settings.cacheSizeLimit) * 1_000_000 || deviceIsTight else { return }

        didAutoClean = true
        let freed = await Task.detached(priority: .utility) {
            StorageCleaner.purgePaginationCache()
        }.value

        PaginationCache.shared.invalidateAll()

        freedMessage = "已自动清理缓存，释放 \(freed.storageFormatted)。"
        await rescan()
    }

    /// 在后台线程重新扫描并回填，不显示"扫描中"占位（数字只是原地更新）。
    @MainActor
    private func rescan() async {
        let sources = books.map {
            BookStorageSource(
                key: $0.bookExtrSubdir.path,
                title: $0.bookTitle,
                author: $0.bookAuthor,
                backupURL: $0.bookBackupdir,
                extractedURL: $0.bookExtrSubdir
            )
        }
        report = await Task.detached(priority: .utility) {
            StorageAnalyzer.analyze(books: sources)
        }.value
    }

    // MARK: - 清理动作

    @MainActor
    private func purgeCache() async {
        isScanning = true
        freedMessage = nil

        let freed = await Task.detached(priority: .utility) {
            StorageCleaner.purgePaginationCache()
        }.value
        PaginationCache.shared.invalidateAll()

        // 开关判断在 `triggerHaptic` 内部（见 `Utils/Haptics.swift`），此处不再重复。
        triggerHaptic(.medium)
        await rescan()
        isScanning = false

        freedMessage = freed > 0
            ? "已清除缓存，释放 \(freed.storageFormatted)。"
            : "缓存已经是空的。"
    }

    @MainActor
    private func purgeOrphans() async {
        guard let orphans = report?.orphans else { return }
        isScanning = true
        freedMessage = nil

        let freed = await Task.detached(priority: .utility) {
            StorageCleaner.purgeOrphans(orphans)
        }.value

        triggerHaptic(.medium)
        await rescan()
        isScanning = false

        freedMessage = freed > 0
            ? "已清理残留文件，释放 \(freed.storageFormatted)。"
            : "没有可清理的残留文件。"
    }

    // MARK: - 设置落盘

    /// 缓存相关偏好改完统一落盘一次。
    ///
    /// 拖动 Slider 时逐帧 save 毫无意义，这里在进入页面后离开时补一次即可；
    /// 清理动作本身不需要广播 `.appSettingsDidChange`——它只影响缓存策略，
    /// 不参与排版，广播会让阅读器做一次无谓的重排。
    private func persistSettings() {
        try? modelContext.save()
    }

    /// 收敛重复的设置记录。
    ///
    /// `appSettings()` 内部已经会自愈，这里只是给用户一个可以立刻看到结果的入口，
    /// 顺手补一次落盘保证下次冷启动读到的就是收敛后的状态。
    private func repairSettingsRows() {
        _ = modelContext.appSettings()
        try? modelContext.save()
        triggerHaptic(.medium)
    }
}

// MARK: - 容量条

/// 设备容量条：本 App 占用 / 系统与其他 / 可用。
///
/// 这一块的取舍是不显示分类堆叠——六个分类里有四个是个位数占比，
/// 切成六段只会得到一堆读不出信息的碎条。容量条要回答的是
/// "我还有多少空间"，分类明细交给下面的列表。
private struct StorageCapacityBar: View {
    let appBytes: Int64
    let device: DeviceCapacity?

    private var total: Int64 { device?.totalBytes ?? 0 }
    private var available: Int64 { device?.availableBytes ?? 0 }
    private var others: Int64 { max(0, total - appBytes - available) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(appBytes.storageFormatted)
                    .font(.title2.weight(.semibold))
                    .monospacedDigit()
                Text("本 App")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                if device != nil {
                    Text("可用 \(available.storageFormatted)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            if total > 0 {
                GeometryReader { proxy in
                    HStack(spacing: 2) {
                        segment(color: .blue, width: ratio(appBytes) * proxy.size.width)
                        segment(color: .secondary.opacity(0.35), width: ratio(others) * proxy.size.width)
                        segment(color: .green.opacity(0.7), width: ratio(available) * proxy.size.width)
                    }
                }
                .frame(height: 10)
                .clipShape(Capsule())

                legend
            }
        }
        // 三段色条对 VoiceOver 是没有意义的一串数字，整块折叠成一句可读的话。
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("存储占用")
        .accessibilityValue(accessibilitySummary)
    }

    private func segment(color: Color, width: CGFloat) -> some View {
        color.frame(width: max(0, width))
    }

    private func ratio(_ bytes: Int64) -> CGFloat {
        guard total > 0 else { return 0 }
        return CGFloat(Double(bytes) / Double(total))
    }

    private var legend: some View {
        HStack(spacing: 14) {
            legendItem(color: .blue, label: "本 App", bytes: appBytes)
            legendItem(color: .secondary.opacity(0.35), label: "系统与其他", bytes: others)
            legendItem(color: .green.opacity(0.7), label: "可用", bytes: available)
            Spacer(minLength: 0)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func legendItem(color: Color, label: String, bytes: Int64) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text("\(label) \(bytes.storageFormatted)")
                .monospacedDigit()
        }
    }

    private var accessibilitySummary: String {
        guard device != nil else {
            return "本 App 占用 \(appBytes.storageFormatted)"
        }
        return "本 App 占用 \(appBytes.storageFormatted)，系统与其他占用 \(others.storageFormatted)，可用 \(available.storageFormatted)"
    }
}

// MARK: - 分类行

private struct StorageCategoryRow: View {
    let category: StorageCategory
    /// nil 表示尚未扫描完成，显示占位而不是 0，避免"扫描中"被读成"真的没占空间"。
    let bytes: Int64?
    let fraction: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: category.systemImage)
                    .foregroundStyle(category.tint)
                    .frame(width: 22)
                    .accessibilityHidden(true)

                Text(category.displayName)

                Spacer()

                Text(bytes?.storageFormatted ?? "—")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            if let bytes, bytes > 0 {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.secondary.opacity(0.15))
                        Capsule()
                            .fill(category.tint)
                            .frame(width: max(2, CGFloat(fraction) * proxy.size.width))
                    }
                }
                .frame(height: 4)
                .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(category.displayName)
        .accessibilityValue("\(bytes?.storageFormatted ?? "正在统计")，\(category.caption)")
    }
}

// MARK: - 预览

#Preview {
    StorageSettingsView(settings: AppSettings())
        .modelContainer(for: [bookItem.self, AppSettings.self, ReadingProgressRecord.self, Bookmark.self], inMemory: true)
}
