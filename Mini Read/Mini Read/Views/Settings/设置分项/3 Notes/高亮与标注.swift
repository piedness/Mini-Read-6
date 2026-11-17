//
//  高亮与标注.swift
//  vellium1218
//
//  Created by Max Piednes on 2026/2/16.
//

import SwiftUI
import SwiftData


// MARK: - 笔记与标注

// 高亮与标注
struct HighlightSettingsView: View {
    @Bindable var settings: AppSettings
    
    var body: some View {
        List {
            // 高亮颜色
            Section {
                Picker("默认高亮颜色", selection: $settings.defaultHighlightColor) {
                    HStack {
                        Circle().fill(.yellow).frame(width: 20, height: 20)
                        Text("黄色")
                    }.tag("yellow")
                    HStack {
                        Circle().fill(.green).frame(width: 20, height: 20)
                        Text("绿色")
                    }.tag("green")
                    HStack {
                        Circle().fill(.blue).frame(width: 20, height: 20)
                        Text("蓝色")
                    }.tag("blue")
                    HStack {
                        Circle().fill(.pink).frame(width: 20, height: 20)
                        Text("粉色")
                    }.tag("pink")
                    HStack {
                        Circle().fill(.orange).frame(width: 20, height: 20)
                        Text("橙色")
                    }.tag("orange")
                }
                
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("高亮透明度")
                        Spacer()
                        Text("\(Int(settings.highlightOpacity * 100))%")
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $settings.highlightOpacity, in: 0.1...0.7, step: 0.05)
                }
                
                NavigationLink("自定义颜色") {
                    Text("自定义颜色管理")
                }
            } header: {
                Text("高亮颜色")
            }
            
            // 标注样式
            Section {
                Picker("默认标注样式", selection: $settings.defaultAnnotationStyle) {
                    Label("下划线", systemImage: "underline").tag("underline")
                    Label("背景高亮", systemImage: "highlighter").tag("highlight")
                    Label("波浪线", systemImage: "wave.3.right").tag("wavy")
                    Label("删除线", systemImage: "strikethrough").tag("strikethrough")
                }
            } header: {
                Text("标注样式")
            }
            
            // 标注交互
            Section {
                Picker("长按选词后", selection: $settings.longPressAction) {
                    Text("高亮").tag("highlight")
                    Text("笔记").tag("note")
                    Text("分享").tag("share")
                    Text("查词").tag("lookup")
                }
                
                Picker("双击词语", selection: $settings.doubleTapAction) {
                    Text("选中").tag("select")
                    Text("查词").tag("lookup")
                }
                
                Toggle("显示笔记指示器", isOn: $settings.showNoteIndicators)
            } header: {
                Text("标注交互")
            }
        }
        .modifier(CustomListModifier(title: "高亮与标注"))
    }
}
