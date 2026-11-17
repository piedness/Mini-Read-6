//
//  ChapterPageSequence.swift
//  TheNewVellium
//
//  ChapterLayout 页与 UIPageViewController 页面数组之间的索引映射。
//  （2026-10-15 修复「扉页/版权页无法翻进正文」时抽出。）
//
//  ChapterLayout 的页码只包含正文文本（0-based）；前置页章节会在页面数组
//  最前面插入一张独立的 CoverPageViewController。因此，前置页章节里：
//
//      页面数组下标： 0 扉页 | 1 版权页 0 | 2 版权页 1 | ...
//      layout 页下标：   —   |     0     |     1     | ...
//
//  UIPageViewController 的 data source 必须用「页面数组下标」找相邻 VC，
//  页码标签仍使用「ChapterLayout 页下标」。两种坐标不可混用。
//
//  纯整数函数、不依赖 UIKit：可在运行时探针中用生产同一实现覆盖首尾与索引映射。
//

import Foundation

enum ChapterPageSequence {

    /// ChapterLayout 页 → 当前章节 VC 数组下标。
    static func arrayIndex(forLayoutPage pageIndex: Int, hasCoverPage: Bool) -> Int {
        pageIndex + (hasCoverPage ? 1 : 0)
    }

    /// 前一张页面数组内的 VC 下标；章节首张返回 nil（调用方处理跨章）。
    static func previousIndex(from pageArrayIndex: Int, pageCount: Int) -> Int? {
        guard pageArrayIndex > 0, pageArrayIndex < pageCount else { return nil }
        return pageArrayIndex - 1
    }

    /// 后一张页面数组内的 VC 下标；章节末张返回 nil（调用方处理跨章）。
    static func nextIndex(from pageArrayIndex: Int, pageCount: Int) -> Int? {
        guard pageArrayIndex >= 0, pageArrayIndex + 1 < pageCount else { return nil }
        return pageArrayIndex + 1
    }

    // MARK: - Double-page spread

    /// 返回一个页面数组下标所属的双页 spread 左页。
    ///
    /// 正常 spread 从偶数页开始；当章节页数为奇数时，最后一页
    /// 会与它前一页组成一个「偏移的末 spread」（例如 `[3, 4]`），
    /// 这样末页仍落在右侧。这个偏移状态必须在恢复进度、旋转重排
    /// 和音量键翻页之间共用，否则末 spread 会被还原成 `[4, blank]`
    /// 或反向翻页时跳过中间 spread。
    static func spreadLeftIndex(for pageIndex: Int, pageCount: Int) -> Int? {
        guard pageCount > 0, pageIndex >= 0 else { return nil }

        var left = min(pageIndex, pageCount - 1)
        // 奇数页只在「偏移末 spread」中保留为左页；其他奇数页归到
        // 前一个偶数左页。对 pageIndex == pageCount - 1 的偶数末页，
        // 下面的无右邻居规则同样会把它前移一位。
        if left % 2 != 0, left + 2 < pageCount {
            left -= 1
        }
        if left + 1 >= pageCount, left > 0 {
            left -= 1
        }
        return left
    }

    /// 从当前 spread 左页计算上一 spread 的目标页面数组下标。
    /// 偏移末 spread（如 `[3, 4]`）的上一 spread 是 `[2, 3]`，
    /// 因此不能统一简单地减 2。
    static func previousSpreadTarget(from leftIndex: Int, pageCount: Int) -> Int? {
        guard let left = spreadLeftIndex(for: leftIndex, pageCount: pageCount) else { return nil }
        if left % 2 != 0, left + 2 >= pageCount {
            return left - 1
        }
        return left - 2
    }

    // MARK: - 程序化跳转动画

    /// 程序化跳转的动画形态。纯函数：探针可全覆盖。
    enum JumpAnimation: Sendable {
        /// 瞬切，不播放翻页动画
        case none
        case forward
        case reverse
    }

