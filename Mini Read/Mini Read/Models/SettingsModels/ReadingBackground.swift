//
//  ReadingBackground.swift
//  TheNewVellium
//
//  阅读纸面的单一真相源。
//
//  一条链路上的三个环节都放在这里，避免它们各自漂移：
//  1. **预设定义** —— 内置纸纹 / 纯色预置色；
//  2. **解析规则** —— `AppSettings` 的三个字符串字段 → `ReadingBackground`；
//  3. **位图缓存** —— 全 App 只有一份已解码纹理。
//
//  阅读器（UIKit）与设置页（SwiftUI）都只从这里取结论，
//  两边不会因为回退规则写得不一样而出现"设置里是这个色、书里是那个色"。
//

import SwiftUI
import UIKit

// MARK: - 墨色

/// 正文墨色。
///
/// 背景一旦可以自由更换，「正文永远是黑色」就不再成立：
/// 用户挑一张深色纸，黑字会直接消失在纸里。
/// 因此墨色不是固定值，而是**由背景推导出来的属性**：
/// 纯色背景按相对亮度算，纹理背景由预设自己声明。
enum ReadingTextTone: String, CaseIterable, Sendable {
    case dark
    case light

    /// 正文颜色。
    ///
    /// 刻意不用纯黑 / 纯白：书页上的墨本来就带一点灰，
    /// 高对比的纯黑色在长时间阅读时更扎眼。
    var inkColor: UIColor {
        switch self {
        case .dark:  return UIColor(red: 0.106, green: 0.106, blue: 0.118, alpha: 1) // #1B1B1E
        case .light: return UIColor(red: 0.898, green: 0.890, blue: 0.871, alpha: 1) // #E5E3DE
        }
    }

    /// 页眉、页码这类辅助文字：比正文淡一档，拉开层次但不至于看不见。
    var secondaryInkColor: UIColor {
        switch self {
        case .dark:  return UIColor(red: 0.42, green: 0.41, blue: 0.39, alpha: 1)
        case .light: return UIColor(red: 0.63, green: 0.62, blue: 0.60, alpha: 1)
        }
    }

    var swiftUIInk: Color { Color(uiColor: inkColor) }
    var swiftUISecondaryInk: Color { Color(uiColor: secondaryInkColor) }

    /// 阅读页浮动控件（目录 / 书签 / 关闭）的图标墨色。
    ///
    /// 与 `inkColor` 分开是有意的：正文墨刻意带一点灰（长时间阅读不扎眼），
    /// 而这三个图标压在**玻璃材质**上、面积又小，需要的是最高对比的纯黑/纯白，
    /// 否则在深色纸面上会和玻璃一起糊成一片。
    ///
    /// 判定直接复用 `ReadingTextTone`，不再写第二套亮度阈值——纸面明暗在
    /// 全工程只有 `ReadingTextTone(contrastingFor:)` 一个出处。
    var chromeControlInk: Color {
        switch self {
        case .dark:  return .black   // 亮纸面（正文用深墨）→ 黑图标
        case .light: return .white   // 暗纸面（正文用浅墨）→ 白图标
        }
    }

    /// 由纸面颜色推导墨色：用 WCAG 相对亮度做阈值判断。
    ///
    /// 没走「用户自己选文字颜色」那条路，是因为纯色背景的明度是确定的，
    /// 深/浅墨可以无歧义地算出来；让用户手动配，反而容易调出看不清的组合。
    init(contrastingFor hex: String) {
        guard let rgb = UIColor(hex: hex)?.srgbComponents else {
            self = .dark
            return
        }
        let luminance = 0.2126 * Self.linearize(rgb.r)
                      + 0.7152 * Self.linearize(rgb.g)
                      + 0.0722 * Self.linearize(rgb.b)

        // 0.34 大致落在中深灰上：比它暗的纸面一律改用浅墨，
        // 保证「深纸黑字」这种必然读不清的组合不会出现。
        self = luminance < 0.34 ? .light : .dark
    }

    /// sRGB → 线性光，相对亮度公式的前置步骤
    private static func linearize(_ channel: CGFloat) -> CGFloat {
        channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
    }
}

// MARK: - 内置纸面纹理

