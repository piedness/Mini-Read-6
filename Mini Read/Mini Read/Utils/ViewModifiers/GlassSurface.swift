//
//  GlassSurface.swift
//  TheNewVellium
//
//  「玻璃表面」的唯一出处。
//
//  ## 为什么要有这一层
//  iOS 26 的 Liquid Glass（`glassEffect(_:in:)`）在 iOS 18 上并不存在，
//  直接调用连编译都过不了。本文件把「玻璃」收成一个语义化修饰器：
//
//  - **iOS 26+**：原样转交 `glassEffect`，视觉与系统完全一致；
//  - **iOS 18–25**：退化为系统材质（Material）+ 发丝边 + 极淡投影。
//
//  这样做而不是在每个调用点写 `if #available`：玻璃出现在卡片、菜单按钮、
//  阅读页浮动控件、翻页转场等七处，散着写必然漂移——有的地方漏了圆角、
//  有的地方少了一层边，最后变成七种「差不多的玻璃」。
//
//  ## 退化时为什么不直接 `.background(.regularMaterial)`
//  材质按 `colorScheme` 解析，而阅读页的 chrome 配色刻意与纸面**相反**
//  （见 `AppSettings.readerChromeColorScheme`）：亮纸面上环境是深色，
//  材质会解析成一块深色圆盘，可图标是黑的——两者一起糊掉。所以「表面明暗」
//  必须由调用方用 `tone` 显式给出，不能交给环境推断。
//

import SwiftUI

// MARK: - 语义

/// 玻璃表面的两种质感，对齐 `Glass` 的 `.regular` / `.clear`。
enum GlassSurfaceStyle: Sendable {
    /// 常规玻璃：有实体感、磨砂明显。用于卡片、菜单按钮这类「浮在内容上」的面。
    case regular

    /// 清透玻璃：几乎透明，只留一层薄霜与边缘。用于压在正文上的浮动控件。
    case clear
}

/// 玻璃**压在什么明暗的内容上**。
///
/// 不是「玻璃自己是什么颜色」——玻璃本身是半透明的，说的是它底下那层内容的明暗，
/// 以及因此玻璃该往哪一侧配平，才能和前景图标拉开对比。
enum GlassSurfaceTone: Sendable {
    /// 跟随当前环境（默认）。App 强制深色时即深色玻璃，适合普通页面。
    case automatic

    /// 浅色玻璃：压在亮色内容上，配深色前景。
    case light

    /// 深色玻璃：压在暗色内容上，配浅色前景。
    case dark
}

// MARK: - 修饰器

extension View {

    /// 给视图铺一层玻璃表面。
    ///
    /// - Parameters:
    ///   - style: 质感，见 `GlassSurfaceStyle`。
    ///   - tone: 表面明暗。只有在环境配色与背景明暗不一致时才需要显式给值。
    ///   - interactive: 是否带按压反馈。iOS 26 交给 `.interactive()` 玻璃；
    ///     iOS 18 的材质没有这层反馈，需要按压感的按钮请配合 `GlassPressButtonStyle`。
    ///   - shape: 玻璃的形状，同时决定裁切轮廓。
    @ViewBuilder
    func glassSurface<S: InsettableShape>(
        _ style: GlassSurfaceStyle = .regular,
        tone: GlassSurfaceTone = .automatic,
        interactive: Bool = false,
        in shape: S
    ) -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(nativeGlass(style, interactive: interactive), in: shape)
        } else {
            modifier(LegacyGlassSurface(style: style, tone: tone, shape: shape))
        }
    }

    /// 把语义质感翻译成系统的 `Glass`。只在 iOS 26 分支里被求值。
    @available(iOS 26.0, *)
    private func nativeGlass(_ style: GlassSurfaceStyle, interactive: Bool) -> Glass {
        let base: Glass = style == .clear ? .clear : .regular
        return interactive ? base.interactive() : base
    }
}

// MARK: - iOS 18–25 的退化实现

/// 用系统材质模拟玻璃。
///
/// 只做三件事：铺材质、描一圈发丝边、给一层极淡投影。刻意**不**做折射、
/// 高光、模糊半径之类的自绘——那既追不平 Liquid Glass，又会在滚动时
/// 触发额外的离屏渲染。
private struct LegacyGlassSurface<S: InsettableShape>: ViewModifier {

    let style: GlassSurfaceStyle
    let tone: GlassSurfaceTone
    let shape: S

    func body(content: Content) -> some View {
        content
            // 玻璃是"背景效果"：`glassEffect` 画在内容之下，这里同样只垫背景，
            // 不改布局、不盖住内容。
            .background {
                surface
                    .shadow(color: shadow.color, radius: shadow.radius, y: shadow.y)
            }
            .overlay {
                shape.strokeBorder(edgeColor, lineWidth: 0.5)
            }
    }

    // MARK: 材质

    private var material: Material {
        switch style {
        case .regular: return .regularMaterial
        case .clear:   return .ultraThinMaterial
        }
    }

    @ViewBuilder
    private var surface: some View {
        switch tone {
        case .automatic:
            shape.fill(material)
        case .light:
            tintedSurface(Color.white.opacity(tintOpacity), scheme: .light)
        case .dark:
            tintedSurface(Color.black.opacity(tintOpacity), scheme: .dark)
        }
    }

    /// 材质 + 一层同色薄染，并把 `colorScheme` 钉在指定侧。
    ///
    /// 薄染是**对比度保险**：材质跟随环境配色解析，万一某代系统上解析结果与预期
    /// 相反，这层染色仍能把表面推向图标的反侧，不至于出现「黑图标压深色盘」。
    private func tintedSurface(_ tint: Color, scheme: ColorScheme) -> some View {
        ZStack {
            shape.fill(material)
            shape.fill(tint)
        }
        .environment(\.colorScheme, scheme)
    }

    private var tintOpacity: Double {
        style == .clear ? 0.20 : 0.14
    }

    // MARK: 边与影

    private var edgeColor: Color {
        switch tone {
        case .light:     return Color.black.opacity(0.10)
        case .dark:      return Color.white.opacity(0.18)
        case .automatic: return Color.primary.opacity(0.10)
        }
    }

    private var shadow: (color: Color, radius: CGFloat, y: CGFloat) {
        switch style {
        case .regular: return (.black.opacity(0.20), 12, 4)
        case .clear:   return (.black.opacity(0.12), 6, 2)
        }
    }
}

// MARK: - 按压反馈

/// 玻璃按钮的按压反馈。
///
/// iOS 26 的 `.interactive()` 玻璃自带缩放与高光，这里必须保持**无动作**，
/// 否则会和系统反馈叠加成"按两下"。iOS 18 的系统材质没有这层反馈，
/// 于是补一个克制的缩放——阅读页三个浮动按钮是主操作，按下去毫无反应
/// 会让人怀疑是不是没点中。
struct GlassPressButtonStyle: ButtonStyle {

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(scale(configuration))
            .opacity(opacity(configuration))
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }

    private func scale(_ configuration: Configuration) -> CGFloat {
        guard #available(iOS 26.0, *) else {
            return configuration.isPressed ? 0.94 : 1
        }
        return 1
    }

    private func opacity(_ configuration: Configuration) -> Double {
        guard #available(iOS 26.0, *) else {
            return configuration.isPressed ? 0.88 : 1
        }
        return 1
    }
}
