//
//  iPadOSLibrary.swift
//  TheNewVellium
//
//  iPad 书库。导航栏在 tab 骨架里（iPad 不设页面标题），这里只排内容。
//
//  与 iPhone 版的差别不只是边距：iPad 的窗口宽度是用户拖出来的，
//  一行放几本由 `BookCardFlowView` 按可用宽度算，所以这里只决定
//  「网格与窗口边缘之间留多少」，不写死列数。
//

import SwiftUI

struct iPadOSLibraryView: View {
    let sortOption: LibrarySortOption
    /// 总数由 `LibraryTabView` 的 `@Query` 统一取，书架自己不再 fetch 一遍。
    let bookCount: Int

    var body: some View {
        ScrollView {
            
            HStack {
                Text("Library")
                    .font(.largeTitle)
                    .fontDesign(.serif)
                    .bold()
                Spacer()
            }
            .padding(.horizontal, 40)
            .padding(.top, 12)
            
            BookCardFlowView(sortOption: sortOption)
                // 40pt：iPad 上网格贴着窗口边缘会显得局促，
                // 也给右侧的浮动按钮留出视觉余量（Home 用的是同一个值）。
                .padding(.horizontal, 40)

            LibraryBookCountLabel(bookCount: bookCount)
        }
    }
}