/// App 自带的纸张纹理预设。
///
/// `rawValue` 直接就是 Assets 里的资源名（含扩展名），
/// 这样持久化的 `readingBackgroundImageSource` 不需要再维护一张映射表。
///
/// 想再加一张纹理：把 imageset 丢进 `Assets.xcassets`，在这里补一个 case 即可，
/// 设置页的网格会自动多出一格。
enum ReadingPaperPreset: String, CaseIterable, Identifiable, Sendable {
    case classic   = "PageBackground2.jpg"
    case parchment = "PaperParchment.jpg"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .classic:   return "经典纸纹"
        case .parchment: return "羊皮纸"
        }
    }

    /// 这张纸面上正文该用哪种墨色。
    ///
    /// 纹理是设计期定好的，明度已知，运行时不必逐张采样——
    /// 采样意味着"首帧先按默认墨色渲染、算完再改"，那会在书页上闪一下。
    var textTone: ReadingTextTone {
        switch self {
        case .classic, .parchment: return .dark
        }
    }

    /// 纹理未就绪或加载失败时的兜底色，取纹理的整体色相。
    ///
    /// 必须与纹理色一致：翻页时相邻两页若一页是纹理、一页是兜底色，
    /// 底色偏了就会看到明显的"闪色"。
    var fallbackColorHex: String {
        switch self {
        case .classic:   return "#F8F2E8"
        case .parchment: return "#E0C99F"
        }
    }
}

// MARK: - 纯色预置色

/// 纯色纸面的预置色。
///
/// 明度刻意拉开梯度（近白 → 暖纸 → 冷灰 → 夜黑），
/// 顺带让「自动配墨色」这条规则在设置页里看得见：
/// 选到「夜读」，预览里的字会当场翻成浅色。
struct ReadingSolidPreset: Identifiable, Hashable, Sendable {
    let hex: String
    let name: String

    var id: String { hex }

    static let all: [ReadingSolidPreset] = [
        ReadingSolidPreset(hex: "#FFFFFF", name: "净白"),
        ReadingSolidPreset(hex: "#F8F2E8", name: "米白"),
        ReadingSolidPreset(hex: "#EFE3CB", name: "宣纸"),
        ReadingSolidPreset(hex: "#DCE4D3", name: "松绿"),
        ReadingSolidPreset(hex: "#D9DEE8", name: "雾蓝"),
        ReadingSolidPreset(hex: "#1B1B1E", name: "夜读")
    ]

    var color: Color { Color(hex: hex) ?? .white }
}

// MARK: - 出厂默认

/// 阅读背景的出厂默认值。
///
/// 与 `AppSettings` 属性声明里的初值必须一致；
/// `resetToDefaults()` 与本地重置都从这里取值，避免两处各写一遍。
enum ReadingBackgroundDefaults {
    static let mode     = ReadingBackgroundMode.solidColor
    static let colorHex = "#F8F2E8"
    static let paper    = ReadingPaperPreset.classic
}

// MARK: - 解析后的背景

/// 解析完成的阅读背景：阅读器只需要认识这一个类型。
enum ReadingBackground: Hashable, Sendable {

    /// 纯色纸面
    case color(hex: String)

    /// 内置纹理纸面
    case paper(ReadingPaperPreset)

    /// 该背景对应的正文墨色
    var textTone: ReadingTextTone {
        switch self {
        case .color(let hex):    return ReadingTextTone(contrastingFor: hex)
        case .paper(let preset): return preset.textTone
        }
    }

    /// 页面填充色。图片模式下这是纹理就绪前的兜底色。
    ///
    /// 页面**必须始终不透明**：`UIPageViewController` 的 `.pageCurl` 转场
    /// 会把相邻页合成到同一层级，透明页会漏出底层黑底。
    var fillColor: UIColor {
        switch self {
        case .color(let hex):    return UIColor(hex: hex) ?? .white
        case .paper(let preset): return UIColor(hex: preset.fallbackColorHex) ?? .white
        }
    }

    var paperPreset: ReadingPaperPreset? {
        if case .paper(let preset) = self { return preset }
        return nil
    }
}

// MARK: - 位图缓存

/// 阅读背景位图的唯一入口。
///
/// 为什么不交给每个 `PageBackgroundView` 各自 `UIImage(named:)`：
/// 一次翻页同时存在 3~5 个页面，纹理若每页各自解码，
/// `pageCurl` 转场会明显掉帧（转场期间所有相邻页都要合成）。
/// 这里保证全 App 只有一份已解码位图，各页共享同一个 `UIImage` 实例。
final class ReadingBackgroundImageLoader {

