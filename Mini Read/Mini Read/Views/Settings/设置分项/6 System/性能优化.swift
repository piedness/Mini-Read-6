//
//  性能优化.swift
//  vellium1218
//
//  Created by Max Piednes on 2026/2/16.
//
import SwiftUI
import SwiftData

// 性能优化
struct PerformanceSettingsView: View {
    @Bindable var settings: AppSettings
    
    var body: some View {
        List {
            // 调试（开发者选项）
            Section {
                NavigationLink("实验性功能") {
                    ExperimentalFeaturesView()
                }
                
            } header: {
                Text("调试")
            }
        }
        .modifier(CustomListModifier(title: "性能优化"))
    }
}
