import UIKit

// MARK: - TextRenderView

/// 基于 NSLayoutManager 的纯渲染视图。
///
/// 只负责将 ChapterLayout 中对应 NSTextContainer 的内容绘制到屏幕上——
/// 标注底色（highlight）、选中高亮、字形 + 下划线装饰。
///
/// 不持有任何手势识别器，不参与触摸事件处理。
/// 选中状态由外部写入共享 `SelectionState`，本视图通过 `onChange` 回调自动重绘。
final class TextRenderView: UIView {

    // MARK: - Properties

    let chapterLayout: ChapterLayout
    let pageIndex: Int
    let selectionState: SelectionState

    private var container: NSTextContainer { chapterLayout.pageContainers[pageIndex] }
    private var layoutManager: NSLayoutManager  { chapterLayout.layoutManager }
    var textStorage: NSTextStorage              { chapterLayout.textStorage }

    private var containerGlyphRange: NSRange { layoutManager.glyphRange(for: container) }

    // MARK: - Callbacks（供外部手势层调用）

    var onHighlight: ((NSRange) -> Void)?
    var onUnderline: ((NSRange) -> Void)?
    var onRemoveAnnotation: ((NSRange) -> Void)?
    var onAnnotationTap: ((NSRange) -> Void)?

    // MARK: - Init

    init(chapterLayout: ChapterLayout, pageIndex: Int, selectionState: SelectionState) {
        self.chapterLayout  = chapterLayout
        self.pageIndex      = pageIndex
        self.selectionState = selectionState
        super.init(frame: .zero)
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw
        // 注册为观察者而不是覆盖共享状态上的回调：同一章的每一页都要跟着重绘，
        // 否则跨页选中只有最后建出来的那一页会刷新（见 SelectionState 注释）。
        selectionState.addObserver(self)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Drawing

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let glyphRange = containerGlyphRange
        guard glyphRange.length > 0 else { return }

        // 1. 标注底色（.backgroundColor = highlight）
        layoutManager.drawBackground(forGlyphRange: glyphRange, at: .zero)

        // 2. 选中高亮
        if let selRange = selectionState.range {
            let selGlyph = layoutManager.glyphRange(forCharacterRange: selRange, actualCharacterRange: nil)
            let visible  = NSIntersectionRange(selGlyph, glyphRange)
            if visible.length > 0 {
                layoutManager.enumerateEnclosingRects(
                    forGlyphRange: visible,
                    withinSelectedGlyphRange: visible,
                    in: container
                ) { rect, _ in
                    UIColor.systemBlue.withAlphaComponent(0.22).setFill()
                    ctx.fill(rect)
                }
            }
        }

        // 3. 字形 + 下划线
        layoutManager.drawGlyphs(forGlyphRange: glyphRange, at: .zero)
    }

    // MARK: - Hit Testing

    /// 将本视图坐标系内的点映射为章节全局字符索引。
    func characterIndex(at point: CGPoint) -> Int? {
        guard bounds.contains(point) else { return nil }
        let gi = layoutManager.glyphIndex(for: point, in: container, fractionOfDistanceThroughGlyph: nil)
        guard gi != NSNotFound, gi < layoutManager.numberOfGlyphs else { return nil }
        return layoutManager.characterIndexForGlyph(at: gi)
    }

    /// 检测 point 处是否存在标注（highlight 或 underline），返回其章节全局 range。
    func annotatedRange(at point: CGPoint) -> NSRange? {
        guard let ci = characterIndex(at: point), ci < textStorage.length else { return nil }
        let full = NSRange(location: 0, length: textStorage.length)
        var er = NSRange()
        if textStorage.attribute(.backgroundColor, at: ci, longestEffectiveRange: &er, in: full) != nil { return er }
        if textStorage.attribute(.underlineStyle,  at: ci, longestEffectiveRange: &er, in: full) != nil { return er }
        return nil
    }
}
