//
//  ImportedFontStore.swift
//  TheNewVellium
//
//  用户导入字体（TTF / OTF）的存储、注册与解析中枢。
//
//  设计取舍：
//  - 不进 SwiftData Schema：导入字体是「文件 + 清单」的纯文件系统资产，
//    放进 SwiftData 反而要对既有持久化层做迁移、引入回归风险。这里用
//    Application Support/ImportedFonts 目录存字体文件，manifest.json 存元数据，
//    进程内 registry 缓存 (id → 字体名)，渲染时免磁盘 / DB 读取。
//  - 注册用 .process 作用域：每次启动由 registerAll() 重新注册，删除时反注册，
//    不污染系统级字体注册表，行为完全可控、可重来。
//  - 解析与 FontFamily 解耦：settings.fontFamily 是持久化字符串，可能是内置枚举
//    rawValue，也可能是 "custom:<id>"。所有渲染点统一走 resolveReading* 函数，
//    先查内置 FontFamily，再查本注册表，最后回退系统字体——正文永不允许渲染不出来。
//

import Foundation
import CoreText
import UIKit
import SwiftUI

/// 已导入字体的元数据（可编码，持久化进 manifest.json）。
struct ImportedFontMeta: Identifiable, Codable, Hashable {
    let id: String
    let displayName: String   // 面向用户展示的名字（取字体 family name）
    let psName: String        // PostScript 全名，UIFont(name:) / Font.custom 靠它解析
    let fileName: String      // 落在 ImportedFonts 目录里的实际文件名 "<id>.<ext>"
    let dateAdded: Date

    /// 持久化到 settings.fontFamily 的 token。
    var token: String { ImportedFontStore.tokenPrefix + id }
}

enum ImportedFontStore {

    // MARK: - 公开常量

    /// settings.fontFamily 里标识「自定义导入字体」的前缀；后面跟字体 id。
    static let tokenPrefix = "custom:"

    // MARK: - 路径

    /// 字体文件与清单统一存放目录：~/Library/Application Support/ImportedFonts
    ///
    /// 与 `StoragePath.importedFonts` 同源：存储管理要统计这一项的占用，
    /// 路径只应存在一份。
    static var directory: URL { StoragePath.importedFonts }

    private static var manifestURL: URL {
        directory.appendingPathComponent("manifest.json")
    }

    static func fileURL(for meta: ImportedFontMeta) -> URL {
        directory.appendingPathComponent(meta.fileName)
    }

    // MARK: - 进程内注册表（id → (PostScript 名, 展示名)）

    /// 渲染解析只查这里，避免每次排版都读磁盘 / 反序列化清单。
    private static var registry: [String: (psName: String, displayName: String)] = [:]

    // MARK: - 清单读写

    /// 列出全部已导入字体（按导入时间倒序）。
    static func all() -> [ImportedFontMeta] {
        guard let data = try? Data(contentsOf: manifestURL),
              let list = try? JSONDecoder().decode([ImportedFontMeta].self, from: data) else {
            return []
        }
        return list.sorted { $0.dateAdded > $1.dateAdded }
    }

