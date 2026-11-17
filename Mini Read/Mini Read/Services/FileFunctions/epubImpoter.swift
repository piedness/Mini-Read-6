//
//  epubImpoter.swift
//  TheNewVellium
//
//  EPUB 导入的唯一执行体。（2026-10-13 重写，修复「无去重 / 无错误 UI / 路径外泄」。）
//
//  原实现的三个问题：
//  1. **无去重**：同名文件再次导入时，解压目录先删再建。若同名却是另一本书，
//     旧书册的解压内容当场被覆盖——旧 bookItem 还在书架上，点开来已是新书的内容。
//  2. **无错误 UI**：每一步失败只 `print`，调用方拿不到原因，用户侧零提示（N8）。
//  3. **路径外泄**：调用方（Tabs）自己拼 `Documents/EpubReader/...` 字面量，
//     违背 `StoragePath` 路径收口纪律。
//
//  现在的契约：
//  - 去重键 = 源文件内容 SHA-256（随 `bookItem.importHash` 持久化）；
//    老书哈希为空串，永不与新导入的书相撞。
//  - 备份文件名与解压目录名都带唯一后缀（哈希前缀 + 冲突计数），
//    任何两次导入互不覆盖——keepBoth 语义因此天然成立。
//  - 所有磁盘工作串行在一条专用后台队列上（fileImporter 支持多选，
//     并发 staging 会撞目录竞争）。
//  - 返回结构化结果：成功（含全部元数据）/ 失败（用户可读中文原因）。
//    取消安全作用域、重复判定等需要主线程/SwiftData 的决策留给调用方。
//

import Foundation
import ZipArchive
import CryptoKit

// MARK: - 路径常量（唯一定义处）

/// 导入相关的相对路径常量。`StoragePath` 的 backupRoot / extractedRoot 引用这里，
/// 保证「导入写入方」「存储统计方」「清理方」三方永远指向同一目录。
enum AppDirectory {
    static let root      = "EpubReader"
    static let backup    = "EpubReader/epubBackup"
    static let extracted = "EpubReader/epubExtr"
}

// MARK: - 错误（用户可读）

/// 导入失败的用户可读原因。原实现只有 `print`，UI 无从提示。
enum EPUBImportError: LocalizedError {
    /// 源文件读不了（被移动/删除、无权限）
    case sourceUnreadable
    /// 复制到备份目录失败（空间不足等）
    case copyFailed(String)
    /// 解压失败：不是 zip，或 zip 损坏
    case unzipFailed
    /// 解压成功但结构不对：没有 META-INF/container.xml，不是 EPUB
    case notAnEPUB
    /// 解压结构合法但 OPF 读不出来（半截文件、格式怪异）
    case metadataParseFailed

    var errorDescription: String? {
        switch self {
        case .sourceUnreadable:
            return "无法读取所选文件，它可能已被移动、删除或无权访问。"
        case .copyFailed(let reason):
            return "无法把文件复制进书库（\(reason)）。请检查设备可用空间后重试。"
        case .unzipFailed:
            return "这个文件解压失败，可能已损坏或根本不是 EPUB。"
        case .notAnEPUB:
            return "这个文件不是有效的 EPUB（缺少 META-INF/container.xml）。"
        case .metadataParseFailed:
            return "EPUB 解压成功，但读不出书籍信息，文件可能不完整。"
        }
    }
}

// MARK: - 成功结果（Sendable，跨线程回传）

/// 一次成功 staging 的全部产物。纯值类型，可安全从后台队列带回主线程。
struct EPUBImportOutcome: Sendable {
    /// 源 .epub 内容的 SHA-256，书库去重键
    let contentHash: String
    /// 解压内容目录（已存在且含合法 EPUB 结构）
    let extrSubdir: URL
    /// 原件备份文件
    let backupURL: URL
    /// OPF 所在目录（阅读器拼接章节相对路径的基准）
    let resourceBaseURL: URL
    let title: String
    let author: String
    let publisher: String
    let coverImageURLs: [URL]
}