    static let shared = ReadingBackgroundImageLoader()

    /// 单页纹理的分辨率上限。
    ///
    /// 纸纹是柔和的大面积图案，超过屏幕实际需要只是让图层纹理成倍变大：
    /// 2048 已足够覆盖 12.9" iPad 的短边，再往上肉眼分辨不出。
    static let pagePixelDimension: CGFloat = 2048

    /// 设置页缩略图尺寸：不该为了 100pt 的卡片把整张 2K 纹理解出来。
    static let thumbnailPixelDimension: CGFloat = 320

    private struct CacheKey: Hashable {
        let preset: ReadingPaperPreset
        let dimension: Int
    }

    /// `NSCache` 而不是字典：收到内存警告时会自行回收，不会把纹理死死攥住。
    private let cache = NSCache<NSString, UIImage>()
    private let queue = DispatchQueue(label: "com.vellium.reading-background.image", qos: .userInitiated)

    private init() {
        cache.countLimit = 6
    }

    // MARK: 取图

    /// 同步取图。首次调用会付一次性解码成本，之后 O(1) 命中。
    func image(
        for preset: ReadingPaperPreset,
        pixelDimension: CGFloat = ReadingBackgroundImageLoader.pagePixelDimension
    ) -> UIImage? {
        queue.sync { decodedImage(for: preset, pixelDimension: pixelDimension) }
    }

    /// 异步取图，供 SwiftUI 视图使用，不阻塞主线程。
    func imageAsync(
        for preset: ReadingPaperPreset,
        pixelDimension: CGFloat = ReadingBackgroundImageLoader.pagePixelDimension
    ) async -> UIImage? {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: self.decodedImage(for: preset, pixelDimension: pixelDimension))
            }
        }
    }

    /// 提前解码。
    ///
    /// 切纸面时调用：让真正的建页发生在缓存命中之后，
    /// 而不是在主线程上一边建页一边解 2K 位图。
    func prewarm(
        _ preset: ReadingPaperPreset,
        pixelDimension: CGFloat = ReadingBackgroundImageLoader.pagePixelDimension
    ) {
        queue.async { _ = self.decodedImage(for: preset, pixelDimension: pixelDimension) }
    }

    // MARK: 私有（只在 queue 上执行）

    private func decodedImage(for preset: ReadingPaperPreset, pixelDimension: CGFloat) -> UIImage? {
        let key = CacheKey(preset: preset, dimension: Int(pixelDimension))
        let cacheKey = "\(key.preset.rawValue)#\(key.dimension)" as NSString

        if let hit = cache.object(forKey: cacheKey) { return hit }

        guard let decoded = load(preset: preset, pixelDimension: pixelDimension) else { return nil }
        cache.setObject(decoded, forKey: cacheKey)
        return decoded
    }

    private func load(preset: ReadingPaperPreset, pixelDimension: CGFloat) -> UIImage? {
        guard let source = UIImage(named: preset.rawValue) else { return nil }

        // 只降不升：源图比目标还小时不做无意义的放大处理
        let longestSide = max(source.size.width, source.size.height) * source.scale
        let scaled: UIImage
        if longestSide > pixelDimension {
            scaled = source.preparingThumbnail(of: CGSize(width: pixelDimension, height: pixelDimension)) ?? source
        } else {
            scaled = source
        }

        // preparingThumbnail 走 ImageIO 的降采样通道，只解出需要的分辨率；
        // preparingForDisplay 再把位图真正解码展平，避免首次上屏时在渲染线程上解码。
        return scaled.preparingForDisplay() ?? scaled
    }
}

// MARK: - AppSettings → 背景

extension AppSettings {

    /// 解析后的阅读背景。**阅读器与设置页都必须走这里**，
    /// 不要各自 `ReadingPaperPreset(rawValue:)` 再各自写一套回退。
    var readingBackground: ReadingBackground {
        switch ReadingBackgroundMode(rawValue: readingBackgroundMode) {
        case .image:
            // 历史数据里可能是没有扩展名的 "PageBackground2"，
            // 解析不到就回到默认纸纹——结果与旧版本的行为一致。
            let preset = ReadingPaperPreset(rawValue: readingBackgroundImageSource)
                ?? ReadingBackgroundDefaults.paper
            return .paper(preset)

        default:
            return .color(hex: readingBackgroundColorHex)
        }
    }

