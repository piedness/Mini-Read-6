//
//  SettingsProfile.swift
//  TheNewVellium
//
//  「设置 → 通用设置 → 配置文件」的模型、字段映射与存取中枢。
//
//  设计取舍：
//  - 配置文件不进 SwiftData：它是「可导出、可分享、可手改」的文件资产，
//    形态是一份 JSON（属性名 → 值），存在 Application Support/SettingsProfiles，
//    一个配置一个文件；保存 / 套用 / 删除 / 导入都是文件操作，不触碰持久化层，
//    也就没有任何 schema 迁移风险。
//  - 字段映射只维护「一张 KeyPath 表」（`SettingsProfileSchema.fields`）：
//    保存与套用共用同一张表，两侧不可能漂移。新增 AppSettings 属性时在表里
//    补一行（与 `resetToDefaults()` 同一纪律）；漏掉会被 DEBUG 守卫在控制台
//    点名——这类缺陷在 UI 上几乎看不见。
//  - 值层（`SettingsProfileValue`）宽容解码：整型的 Double（如 28.0）序列化成
//    JSON 数字后读回时是 Int 形态，故 Int/Double 两个方向都做了显式互转，
//    保证往返不丢值（实测 JSON 里 `20.0` 写成 `20`，读回即 `.int(20)`）。
//

import Foundation
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 值类型

/// 配置文件里一个设置项的取值。
///
/// `AppSettings` 的全部持久化属性都是 String / Double / Int / Bool 四种之一，
/// 这里用单一枚举收进一个可 JSON 化的类型，配置文件因此是扁平的
/// 「属性名 → 标量」对象，手写、阅读、diff 都最省事。
enum SettingsProfileValue: Codable, Equatable {
    case string(String)
    case double(Double)
    case int(Int)
    case bool(Bool)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        // 顺序即优先级：JSON 的 true/false 只会命中 Bool；
        // 数字先 Int 后 Double（整型数以 Int 形态回来，由转换层吸收，见文件头说明）。
        if let value = try? container.decode(Bool.self)   { self = .bool(value);   return }
        if let value = try? container.decode(Int.self)    { self = .int(value);    return }
        if let value = try? container.decode(Double.self) { self = .double(value); return }
        if let value = try? container.decode(String.self) { self = .string(value); return }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "不支持的配置值类型")
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .int(let value):    try container.encode(value)
        case .bool(let value):   try container.encode(value)
        }
    }
}

/// 让四种标量类型和 `SettingsProfileValue` 互相转换，供字段表泛型使用。
protocol SettingsProfileValueConvertible {
    var profileValue: SettingsProfileValue { get }
    init?(profileValue: SettingsProfileValue)
}

extension String: SettingsProfileValueConvertible {
    var profileValue: SettingsProfileValue { .string(self) }
    init?(profileValue: SettingsProfileValue) {
        guard case .string(let value) = profileValue else { return nil }
        self = value
    }
}

extension Double: SettingsProfileValueConvertible {
    var profileValue: SettingsProfileValue { .double(self) }
    init?(profileValue: SettingsProfileValue) {
        switch profileValue {
        case .double(let value): self = value
        case .int(let value):    self = Double(value)   // 整型 Double 经 JSON 往返后的形态
        default: return nil
        }
    }
}

extension Int: SettingsProfileValueConvertible {
    var profileValue: SettingsProfileValue { .int(self) }
    init?(profileValue: SettingsProfileValue) {
        switch profileValue {
        case .int(let value): self = value
        case .double(let value):
            // 只有整值才接受（20.0 → 20）；20.5 这类不该出现在 Int 属性上的值直接放弃。
            guard let exact = Int(exactly: value) else { return nil }
            self = exact
        default: return nil
        }
    }
}

extension Bool: SettingsProfileValueConvertible {
    var profileValue: SettingsProfileValue { .bool(self) }
    init?(profileValue: SettingsProfileValue) {
        guard case .bool(let value) = profileValue else { return nil }
        self = value
    }
}

// MARK: - 字段映射表

/// 配置文件的字段覆盖表：**保存与套用共用的唯一一处**「属性名 → KeyPath」映射。
enum SettingsProfileSchema {

