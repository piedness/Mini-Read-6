//
//  settingmodel.swift
//  vellium1218
//
//  Created by Max Piednes on 2026/2/15.
//

import SwiftUI
import SwiftData



// MARK: - SwiftData Models

@Model
final class AppSettings {
    // 1. 阅读体验 - 文字排版
    var fontFamily: String = "LXGWWenKai"
    var fontSize: Double = 28.0
    var lineSpacing: Double = 20
    var paragraphSpacing: Double = 30
    var letterSpacing: Double = 0.0
    var marginTop: Double = 110.0
    var marginBottom: Double = 85.0
    var marginLeft: Double = 40.0
    var marginRight: Double = 40.0
    var textAlignment: String = "justified"
    var firstLineIndent: Bool = true

    // 1. 阅读体验 - 主题与色彩
    var currentTheme: String = "default"
    var customBackgroundColor: String = "#FFFFFF"
    var customTextColor: String = "#000000"
    var customLinkColor: String = "#007AFF"
    var customSelectionColor: String = "#FFD700"
    var followSystemAppearance: Bool = true

    // 1. 阅读体验 - 阅读背景扩展
    //    取值与回退规则统一收在 ReadingBackground.swift，这里只做持久化。
    //    imageSource 存的是 Assets 资源名（含扩展名）；旧数据里的 "PageBackground2"
    //    会在解析时回退到默认纸纹，因此升级后行为不变。
    var readingBackgroundMode: String = "color"
    var readingBackgroundColorHex: String = "#F8F2E8"
    var readingBackgroundImageSource: String = "PageBackground2.jpg"

    // 1. 阅读体验 - 翻页与交互
    var pageTransitionStyle: String = "slide"
    var volumeKeysTurn: Bool = false

    // 1. 阅读体验 - 阅读辅助
    //
    // 页码与章节标题是两个**独立**元素：页码固定在底部（水平可选偏左/中/右）、
    // 标题固定在顶部（水平可选偏左/中/右），两者可同时显示。
    // 值域与归一规则见 `ReaderChrome`。
    var showPageNumber: Bool = true
    /// 页码水平位置：bottom left | bottom center | bottom right
    var pageNumberPosition: String = "bottom center"
    /// 页码格式：book（当前页码/整书页数）| chapter（本章页码/本章页数）
    var pageNumberFormat: String = "book"
    var showChapterTitle: Bool = false
    /// 标题水平位置：top left | top center | top right
    var chapterTitlePosition: String = "top center"
    var autoHideToolbar: Bool = true
    var toolbarHideDelay: Double = 3.0 
    var keepScreenOn: Bool = true

    // 2. 书库管理 - 视图与组织
    var libraryViewMode: String = "grid"
    var listViewStyle: String = "standard"
    // 默认值取「添加时间（最新）」而非「最近阅读」：前者是书架原本就有的顺序
    // （见 BookCardFlowView 的 @Query），接上排序偏好后视觉不发生跳变；
    // 后者对从未打开过的书没有意义，做默认会让新导入的书沉到底部。
    // 取值集合见 `LibrarySortOption`。
    var sortBy: String = "dateAddedNew"

    // 2. 书库管理 - 导入与格式
    /// 取值见 `DuplicateHandling`：`skip`（默认）| `keepBoth`。
    /// 历史值 `overwrite` 已废弃，读取端把无法识别的值一律按 `skip` 处理。
    var duplicateHandling: String = "skip"

    // 2. 书库管理 - 存储管理
    var storageLocation: String = "local"
    var cacheSizeLimit: Int = 500
    var preloadPages: Int = 5
    var imageCacheQuality: String = "standard"
    var autoCleanCache: Bool = true

    // 3. 笔记与标注 - 高亮与标注
    var defaultHighlightColor: String = "yellow"
    var highlightOpacity: Double = 0.3
    var defaultAnnotationStyle: String = "highlight"
    var longPressAction: String = "highlight"
    var doubleTapAction: String = "select"
    var showNoteIndicators: Bool = true

