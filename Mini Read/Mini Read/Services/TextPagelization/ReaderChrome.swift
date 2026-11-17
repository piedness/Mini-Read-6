//
//  ReaderChrome.swift
//  TheNewVellium
//
//  阅读页「页码 / 章节标题」两个独立元素的唯一事实来源。
//  （2026-10-15 新增，随辅助功能页改版两次收敛。）
//
//  规则来自「设置 → 辅助功能」：
//  - **页码**：固定在底部，水平可选偏左 / 中间 / 偏右，可整体不显示；
//    格式二选一——「当前页码 / 整书页数」或「当前章节页码 / 章节页数」。
//  - **章节标题**：固定在顶部，水平可选偏左 / 中间 / 偏右，可整体不显示。
//  - 两者互相独立，可以同时出现（标题在上、页码在下）。
//  - **与浮动按钮高度对齐**：底部页码与 TableButton 同行、顶部标题与
//    dismissButton 同行。两侧几何共享 `ReaderChromeMetrics`：UIKit 侧（TextVC）
//    与 SwiftUI 侧（BookContent 浮动按钮、ReaderToolbarButton 尺寸）引用同一组常量。
//  - 前置页（扉页 / 版权页）两个元素都不显示，正文页码仍从 1 起算。
//
//  本文件只用 Foundation：可被运行时探针直接编译验证，不依赖 UIKit 视图。
//

import Foundation

/// 浮动按钮与页眉/页脚元素共用的几何度量。
///
/// **iPhone 与 iPad 的阅读页布局分开定义**：两端的浮动按钮布局本身就不同
/// （见 `BookContent` 的 overlay 分支），元素要对齐或贴边，参考边与数值都不同。
/// 这里把两端各自的数值显式写开，任何一端调整都不会牵动另一端。
enum ReaderChromeMetrics {

    /// 浮动按钮**视觉圆盘**直径（`ReaderToolbarButton` 画出来的那个玻璃圆）。
    ///
    /// 两端一致，页眉/页脚元素按它的中心对齐。
    static let buttonSize: CGFloat = 48

    /// 浮动按钮**可点击区域**（命中盒）边长。
    ///
    /// 视觉仍是 48 的圆盘，命中盒每边再向外扩 `buttonHitExpansion`（6）：
    /// 48 → 60，可点击面积 +56%，而纸面上一个像素都没动。
    ///
    /// 为什么不直接把圆盘画大：三个按钮与页码/标题共用这一组几何，圆盘一变，
    /// 页眉页脚就得跟着漂——读者对「控件挪位」比对「按钮略大」敏感得多。
    ///
    /// 为什么是 60 而不是更大：iPad 上三个按钮相邻，命中盒放大后
    /// 盒与盒之间仍留 8pt 净空（见 `Pad.buttonSpacing`），不会出现
    /// 「点书签却开了目录」的误触。
    static let buttonHitSize: CGFloat = 60

    /// 命中盒比圆盘每边多出来的量。所有「贴边内边距」都要减掉它，
    /// 才能让圆盘停在改版前的视觉位置。
    static var buttonHitExpansion: CGFloat { (buttonHitSize - buttonSize) / 2 }

    // MARK: - iPhone（compact）

    /// iPhone 的 chrome 几何。
    ///
    /// 浮动按钮所在容器显式 `ignoresSafeArea`，内边距相对**屏幕边**计量：
    /// dismissButton 圆盘顶部 = 35（`.top` 内边距）+ 16（命中盒内边距 10 + 扩张 6），
    /// TableButton 圆盘底部 = 30。元素与按钮同高即锚屏幕边。
    ///
    /// ⚠️ 下面两个内边距是**命中盒**的内边距，不是圆盘的：数值上比改版前
    /// （16 / 30）各少 6，因为多出来的 6 现在属于可点击范围而不是空白。
    enum Phone {
        /// dismissButton 的 `.top` 内边距（在命中盒内边距之外再叠加）。
        static let topButtonTopInset: CGFloat = 35
        /// 浮动按钮命中盒的四周内边距：16 - 6 → 圆盘仍距屏幕边 16。
        static let buttonEdgeInset: CGFloat = 16 - ReaderChromeMetrics.buttonHitExpansion
        /// TableButton 命中盒的四周内边距：30 - 6 → 圆盘仍距屏幕底 30。
        static let bottomButtonInset: CGFloat = 30 - ReaderChromeMetrics.buttonHitExpansion