// MARK: - 导入主入口

/// 把用户选中的 .epub 落进书库目录并解析出元数据。
///
/// 只做「文件系统 + 解析」；不碰 SwiftData、不判断重复——
/// 去重需要查 `bookItem.importHash`，那是调用方（主线程）的职责。
func importEPUB(from sourceURL: URL) async -> Result<EPUBImportOutcome, EPUBImportError> {
    await withCheckedContinuation { continuation in
        EPUBImportQueue.sync {
            continuation.resume(returning: stageEPUBImport(from: sourceURL))
        }
    }
}

/// Staging 专用**串行**队列：fileImporter 允许多选，会连续调多次 staging。
/// 目录命名虽带唯一后缀，串行执行仍是最简单的正确性保证。
private let EPUBImportQueue = DispatchQueue(label: "com.vellium.epubimport", qos: .userInitiated)

/// 清掉一次 staging 的磁盘产物（重复跳过、失败回退时调用）。
/// 后台执行；万一删除失败也无妨——孤儿扫描按「目录在、书库无记录」回收。
func removeImportArtifacts(extrSubdir: URL, backupURL: URL) {
    EPUBImportQueue.async {
        try? FileManager.default.removeItem(at: extrSubdir)
        try? FileManager.default.removeItem(at: backupURL)
    }
}

// MARK: - Staging（同步，只在 EPUBImportQueue 上跑）

private func stageEPUBImport(from sourceURL: URL) -> Result<EPUBImportOutcome, EPUBImportError> {
    // 0. 兜底两个根目录。原实现里有这一步，重写时差点漏掉——
    //    全新安装（或清理过数据）时 backupRoot/extractedRoot 都不存在，
    //    后面 copyItem 会连错都没处说。pathExists 判断放在 try? 之后无意义，
    //    createDirectory 对已存在目录是幂等成功。
    do {
        try FileManager.default.createDirectory(
            at: StoragePath.backupRoot, withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: StoragePath.extractedRoot, withIntermediateDirectories: true
        )
    } catch {
        return .failure(.copyFailed(error.localizedDescription))
    }

    // 1. 内容哈希——先算再动盘，重复导入可以零落盘直接跳过
    guard let hash = EPUBHasher.sha256(ofFileAt: sourceURL) else { return .failure(.sourceUnreadable) }

    // 2. 唯一命名：同名不同书、同书 keepBoth 两种场景都不互覆盖
    let baseName = EPUBImportNaming.sanitizedBaseName(
        sourceURL.deletingPathExtension().lastPathComponent
    ) + "-" + String(hash.prefix(8))
    let backupURL = EPUBImportNaming.uniqueURL(
        for: baseName, extension: "epub", in: StoragePath.backupRoot
    )
    let extrSubdir = EPUBImportNaming.uniqueDirectoryURL(
        for: baseName, in: StoragePath.extractedRoot
    )

    // 3. 复制原件进备份目录
    do {
        if FileManager.default.fileExists(atPath: backupURL.path) {
            try FileManager.default.removeItem(at: backupURL)
        }
        try FileManager.default.copyItem(at: sourceURL, to: backupURL)
    } catch {
        return .failure(.copyFailed(error.localizedDescription))
    }

    // 4. 解压
    do {
        try FileManager.default.createDirectory(
            at: extrSubdir, withIntermediateDirectories: true
        )
        guard SSZipArchive.unzipFile(atPath: backupURL.path, toDestination: extrSubdir.path) else {
            try? FileManager.default.removeItem(at: extrSubdir)
            try? FileManager.default.removeItem(at: backupURL)
            return .failure(.unzipFailed)
        }

        // 5. 结构预检：META-INF/container.xml 是合法 EPUB 的硬性标志。
        //    原来「是不是 EPUB」要等解析 OPF 才知道，且失败时解压产物已经落盘。
        guard FileManager.default.fileExists(
            atPath: extrSubdir.appendingPathComponent("META-INF/container.xml").path
        ) else {
            try? FileManager.default.removeItem(at: extrSubdir)
            try? FileManager.default.removeItem(at: backupURL)
            return .failure(.notAnEPUB)
        }

        // 6. 解析元数据。EPUBBook 的 lazy 属性全部在这一步访问——
        //    值取出来后装进 Sendable 结构体，不跨线程触碰 lazy 缓存。
        guard let book = EPUBBook(contentsOf: extrSubdir) else {
            try? FileManager.default.removeItem(at: extrSubdir)
            try? FileManager.default.removeItem(at: backupURL)
            return .failure(.metadataParseFailed)
        }

        let outcome = EPUBImportOutcome(
            contentHash: hash,
            extrSubdir: extrSubdir,
            backupURL: backupURL,
            resourceBaseURL: book.resourceBaseURL,
            title: book.opf.metadata.titles.first ?? sourceURL.deletingPathExtension().lastPathComponent,
            author: book.opf.metadata.creators.first ?? "Unknown Author",
            publisher: book.opf.metadata.publisher ?? "Unknown Publisher",
            coverImageURLs: book.coverImageURLs
        )
        return .success(outcome)
    } catch {
        try? FileManager.default.removeItem(at: extrSubdir)
        try? FileManager.default.removeItem(at: backupURL)
        return .failure(.copyFailed(error.localizedDescription))
    }
}