    /// 单页（compact / iPhone）模式下，程序化换页能不能播放翻页动画。
    ///
    /// 单页卷曲走的是 `.min` 书脊 + `isDoubleSided` 的「页张正反面」模型：
    /// 每一次合法的卷曲动画都是**一张页张**的翻转，因此起止页必须在
    /// data source 链上相邻——同章前后一页，或章边界处「本章末页 ↔ 相邻章
    /// 首页」。目录/书签跳转常常跨章、跨多页，对这种目标调用
    /// `setViewControllers(animated: true)` 属于未定义行为：UIKit 会按一次
    /// 页张翻转换算转场，轻则方向错乱，重则停在半翻/纸背/空白页面上。
    ///
    /// iPad 双页有结构相同的 `spreadJumpAnimation`；本函数是单页侧的对应
    /// 判定。`.scroll` 样式不经过这里（它没有页张模型，任意距离的滑动
    /// 过渡都有定义）。
    static func singlePageJumpAnimation(
        currentSrc: String, currentIndex: Int, currentPageCount: Int,
        targetSrc: String, targetIndex: Int, targetPageCount: Int,
        orderedSources: [String]
    ) -> JumpAnimation {
        guard currentPageCount > 0, targetPageCount > 0,
              currentIndex >= 0, currentIndex < currentPageCount,
              targetIndex >= 0, targetIndex < targetPageCount
        else { return .none }

        // 同章：只有前后一页是「一次页张翻转」
        if currentSrc == targetSrc {
            if targetIndex == currentIndex + 1 { return .forward }
            if targetIndex == currentIndex - 1 { return .reverse }
            return .none
        }

        // 跨章：只有章边界处的一张页张翻转（本章末页 ↔ 相邻章首页）
        guard let ci = orderedSources.firstIndex(of: currentSrc),
              let ti = orderedSources.firstIndex(of: targetSrc),
              abs(ci - ti) == 1
        else { return .none }

        if ti > ci, currentIndex == currentPageCount - 1, targetIndex == 0 {
            return .forward
        }
        if ti < ci, currentIndex == 0, targetIndex == targetPageCount - 1 {
            return .reverse
        }
        return .none
    }

    /// 双页（double-sided）模式下，程序化换页能不能播放翻页动画。
    ///
    /// **为什么需要这道判定**：`UIPageViewController` 的 pageCurl 只对
    /// 「起止两个 spread 在 data source 链上相邻」的动画有定义——即一次
    /// 手势能翻到的距离。书签/目录跳转经常跨章、或同章跨多个 spread，
    /// 对这种目标播动画，UIKit 会在动画期间经 data source 逐对推导中间页，
    /// 任一环断裂（相邻章未缓存返回 nil、右页是合成空白页）就会停在
    /// **只铺好左页、右页没上屏**的状态——读者看到的就是右半屏露底。
    /// （2026-10-17 实机报告：iPad 点书签跳转后右半屏白屏。）
    ///
    /// 判定与 `viewControllerAfter/Before` 同一套链式规则：
    /// - 同章：目标左页与当前左页相差一个 spread（含奇数章尾的偏移
    ///   spread `[n-2, n-1]`，Δ=1）；
    /// - 跨章：本章边界 spread ↔ 相邻章的对应边界 spread；
    /// - 其余一律 `.none`（瞬切）。Apple Books 的目录/书签跳转同样不播
    ///   跨距离翻页动画——瞬切既是对的，也不会把转场交给未定义行为。
    ///
    /// 合成空白页（`left + 1 >= pageCount`，仅单页章会出现）两侧都不参与
    /// 动画：空白页不在 data source 链上，它做动画起止点正是上面那类
    /// 半屏状态的直接诱因。
    static func spreadJumpAnimation(
        currentSrc: String, currentLeft: Int, currentPageCount: Int,
        targetSrc: String, targetLeft: Int, targetPageCount: Int,
        orderedSources: [String]
    ) -> JumpAnimation {
        // 起止两侧的右页都必须是真实页
        guard currentLeft + 1 < currentPageCount,
              targetLeft + 1 < targetPageCount
        else { return .none }

        // 同章：差一个 spread
        if currentSrc == targetSrc {
            let delta = targetLeft - currentLeft
            if delta == 1 || delta == 2 { return .forward }
            if delta == -1 || delta == -2 { return .reverse }
            return .none
        }

        // 跨章：仅本章边界 spread ↔ 相邻章的对应边界 spread
        guard let ci = orderedSources.firstIndex(of: currentSrc),
              let ti = orderedSources.firstIndex(of: targetSrc),
              abs(ci - ti) == 1
        else { return .none }

        let currentIsLast  = nextIndex(from: currentLeft + 1, pageCount: currentPageCount) == nil
        let currentIsFirst = currentLeft == 0
        let targetIsFirst  = targetLeft == 0
        let targetIsLast   = nextIndex(from: targetLeft + 1, pageCount: targetPageCount) == nil

        if ti > ci, currentIsLast, targetIsFirst { return .forward }
        if ti < ci, currentIsFirst, targetIsLast { return .reverse }
        return .none
    }
}
