//
//  云端同步.swift
//  vellium1218
//
//  Created by Max Piednes on 2026/2/16.
//
import SwiftUI
import SwiftData

// MARK: - 同步与备份

// 云端同步
struct CloudSyncSettingsView: View {
    @Bindable var settings: AppSettings
    
    var body: some View {
        List {
            // iCloud 同步
            Section {
                Toggle("启用 iCloud 同步", isOn: $settings.iCloudSync)
                
                if settings.iCloudSync {
                    Toggle("阅读进度", isOn: $settings.syncProgress)
                    Toggle("书签", isOn: $settings.syncBookmarks)
                    Toggle("高亮与笔记", isOn: $settings.syncNotes)
                    Toggle("应用设置", isOn: $settings.syncSettings)
                    Toggle("书籍文件", isOn: $settings.syncBooks)
                    
                    Picker("同步频率", selection: $settings.syncFrequency) {
                        Text("实时").tag("realtime")
                        Text("WiFi 时").tag("wifi")
                        Text("手动").tag("manual")
                    }
                }
            } header: {
                Text("iCloud 同步")
            } footer: {
                Text("同步阅读数据到 iCloud，在所有设备间保持一致")
            }
            
            // 同步策略
            Section {
                Picker("冲突处理", selection: $settings.conflictResolution) {
                    Text("本地优先").tag("local")
                    Text("云端优先").tag("cloud")
                    Text("手动选择").tag("manual")
                    Text("合并").tag("merge")
                }
                
                Toggle("仅 WiFi 同步", isOn: $settings.syncOnWiFiOnly)
                
                Button("立即同步") {
                    // 触发同步
                }
                
                Button("查看同步日志") {
                    // 打开日志
                }
            } header: {
                Text("同步策略")
            }
        }
        .modifier(CustomListModifier(title: "云端同步"))
    }
}
