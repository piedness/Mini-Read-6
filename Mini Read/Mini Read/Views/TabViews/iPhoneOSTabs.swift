//
//  iPhoneOSTabs.swift
//  TheNewVellium
//
//  iPhone 的 tab 骨架。
//
//  ## 为什么这里保留 navigationTitle
//  紧凑宽度下没有常驻的 tab bar 文案（图标 + 底部条），页面级标题是用户
//  判断「我在哪一页」最直接的线索；大标题随滚动收缩成 inline，滚到内容
//  深处时顶部仍留一条可辨认的 chrome。
//
//  这里只决定「怎么排」，Home / Library / Search 的内容与动作项都在
//  `TabScreens.swift` 里共享——两套骨架各写一份才是真正会漂移的地方。
//

import SwiftUI

struct iPhoneOSTabs: View {
    @Binding var selection: TabsTab
    @Binding var searchText: String
    let onImport: () -> Void

    var body: some View {
        TabView(selection: $selection) {
            Tab("", systemImage: "house", value: TabsTab.home) {
                HomeTabView(title: "Home")
            }

            Tab("", systemImage: "books.vertical", value: TabsTab.library) {
                LibraryTabView(title: "Library", onImport: onImport)
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
