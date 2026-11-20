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

    /// 元数据编辑器（书库列表 + 编辑页）以面板形式呈现：
    /// 它是一次独立的小任务，不该把设置页的导航栈也一起推进去。
    @State private var isEditingMetadata = false

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
                Button {
                    isEditingMetadata = true
                } label: {
                    Label("手动编辑元数据", systemImage: "text.badge.checkmark")
                }
                .accessibilityHint("选择一本书，修改它的书名、作者、出版社与封面")
            } header: {
                Text("元数据管理")
            } footer: {
                Text("改掉 EPUB 里写错或不想要的书名、作者与封面。只影响本机书库的显示，不会改动文件本身。")
            }

        }
        .modifier(CustomListModifier(title: "导入与格式"))
        .sheet(isPresented: $isEditingMetadata) {
            BookMetadataLibraryView()
        }
        .onAppear {
            guard DuplicateHandling(rawValue: settings.duplicateHandling) == nil else { return }
            settings.duplicateHandling = DuplicateHandling.skip.rawValue
        }
    }
}
