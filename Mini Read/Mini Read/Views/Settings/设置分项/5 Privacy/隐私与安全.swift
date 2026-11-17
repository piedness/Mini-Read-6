//
//  隐私与安全.swift
//  vellium1218
//
//  Created by Max Piednes on 2026/2/16.
//

import SwiftUI
import SwiftData

// MARK: - 隐私与安全

struct PrivacySecuritySettingsView: View {
    @Bindable var settings: AppSettings
    
    var body: some View {
        List {
            
            // 隐私保护
            Section {
                Toggle("隐藏阅读记录", isOn: $settings.hideReadingHistory)
                Toggle("启用隐私书架", isOn: $settings.enablePrivateShelf)
            } header: {
                Text("隐私保护")
            } footer: {
                Text("保护你的阅读隐私")
            }
            
            // 权限管理
            Section {
                InfoRow(title: "相册访问", value: "已授权")
                InfoRow(title: "通知权限", value: "已授权")
                InfoRow(title: "网络访问", value: "已授权")
                
                Button("前往系统设置") {
                    // 打开系统设置
                }
            } header: {
                Text("权限管理")
            }
        }
        .modifier(CustomListModifier(title: "访问控制与隐私"))
    }
}
