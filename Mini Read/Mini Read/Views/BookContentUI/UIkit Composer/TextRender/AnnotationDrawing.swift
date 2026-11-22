//
//  AnnotationDrawing.swift
//  TheNewVellium
//
//  标注的绘制与边注指示器。
//
//  绘制发生在 `TextRenderView.draw` 里、字形之前：底色压在字下，
//  下划线/波浪线/删除线压在字后。所有矩形都来自 `NSLayoutManager`
//  的行片段/字形几何，与正文共享同一套排版结果，
//  不存在"另算一遍坐标"的可能。
//

import UIKit

// MARK: - 绘制参数
//
// 所有标注的视觉参数集中在这里：下划线的位置/粗细、高亮的内缩、
// 波浪线的振幅、聚焦圈的描边、边注条的尺寸……调样式只改这一处。
private enum AnnotationMetrics {

    // 通用
    static let minOpacity: CGFloat = 0.05
    static let maxOpacity: CGFloat = 0.9
    static let minimumDrawableSide: CGFloat = 0.5

    // 高亮底色
    static let highlightHorizontalExpansion: CGFloat = 2
    static let highlightVerticalInset: CGFloat = 0.5
    static let highlightCornerRadius: CGFloat = 3

    // 下划线
    /// 基线往下偏移多少（pt）。想更贴字就调小，想更往下就调大。
    static let underlineOffset: CGFloat = 10
    /// 线宽（pt）。
    static let underlineWidth: CGFloat = 3
    /// 在底色透明度上再加多少，让线条比底色更实。
    static let underlineAlphaBoost: CGFloat = 0.45
    /// 没有基线几何时的兜底：从行框底部往上收多少。
    static let fallbackBaselineInset: CGFloat = 2

    // 波浪线
    static let wavyOffset: CGFloat = 10
    static let wavyAlphaBoost: CGFloat = 0.45
    static let wavyAmplitude: CGFloat = 2.5
    static let wavyHalfWave: CGFloat = 8
    static let wavyControlFactor: CGFloat = 1.6
    static let wavyWidth: CGFloat = 3

    // 删除线
    static let strikethroughWidth: CGFloat = 1.3
    static let strikethroughAlphaBoost: CGFloat = 0.35
    /// 删除线位于基线上方 `xHeight × factor` 处。
    static let strikethroughOffsetFactor: CGFloat = 0.5

    // 聚焦圈
    static let focusMaxAlpha: CGFloat = 0.9
    static let focusMinAlpha: CGFloat = 0.02
    static let focusHorizontalInset: CGFloat = 3.5
    static let focusVerticalInset: CGFloat = 2.5
    static let focusCornerRadius: CGFloat = 4
    static let focusLineWidth: CGFloat = 2

    // 边注指示条
    static let marginBarWidth: CGFloat = 3
    static let marginBarHeight: CGFloat = 11
    static let marginMinimumInset: CGFloat = 7
    static let marginInsetFactor: CGFloat = 0.55
    static let marginBarAlpha: CGFloat = 0.8
}

// MARK: - 绘制

enum AnnotationDrawing {