    /// 解析后的正文墨色
    var readingTextTone: ReadingTextTone { readingBackground.textTone }

    /// 阅读器外围系统界面（状态栏、目录面板、加载指示器）的配色方案。
    ///
    /// 刻意与纸面明暗**相反**：亮纸面配深色系统界面、暗纸面配浅色系统界面，
    /// 让书页在外围 UI 上形成强对比。这是项目既定的设计取向而非笔误——
    /// 若要改成"系统界面跟随纸面明暗"，把下面两个 case 的返回值对调即可。
    ///
    /// 放在这里而不是在阅读器里硬编码，是为了让映射只此一处：
    /// 纸面明暗判定直接复用 `readingTextTone`，不必再写第二套亮度阈值。
    var readerChromeColorScheme: ColorScheme {
        switch readingTextTone {
        case .dark:  return .light   // 亮纸面（正文用深墨）→ 深色系统界面
        case .light: return .dark  // 暗纸面（正文用浅墨）→ 浅色系统界面
        }
    }

    /// 「阅读背景」页的局部重置：只还原纸面，不动排印 / 翻页 / 同步等偏好。
    ///
    /// 与 `resetTypographyToDefaults()` 同构——在一个子页里静默改掉别的偏好很突兀。
    func resetReadingBackgroundToDefaults() {
        readingBackgroundMode        = ReadingBackgroundDefaults.mode.rawValue
        readingBackgroundColorHex    = ReadingBackgroundDefaults.colorHex
        readingBackgroundImageSource = ReadingBackgroundDefaults.paper.rawValue
    }
}

// MARK: - 颜色工具

extension UIColor {

    /// 十六进制解析，与 `Color(hex:)` 同一套规则（仅 6 / 8 位，8 位按 RRGGBBAA）。
    ///
    /// UIKit 侧的页面背景拿不到 SwiftUI 的 `Color`，因此需要一份等价的解析。
    convenience init?(hex: String) {
        var sanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        sanitized = sanitized.replacingOccurrences(of: "#", with: "")

        var value: UInt64 = 0
        guard !sanitized.isEmpty, Scanner(string: sanitized).scanHexInt64(&value) else { return nil }

        switch sanitized.count {
        case 6:
            self.init(red:   CGFloat((value & 0xFF0000) >> 16) / 255,
                      green: CGFloat((value & 0x00FF00) >> 8)  / 255,
                      blue:  CGFloat( value & 0x0000FF)        / 255,
                      alpha: 1)
        case 8:
            self.init(red:   CGFloat((value & 0xFF000000) >> 24) / 255,
                      green: CGFloat((value & 0x00FF0000) >> 16) / 255,
                      blue:  CGFloat((value & 0x0000FF00) >> 8)  / 255,
                      alpha: CGFloat( value & 0x000000FF)        / 255)
        default:
            return nil
        }
    }

    /// sRGB 分量。非 RGB 色彩空间（灰度、CMYK）会通过 ColorSync 先转换，转换失败返回 nil。
    var srgbComponents: (r: CGFloat, g: CGFloat, b: CGFloat)? {
        let converted = cgColor.converted(
            to: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            intent: .defaultIntent,
            options: nil
        ) ?? cgColor

        guard let components = converted.components, components.count >= 3 else { return nil }
        return (components[0], components[1], components[2])
    }

    /// 转成 `#RRGGBB`。
    ///
    /// 没有直接用 `Color.toHex()`：取色盘在某些面板下给出的是灰度或 P3 空间的颜色，
    /// 那条路径会返回 nil，表现就是"选了自定义颜色但纸面没变"。
    var srgbHexString: String? {
        guard let components = srgbComponents else { return nil }
        return String(format: "#%02lX%02lX%02lX",
                      lroundf(Float(components.r) * 255),
                      lroundf(Float(components.g) * 255),
                      lroundf(Float(components.b) * 255))
    }
}

// MARK: - 时序

enum ReadingBackgroundTiming {
    /// 背景设置同步给阅读器的尾随去抖窗口。
    ///
    /// 取色盘是连续事件，一次拖动能产生几十次变更；设置页用这个时长做尾随去抖，
    /// 避免阅读器跟着反复整章重排（阅读器侧另有 0.35s 的合并窗口）。
    static let changeDebounceNanoseconds: UInt64 = 500_000_000
}
