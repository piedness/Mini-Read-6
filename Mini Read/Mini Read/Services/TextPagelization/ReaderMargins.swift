//
//  ReaderMargins.swift
//  TheNewVellium
//
//  一次排版实际使用的页边距（已按页尺寸裁剪）。
//
//  为什么需要"有效边距"：设置里允许上下边距各 200pt，而横屏 iPhone 的
//  页高只有 ~393pt。直接把设置值相减会得到非正版心，TextKit 一页都排不
//  出来（空白页 + 零页缓存），Reader 还必须拒绝上屏。这里在保留用户偏好
//  的前提下按比例收缩到"至少能排下一行字"：
//    - 能放下时数值与设置完全一致（不改变现有观感）；
//    - 放不下时上下/左右各自按比例缩，两边的比例关系不变。
//
//  这是**排版与视图共用**的唯一有效边距：PaginationConfig 用它算版心，
//  TextVC / CoverPageVC 用它建约束。两边各算一套迟早会差几个 point，
//  表现就是正文贴着边或被裁掉。
//
//  纯值类型、不依赖 AppSettings/UIKit，可被探针独立编译验证。
//

import CoreGraphics

struct ReaderMargins: Equatable, Sendable {
    let top: CGFloat
    let bottom: CGFloat
    let left: CGFloat
    let right: CGFloat

    func clamped(to pageSize: CGSize, fontSize: CGFloat) -> ReaderMargins {
        guard pageSize.width > 0, pageSize.height > 0 else {
            return ReaderMargins(top: 0, bottom: 0, left: 0, right: 0)
        }

        let safeFont = max(1, fontSize)
        // 一行至少四个字；高度至少容得下一行大标题（约 1.5 倍字号）加上
        // 它的段前距，避免极端边距下 TextKit 连第一行都放不下、排成零页。
        let minContentWidth  = max(80, safeFont * 4)
        // 还要容得下最大行距/段距下的一行大标题：font*1.5、lineSpacing 最大
        // 50、段前距 0.9*font。取 font*4 与 160 的较大值。
        let minContentHeight = max(160, safeFont * 4)

        func shrink(_ first: CGFloat, _ second: CGFloat, limit: CGFloat) -> (CGFloat, CGFloat) {
            let a = max(0, first)
            let b = max(0, second)
            let sum = a + b
            guard sum > limit, sum > 0 else { return (a, b) }
            let factor = max(0, limit) / sum
            return (a * factor, b * factor)
        }

        let (left, right) = shrink(self.left, self.right,
                                   limit: pageSize.width - minContentWidth)
        let (top, bottom) = shrink(self.top, self.bottom,
                                   limit: pageSize.height - minContentHeight)
        return ReaderMargins(top: top, bottom: bottom, left: left, right: right)
    }
}