    // 3. 笔记与标注 - 笔记系统
    var noteDisplayPosition: String = "sidebar"
    var noteBubbleStyle: String = "standard"
    var showNoteCount: Bool = true

    // 3. 笔记与标注 - 导出与分享
    var exportFormat: String = "markdown"
    var includeOriginalText: Bool = true
    var includeMetadata: Bool = true
    var exportByChapter: Bool = false
    var watermarkEnabled: Bool = false
    var watermarkText: String = ""

    // 5. 同步与备份
    var iCloudSync: Bool = true
    var syncProgress: Bool = true
    var syncBookmarks: Bool = true
    var syncNotes: Bool = true
    var syncSettings: Bool = true
    var syncBooks: Bool = false
    var syncFrequency: String = "realtime"
    var syncOnWiFiOnly: Bool = true
    var conflictResolution: String = "manual"
    var autoBackup: Bool = true
    var backupFrequency: String = "weekly"
    var backupLocation: String = "icloud"

    // 8. 隐私与安全
    var hideReadingHistory: Bool = false
    var enablePrivateShelf: Bool = false

    // 10. 系统设置
    var appLanguage: String = "system"
    var dateFormat: String = "system"
    var hapticFeedback: Bool = true
    var developerMode: Bool = false
    
    
    // 个性化 - App 外观扩展
    var appTintColorHex: String = "#6B7280"
    var appBackgroundMode: String = "image"
    var appBackgroundColorHex: String = "#242424"
    var appBackgroundGradientStartHex: String = "#F8FAFF"
    var appBackgroundGradientEndHex: String = "#E2E9F7"
    var appBackgroundImageSource: String = "AppBG.jpg"
    var maxImageCacheCount: Int = 5
    
    var appBackgroundColorHex_Dark: String = "#242424"
    var appBackgroundGradientStartHex_Dark: String = "#F8FAFF"
    var appBackgroundGradientEndHex_Dark: String = "#E2E9F7"
    
    // ⚠️ 给本类新增持久化属性后，必须同步在文件末尾 AppSettings.resetToDefaults() 里补一行，
    //    否则「通用设置 → 恢复默认设置」会悄悄漏掉该项。
    init() {}
}

// MARK: - Enums

enum ReadingTheme: String, CaseIterable {
    case defaultLight = "default"
    case night = "night"
    case sepia = "sepia"
    case parchment = "parchment"
    case green = "green"

    var displayName: String {
        switch self {
        case .defaultLight: return "白天"
        case .night: return "夜间"
        case .sepia: return "护眼"
        case .parchment: return "羊皮纸"
        case .green: return "护眼绿"
        }
    }

    var backgroundColor: Color {
        switch self {
        case .defaultLight: return .white
        case .night: return Color(red: 0.1, green: 0.1, blue: 0.1)
        case .sepia: return Color(red: 0.98, green: 0.96, blue: 0.89)
        case .parchment: return Color(red: 0.96, green: 0.94, blue: 0.87)
        case .green: return Color(red: 0.78, green: 0.84, blue: 0.71)
        }
    }

    var textColor: Color {
        switch self {
        case .defaultLight, .sepia, .parchment, .green: return .black
        case .night: return Color(red: 0.9, green: 0.9, blue: 0.9)
        }
    }
}


enum ReadingBackgroundMode: String, CaseIterable, Identifiable {
    case solidColor = "color"
    case image = "image"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .solidColor: return "纯色"
        case .image: return "纸张纹理"
        }
    }
}

// MARK: - Duplicate Handling

/// 导入重复书籍时的处理方式。
///
/// `rawValue` 与 `AppSettings.duplicateHandling` 的持久化值一一对应，
/// 设置页 Picker 的 tag 也直接取自这里，避免"枚举改了、tag 没改"这种静默错位
/// （那种错位的表现是：用户点了没反应，或者 Picker 停在空行）。
///
/// 这里刻意不再提供「覆盖」：删掉旧书会连它的书签与阅读进度一起带走，
/// 而重复导入通常只是用户忘了自己已经加过这本书——代价远高于收益。
enum DuplicateHandling: String, CaseIterable, Identifiable, Sendable {

