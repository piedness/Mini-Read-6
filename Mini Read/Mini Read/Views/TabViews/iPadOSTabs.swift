//
//  iPadOSTabs.swift
//  TheNewVellium
//
//  iPad 的 tab 骨架。
//
//  ## 不设 navigationTitle 的原因
//  iPad 顶部已经有浮动 tab bar 交代「我在哪」；再叠一条大标题，就是两层
//  chrome 抢同一条顶带——首屏被白拿走一截，而信息量为零。Apple Books 在
//  iPad 上同样不给页面挂标题，位置感由 tab bar 与内容本身承担。
//
//  注意这里用的是「不挂 `navigationTitle`」而不是「挂空字符串」：空标题
//  仍会占住大标题那一行的高度与收缩动画，只是看起来没字。`title: nil`
//  才是真的没有这一层。见 `TabScreens.swift` 的 `TabNavigationTitle`。
//
//  这里只决定「怎么排」，内容与动作项都在共享屏幕里。
//

import SwiftUI

struct iPadOSTabs: View {
    @Binding var selection: TabsTab
    @Binding var searchText: String
    let onImport: () -> Void

    var body: some View {
        TabView(selection: $selection) {
            Tab("", systemImage: "house", value: TabsTab.home) {
                HomeTabView(title: nil)
            }

            Tab("", systemImage: "books.vertical", value: TabsTab.library) {
                LibraryTabView(title: nil, onImport: onImport)
            }

            Tab("", systemImage: "gear", value: TabsTab.settings) {
                SettingsView()
            }

            Tab("", systemImage: "magnifyingglass", value: TabsTab.search, role: .search) {
                SearchTabView(searchText: $searchText)
            }
        }
        .minimizesTabBarOnScrollDown()
    }
}