    /// 一个可读写字段。
    ///
    /// 写闭包对「类型对不上」的值直接跳过并返回 false（`init?(profileValue:)`
    /// 返回 nil），坏数据因此永远污染不了设置——导入的文件再离谱，认不出的项
    /// 就是不生效；返回的 Bool 让套用计数只统计**真正写进去**的项。
    struct Field {
        let name: String
        let read: (AppSettings) -> SettingsProfileValue
        let write: (AppSettings, SettingsProfileValue) -> Bool
    }

    /// 全部字段。顺序与 `AppSettings` 的属性声明顺序逐段一致，方便对照 review。
    /// ⚠️ 新增持久化属性时**必须**在这里补一行（与 `resetToDefaults()` 同一纪律）。
    static let fields: [Field] = [
        // 1. 阅读体验 - 文字排版
        field("fontFamily", \.fontFamily),
        field("fontSize", \.fontSize),
        field("lineSpacing", \.lineSpacing),
        field("paragraphSpacing", \.paragraphSpacing),
        field("letterSpacing", \.letterSpacing),
        field("marginTop", \.marginTop),
        field("marginBottom", \.marginBottom),
        field("marginLeft", \.marginLeft),
        field("marginRight", \.marginRight),
        field("textAlignment", \.textAlignment),
        field("firstLineIndent", \.firstLineIndent),

        // 1. 阅读体验 - 主题与色彩
        field("currentTheme", \.currentTheme),
        field("customBackgroundColor", \.customBackgroundColor),
        field("customTextColor", \.customTextColor),
        field("customLinkColor", \.customLinkColor),
        field("customSelectionColor", \.customSelectionColor),
        field("followSystemAppearance", \.followSystemAppearance),

        // 1. 阅读体验 - 阅读背景扩展
        field("readingBackgroundMode", \.readingBackgroundMode),
        field("readingBackgroundColorHex", \.readingBackgroundColorHex),
        field("readingBackgroundImageSource", \.readingBackgroundImageSource),

        // 1. 阅读体验 - 翻页与交互
        field("pageTransitionStyle", \.pageTransitionStyle),
        field("volumeKeysTurn", \.volumeKeysTurn),

        // 1. 阅读体验 - 阅读辅助（页码：底部 + 格式；标题：顶部；两者独立）
        field("showPageNumber", \.showPageNumber),
        field("pageNumberPosition", \.pageNumberPosition),
        field("pageNumberFormat", \.pageNumberFormat),
        field("showChapterTitle", \.showChapterTitle),
        field("chapterTitlePosition", \.chapterTitlePosition),
        field("autoHideToolbar", \.autoHideToolbar),
        field("toolbarHideDelay", \.toolbarHideDelay),
        field("keepScreenOn", \.keepScreenOn),

        // 2. 书库管理 - 视图与组织
        field("libraryViewMode", \.libraryViewMode),
        field("listViewStyle", \.listViewStyle),
        field("sortBy", \.sortBy),

        // 2. 书库管理 - 导入与格式
        field("duplicateHandling", \.duplicateHandling),

        // 2. 书库管理 - 存储管理
        field("storageLocation", \.storageLocation),
        field("cacheSizeLimit", \.cacheSizeLimit),
        field("preloadPages", \.preloadPages),
        field("imageCacheQuality", \.imageCacheQuality),
        field("autoCleanCache", \.autoCleanCache),

        // 3. 笔记与标注 - 高亮与标注
        field("defaultHighlightColor", \.defaultHighlightColor),
        field("highlightOpacity", \.highlightOpacity),
        field("defaultAnnotationStyle", \.defaultAnnotationStyle),
        field("longPressAction", \.longPressAction),
        field("doubleTapAction", \.doubleTapAction),
        field("showNoteIndicators", \.showNoteIndicators),

        // 3. 笔记与标注 - 笔记系统
        field("noteDisplayPosition", \.noteDisplayPosition),
        field("noteBubbleStyle", \.noteBubbleStyle),
        field("showNoteCount", \.showNoteCount),

        // 3. 笔记与标注 - 导出与分享
        field("exportFormat", \.exportFormat),
        field("includeOriginalText", \.includeOriginalText),
        field("includeMetadata", \.includeMetadata),
        field("exportByChapter", \.exportByChapter),
        field("watermarkEnabled", \.watermarkEnabled),
        field("watermarkText", \.watermarkText),

        // 8. 隐私与安全
        field("hideReadingHistory", \.hideReadingHistory),
        field("enablePrivateShelf", \.enablePrivateShelf),

        // 10. 系统设置
        field("appLanguage", \.appLanguage),
        field("dateFormat", \.dateFormat),
        field("hapticFeedback", \.hapticFeedback),
        field("developerMode", \.developerMode),

        // 个性化 - App 外观扩展
        field("appTintColorHex", \.appTintColorHex),
        field("appBackgroundMode", \.appBackgroundMode),
        field("appBackgroundColorHex", \.appBackgroundColorHex),
        field("appBackgroundGradientStartHex", \.appBackgroundGradientStartHex),
        field("appBackgroundGradientEndHex", \.appBackgroundGradientEndHex),
        field("appBackgroundImageSource", \.appBackgroundImageSource),
        field("maxImageCacheCount", \.maxImageCacheCount),
        field("appBackgroundColorHex_Dark", \.appBackgroundColorHex_Dark),
        field("appBackgroundGradientStartHex_Dark", \.appBackgroundGradientStartHex_Dark),
        field("appBackgroundGradientEndHex_Dark", \.appBackgroundGradientEndHex_Dark),
    ]

