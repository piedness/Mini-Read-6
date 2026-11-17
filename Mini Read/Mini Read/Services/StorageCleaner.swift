//
//  StorageCleaner.swift
//  TheNewVellium
//
//  存储管理页各类「释放空间」动作的唯一执行体。
//
//  设计取舍：
//  - 与 `StorageAnalyzer` 一样是同步 API，并发上下文交给调用方。
//    清理前必然先取得体积快照（读），清理后必然重新扫描（读），
//    这两件事都在后台线程，把清理也放进去就不用在 MainActor 之间来回跳。
//  - 只暴露「删什么」，不暴露「怎么删」：内部统一用 FileManager，
//    复用既有 `deleteDirectory(at:)` 的日志口径。
//  - 删除前一律做路径归属校验。孤儿检测已经是"磁盘有、书库无"的差集，
//    但差集算错了的代价是删掉用户正在读的书，所以这里再兜一道底。
//

import Foundation

enum StorageCleaner {

    // MARK: - 分页缓存

    /// 清空磁盘分页缓存（目录本身保留），返回释放的字节数。
    ///
    /// 只删磁盘，不动 `PaginationCache` 的内存层：内存字典不是线程安全的，
    /// 应当在清理完成后于主线程调用 `invalidateAll()` 一并清掉。
    /// 这样调用顺序是：后台删磁盘 → 主线程清内存 → 后台重新扫描。
    @discardableResult
    static func purgePaginationCache() -> Int64 {
        PaginationCache.purgeDiskContents()
    }

    // MARK: - 孤儿文件

    /// 删除孤儿项，返回释放的字节数。
    ///
    /// - Parameter items: `StorageReport.orphans`，即磁盘有、书库无的残留。
    /// - Returns: 实际释放的字节数（删除失败的不计入）。
    @discardableResult
    static func purgeOrphans(_ items: [OrphanItem]) -> Int64 {
        let extractedRoot = StoragePath.extractedRoot.standardizedFileURL.resolvingSymlinksInPath().path
        let backupRoot = StoragePath.backupRoot.standardizedFileURL.resolvingSymlinksInPath().path

        var freed: Int64 = 0
        for item in items {
            let path = item.url.standardizedFileURL.resolvingSymlinksInPath().path
            // 兜底：只承认 App 两个 EPUB 目录下的直接子项，
            // 越界的路径一律跳过，宁可清不干净也不能误删。
            let isUnderExtracted = path.hasPrefix(extractedRoot + "/") && path != extractedRoot
            let isUnderBackup = path.hasPrefix(backupRoot + "/") && path != backupRoot
            guard isUnderExtracted || isUnderBackup else {
                print("⚠️ [StorageCleaner] 跳过越界路径：\(path)")
                continue
            }

            freed += item.bytes
            deleteDirectory(at: item.url)
        }
        return freed
    }

    // MARK: - 单本书

    /// 删除一本书占用的全部磁盘目录。
    ///
    /// 与书架删除（`BookCard.performDelete`）删的是同一组目录，
    /// 这里抽出来是为了让「存储管理 → 按书占用」能复用同一套清理口径，
    /// 而不是再抄一遍三个 URL。SwiftData 记录的删除由视图负责。
    static func purgeBookDirectories(_ source: BookStorageSource) {
        deleteDirectory(at: source.extractedURL)
        deleteDirectory(at: source.backupURL)
    }

    // MARK: - 全部书籍

    /// 统计「书籍数据」的总占用：解压内容 + 原书备份 + 分页缓存。
    /// 前两项直接量根目录，因此也把没有对应记录的残留算了进去——
    /// 一键清除要清的就是这整块，统计口径必须和清理口径一致。
    static func bookDataBytes() -> Int64 {
        StorageAnalyzer.directorySize(StoragePath.extractedRoot)
        + StorageAnalyzer.directorySize(StoragePath.backupRoot)
        + StorageAnalyzer.directorySize(StoragePath.paginationCache)
    }

    /// 清空磁盘上的全部书籍数据，返回释放的字节数。同步，后台调用。
    ///
    /// 只碰书：解压根目录、备份根目录、分页缓存。
    /// 字体、背景图、头像、设置一概不动——它们不是"书籍数据"，
    /// 用户点这个按钮时不该失去自己导入的字体。
    ///
    /// 连根目录一起删而不是只删内容，是为了把隐藏文件、半截解压残留
    /// 一并带走；下次导入时 `importEPUB(from:)` 的 staging 会幂等重建这两个目录
    /// （staging 第 0 步 createDirectory，已存在也成功）。
    @discardableResult
    static func purgeAllBookDataOnDisk() -> Int64 {
        let freed = bookDataBytes()
        deleteDirectory(at: StoragePath.extractedRoot)
        deleteDirectory(at: StoragePath.backupRoot)
        PaginationCache.purgeDiskContents()
        return freed
    }
}
