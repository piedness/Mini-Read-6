//
//  iPadOSHome.swift
//  TheNewVellium
//
//  iPad 首页。导航栏里只有动作项（iPad 不设页面标题），这里只排内容。
//  原先的 `.padding(.top, 90)` 是给浮层工具栏让位写死的常量，与导航栏
//  从来没有对齐过（iPad 顶部安全区只有 24 左右）；改走系统导航栏后，
//  大标题的间距由系统给，本视图不再需要知道安全区是多少。
//

import SwiftUI

struct iPadOSHomeView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                
                HStack {
                    Text("Home")
                        .font(.largeTitle)
                        .fontDesign(.serif)
                        .bold()
                    Spacer()
                }
                .padding(.horizontal, 40)
                
                ReadingStatsRow()
                    .padding(.horizontal, 40)

                RecentCardView()
                    .padding(.leading, 40)
                    .padding(.trailing, 12)

                CollectionView()
                    .padding(.leading, 40)
                    .padding(.trailing, 12)
            }
            .padding(.top, 12)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
    }
}
