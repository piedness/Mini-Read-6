//
//  视图与组织.swift
//  vellium1218
//
//  Created by Max Piednes on 2026/2/16.
//
import SwiftUI
import SwiftData

// MARK: - 书库管理

// 视图与组织
struct LibraryViewSettingsView: View {
    @Bindable var settings: AppSettings
    
    var body: some View {
        List {
            // 显示方式
            Section {
                Picker("显示方式", selection: $settings.libraryViewMode) {
                    Label("网格视图", systemImage: "square.grid.2x2").tag("grid")
                    Label("封面墙", systemImage: "square.grid.3x3").tag("coverWall")
                }
            } header: {
                Text("显示方式")
            }
            
            // 排序方式
            Section {
                Picker("排序方式", selection: $settings.sortBy) {
                    Text("最近阅读").tag("recentlyRead")
                    Text("添加时间 (最新)").tag("dateAddedNew")
                    Text("添加时间 (最早)").tag("dateAddedOld")
                    Text("书名 (A-Z)").tag("titleAZ")
                    Text("书名 (拼音)").tag("titlePinyin")
                    Text("作者").tag("author")
                    Text("进度 (未读优先)").tag("progressUnread")
                    Text("进度 (已完成优先)").tag("progressCompleted")
                }
            } header: {
                Text("排序方式")
            }
            
        }
        .modifier(CustomListModifier(title: "视图与组织"))
    }
}