        /// 顶部标题中心距**屏幕顶**：与 dismissButton 圆盘中心同高。
        static var topCenterOffset: CGFloat {
            topButtonTopInset + buttonEdgeInset + ReaderChromeMetrics.buttonHitSize / 2
        }
        /// 底部页码中心距**屏幕底**：与 TableButton 圆盘中心同高。
        static var bottomCenterOffset: CGFloat {
            bottomButtonInset + ReaderChromeMetrics.buttonHitSize / 2
        }
    }

    // MARK: - iPad（regular）

    /// iPad 的 chrome 几何。
    ///
    /// 三个浮动按钮都在右上角、贴**安全区**上沿（只有横向内边距，没有纵向内边距），
    /// 所以顶部元素以安全区顶为参考。
    /// 底部没有按钮可对齐——页码只留一个避让 Home Indicator 的余量贴着安全区底，
    /// 而不是沿用 iPhone 的「按钮内边距 + 半径」（那会让它离屏幕下边缘过远）。
    enum Pad {
        /// 右上角按钮组命中盒距安全区左右边缘：25 - 6 → 圆盘仍贴 25。
        static let buttonEdgeInset: CGFloat = 25 - ReaderChromeMetrics.buttonHitExpansion

        /// 按钮**命中盒**之间的间距：20 - 12 → 圆盘间距仍是改版前的 20。
        ///
        /// 命中盒比圆盘每边大 6，若继续沿用 20 的间距，圆盘之间会被撑到 32，
        /// 三个按钮看上去像散开了——所以这里反向扣掉两侧各 6。
        static let buttonSpacing: CGFloat = 20 - ReaderChromeMetrics.buttonHitExpansion * 2

        /// 顶部标题中心距**安全区顶**：命中盒贴安全区上沿，圆盘中心在盒内一半处。
        ///
        /// 命中盒把圆盘每边各撑开 6，所以圆盘比改版前低 6pt（此前圆盘顶边
        /// 正好压着安全区顶）。这是唯一一处圆盘位置有位移的地方：命中盒不可能
        /// 越过安全区上沿去取负内边距，且 6pt 的下移换来的是顶部不再顶格，
        /// 观感上反而更松。
        static var topCenterOffset: CGFloat { ReaderChromeMetrics.buttonHitSize / 2 }

        /// 底部页码中心距**安全区底**：比顶部更贴边（下方没有按钮要对齐），
        /// 16pt ≈ 1/3 个按钮高，足够避开 Home Indicator。
        static let bottomElementInset: CGFloat = 16
        static var bottomCenterOffset: CGFloat { bottomElementInset }
    }
}

enum ReaderChrome {

    enum HorizontalAlignment: String, Sendable {
        case center
        case left
        case right
    }

    /// 页码格式。
    enum PageNumberFormat: String, Sendable {
        /// 当前页码 / 整书页数，例如 `12 / 320`
        case book
        /// 当前章节中的页码 / 章节页数，例如 `3 / 18`
        case chapter
        /// 只显示当前页码（整书口径的序号），例如 `12`
        case current
    }

    /// 一页的两个元素布局，由父 VC 计算后注入 TextVC
    /// （TextVC 不再自行读设置字段）。
    struct Placement: Equatable, Sendable {
        var showsPageNumber: Bool
        var pageNumberAlignment: HorizontalAlignment
        var pageNumberFormat: PageNumberFormat
        var showsChapterTitle: Bool
        var chapterTitleAlignment: HorizontalAlignment
        var isRegular: Bool

        /// 前置页（扉页 / 版权页）：两个元素都不显示。
        static let none = Placement(
            showsPageNumber: false,
            pageNumberAlignment: .center,
            pageNumberFormat: .book,
            showsChapterTitle: false,
            chapterTitleAlignment: .center,
            isRegular: false
        )
    }

    /// 由设置算出某页的元素布局。**唯一入口**：阅读器不再自行解释字段。
    static func placement(
        showPageNumber: Bool,
        pageNumberPosition: String,
        pageNumberFormat: String,
        showChapterTitle: Bool,
        chapterTitlePosition: String,
        isRegular: Bool
    ) -> Placement {
        Placement(
            showsPageNumber: showPageNumber,
            pageNumberAlignment: horizontalAlignment(pageNumberPosition),
            pageNumberFormat: PageNumberFormat(rawValue: pageNumberFormat) ?? .book,
            showsChapterTitle: showChapterTitle,
            chapterTitleAlignment: horizontalAlignment(chapterTitlePosition),
            isRegular: isRegular
        )
    }

