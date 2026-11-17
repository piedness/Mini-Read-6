//
//  PageBackViewController.swift
//  TheNewVellium
//
//  一个「页张」的背面。
//
//  iPhone 的仿真卷曲走的是 `.min` 书脊 + 正反面模型：`isDoubleSided = true` 时
//  UIKit 把每个页张拆成正反两面，正面常驻上屏，背面只在卷曲过程中露出。
//  此前背面由 UIKit 私有图层合成——一张**固定的浅色面**，不读纸面设置，
//  夜读纸面上翻页会露出一道浅色断层，也没有任何透印质感。
//
//  交给本类之后，背面就是**正面的一张镜像纸**：同一张纸、同一张纹理、同一版心
//  的字形，整体左右翻转。没有额外的明暗、渐变、阴影参数——观感全部由阅读设置
//  里的纸面决定，改纸色 / 字体 / 边距，正反两面一起变。
//
//  ## 为什么背面不截正面页的图
//  透印只是「墨迹在纸里的淡淡一层」。正面页的排版结果（`ChapterLayout` 的
//  共享 `NSLayoutManager`）本来就在内存里，把同一段字形以极低 alpha 再画一遍
//  即可：没有离屏渲染、没有整屏位图、没有缓存失效问题。翻页时反复创建/销毁
//  背面 VC 也不会引起内存抖动。
//

import UIKit

// MARK: - 透印参数

/// 背面「透印」的绘制参数。
///
/// 刻意**不存位图**：背面要透出的只是墨迹，直接引用正面页的 `ChapterLayout`，
/// 在本视图的 `draw(_:)` 里把同一段字形再画一遍即可。于是没有快照成本、
/// 没有缓存、也没有整页位图的内存占用。
struct PageBackGhost {

    let layout: ChapterLayout

    /// 该页在 `ChapterLayout` 中的页下标。**不是**页面数组下标：
    /// 前置页章节的数组前面多一张扉页，两者差 1（见 `ChapterPageSequence`）。
    let pageIndex: Int

    /// 版心左上角在页面坐标系中的位置，即正面页的左右/上边距。
    /// 透印必须落在与正面完全相同的位置，否则卷曲到一半时字会"跳"一下。
    let inset: CGPoint

    /// 透印强度。真实纸背的透印很淡；再高会让读者以为背面也有正文可读。
    var alpha: CGFloat = 0.07
}

// MARK: - PageBackViewController

/// 页张的背面：只负责「它看起来像一张纸的背面」，不承载任何语义。
///
/// 设计边界：
/// - **不进 `vcIndexMap`**：没有位置、没有页码，阅读位置永远以正面页为准；
/// - **对 Accessibility 完全隐藏**：VoiceOver 不该在翻页过程中聚焦到它；
/// - **永远满幅不透明**：卷曲期间正反两面会被合成到同一层级，透明背面会漏黑底；
/// - **不接收触摸**：翻页手势只由 `UIPageViewController` 处理，
///   背面在转场中覆盖在正面之上，抢触摸会让卷曲中途"卡住"。
final class PageBackViewController: UIViewController {

    /// 该背面所属的章。仅用于与正面页配对，不参与位置计算。
    let src: String

    /// 该背面所属页张的**页面数组下标**（与 `vcIndexMap.pageArrayIndex` 同口径）。
    ///
    /// 只在一条路径上被读取：万一某次手势翻页把背面当成了当前页
    /// （见 `ViewController.recoverIfLandedOnSheetBack`），要靠它找回正面。
    let pageIndex: Int

    private let background: ReadingBackground
    private let ghost: PageBackGhost?

    init(
        src: String,
        pageIndex: Int,
        background: ReadingBackground,
        ghost: PageBackGhost?
    ) {
        self.src = src
        self.pageIndex = pageIndex
        self.background = background
        self.ghost = ghost
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = PageBackView(background: background, ghost: ghost)
    }
}

// MARK: - PageBackView

