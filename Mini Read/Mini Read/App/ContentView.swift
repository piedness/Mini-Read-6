//
//  ContentView.swift
//  TheNewVellium
//
//  Created by Max Piednes on 2026/4/11.
//

import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    var body: some View {
        TabsView()
            .onAppear {
                initializeDefaultSettings()
                AvatarImageStore.shared.load()   // App 启动即加载，所有 View 首帧就有头像
            }
    }
    
    // 初始化默认设置（并确保 AppSettings 只有一条）
    private func initializeDefaultSettings() {
        // 走统一入口：既保证存在、又会在启动时收敛历史遗留的重复记录
        _ = modelContext.appSettings()
        try? modelContext.save()
    }
    
    
}


