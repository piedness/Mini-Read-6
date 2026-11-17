import UIKit

// MARK: - PageBackgroundView

/// 阅读页面的纸张背景层。
///
/// 内容页（`TextViewControllerTest`）与空白页/占位页必须使用**完全相同**的背景绘制方式：
/// `UIPageViewController` 的 `.pageCurl` 转场会把相邻页面合成到同一层级，
/// 只要有一方透明就会漏出底层 UIKit 的默认黑底，翻页过程中出现黑边或黑洞。
/// 这也是空白页不能再用 `.clear` 背景的原因。
///
/// 纸面内容（纯色 / 纹理 / 兜底色）全部由 `ReadingBackground` 决定，
/// 本类不解释任何设置字段，只负责把解析结果画满整页。
///
/// 设计要点：
/// - **始终不透明**：资源缺失或解码失败时回退到纸色 `fillColor`，绝不露出黑底；
/// - **`scaleAspectFill` 铺满**：保证双页模式下左右两半页的纹理连续；
/// - **位图全局共享**：纹理走 `ReadingBackgroundImageLoader`，
///   多个页面共用同一个已解码 `UIImage`，翻页时不会各解一遍；
/// - **对 Accessibility 隐藏**：纸张纹理是装饰性内容，VoiceOver 无需朗读。
final class PageBackgroundView: UIImageView {

    // MARK: - Factory

    /// 在 `container` 中安装一张铺满全页的纸面，并置于最底层。
    ///
    /// - Parameters:
    ///   - container: 承载背景的页面根视图
    ///   - background: 已解析的阅读背景；纯色模式只画底色，纹理模式再叠一张位图
    /// - Returns: 已安装并完成约束的背景视图
    @discardableResult
    static func install(
        in container: UIView,
        background: ReadingBackground
    ) -> PageBackgroundView {
        let view = PageBackgroundView(background: background)
        container.addSubview(view)
        container.sendSubviewToBack(view)

        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor)
        ])

        return view
    }

    // MARK: - Init

    init(background: ReadingBackground) {
        super.init(frame: .zero)

        translatesAutoresizingMaskIntoConstraints = false
        // 兜底色先铺好：即便纹理资源缺失，页面也保持纸面质感
        backgroundColor = background.fillColor
        contentMode     = .scaleAspectFill
        clipsToBounds   = true
        isOpaque        = true          // 始终是满幅不透明画面，避免无谓的图层混合

        if let preset = background.paperPreset {
            image = ReadingBackgroundImageLoader.shared.image(for: preset)
        }

        // 装饰性图层，不进入 Accessibility 树
        isAccessibilityElement      = false
        accessibilityElementsHidden = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
