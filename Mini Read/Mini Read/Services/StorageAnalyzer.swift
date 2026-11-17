//
//  StorageAnalyzer.swift
//  TheNewVellium
//
//  存储占用的唯一计算入口：分类统计、按书统计、孤儿文件检测、设备容量。
//
//  设计取舍：
//  - 纯 Foundation，不引入 SwiftUI / SwiftData。分析与呈现解耦，
//    将来接单元测试或命令行校验都不必拉起视图栈。
//  - 全部是同步 I/O，由调用方决定并发上下文（本 App 统一
//    `Task.detached(priority: .utility)`）。这里不再自己包 async，
//    避免多一次无意义的线程跳跃。
//  - 统计口径用 `totalFileAllocatedSize`（磁盘实际块占用）而非
//    `fileSize`（逻辑字节数）：用户关心的是"占了设备多少空间"，
//    块对齐后的数字才是系统设置里能对上的那个值。
//  - 扫描结果一次性快照，不做增量：书库规模是千本量级，
//    单次全量扫描在后台线程上是百毫秒级，增量缓存带来的复杂度不划算。
//

import Foundation

// MARK: - 路径中枢

/// App 内所有可统计 / 可清理目录的唯一定义处。
///
/// 分页缓存目录与导入字体目录原本各自硬编码一份字面量，
/// 清理逻辑一旦加进来就必须与存储端保持一致，否则会出现
/// "统计看到 A 目录、清理删了 B 目录"。这里收口，`PaginationCache`
/// 与 `ImportedFontStore` 都改为引用它。
enum StoragePath {

    static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static var caches: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    }

    static var applicationSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    /// EPUB 原件备份：Documents/EpubReader/epubBackup
    /// （相对路径常量见 `AppDirectory.backup`）
    static var backupRoot: URL {
        documents.appendingPathComponent(AppDirectory.backup, isDirectory: true)
    }

    /// EPUB 解压内容：Documents/EpubReader/epubExtr
    /// （相对路径常量见 `AppDirectory.extracted`）
    static var extractedRoot: URL {
        documents.appendingPathComponent(AppDirectory.extracted, isDirectory: true)
    }

    /// 分页缓存：Library/Caches/PaginationCache
    static var paginationCache: URL {
        caches.appendingPathComponent("PaginationCache", isDirectory: true)
    }

    /// 用户导入字体：Library/Application Support/ImportedFonts
    static var importedFonts: URL {
        applicationSupport.appendingPathComponent("ImportedFonts", isDirectory: true)
    }

    /// 设置配置文件：Library/Application Support/SettingsProfiles
    ///
    /// 每个配置文件一个 JSON 文件（`SettingsProfileStore` 读写）。
    /// 属**用户数据**而非缓存：刻意不参与存储统计与自动清理
    /// （见 `StorageAnalyzer` / `StorageCleaner` 的口径），收进这里只为路径收口。
    static var settingsProfiles: URL {
        applicationSupport.appendingPathComponent("SettingsProfiles", isDirectory: true)
    }
}

// MARK: - 分类

/// 存储占用分类。顺序即 UI 展示顺序（CaseIterable 保证）。
enum StorageCategory: String, CaseIterable, Identifiable, Sendable {
    /// EPUB 原件（导入时复制进来的 .epub）
    case books
    /// 解压后的正文与内嵌资源（阅读必需，删了书就读不了）
    case extracted
    /// 分页缓存（可安全重建，下次翻页会重新计算）
    case cache
    /// 用户导入的字体
    case fonts
    /// 个人化资产：App 背景图历史 + 头像
    case media
    /// SwiftData 持久化文件（书籍元数据、进度、设置）
    case database

    var id: String { rawValue }
}

// MARK: - 数据模型

/// 参与统计的一本书的最小描述。
///
/// 刻意与 SwiftData 的 `bookItem` 解耦：`bookItem` 不是 Sendable，
/// 无法跨线程传给扫描任务；视图层在主线程把模型映射成本结构再传入。
struct BookStorageSource: Sendable {
    /// 稳定主键，取解压目录路径——与 `bookItem.bookExtrSubdir` 一一对应。
    let key: String
    let title: String
    let author: String
    let backupURL: URL
    let extractedURL: URL

    init(key: String, title: String, author: String, backupURL: URL, extractedURL: URL) {
        self.key = key
        self.title = title
        self.author = author
        self.backupURL = backupURL
        self.extractedURL = extractedURL
    }
}

struct BookStorageUsage: Identifiable, Sendable {
    var id: String { source.key }
    let source: BookStorageSource
    let backupBytes: Int64
    let extractedBytes: Int64

    var totalBytes: Int64 { backupBytes + extractedBytes }
}

/// 磁盘上存在、但书库里已无对应记录的残留目录 / 文件。
struct OrphanItem: Identifiable, Sendable {
    var id: String { url.path }
    let url: URL
    let bytes: Int64
}

/// 设备容量快照。取不到时（极少数越狱 / 异常卷）返回 nil，UI 自行降级。
struct DeviceCapacity: Sendable {
    let totalBytes: Int64
    let availableBytes: Int64
}

/// 一次完整扫描的结果快照。
struct StorageReport: Sendable {
    /// 分类 → 占用字节。缺失的 key 视为 0。
    let categoryBytes: [StorageCategory: Int64]
    /// 按占用降序的书籍明细。
    let books: [BookStorageUsage]
    /// 孤儿文件。
    let orphans: [OrphanItem]
    /// 设备容量，可能为 nil。
    let device: DeviceCapacity?

    func bytes(for category: StorageCategory) -> Int64 {
        categoryBytes[category] ?? 0
    }

    /// App 自身占用（不含设备上其它 App）。
    var appBytes: Int64 {
        categoryBytes.values.reduce(0, +)
    }