    /// 已知属性名集合（导入时过滤未知键用）。
    static let knownNames: Set<String> = Set(fields.map(\.name))

    /// 快照：把当前设置读成「属性名 → 值」。
    static func capture(from settings: AppSettings) -> [String: SettingsProfileValue] {
        var values: [String: SettingsProfileValue] = [:]
        values.reserveCapacity(fields.count)
        for item in fields { values[item.name] = item.read(settings) }
        return values
    }

    /// 套用：把值写给设置。只写「表里认识、且类型对得上」的项；
    /// 返回值是**真正写入**的项数（名字命中但类型不符的不计入）。
    @discardableResult
    static func apply(_ values: [String: SettingsProfileValue], to settings: AppSettings) -> Int {
        var applied = 0
        for item in fields {
            guard let value = values[item.name] else { continue }
            if item.write(settings, value) { applied += 1 }
        }
        return applied
    }

    private static func field<T: SettingsProfileValueConvertible>(
        _ name: String,
        _ keyPath: ReferenceWritableKeyPath<AppSettings, T>
    ) -> Field {
        Field(
            name: name,
            read: { $0[keyPath: keyPath].profileValue },
            write: { settings, value in
                guard let typed = T(profileValue: value) else { return false }
                settings[keyPath: keyPath] = typed
                return true
            }
        )
    }

    #if DEBUG
    /// 开发期守卫：`AppSettings` 新增了持久化属性、但没同步进 `fields` 时，
    /// 在控制台把名字列出来。依据是 SwiftData `Schema` 反射出的属性逻辑名
    /// （与属性声明一一对应），不依赖任何手工维护的第二份清单。
    static func warnIfFieldsOutOfSync() {
        guard !didRunFieldCheck else { return }
        didRunFieldCheck = true

        guard let entity = Schema([AppSettings.self]).entities.first else { return }
        let declared = Set(entity.properties.map(\.name))
        let covered = Set(fields.map(\.name))

        let missing = declared.subtracting(covered).sorted()
        let stale = covered.subtracting(declared).sorted()
        if !missing.isEmpty {
            print("⚠️ SettingsProfile 漏掉的 AppSettings 属性：\(missing.joined(separator: ", "))")
        }
        if !stale.isEmpty {
            print("⚠️ SettingsProfile 里存在 AppSettings 没有的属性：\(stale.joined(separator: ", "))")
        }
    }

    private static var didRunFieldCheck = false
    #endif
}

// MARK: - 配置文件

/// 一个保存下来的设置快照。
///
/// 序列化形态（JSON，ISO8601 日期、键排序）：
/// ```json
/// {
///   "id": "…", "name": "深色阅读", "createdAt": "2026-10-08T12:00:00Z",
///   "values": { "fontSize": 30, "currentTheme": "night", … }
/// }
/// ```
struct SettingsProfile: Codable, Identifiable {
    var id: UUID
    var name: String
    var createdAt: Date
    /// 「属性名 → 值」。键与 `SettingsProfileSchema.fields` 的 name 一一对应；
    /// 未知键在导入时会被滤掉，保证这里只包含可套用的项（统计数也随之诚实）。
    var values: [String: SettingsProfileValue]

    private enum CodingKeys: String, CodingKey { case id, name, createdAt, values }

