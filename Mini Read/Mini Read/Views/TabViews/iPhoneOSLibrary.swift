//
//  iPhoneOSLibrary.swift
//  TheNewVellium
//
//  iPhone 书库。标题与动作项在 tab 骨架的导航栏里，这里只排内容。
//
//  20pt 与 `iPhoneOSHomeView` 的水平边距是同一个值：切 tab 时网格
//  与统计卡的左右边缘对齐，不会出现「换了一页、内容往两边跳」。
//

import SwiftUI

struct iPhoneOSLibraryView: View {
    let sortOption: LibrarySortOption
    /// 总数由 `LibraryTabView` 的 `@Query` 统一取，书架自己不再 fetch 一遍。
    let bookCount: Int

    var body: some View {
        ScrollView {
            BookCardFlowView(sortOption: sortOption)
                .padding(.vertical)
                .padding(.horizontal, 20)

            LibraryBookCountLabel(bookCount: bookCount)
        }
    }
}
