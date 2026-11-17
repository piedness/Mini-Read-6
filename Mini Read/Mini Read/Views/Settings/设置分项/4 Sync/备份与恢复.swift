//
//  备份与恢复.swift
//  vellium1218
//
//  Created by Max Piednes on 2026/2/16.
//

import SwiftUI
import SwiftData


// 备份与恢复
struct BackupRecoverySettingsView: View {
    @Bindable var settings: AppSettings
    
    var body: some View {
        List {
            // 备份设置
            Section {
                Toggle("自动备份", isOn: $settings.autoBackup)
                
                if settings.autoBackup {
                    Picker("备份频率", selection: $settings.backupFrequency) {
                        Text("每日").tag("daily")
                        Text("每周").tag("weekly")
                        Text("手动").tag("manual")
                    }
                }
                
                Picker("备份位置", selection: $settings.backupLocation) {
                    Text("iCloud").tag("icloud")
                    Text("本地").tag("local")
                    Text("云盘").tag("cloud")
                }
                
                Button("立即备份") {
                    // 触发备份
                }
            } header: {
                Text("备份设置")
            } footer: {
                Text("上次备份: 2024年1月15日 14:23")
            }
            
            // 数据管理
            Section {
                Button("导出所有数据") {
                    // ZIP 打包导出
                }
                
                Button("从备份恢复") {
                    // 选择备份文件
                }
                
                Button("迁移到新设备") {
                    // 生成迁移码
                }
                
                Button("完全重置") {
                    // 重置确认
                }
                .foregroundStyle(.red)
            } header: {
                Text("数据管理")
            }
        }
        .modifier(CustomListModifier(title: "备份与恢复"))
    }
}