    /// 画一处标注的所有行。
    ///
    /// - Parameters:
    ///   - rects: 该标注在当前页上的行矩形（`TextRenderView` 坐标系）。
    ///   - lineGeometries: 逐行基线几何。下划线/波浪线/删除线必须按基线画，
    ///     不能用行矩形底部——那是行框底部，含行距与 descender，会沉下去。
    ///   - opacity: 全局高亮透明度（设置项）。
    static func draw(
        _ item: AnnotationItem,
        rects: [CGRect],
        lineGeometries: [ChapterLayout.LineFragmentGeometry] = [],
        opacity: CGFloat,
        in context: CGContext
    ) {
        guard !rects.isEmpty else { return }
        let clampedOpacity = max(AnnotationMetrics.minOpacity, min(AnnotationMetrics.maxOpacity, opacity))
        let color = item.color.uiColor

        switch item.style {
        case .highlight:
            // 每一行单独一块底色。高度必须用 `textRect`（font.lineHeight），
            // 不能用 `rect`：行距较大时 `rect` 会把行距一起包进去，
            // 色块向下填满行距，两行看起来就粘在一起。
            // 行间空白由行距自然提供；这里只再做一次很小的纵向内缩，
            // 保证行距为 0 时也有一条缝。
            context.setFillColor(color.withAlphaComponent(clampedOpacity).cgColor)
            let boxes = lineGeometries.isEmpty ? rects : lineGeometries.map(\.textRect)

            for rect in boxes {
                let box = rect.insetBy(
                    dx: -AnnotationMetrics.highlightHorizontalExpansion,
                    dy: AnnotationMetrics.highlightVerticalInset
                )
                guard box.width > AnnotationMetrics.minimumDrawableSide,
                      box.height > AnnotationMetrics.minimumDrawableSide
                else { continue }
                context.addPath(
                    UIBezierPath(
                        roundedRect: box,
                        cornerRadius: AnnotationMetrics.highlightCornerRadius
                    ).cgPath
                )
                context.fillPath()
            }

        case .underline:
            let stroke = color.withAlphaComponent(
                min(1, clampedOpacity + AnnotationMetrics.underlineAlphaBoost)
            )
            context.setStrokeColor(stroke.cgColor)
            context.setLineWidth(AnnotationMetrics.underlineWidth)

            if lineGeometries.isEmpty {
                // 兜底：没有拿到字体基线时贴着行框底部画，至少不会消失。
                for rect in rects {
                    let y = rect.maxY - AnnotationMetrics.fallbackBaselineInset
                    context.move(to: CGPoint(x: rect.minX, y: y))
                    context.addLine(to: CGPoint(x: rect.maxX, y: y))
                }
            } else {
                for line in lineGeometries {
                    let y = line.baselineY + AnnotationMetrics.underlineOffset
                    context.move(to: CGPoint(x: line.rect.minX, y: y))
                    context.addLine(to: CGPoint(x: line.rect.maxX, y: y))
                }
            }
            context.strokePath()

        case .wavy:
            let stroke = color.withAlphaComponent(
                min(1, clampedOpacity + AnnotationMetrics.wavyAlphaBoost)
            )
            stroke.setStroke()

            if lineGeometries.isEmpty {
                for rect in rects {
                    wavyPath(
                        from: rect.minX,
                        to: rect.maxX,
                        baselineY: rect.maxY - AnnotationMetrics.fallbackBaselineInset
                    ).stroke()
                }
            } else {
                for line in lineGeometries {
                    wavyPath(
                        from: line.rect.minX,
                        to: line.rect.maxX,
                        baselineY: line.baselineY + AnnotationMetrics.wavyOffset
                    ).stroke()
                }
            }

        case .strikethrough:
            context.setStrokeColor(
                color.withAlphaComponent(
                    min(1, clampedOpacity + AnnotationMetrics.strikethroughAlphaBoost)
                ).cgColor
            )
            context.setLineWidth(AnnotationMetrics.strikethroughWidth)

            if lineGeometries.isEmpty {
                for rect in rects {
                    let y = rect.midY
                    context.move(to: CGPoint(x: rect.minX, y: y))
                    context.addLine(to: CGPoint(x: rect.maxX, y: y))
                }
            } else {
                for line in lineGeometries {
                    let y = line.baselineY
                        - line.xHeight * AnnotationMetrics.strikethroughOffsetFactor
                    context.move(to: CGPoint(x: line.rect.minX, y: y))
                    context.addLine(to: CGPoint(x: line.rect.maxX, y: y))
                }
            }
            context.strokePath()
        }
    }

    /// 跳转落点后的聚焦提示：在标注外圈描一道逐渐消失的线。
    ///
    /// 只做透明度淡出，不做缩放/位移——`reduceMotion` 下它也仍然成立，
    /// 不需要额外分支。
    static func drawFocus(
        _ item: AnnotationItem,
        rects: [CGRect],
        progress: CGFloat,
        in context: CGContext
    ) {
        let alpha = max(0, 1 - progress) * AnnotationMetrics.focusMaxAlpha
        guard alpha > AnnotationMetrics.focusMinAlpha else { return }

        let color = item.color.uiColor.withAlphaComponent(alpha)
        color.setStroke()

        for rect in rects {
            let path = UIBezierPath(
                roundedRect: rect.insetBy(
                    dx: -AnnotationMetrics.focusHorizontalInset,
                    dy: -AnnotationMetrics.focusVerticalInset
                ),
                cornerRadius: AnnotationMetrics.focusCornerRadius
            )
            path.lineWidth = AnnotationMetrics.focusLineWidth
            path.stroke()
        }
    }