    // MARK: - 位置值域

    /// 水平位置归一。同时兼容三种历史写法：
    /// - 旧默认 `"bottom"`（页码曾经只有一个「底部」概念）；
    /// - 上一版的值域 `"bottom left"` / `"bottom center"` / `"bottom right"`；
    /// - 标题的 `"top"` / `"bottom"`（标题曾经可选上下）。
    /// 未知值一律回退居中。
    static func horizontalAlignment(_ raw: String) -> HorizontalAlignment {
        switch raw {
        case "left", "bottom left", "top left":
            return .left
        case "right", "bottom right", "top right":
            return .right
        default:
            return .center
        }
    }

    /// 页码位置在设置页 Picker 里的规范值：`bottom left|center|right`。
    static func pageNumberPositionTag(_ raw: String) -> String {
        "bottom " + horizontalAlignment(raw).rawValue
    }

    /// 章节标题位置在设置页 Picker 里的规范值：`top left|center|right`。
    static func chapterTitlePositionTag(_ raw: String) -> String {
        "top " + horizontalAlignment(raw).rawValue
    }

    // MARK: - 页码数值

    /// 页码文本。
    ///
    /// - `book` / `chapter`：`当前 / 总数`。**渐进呈现**——总数还没算出来
    ///   （全书页数索引未完成）时先只显示当前页码，索引完成后由父 VC 刷新为
    ///   `当前 / 总数`；分母为 0 时同样只显示当前页码。
    /// - `current`：只显示当前页码（整书口径的序号）。
    /// - 连当前页码都拿不到时返回 nil，调用方显示占位「…」。
    static func pageNumberText(
        format: PageNumberFormat,
        current: Int?,
        total: Int?
    ) -> String? {
        guard let current else { return nil }
        switch format {
        case .current:
            return "\(current)"
        case .book, .chapter:
            guard let total, total > 0 else { return "\(current)" }
            return "\(current) / \(total)"
        }
    }

    /// 计算全书页码（整书口径）。前置页章节不编号；正文从 1 开始。
    /// 页数索引尚未完成时返回 nil，避免先显示错误偏移再跳变。
    static func pageNumber(
        src: String,
        pageIndex: Int,
        orderedSources: [String],
        pageCounts: [String: Int],
        frontMatterSrc: String?
    ) -> Int? {
        guard let position = orderedSources.firstIndex(of: src),
              pageIndex >= 0,
              src != frontMatterSrc
        else { return nil }

        let start = frontMatterSrc != nil && orderedSources.first == frontMatterSrc ? 1 : 0
        guard position >= start else { return nil }
        let previousSources = orderedSources[start..<position]
        // 页数 0 表示那一章**索引失败**（文件缺失 / 解析为空），不是"零页"。
        // 旧实现只判 nil，0 会以 0 的偏移混进前缀和：后面章节的页码整体偏小，
        // 而 totalPageCount 又因 0 返回 nil——分子是错的、分母又消失。
        // 这里一律当作"索引未就绪"，页码先显示「…」，绝不给一个错的数字。
        guard previousSources.allSatisfy({ (pageCounts[$0] ?? 0) > 0 }) else { return nil }

        let offset = previousSources.reduce(0) { $0 + (pageCounts[$1] ?? 0) }
        return offset + pageIndex + 1
    }

    /// 全书正文总页数（不含扉页与版权页）——「整书页数」格式的分母。
    /// 索引未齐或没有正文时返回 nil，而不是报一个偏小的数字。
    static func totalPageCount(
        orderedSources: [String],
        pageCounts: [String: Int],
        frontMatterSrc: String?
    ) -> Int? {
        let start = frontMatterSrc != nil && orderedSources.first == frontMatterSrc ? 1 : 0
        let contentSources = orderedSources.dropFirst(start)
        guard !contentSources.isEmpty,
              contentSources.allSatisfy({
                  guard let pageCount = pageCounts[$0] else { return false }
                  return pageCount > 0
              })
        else { return nil }
        let total = contentSources.reduce(0) { $0 + (pageCounts[$1] ?? 0) }
        return total > 0 ? total : nil
    }
}