    /// 已在书库中就不重复添加（默认）。
    case skip

    /// 两本都留在书架上，各自独立。
    case keepBoth

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .skip:     return "跳过"
        case .keepBoth: return "保留两者"
        }
    }
}

// MARK: - Reading Font Family

/// FontFamily → 真实 UIFont/SwiftUI Font 的唯一解析入口。
enum FontFamily: String, CaseIterable, Sendable {
    case system     = "系统默认"
    case songti     = "宋体"
    case heiti      = "黑体"
    case LXGWWenKai = "LXGWWenKai"

    /// 设置里展示用的名字（比 PostScript 名友好）
    var displayName: String {
        switch self {
        case .system:     return "系统默认"
        case .songti:     return "宋体"
        case .heiti:      return "黑体"
        case .LXGWWenKai: return "霞鹜文楷"
        }
    }

    /// PostScript 候选名，按优先级排列。
    ///
    /// iOS 各版本 / 设备的可用字体并不一致：`STHeiti` 系列不是公开可用的 API，
    /// `LXGWWenKai-Medium` 依赖 Info.plist 的 UIAppFonts 注册成功。
    /// 逐个尝试、命中即用，全部落空则回退系统字体——正文绝不允许渲染不出来。
    private var candidateFontNames: [String] {
        switch self {
        case .system:     return []
        case .songti:     return ["STSongti-SC-Regular", "SongtiSC-Regular", "Songti SC"]
        case .heiti:      return ["PingFangSC-Regular", "Heiti SC", "STHeitiSC-Light"]
        case .LXGWWenKai: return ["LXGWWenKai-Medium", "LXGWWenKai"]
        }
    }

    /// 当前设备上真实可用的字体名；系统字体返回 nil
    var resolvedFontName: String? {
        candidateFontNames.first { UIFont(name: $0, size: UIFont.systemFontSize) != nil }
    }

    /// UIKit 侧入口：阅读器正文、章节标题、页码统一走这里，保证三处字体永远一致
    func uiFont(ofSize size: CGFloat) -> UIFont {
        guard let name = resolvedFontName else { return .systemFont(ofSize: size) }
        return UIFont(name: name, size: size) ?? .systemFont(ofSize: size)
    }

    /// SwiftUI 侧入口：设置预览与选项行用同一套解析，保证预览不说谎
    func swiftUIFont(ofSize size: CGFloat) -> Font {
        guard let name = resolvedFontName else { return .system(size: size) }
        return .custom(name, size: size)
    }
}

extension ModelContext {

    /// 全 App 唯一的 AppSettings 实例。**所有读写设置的地方都必须走这里。**
    ///
    /// 为什么必须有这个入口：原先有四处各自写着「fetch 为空就 insert 一行」。
    /// 首帧渲染时 `@Query` 还没回填，这四处会依次各自判断为空并各插一行，
    /// 于是库里躺着多行 AppSettings；而读取方用的是**无排序**的 `fetch().first`，
    /// 谁排第一不确定——写进去的可能不是被读的那一行，
    /// 表现就是"设置改了、书里纹丝不动"。
    ///
    /// 本方法做三件事：
    /// 1. 优先复用本 context 事务里已 insert 但尚未落盘的实例，杜绝同帧重复创建；
    /// 2. 落盘行存在则直接返回；
    /// 3. 顺手**收敛历史脏数据**：重复行删除多余、只留最早那行，
    ///    老用户升级后自动修复，无需清库。
    func appSettings() -> AppSettings {
        // 1. 本次事务里已经建过
        for model in insertedModelsArray {
            if let settings = model as? AppSettings { return settings }
        }

        // 2. 已经落盘的
        let persisted = (try? fetch(FetchDescriptor<AppSettings>())) ?? []

        guard let first = persisted.first else {
            let created = AppSettings()
            insert(created)
            return created
        }

        // 3. 自愈：重复行一律是出厂默认值，真正的用户改动都在最早那行上。
        //    删完后广播一次，让持有旧实例的阅读器重新解析。
        if persisted.count > 1 {
            print("⚠️ 发现 \(persisted.count) 条 AppSettings 记录，已收敛为 1 条")
            persisted.dropFirst().forEach(delete)
            try? save()
            NotificationCenter.default.post(name: .appSettingsDidChange, object: nil)
        }

        return first
    }
}

