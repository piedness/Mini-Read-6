//
//  笔记系统.swift
//  vellium1218
//
//  Created by Max Piednes on 2026/2/16.
//
import SwiftUI
import SwiftData

// MARK: - InfoRow（保持不变）
struct InfoRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
        }
    }
}


// 笔记系统
struct NoteSystemSettingsView: View {
    @Bindable var settings: AppSettings
    
    var body: some View {
        List {
            // 笔记功能（信息展示）
            Section {
                InfoRow(title: "文字笔记", value: "✓")
                InfoRow(title: "语音笔记", value: "转文字/保留音频")
                InfoRow(title: "手写笔记", value: "Apple Pencil 支持")
                InfoRow(title: "图片附件", value: "✓")
                InfoRow(title: "想法卡片", value: "Zettelkasten 风格")
            } header: {
                Text("笔记功能")
            }
            
            // 笔记显示
            Section {
                Picker("显示位置", selection: $settings.noteDisplayPosition) {
                    Text("侧边栏").tag("sidebar")
                    Text("浮窗").tag("popover")
                    Text("页面底部").tag("bottom")
                }
                
                Picker("笔记气泡样式", selection: $settings.noteBubbleStyle) {
                    Text("标准").tag("standard")
                    Text("简约").tag("minimal")
                    Text("卡片").tag("card")
                }
                
                Toggle("显示笔记计数", isOn: $settings.showNoteCount)
            } header: {
                Text("笔记显示")
            }
        }
        .modifier(CustomListModifier(title: "笔记系统"))
    }
}