    private static func save(_ list: [ImportedFontMeta]) throws {
        let data = try JSONEncoder().encode(list)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: manifestURL, options: .atomic)
    }

    // MARK: - 导入 / 删除

    /// 从系统文件选择器拿到的 URL 导入一个字体文件。
    ///
    /// 1. 安全作用域访问源文件并复制到 ImportedFonts 目录；
    /// 2. 注册进 Core Text 并捕获 PostScript / family 名（注册后才能被 name 解析）；
    /// 3. 写入 manifest，刷新 registry。
    /// 任一步失败都会清理已产生的文件，不会留下半截数据。
    @discardableResult
    static func importFont(from sourceURL: URL) throws -> ImportedFontMeta {
        guard sourceURL.startAccessingSecurityScopedResource() else {
            throw ImportedFontError.cannotAccessFile
        }
        defer { sourceURL.stopAccessingSecurityScopedResource() }

        let id = UUID().uuidString
        let ext = (sourceURL.pathExtension.isEmpty ? "ttf" : sourceURL.pathExtension).lowercased()
        let fileName = "\(id).\(ext)"

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let dest = directory.appendingPathComponent(fileName)

        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        do {
            try FileManager.default.copyItem(at: sourceURL, to: dest)
        } catch {
            throw ImportedFontError.copyFailed
        }

        // 注册失败 → 删掉刚复制的文件，不让坏字体残留。
        do {
            try register(fontAt: dest)
        } catch {
            try? FileManager.default.removeItem(at: dest)
            throw error
        }

        guard let uiFont = loadUIFont(from: dest) else {
            try? FileManager.default.removeItem(at: dest)
            throw ImportedFontError.invalidFontFile
        }

        let psName  = uiFont.fontName
        let display = uiFont.familyName ?? sourceURL.deletingPathExtension().lastPathComponent

        let meta = ImportedFontMeta(
            id: id,
            displayName: display,
            psName: psName,
            fileName: fileName,
            dateAdded: Date()
        )

        var list = all()
        list.append(meta)
        try save(list)

        registry[id] = (psName, display)
        return meta
    }

    /// 删除一个已导入字体：反注册、删文件、移出清单与 registry。
    static func delete(_ id: String) throws {
        var list = all()
        guard let meta = list.first(where: { $0.id == id }) else { return }

        let url = fileURL(for: meta)
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
        unregister(fontAt: url)

        list.removeAll { $0.id == id }
        try save(list)
        registry.removeValue(forKey: id)
    }

    // MARK: - 启动注册

    /// App 启动时调用：把清单里所有字体文件重新注册进当前进程，并重建 registry。
    /// 用 .process 作用域，重启后需要重新注册，因此必须走这一步。
    static func registerAll() {
        registry.removeAll()
        for meta in all() {
            let url = fileURL(for: meta)
            guard FileManager.default.fileExists(atPath: url.path) else {
                // 文件丢了：清掉这条孤儿记录，避免永久选不中又删不掉。
                try? delete(meta.id)
                continue
            }
            try? register(fontAt: url)
            registry[meta.id] = (meta.psName, meta.displayName)
        }
    }

    // MARK: - 渲染解析（供阅读器正文 / 页眉 / SwiftUI 预览使用）

    static func uiFont(token: String, size: CGFloat) -> UIFont {
        if let id = idFromToken(token),
           let entry = registry[id], !entry.psName.isEmpty {
            return UIFont(name: entry.psName, size: size) ?? .systemFont(ofSize: size)
        }
        return .systemFont(ofSize: size)
    }

    static func swiftUIFont(token: String, size: CGFloat) -> Font {
        if let id = idFromToken(token),
           let entry = registry[id], !entry.psName.isEmpty {
            return Font.custom(entry.psName, size: size)
        }
        return .system(size: size)
    }

    static func displayName(token: String) -> String {
        if let id = idFromToken(token), let entry = registry[id] {
            return entry.displayName
        }
        return ""
    }

    // MARK: - 内部

    static func idFromToken(_ token: String) -> String? {
        guard token.hasPrefix(tokenPrefix) else { return nil }
        let id = String(token.dropFirst(tokenPrefix.count))
        return id.isEmpty ? nil : id
    }

    private static func register(fontAt url: URL) throws {
        var error: Unmanaged<CFError>?
        let ok = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
        // 注册返回 false 但若字体实际已能加载（例如重复注册），视为成功，不报错。
        guard ok || loadUIFont(from: url) != nil else {
            throw ImportedFontError.registrationFailed
        }
    }

    private static func unregister(fontAt url: URL) {
        CTFontManagerUnregisterFontsForURL(url as CFURL, .process, nil)
    }

    private static func loadUIFont(from url: URL, size: CGFloat = UIFont.systemFontSize) -> UIFont? {
        guard let descs = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
              let desc = descs.first else { return nil }
        return CTFontCreateWithFontDescriptorAndOptions(desc, size, nil, []) as UIFont
    }
}

// MARK: - 统一字体解析（阅读器与预览的唯一入口）

/// settings.fontFamily 是持久化字符串：内置枚举 rawValue，或 "custom:<id>"。
/// 这三个函数是正文 / 页眉 / 预览解析字体的唯一收口，先查内置 FontFamily，
/// 再查已导入字体注册表，最后回退系统字体——正文永远渲染得出来。

func resolveReadingUIFont(_ value: String, size: CGFloat) -> UIFont {
    if let builtIn = FontFamily(rawValue: value) {
        return builtIn.uiFont(ofSize: size)
    }
    if value.hasPrefix(ImportedFontStore.tokenPrefix) {
        return ImportedFontStore.uiFont(token: value, size: size)
    }
    return .systemFont(ofSize: size)
}

func resolveReadingSwiftUIFont(_ value: String, size: CGFloat) -> Font {
    if let builtIn = FontFamily(rawValue: value) {
        return builtIn.swiftUIFont(ofSize: size)
    }
    if value.hasPrefix(ImportedFontStore.tokenPrefix) {
        return ImportedFontStore.swiftUIFont(token: value, size: size)
    }
    return .system(size: size)
}

func resolveReadingFontDisplayName(_ value: String) -> String {
    if let builtIn = FontFamily(rawValue: value) {
        return builtIn.displayName
    }
    if value.hasPrefix(ImportedFontStore.tokenPrefix) {
        return ImportedFontStore.displayName(token: value)
    }
    return FontFamily.LXGWWenKai.displayName
}

// MARK: - 错误

enum ImportedFontError: LocalizedError {
    case cannotAccessFile
    case copyFailed
    case invalidFontFile
    case registrationFailed

    var errorDescription: String? {
        switch self {
        case .cannotAccessFile:  return "无法访问所选文件，请重试。"
        case .copyFailed:        return "字体文件复制失败，请检查存储空间。"
        case .invalidFontFile:   return "该文件不是有效的字体文件。"
        case .registrationFailed: return "字体注册失败，文件可能已损坏或系统不支持该格式。"
        }
    }
}