    var orphanBytes: Int64 {
        orphans.reduce(0) { $0 + $1.bytes }
    }
}

// MARK: - 分析器

enum StorageAnalyzer {

    /// 全量扫描。同步执行，请勿在主线程调用。
    static func analyze(books: [BookStorageSource]) -> StorageReport {
        var categoryBytes: [StorageCategory: Int64] = [:]

        // ── 书籍：原件 + 解压内容 ─────────────────────────────
        var backupTotal: Int64 = 0
        var extractedTotal: Int64 = 0
        var usages: [BookStorageUsage] = []

        for book in books {
            let backup = allocatedSize(of: book.backupURL)
            let extracted = directorySize(book.extractedURL)
            backupTotal += backup
            extractedTotal += extracted
            usages.append(
                BookStorageUsage(
                    source: book,
                    backupBytes: backup,
                    extractedBytes: extracted
                )
            )
        }

        usages.sort { $0.totalBytes > $1.totalBytes }
        categoryBytes[.books] = backupTotal
        categoryBytes[.extracted] = extractedTotal

        // ── 可重建资产 ───────────────────────────────────────
        categoryBytes[.cache] = directorySize(StoragePath.paginationCache)
        categoryBytes[.fonts] = directorySize(StoragePath.importedFonts)

        // ── 个人化资产：背景图历史（UserDefaults 记录）+ 头像 ──
        var media: Int64 = 0
        let bgFilenames = (UserDefaults.standard.array(forKey: "bgImageHistory") as? [String]) ?? []
        for name in bgFilenames {
            media += allocatedSize(of: StoragePath.documents.appendingPathComponent(name))
        }
        if UserDefaults.standard.bool(forKey: "hasCustomAvatar") {
            media += allocatedSize(of: StoragePath.documents.appendingPathComponent("avatar.jpg"))
        }
        categoryBytes[.media] = media

        // ── SwiftData 持久化文件 ─────────────────────────────
        categoryBytes[.database] = databaseSize()

        return StorageReport(
            categoryBytes: categoryBytes,
            books: usages,
            orphans: detectOrphans(knownBooks: books),
            device: deviceCapacity()
        )
    }

    // MARK: 体积计算

    /// 单个文件的磁盘占用。目录、符号链接、已删除的文件一律返回 0。
    static func allocatedSize(of url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey])
        guard values?.isRegularFile == true else { return 0 }
        return Int64(values?.totalFileAllocatedSize ?? 0)
    }

    /// 递归统计目录占用。路径不存在或不是目录时回退到单文件口径。
    static func directorySize(_ url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
        guard values?.isDirectory == true else { return allocatedSize(of: url) }

        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return allocatedSize(of: url) }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let rv = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey])
            guard rv?.isRegularFile == true else { continue }
            total += Int64(rv?.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    /// SwiftData 默认落盘在 Application Support，主文件 default.store
    /// 外加 -wal / -shm 两个附属文件，一并计入。
    private static func databaseSize() -> Int64 {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: StoragePath.applicationSupport,
            includingPropertiesForKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return contents
            .filter { $0.lastPathComponent.hasPrefix("default.store") }
            .reduce(0) { $0 + allocatedSize(of: $1) }
    }

    // MARK: 设备容量

    static func deviceCapacity() -> DeviceCapacity? {
        let values = try? StoragePath.documents.resourceValues(forKeys: [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey
        ])
        guard let total = values?.volumeTotalCapacity,
              let available = values?.volumeAvailableCapacityForImportantUsage,
              total > 0
        else { return nil }

        return DeviceCapacity(totalBytes: Int64(total), availableBytes: available)
    }

    // MARK: 孤儿检测

    /// 找出磁盘上有、书库里没有的残留。
    ///
    /// 典型来源：删除书籍时进程被杀、早前版本删书只删了 SwiftData 记录、
    /// 导入解压成功但写库失败。这些不会被任何 UI 引用，也永远不会自愈。
    static func detectOrphans(knownBooks: [BookStorageSource]) -> [OrphanItem] {
        let knownExtracted = Set(knownBooks.map { normalizedPath($0.extractedURL) })
        let knownBackup = Set(knownBooks.map { normalizedPath($0.backupURL) })

        var items: [OrphanItem] = []

        items.append(contentsOf: children(of: StoragePath.extractedRoot, excluding: knownExtracted))
        items.append(contentsOf: children(of: StoragePath.backupRoot, excluding: knownBackup))

        return items.sorted { $0.bytes > $1.bytes }
    }

    /// 列出目录下所有直接子项，剔除存在于 `known` 中的路径。
    private static func children(of root: URL, excluding known: Set<String>) -> [OrphanItem] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return contents.compactMap { url in
            let path = normalizedPath(url)
            guard !known.contains(path) else { return nil }
            return OrphanItem(url: url, bytes: directorySize(url))
        }
    }

    /// 统一路径口径再比较。
    ///
    /// `bookItem` 存的是导入时拼出来的 URL，enumerator 出来的是磁盘实际路径，
    /// 两者可能差一个 `/private` 前缀或尾部斜杠；不归一化会误判成孤儿，
    /// 而误判的后果是删掉用户正在读的书——必须宁可漏、不可错。
    private static func normalizedPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}

// MARK: - 格式化

extension Int64 {

    /// 面向用户的体积文案。统一走这里，保证各处口径与位数一致。
    ///
    /// 用 `.file` 计数风格（1000 进制）而不是 `.memory`（1024 进制），
    /// 与 iOS 设置 / Finder 显示的数字对得上。
    var storageFormatted: String {
        ByteCountFormatter.string(fromByteCount: self, countStyle: .file)
    }
}