    init(id: UUID, name: String, createdAt: Date, values: [String: SettingsProfileValue]) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.values = values
    }

    /// 宽容解码：四个键全部可按缺省处理（手写 / 旧版本文件都不至于整份作废），
    /// 缺 `id` 时发新主键（导入路径随后还会再换一次，双保险）。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = (try? container.decode(UUID.self, forKey: .id)) ?? UUID()
        self.name = (try? container.decode(String.self, forKey: .name)) ?? ""
        self.createdAt = (try? container.decode(Date.self, forKey: .createdAt)) ?? Date()
        self.values = (try? container.decode([String: SettingsProfileValue].self, forKey: .values)) ?? [:]
    }
}

// MARK: - 存取

/// 配置文件的读写中枢。同步 I/O、文件以 KB 计，调用方（设置页）在主线程直接用，
/// 与 `ImportedFontStore` 同一约定。
enum SettingsProfileStore {

    /// 配置文件目录：Library/Application Support/SettingsProfiles
    static var directory: URL { StoragePath.settingsProfiles }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        // 排序键：文件可 diff、可手改；prettyPrinted 让它对用户是"可读的"。
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func fileURL(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    /// 列出全部配置文件（按保存时间倒序）。
    /// 解不出的单个文件跳过，不因一个坏文件丢掉整份列表。
    static func all() -> [SettingsProfile] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []

        let jsonDecoder = decoder
        return urls
            .filter { $0.pathExtension.lowercased() == "json" }
            .compactMap { url -> SettingsProfile? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                guard var profile = try? jsonDecoder.decode(SettingsProfile.self, from: data) else {
                    #if DEBUG
                    print("⚠️ 配置文件解码失败：\(url.lastPathComponent)")
                    #endif
                    return nil
                }
                // 统一只保留可套用的键：无论文件出自哪个版本，列表里的「N 项设置」都说真话。
                profile.values = filterKnown(profile.values)
                return profile
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// 保存当前设置为一个新的配置文件（写入一个新的 JSON 文件）。
    @discardableResult
    static func create(from settings: AppSettings, name: String) throws -> SettingsProfile {
        let profile = SettingsProfile(
            id: UUID(),
            name: sanitizedName(name, fallback: "未命名配置"),
            createdAt: Date(),
            values: SettingsProfileSchema.capture(from: settings)
        )
        try write(profile)
        return profile
    }

    /// 删除一个配置文件。
    static func delete(_ id: UUID) throws {
        let url = fileURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    /// 套用一份配置到设置上（只写值；落盘 / 广播由调用方合并成一次）。
    @discardableResult
    static func apply(_ profile: SettingsProfile, to settings: AppSettings) -> Int {
        SettingsProfileSchema.apply(profile.values, to: settings)
    }

    /// 从「文件」应用导入一份配置文件，落进本机列表并返回它。
    ///
    /// 两种可接受的文件形态：
    /// 1. 本 App 保存的标准文件（含 id/name/createdAt/values 外层结构）；
    /// 2. 手写的扁平对象（如 `{"fontSize": 30}`），缺的元数据就地补齐，
    ///    名字回退为文件名。
    ///
    /// - Note: 导入的 id **一律换成新 UUID**——绝不覆盖本机同 id 的既有文件。
    static func importProfile(from sourceURL: URL) throws -> SettingsProfile {
        // `startAccessingSecurityScopedResource()` 返回 false **不代表失败**：
        // 不在安全作用域里的文件（本容器内直接可读）本来就会返回 false。
        // 因此这里与 `ImportedFontStore` 的 `guard` 写法**有意不同**——
        // 以"读得出来"为准，读不出才是错误。
        let isScoped = sourceURL.startAccessingSecurityScopedResource()
        defer { if isScoped { sourceURL.stopAccessingSecurityScopedResource() } }

        guard let data = try? Data(contentsOf: sourceURL) else {
            throw SettingsProfileError.cannotReadFile
        }

        let fallbackName = sanitizedName(
            sourceURL.deletingPathExtension().lastPathComponent,
            fallback: "导入的配置"
        )

        // ① 标准结构（本 App 保存的文件）：含 values 外层。
        let envelope = try? decoder.decode(SettingsProfile.self, from: data)
        let envelopeValues: [String: SettingsProfileValue] = envelope.map { filterKnown($0.values) } ?? [:]

        // ② 手写 / 精简结构：纯扁平对象。
        //
        // ⚠️ 路由不能靠"① 解码失败"判断：`SettingsProfile` 是宽容解码，
        // 任何 JSON 对象都能解出一个 values 为空的壳。判据取「① 实际解出了
        // 可套用项没有」。反向也不会误判——标准文件里 values 是嵌套对象，
        // 扁平解码 `[String: SettingsProfileValue]` 必然失败。
        let flatValues: [String: SettingsProfileValue]
        if envelopeValues.isEmpty {
            flatValues = (try? decoder.decode([String: SettingsProfileValue].self, from: data))
                .map(filterKnown) ?? [:]
        } else {
            flatValues = [:]
        }

        let values = envelopeValues.isEmpty ? flatValues : envelopeValues
        guard !values.isEmpty else { throw SettingsProfileError.notAProfile }

        // 名字：标准文件用文件内的名字；扁平文件回退文件名；
        // 两者都空则"导入的配置"。带 name 的手写混合对象也会沿用到这个名字。
        let imported = SettingsProfile(
            id: UUID(),
            name: sanitizedName(envelope?.name ?? "", fallback: fallbackName),
            createdAt: envelope?.createdAt ?? Date(),
            values: values
        )

        try write(imported)
        return imported
    }

    // MARK: - 导出

    /// 把一个配置文件编码成可写进「文件」App 的 JSON 数据。
    ///
    /// 与保存 / 导入共用同一套编码器与同一张字段表，因此：
    /// ① 导出的文件是一份**标准配置文件**，再导入回来必然等价（往返不丢值）；
    /// ② 只含字段表认识的键，与 `all()` 的过滤口径一致——用户看到的「N 项设置」
    ///    和文件里真实可套用的项数是同一个数字。
    static func exportData(for profile: SettingsProfile) throws -> Data {
        var snapshot = profile
        snapshot.values = filterKnown(profile.values)
        return try encoder.encode(snapshot)
    }

    /// 导出时的建议文件名（**不含扩展名**，由系统按 content type 补 `.json`）。
    ///
    /// 用户起的名字里可能带 `/`、`:` 等文件系统非法字符，统一替换掉，
    /// 免得系统保存面板写盘失败或落成意料之外的路径。
    static func exportFileName(for profile: SettingsProfile) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t")
        let cleaned = profile.name
            .components(separatedBy: invalid)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Vellium 配置" : String(cleaned.prefix(60))
    }

    // MARK: 内部

    private static func write(_ profile: SettingsProfile) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try encoder.encode(profile)
        try data.write(to: fileURL(for: profile.id), options: .atomic)
    }

    /// 只保留字段表认识的键。未知键在套用时本来就会被忽略，
    /// 提前滤掉让「N 项设置」这个数字说真话。
    private static func filterKnown(_ values: [String: SettingsProfileValue]) -> [String: SettingsProfileValue] {
        values.filter { SettingsProfileSchema.knownNames.contains($0.key) }
    }

    /// 名字统一口径：去首尾空白；空名用兜底名；截到 40 字符（列表一行放得下）。
    private static func sanitizedName(_ raw: String, fallback: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let effective = trimmed.isEmpty ? fallback : trimmed
        return String(effective.prefix(40))
    }
}

// MARK: - 错误

enum SettingsProfileError: LocalizedError {
    case cannotReadFile
    case notAProfile

    var errorDescription: String? {
        switch self {
        case .cannotReadFile: return "无法读取所选文件，请检查文件是否完整。"
        case .notAProfile:    return "该文件不是有效的 Vellium 配置文件。"
        }
    }
}

// MARK: - 导出文档

/// 供 `fileExporter` 写进「文件」App 的配置文件文档。
///
/// 只承载**已经编码好的 JSON `Data`**：编码逻辑留在 `SettingsProfileStore`，
/// 与保存 / 导入共用同一套编码器，文档自身不做任何转换——导出即原样落盘。
/// 这样「导出的文件能被本 App 再导入回来」这件事由同一条代码路径保证，
/// 不需要在文档层再维护第二份序列化规则。
struct SettingsProfileDocument: FileDocument {

    static var readableContentTypes: [UTType] { [.json] }
    static var writableContentTypes: [UTType] { [.json] }

    var data: Data

    init(data: Data) { self.data = data }

    /// `FileDocument` 协议要求的读入构造。本 App 的导出是单向的（写盘），
    /// 这里只在系统需要回读时兜底，读不到就按损坏文件报错。
    init(configuration: ReadConfiguration) throws {
        guard let contents = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = contents
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