/// 背面的绘制层。
///
/// 只做三件事：铺纸 → 铺纹理 → 把正面页的字形按同一版心再画一遍。
/// 全部在一个 `draw(_:)` 里完成，不用子视图、不用 `CAGradientLayer`：
/// 背面是**一次性**的临时页（每次卷曲都会新建），少一层图层就少一次合成，
/// 也省掉一套约束/布局代码。
private final class PageBackView: UIView {

    private let background: ReadingBackground
    private let ghost: PageBackGhost?

    /// 纹理纸面的位图。在 init 里取好而不是在 `draw(_:)` 里取：
    /// `ReadingBackgroundImageLoader` 首次取图要解码 2K 位图（同步返回），
    /// 那一步落在卷曲动画的绘制帧里就会掉帧。正面页总会先解同一张纹理，
    /// 这里通常是缓存命中；即便如此，也不该把它放在绘制路径上。
    private let texture: UIImage?

    init(background: ReadingBackground, ghost: PageBackGhost?) {
        self.background = background
        self.ghost = ghost
        self.texture = background.paperPreset.flatMap {
            ReadingBackgroundImageLoader.shared.image(for: $0)
        }
        super.init(frame: .zero)

        // 底色先铺好：`draw(_:)` 之前（例如被系统快照的瞬间）也不能是透明或黑色。
        // 与正面页**完全同色**——背面就是同一张纸，不另做明暗。
        backgroundColor = background.fillColor
        isOpaque = true
        contentMode = .redraw
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        accessibilityElementsHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: 绘制

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let bounds = self.bounds
        guard bounds.width > 1, bounds.height > 1 else { return }

        // **左右镜像**：这一层画的是同一张纸的背面，翻过来之后左右与正面相反。
        // 所以整幅（纸面 → 纹理 → 透印）都按**正面坐标**绘制，再在绘制上下文里
        // 翻一次：屏幕上的字因此是"反着读"的，与真实纸背一致。
        //
        // 不要指望 UIKit 替我们翻——它只负责把这张视图摆到卷曲的背面，
        // 视图内容按自己的坐标系正常绘制，不翻就是正着读的字。
        ctx.saveGState()
        ctx.translateBy(x: bounds.width, y: 0)
        ctx.scaleBy(x: -1, y: 1)

        background.fillColor.setFill()
        ctx.fill(bounds)

        // 纹理纸面：背面沿用同一张纹理，否则卷曲到一半时两张纸的质感对不上。
        if let texture {
            drawAspectFill(texture, in: bounds)
        }

        drawGhost(in: ctx)

        ctx.restoreGState()
    }

    /// 透印：把正面页的字形在原位置再画一遍，整体压到极低不透明度。
    ///
    /// 用 `NSLayoutManager` 直接画而不是截正面页的图：字形是现成的排版结果，
    /// 一次绘制即可，不需要先把正面页渲染成位图（那要求视图已经上屏、
    /// 且每页多一份整屏位图）。
    ///
    /// 方向：按**正面坐标**绘制（左页边距还是左页边距），由 `draw(_:)` 里那层
    /// 水平翻转统一镜像。两处各翻一次就会翻回去（字变正着读），别再叠。
    private func drawGhost(in ctx: CGContext) {
        guard let ghost,
              ghost.layout.pageContainers.indices.contains(ghost.pageIndex)
        else { return }

        let layoutManager = ghost.layout.layoutManager
        let glyphRange = layoutManager.glyphRange(for: ghost.layout.pageContainers[ghost.pageIndex])
        guard glyphRange.length > 0 else { return }

        ctx.saveGState()
        ctx.setAlpha(ghost.alpha)
        layoutManager.drawGlyphs(forGlyphRange: glyphRange, at: ghost.inset)
        ctx.restoreGState()
    }

    /// 按 `scaleAspectFill` 铺满（与 `PageBackgroundView` 同一规则，
    /// 保证正反两面的纹理尺度一致）。
    private func drawAspectFill(_ image: UIImage, in bounds: CGRect) {
        let source = image.size
        guard source.width > 0, source.height > 0 else { return }

        let scale = max(bounds.width / source.width, bounds.height / source.height)
        let size = CGSize(width: source.width * scale, height: source.height * scale)
        let origin = CGPoint(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2
        )
        image.draw(in: CGRect(origin: origin, size: size))
    }
}