// MARK: - 稳定内容哈希

/// 流式计算大文件的 SHA-256。整书可能上百 MB，不能一次性读进内存。
private enum EPUBHasher {
    static func sha256(ofFileAt url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        var hasher = SHA256()
        let chunkSize = 1024 * 1024
        while true {
            let chunk = handle.readData(ofLength: chunkSize)
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - 安全命名

/// 目录/文件名净化与唯一化。文件名直接来自用户磁盘，可能含 `/`、`:`、
/// 换行等——与原「设置配置文件导出」的净化同一套字符表。
private enum EPUBImportNaming {

    /// 非法字符替换为 `-`；空名回退 `book`；截到 48 字符
    /// （目录名还要追加哈希与计数，无限制全长会在长文件名书目上爆 PATH_MAX）。
    static func sanitizedBaseName(_ raw: String) -> String {
        let cleaned = raw.replacingOccurrences(
            of: "[/\\\\:*?\"<>|\\r\\n]",
            with: "-",
            options: .regularExpression
        )
        let trimmed = String(cleaned.prefix(48))
        return trimmed.isEmpty ? "book" : trimmed
    }

    /// 在目录里找一个不冲突的文件 URL（含后缀）。
    static func uniqueURL(for base: String, extension ext: String, in directory: URL) -> URL {
        let candidate = directory.appendingPathComponent("\(base).\(ext)")
        return disambiguate(candidate) { idx in
            directory.appendingPathComponent("\(base)-\(idx).\(ext)")
        }
    }

    /// 在目录里找一个不冲突的子目录 URL（无后缀）。
    static func uniqueDirectoryURL(for base: String, in directory: URL) -> URL {
        let candidate = directory.appendingPathComponent(base, isDirectory: true)
        return disambiguate(candidate) { idx in
            directory.appendingPathComponent("\(base)-\(idx)", isDirectory: true)
        }
    }

    /// 首个不存在的 URL；冲突时按 -2、-3… 递增。父目录保证已创建，
    /// fileExists 不会因父目录缺失而误判。
    private static func disambiguate(_ first: URL, make: (Int) -> URL) -> URL {
        guard FileManager.default.fileExists(atPath: first.path) else { return first }
        var index = 2
        while true {
            let candidate = make(index)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            index += 1
        }
    }
}
