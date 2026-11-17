//
//  导入与格式.swift
//  vellium1218
//
//  Created by Max Piednes on 2026/2/16.
//
import SwiftUI
import SwiftData

// 导入与格式
struct ImportFormatSettingsView: View {
    @Bindable var settings: AppSettings
    
    var body: some View {
        List {
            // 导入设置
            Section {
                // tag 直接取 `DuplicateHandling.rawValue`：枚举与持久化值只此一处对应，
                // 手写字符串容易改了一边忘了另一边。
                Picker("重复书籍处理", selection: $settings.duplicateHandling) {
                    ForEach(DuplicateHandling.allCases) { handling in
                        Text(handling.displayName).tag(handling.rawValue)
                    }
                }
            } header: {
                Text("导入设置")
            } footer: {
                Text("按文件内容判断是否重复（同一本书改文件名也认得）：\n跳过——已在书库中，不重复添加；\n保留两者——两本都存在，各自独立。")
            }
            
            // 元数据管理
            Section {
                Button("手动编辑元数据") {
                    // 打开元数据编辑器
                }
            } header: {
                Text("元数据管理")
            }
            
            // 支持格式（信息展示）
            Section {
                InfoRow(title: "EPUB", value: "2.0 / 3.0")
                InfoRow(title: "PDF", value: "✓")
                InfoRow(title: "MOBI / AZW3", value: "✓")
                InfoRow(title: "TXT", value: "✓")
                InfoRow(title: "RTF / DOCX", value: "✓")
                InfoRow(title: "HTML", value: "✓")
                InfoRow(title: "CBZ / CBR", value: "漫画格式")
            } header: {
                Text("支持格式")
            } footer: {
                Text("当前版本支持以上格式的电子书")
            }
        }
        .modifier(CustomListModifier(title: "导入与格式"))
        // 归一化无法识别的存量值（旧版本的 "overwrite"、外部导入的配置文件）。
        // 不归一会让 Picker 停在"没有任何一行被选中"的状态——看起来像设置坏了。
        .onAppear {
            guard DuplicateHandling(rawValue: settings.duplicateHandling) == nil else { return }
            settings.duplicateHandling = DuplicateHandling.skip.rawValue
        }
    }
}