// MARK: - 恢复默认设置

extension AppSettings {

    /// 「文字排版」页的局部重置：只还原排印相关项，主题 / 书库 / 同步等一概不动。
    ///
    /// 这里的每一项都与 `TypographySettingsView` 上能直接调到的控件一一对应，
    /// 因此该页的「恢复默认设置」走这里，而不是全量重置——
    /// 在一个子页里静默改掉 iCloud 同步之类的偏好会很突兀。
    func resetTypographyToDefaults() {
        fontFamily       = FontFamily.LXGWWenKai.rawValue
        fontSize         = 28.0
        lineSpacing      = 20
        paragraphSpacing = 30
        letterSpacing    = 0.0
        marginTop        = 110.0
        marginBottom     = 85.0
        marginLeft       = 40.0
        marginRight      = 40.0
        textAlignment    = "justified"
        firstLineIndent  = true
    }

    /// 全量还原出厂默认值。目前只有「通用设置 → 恢复默认设置」调用。
    ///
    /// - Important: **新增持久化属性时必须在这里补一行赋值**。赋值顺序刻意镜像
    ///   `AppSettings` 的属性声明顺序，方便两边对照 review。漏写一项的表现是
    ///   「点了恢复默认，只有这一项纹丝不动」，在 UI 上几乎不可能被发现。
    ///
    /// - Note: 就地写回而不是「删掉重建一行」：`MainViewController.cachedSettings`
    ///   持有本实例，对象一旦被删除，后续再访问其属性会触发 SwiftData 的
    ///   deleted-object 断言，直接崩在阅读器里。
    ///
    /// - Note: 本方法只写内存值，不 `save()`、不发 `appSettingsDidChange`；
    ///   合并成一次落盘 + 一次重排广播是调用方的职责。
    func resetToDefaults() {
        // 1. 阅读体验 - 文字排版
        resetTypographyToDefaults()

        // 1. 阅读体验 - 主题与色彩
        currentTheme          = "default"
        customBackgroundColor = "#FFFFFF"
        customTextColor       = "#000000"
        customLinkColor       = "#007AFF"
        customSelectionColor  = "#FFD700"
        followSystemAppearance = true

        // 1. 阅读体验 - 阅读背景扩展
        readingBackgroundMode        = ReadingBackgroundDefaults.mode.rawValue
        readingBackgroundColorHex    = ReadingBackgroundDefaults.colorHex
        readingBackgroundImageSource = ReadingBackgroundDefaults.paper.rawValue

        // 1. 阅读体验 - 翻页与交互
        pageTransitionStyle = "slide"
        volumeKeysTurn      = false

        // 1. 阅读体验 - 阅读辅助（页码在底部偏中、整书口径；标题默认不显示）
        showPageNumber       = true
        pageNumberPosition   = "bottom center"
        pageNumberFormat     = "book"
        showChapterTitle     = false
        chapterTitlePosition = "top center"
        autoHideToolbar      = true
        toolbarHideDelay     = 3.0
        keepScreenOn         = true

        // 2. 书库管理 - 视图与组织
        libraryViewMode   = "grid"
        listViewStyle     = "standard"
        sortBy            = "dateAddedNew"

        // 2. 书库管理 - 导入与格式
        duplicateHandling = "skip"

        // 2. 书库管理 - 存储管理
        storageLocation   = "local"
        cacheSizeLimit    = 500
        preloadPages      = 5
        imageCacheQuality = "standard"
        autoCleanCache    = true

        // 3. 笔记与标注 - 高亮与标注
        defaultHighlightColor  = "yellow"
        highlightOpacity       = 0.3
        defaultAnnotationStyle = "highlight"
        longPressAction        = "highlight"
        doubleTapAction        = "select"
        showNoteIndicators     = true

        // 3. 笔记与标注 - 笔记系统
        noteDisplayPosition = "sidebar"
        noteBubbleStyle     = "standard"
        showNoteCount       = true

        // 3. 笔记与标注 - 导出与分享
        exportFormat        = "markdown"
        includeOriginalText = true
        includeMetadata     = true
        exportByChapter     = false
        watermarkEnabled    = false
        watermarkText       = ""

        // 5. 同步与备份
        iCloudSync         = true
        syncProgress       = true
        syncBookmarks      = true
        syncNotes          = true
        syncSettings       = true
        syncBooks          = false
        syncFrequency      = "realtime"
        syncOnWiFiOnly     = true
        conflictResolution = "manual"
        autoBackup         = true
        backupFrequency    = "weekly"
        backupLocation     = "icloud"

        // 8. 隐私与安全
        hideReadingHistory = false
        enablePrivateShelf = false

        // 10. 系统设置
        appLanguage    = "system"
        dateFormat     = "system"
        hapticFeedback = true
        developerMode  = false

        // 个性化 - App 外观扩展
        appTintColorHex               = "#6B7280"
        appBackgroundMode             = "image"
        appBackgroundColorHex         = "#242424"
        appBackgroundGradientStartHex = "#F8FAFF"
        appBackgroundGradientEndHex   = "#E2E9F7"
        appBackgroundImageSource      = "AppBG.jpg"
        maxImageCacheCount            = 5

        appBackgroundColorHex_Dark         = "#242424"
        appBackgroundGradientStartHex_Dark = "#F8FAFF"
        appBackgroundGradientEndHex_Dark   = "#E2E9F7"
    }
}


