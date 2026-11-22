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

                Button("查看日志") {
                    // 打开日志
                }
                Button("网络诊断") {
                    // 网络测试
                }
                Button("性能监控") {
                    // 性能面板
                }
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
