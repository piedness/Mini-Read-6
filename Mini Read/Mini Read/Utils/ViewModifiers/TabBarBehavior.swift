//
//  TabBarBehavior.swift
//  TheNewVellium
//
//  iOS 26 才有的 tab bar 行为，在旧系统上安全退化。
//

import SwiftUI

extension View {

    /// 滚动内容下滑时收起 tab bar。
    ///
    /// `tabBarMinimizeBehavior(_:)` 是 iOS 26 新增的能力。iOS 18 的 tab bar
    /// 没有「可收起」这个状态，也就没有等价 API——旧系统上保持常驻是系统
    /// 本来的行为，不是少做了一块。
    @ViewBuilder
    func minimizesTabBarOnScrollDown() -> some View {
        if #available(iOS 26.0, *) {
            self.tabBarMinimizeBehavior(.onScrollDown)
        } else {
            self
        }
    }
}