// MARK: - Notification Names

extension Notification.Name {
    static let appSettingsDidChange = Notification.Name("AppSettingsDidChange")
}



extension Color {
    // Hex String -> Color
    init?(hex: String) {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")

        var rgb: UInt64 = 0

        guard Scanner(string: hexSanitized).scanHexInt64(&rgb) else { return nil }

        let length = hexSanitized.count
        let r, g, b, a: CGFloat
        if length == 6 {
            r = CGFloat((rgb & 0xFF0000) >> 16) / 255.0
            g = CGFloat((rgb & 0x00FF00) >> 8) / 255.0
            b = CGFloat(rgb & 0x0000FF) / 255.0
            a = 1.0
        } else if length == 8 {
            r = CGFloat((rgb & 0xFF000000) >> 24) / 255.0
            g = CGFloat((rgb & 0x00FF0000) >> 16) / 255.0
            b = CGFloat((rgb & 0x0000FF00) >> 8) / 255.0
            a = CGFloat(rgb & 0x000000FF) / 255.0
        } else {
            return nil
        }

        self.init(red: r, green: g, blue: b, opacity: a)
    }

    // Color -> Hex String
    func toHex(alpha: Bool = false) -> String? {
        guard let components = cgColor?.components, components.count >= 3 else {
            return nil
        }

        let r = Float(components[0])
        let g = Float(components[1])
        let b = Float(components[2])
        var a = Float(1.0)

        if components.count >= 4 {
            a = Float(components[3])
        }

        if alpha {
            return String(format: "#%02lX%02lX%02lX%02lX", lroundf(r * 255), lroundf(g * 255), lroundf(b * 255), lroundf(a * 255))
        } else {
            return String(format: "#%02lX%02lX%02lX", lroundf(r * 255), lroundf(g * 255), lroundf(b * 255))
        }
    }
}
