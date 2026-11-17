//
//  导出与分享.swift
//  vellium1218
//
//  Created by Max Piednes on 2026/2/16.
//
import SwiftUI
import SwiftData

// 导出与分享
struct ExportShareSettingsView: View {
    @Bindable var settings: AppSettings
    
    var body: some View {
        List {
            // 导出格式
            Section {
                Picker("默认导出格式", selection: $settings.exportFormat) {
                    Text("Markdown").tag("markdown")
                    Text("PDF").tag("pdf")
                    Text("纯文本").tag("txt")
                    Text("HTML").tag("html")
                    Text("Notion").tag("notion")
                    Text("CSV").tag("csv")
                }
            } header: {
                Text("导出格式")
            }
            
            // 导出设置
            Section {
                Toggle("包含原文", isOn: $settings.includeOriginalText)
                Toggle("包含元数据", isOn: $settings.includeMetadata)
                Toggle("按章节导出", isOn: $settings.exportByChapter)
                
                Button("自定义导出模板") {
                    // 模板编辑器
                }
            } header: {
                Text("导出设置")
            }
            
            // 分享功能
            Section {
                Toggle("启用水印", isOn: $settings.watermarkEnabled)
                
                if settings.watermarkEnabled {
                    TextField("水印文字", text: $settings.watermarkText)
                }
                
            } header: {
                Text("分享功能")
            }
        }
        .modifier(CustomListModifier(title: "笔记导出与分享"))
    }
}