    private static func wavyPath(
        from startX: CGFloat,
        to endX: CGFloat,
        baselineY: CGFloat
    ) -> UIBezierPath {
        let path = UIBezierPath()
        let amplitude = AnnotationMetrics.wavyAmplitude
        let halfWave = AnnotationMetrics.wavyHalfWave

        var x = startX
        var up = true
        path.move(to: CGPoint(x: x, y: baselineY))

        while x < endX {
            let nextX = min(x + halfWave, endX)
            let controlY = baselineY
                + (up ? -amplitude : amplitude) * AnnotationMetrics.wavyControlFactor
            path.addQuadCurve(
                to: CGPoint(x: nextX, y: baselineY),
                controlPoint: CGPoint(x: (x + nextX) / 2, y: controlY)
            )
            x = nextX
            up.toggle()
        }

        path.lineWidth = AnnotationMetrics.wavyWidth
        return path
    }
}

// MARK: - 边注指示器

/// 页面右侧留白里的「这条标注有笔记」指示条。
///
/// 为什么不画在 `TextRenderView` 里：它的 frame 被约束在版心内（见 `TextVC`
/// 的四边约束），右边距在视图之外，画出去会被裁掉。这里用一层铺满整页、
/// 不接收触摸的兄弟视图，只负责在留白里画几根短线。
final class AnnotationMarginView: UIView, AnnotationStateObserver {

    private let chapterLayout: ChapterLayout
    private let pageIndex: Int
    private let margins: ReaderMargins
    private let annotationState: ChapterAnnotationState
    private let showsIndicators: Bool

    init(
        chapterLayout: ChapterLayout,
        pageIndex: Int,
        margins: ReaderMargins,
        annotationState: ChapterAnnotationState,
        showsIndicators: Bool
    ) {
        self.chapterLayout = chapterLayout
        self.pageIndex = pageIndex
        self.margins = margins
        self.annotationState = annotationState
        self.showsIndicators = showsIndicators
        super.init(frame: .zero)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false
        contentMode = .redraw
        annotationState.addObserver(self)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func annotationStateDidChange() {
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard showsIndicators,
              bounds.width > 0,
              let pageRange = chapterLayout.characterRange(forPage: pageIndex)
        else { return }

        let items = annotationState.items(intersecting: pageRange).filter(\.hasNote)
        guard !items.isEmpty else { return }

        let barWidth = AnnotationMetrics.marginBarWidth
        let barHeight = AnnotationMetrics.marginBarHeight
        // 右边距通常 16–40pt；取中间偏外一点，太贴版心会像正文的一部分。
        let centerX = bounds.width - max(
            AnnotationMetrics.marginMinimumInset,
            margins.right * AnnotationMetrics.marginInsetFactor
        )

        for item in items {
            let rects = lineRects(for: item.range)
            guard let first = rects.first else { continue }

            let box = CGRect(
                x: centerX - barWidth / 2,
                // 贴着页底时上移，而不是直接不画：读者至少能看到"这一页有笔记"。
                y: min(
                    max(0, margins.top + first.midY - barHeight / 2),
                    bounds.height - barHeight
                ),
                width: barWidth,
                height: barHeight
            )
            guard box.maxY <= bounds.height else { continue }

            let path = UIBezierPath(roundedRect: box, cornerRadius: barWidth / 2)
            item.color.uiColor.withAlphaComponent(AnnotationMetrics.marginBarAlpha).setFill()
            path.fill()
        }
    }

    private func lineRects(for range: NSRange) -> [CGRect] {
        chapterLayout.lineRects(forCharacterRange: range, pageIndex: pageIndex)
    }
}
