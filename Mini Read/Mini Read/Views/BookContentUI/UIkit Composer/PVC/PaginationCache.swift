import UIKit
import CryptoKit

// MARK: - 稳定哈希（跨进程确定）

/// 缓存放大到磁盘上的键派生函数。
///
/// **为什么不能用 `hashValue`**：Swift 的 `Hasher` 每进程随机播种（SE-0206），
/// 同一个字符串/结构体在不同次启动会得到不同的 hashValue。磁盘缓存文件名一旦由
/// hashValue 拼成，每次冷启动都换名字——缓存写得出、永远读不回（P0-B）。
/// 这里用 SHA-256 做确定性摘要，跨进程、跨启动、跨设备一致。
///
/// 组件之间用 `\u{1F}`（unit separator）连接，避免「ab+c」与「a+bc」
/// 这类拼接歧义导致撞键。
enum StableHash {

    /// 对若干字符串组件求 SHA-256，返回 64 位十六进制串。
    static func hexDigest(_ components: [String]) -> String {
        let payload = components.joined(separator: "\u{1F}")
        let digest = SHA256.hash(data: Data(payload.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - PaginationKey

/// 分页缓存键。三个维度缺一不可：
/// - `bookKey`：书籍身份。缺了它，两本书章节同名（Calibre 的 `part0001.xhtml` 等）
///   就会共用一条缓存，书 B 会读到书 A 的正文（P0-A，静默错内容）。
///   取值与 `PageProgress.bookKey` 同源：`bookItem.bookExtrSubdir.path`
///   （见 `ViewController.bookKey`）。
/// - `src`：章相对路径。
/// - `configDigest`：排版配置的**稳定**摘要（`PaginationConfig.stableDigest`，
///   同样不能用 hashValue——见 `StableHash` 注释）。
struct PaginationKey: Hashable, Codable {
    let bookKey: String
    let src: String
    let configDigest: String
}

// MARK: - PaginationCache

/// 两级分页缓存：内存（以 ChapterLayout 为单位）+ 磁盘（存储整章富文本以便重建）
///
/// 架构变更说明：
/// 旧架构缓存的是 [NSAttributedString]（每页一份独立切片），
/// 新架构缓存的是 ChapterLayout（共享 NSTextStorage + NSLayoutManager + 一组 NSTextContainer）。
///
/// 磁盘层存储整章的全文富文本 NSAttributedString（含已应用的字体、间距等属性）
/// 以及 pageCount，加载时从磁盘重建 ChapterLayout（开销极小，仅遍历 container）。
final class PaginationCache {

    static let shared = PaginationCache()

    // MARK: - 磁盘包装

    /// 磁盘存储结构：整章富文本 + 页数，用于重建 ChapterLayout
    private struct DiskEntry: Codable {
        let attributedStringData: Data
        let pageCount: Int
        /// 目录锚点（元素 id → 字符偏移）。
        ///
        /// 可选：早于 v4 的缓存没有这一项。`ChapterTypography.contentSchemaVersion`
        /// 已随之升级，那些条目在新键下不可达，这里只是解档层的防御。
        let anchors: [String: Int]?
    }

    // MARK: - 内存层

    /// `memory` 的锁。
    ///
    /// 这不是防御性冗余，是**修正既有缺陷**：内存层此前完全没有同步，
    /// 而调用方本来就跨线程——
    ///   - `save` / `pageCount` 在 `loadChapterAsync`、全书页码索引的后台队列里
    ///   - `load` 在主线程（`loadChapterAsync` 主体）
    ///   - `invalidateAll` 在主线程（改设置、切尺寸类）与设置页
    /// Swift 的 `Dictionary` 并非线程安全，并发读写可能直接崩在哈希桶上。
    /// 搬 `load` 到后台会把这个窗口进一步放大，所以锁先补上。
    private let lock = NSLock()

    private var memory: [PaginationKey: ChapterLayout] = [:]

    // MARK: - 磁盘层

    /// 磁盘缓存根目录。
    ///
    /// 用 static 暴露出去是为了让「设置 → 存储管理」统计与清理同一处路径：
    /// 路径字面量只应存在一份，否则统计看到 A 目录、清理删了 B 目录。
    static let diskDirectoryURL: URL = {
        let url = StoragePath.paginationCache
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    private let diskURL: URL = PaginationCache.diskDirectoryURL

    /// 「写盘」与「清盘」的互斥闸门。
    ///
    /// 这不是防御性冗余：`save` 把编码后的 JSON 派发到 global 后台队列，
    /// 而清盘在另一条队列上删同一个目录。没有这道锁，一次在途的写可以落在
    /// 清理之后，给一本已删除的书留下一个永远读不到、也永远删不掉的缓存文件
    /// （`StorageAnalyzer` 只扫 extracted / backup 两个根，孤儿检测看不见它）。
    private let diskLock = NSLock()

    /// 磁盘代次。清盘时递增；`save` 落盘前校验，代次不符即丢弃。
    ///
    /// 光有锁不够：锁只保证「两者不并发」，不保证「清理之前排队的写
    /// 不会在清理之后落盘」——编码耗时正是那段窗口。
    private var diskGeneration: Int = 0

    private init() {
        purgeLegacySchemeFiles()
    }

    /// 一次性清理旧命名方案的磁盘文件（2026-10-13 之前的版本）。
    ///
    /// 旧文件名 = `abs(src.hashValue)_abs(configHash).paginationcache`，而 hashValue
    /// 每进程随机——那些文件从来就没有被再次命中的可能，纯粹是白占空间的死数据。
    /// 新方案文件名是 64 位十六进制、**不含下划线**；旧文件名必含一个下划线，
    /// 据此区分，只删旧的，绝不碰新缓存。
    /// 后台执行，不占启动主线程；目录本身不存在（全新安装）时直接跳过。
    private func purgeLegacySchemeFiles() {
        let dir = diskURL
        DispatchQueue.global(qos: .background).async {
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil
            ) else { return }
            for url in files where url.pathExtension == "paginationcache"
                && url.deletingPathExtension().lastPathComponent.contains("_") {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    // MARK: - 读取

    /// 命中内存层时立刻返回；未命中则同步读磁盘 + 解档 + 重建排版。
    ///
    /// ⚠️ 后半段是**重 I/O + 重排版**，只在确实需要时调用。
    /// 读磁盘请用 `loadAsync(key:usableSize:completion:)`，它把这段整体搬到后台。
    func load(key: PaginationKey, usableSize: CGSize) -> ChapterLayout? {
        lock.lock()
        let mem = memory[key]
        lock.unlock()
        if let mem { return mem }

        let url = fileURL(for: key)
        guard let data = try? Data(contentsOf: url),
              let entry = try? JSONDecoder().decode(DiskEntry.self, from: data),
              let attrStr = try? NSKeyedUnarchiver.unarchivedObject(
                  ofClass: NSAttributedString.self,
                  from: entry.attributedStringData
              )
        else { return nil }

        let layout = ChapterLayout(
            attributedString: attrStr,
            usableSize: usableSize,
            anchors: entry.anchors ?? [:]
        )
        lock.lock()
        memory[key] = layout
        lock.unlock()
        return layout
    }

    /// `load` 的后台版本，completion 回到主线程。
    ///
    /// 供主线程调用点使用：磁盘读、JSON 解码、`NSKeyedUnarchiver` 解档、
    /// 以及重建 `ChapterLayout` 的整章 TextKit 排版，全部不在主线程上做。
    func loadAsync(
        key: PaginationKey,
        usableSize: CGSize,
        completion: @escaping (ChapterLayout?) -> Void
    ) {
        // 内存命中是 O(1) 且无 I/O，直接在调用线程返回，不必绕后台。
        lock.lock()
        let mem = memory[key]
        lock.unlock()
        if let mem {
            completion(mem)
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let layout = self.load(key: key, usableSize: usableSize)
            DispatchQueue.main.async { completion(layout) }
        }
    }

    /// 仅读取页数，用于全书页码索引
    func pageCount(key: PaginationKey) -> Int? {
        lock.lock()
        let mem = memory[key]
        lock.unlock()
        if let mem { return mem.pageCount }

        let url = fileURL(for: key)
        guard let data = try? Data(contentsOf: url),
              let entry = try? JSONDecoder().decode(DiskEntry.self, from: data)
        else { return nil }
        return entry.pageCount
    }

    // MARK: - 写入

    func save(
        layout: ChapterLayout,
        sourceAttributedString: NSAttributedString,
        for key: PaginationKey
    ) {
        lock.lock()
        memory[key] = layout
        lock.unlock()

        // 代次必须在**调用时**同步捕获，不能在后台块里读：
        // 编码要几十到几百毫秒，这期间若发生一次清盘，块里读到的就是新代次，
        // 这份属于旧书的数据会被误判成"清理之后的新写"落进已清空的目录。
        diskLock.lock()
        let generation = diskGeneration
        diskLock.unlock()

        let url = fileURL(for: key)
        let pageCount = layout.pageCount
        // 空表不写：绝大多数章没有目录锚点，省掉每个缓存文件里的一个空字典。
        let anchors: [String: Int]? = layout.anchors.isEmpty ? nil : layout.anchors
        DispatchQueue.global(qos: .background).async { [weak self] in
            guard let attrData = try? NSKeyedArchiver.archivedData(
                withRootObject: sourceAttributedString,
                requiringSecureCoding: false
            ) else { return }
            let entry = DiskEntry(attributedStringData: attrData, pageCount: pageCount, anchors: anchors)
            guard let json = try? JSONEncoder().encode(entry) else { return }
            guard let self else { return }
            // 校验代次与写文件必须在同一把锁里，否则
            // 「校验通过 → 清盘删空 → 本块才写」仍会留下一个已删书的缓存文件。
            self.diskLock.lock()
            defer { self.diskLock.unlock() }
            guard self.diskGeneration == generation else { return }
            try? json.write(to: url, options: .atomic)
        }
    }

    // MARK: - 失效

    /// 只清内存层。调用方需要同步删除磁盘并准确复测占用时，
    /// 用它避免再派发一条与磁盘清理竞争的异步任务。
    func invalidateMemory() {
        lock.lock()
        memory.removeAll()
        lock.unlock()
    }

    /// 内存层立即清空，磁盘层派发到后台——调用方不关心何时删完时用这个。
    func invalidateAll() {
        invalidateMemory()
        DispatchQueue.global(qos: .background).async { [weak self] in
            self?.purgeDisk()
        }
    }

    /// 清空磁盘层，返回释放的字节数。同步，后台调用。
    ///
    /// **所有清盘路径的唯一入口**（存储管理清缓存、一键清除书籍数据、
    /// 切换排版配置导致的整层失效）。与 `save` 的后台落盘共用 `diskLock`：
    /// 清盘期间要么写盘先完成（随后被一并删掉），要么被代次校验丢弃——
    /// 不会出现"清完之后又冒出一个已删书的缓存文件"。
    ///
    /// 只动磁盘，不动内存层：内存字典归 `invalidateMemory()` 管，
    /// 调用方按「后台删盘 → 主线程清内存」的顺序分开调用。
    @discardableResult
    func purgeDisk() -> Int64 {
        diskLock.lock()
        defer { diskLock.unlock() }
        diskGeneration &+= 1
        return Self.purgeDiskContents(at: diskURL)
    }

    /// 磁盘层同步清理，返回释放的字节数。
    ///
    /// **私有**：清盘必须经过 `purgeDisk()`，由它递增代次并与 `save` 的落盘互斥。
    /// 直接调这里会绕过闸门，重新打开"清完之后又冒出已删书缓存"的窗口。
    ///
    /// 「存储管理 → 清除缓存」需要删完立刻重新统计占用，异步版本会让
    /// 重新扫描跑到删除之前，UI 上表现成"点了没反应"。内存层仍由
    /// `invalidateAll()` 负责，调用方把两者分开在不同线程调用即可。
    @discardableResult
    private static func purgeDiskContents(at dir: URL = PaginationCache.diskDirectoryURL) -> Int64 {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey]
        )) ?? []

        var freed: Int64 = 0
        for url in contents {
            freed += StorageAnalyzer.allocatedSize(of: url)
            try? FileManager.default.removeItem(at: url)
        }
        return freed
    }

    // MARK: - 私有

    private func fileURL(for key: PaginationKey) -> URL {
        // 三个维度一起进哈希：书籍身份排最前，同书不同章、同章不同配置
        // 都不可能撞到同一文件。SHA-256 确定性输出 → 跨启动稳定命中。
        diskURL.appendingPathComponent(
            StableHash.hexDigest([key.bookKey, key.src, key.configDigest]) + ".paginationcache"
        )
    }
}
