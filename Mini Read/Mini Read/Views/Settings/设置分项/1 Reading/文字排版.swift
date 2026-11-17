//
//  文字排版.swift
//  vellium1218
//
//  Created by Max Piednes on 2026/2/16.
//  Refactored for Apple-like UX and Performance
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct TypographySettingsView: View {
    @Bindable var settings: AppSettings
    
    var body: some View {
        List {
            // 字体与字号
            Section {
                // 字体选择：点进去进二级菜单单选（所见即所得）
                NavigationLink(destination: FontSelectionView(settings: settings)) {
                    HStack {
                        Label("字体", systemImage: "textformat")
                        Spacer()
                        Text(resolveReadingFontDisplayName(settings.fontFamily))
                            .font(resolveReadingSwiftUIFont(settings.fontFamily, size: 17)) // 所见即所得
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .accessibilityLabel("字体")
                .accessibilityValue(resolveReadingFontDisplayName(settings.fontFamily))
                
                // 经典的 A- / A+ 字号调节器
                FontSizeControl(settings: settings)
                
                TypographySlider(
                    title: "字间距",
                    systemImage: "arrow.up.and.down.text.horizontal",
                    value: $settings.letterSpacing,
                    range: -1...5,
                    step: 0.1,
                    format: "%.1f"
                )
            } header: {
                Text("字体排印")
            }
            
            // 行距与段落
            Section {
                TypographySlider(
                    title: "行间距",
                    systemImage: "arrow.up.and.down.text.horizontal",
                    value: $settings.lineSpacing,
                    range: 10...50.0,
                    step: 1,
                    format: "%.0f"
                )
                
                TypographySlider(
                    title: "段落间距",
                    systemImage: "paragraphsign",
                    value: $settings.paragraphSpacing,
                    range: 10...60,
                    step: 1,
                    format: "%.0f"
                )
                
                Toggle(isOn: $settings.firstLineIndent) {
                    Label("首行缩进", systemImage: "text.line.first.and.arrowtriangle.forward")
                }
                .tint(.accentColor)
                
                NavigationLink(destination: MarginSettingsView(settings: settings)) {
                    Label("页边距", systemImage: "rectangle.inset.filled")
                        .badge("独立设置")
                }
            } header: {
                Text("间距与排版")
            }
            
            // 重置操作
            Section {
                Button(role: .destructive) {
                    withAnimation {
                        resetToDefaults()
                    }
                } label: {
                    HStack {
                        Spacer()
                        Text("恢复默认设置")
                        Spacer()
                    }
                }
                .accessibilityLabel("恢复默认文字排版设置")
            }
        }
        // 首行缩进在本页由 Toggle 直接改，onChange 即可捕获；
        // 字体变更则改为在 FontSelectionView 内直接 notifyReader——父视图被 push
        // 覆盖后其 onChange 不再触发，不能依赖这里兜底（详见 FontSelectionView.select 的注释）。
        .onChange(of: settings.firstLineIndent) { _, _ in notifyReader() }
        .navigationBarTitleDisplayMode(.inline)
    }
    
    private func resetToDefaults() {
        // 默认值统一收在 AppSettings 上，避免和模型声明里的一份初值各走各的
        settings.resetTypographyToDefaults()
        notifyReader()
    }
}

// MARK: - 精致的组件库

/// 经典的字号控制器：小A - 滑块 - 大A
struct FontSizeControl: View {
    @Bindable var settings: AppSettings
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("字号", systemImage: "textformat.size")
                Spacer()
                Text("\(Int(settings.fontSize))pt")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            
            HStack(spacing: 16) {
                Button {
                    stepFontSize(by: -1)
                } label: {
                    Image(systemName: "textformat.size.smaller")
                        .font(.title3)
                        .frame(minWidth: 32, minHeight: 32)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(settings.fontSize <= 10)
                
                Slider(value: $settings.fontSize, in: 10...50, step: 1) { editing in
                    if !editing { notifyReader() }
                }
                
                Button {
                    stepFontSize(by: 1)
                } label: {
                    Image(systemName: "textformat.size.larger")
                        .font(.title3)
                        .frame(minWidth: 32, minHeight: 32)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(settings.fontSize >= 50)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("字号调节")
        .accessibilityValue("\(Int(settings.fontSize)) 磅")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: stepFontSize(by: 1)
            case .decrement: stepFontSize(by: -1)
            @unknown default: break
            }
        }
    }
    
    private func stepFontSize(by amount: Double) {
        let newValue = max(10, min(50, settings.fontSize + amount))
        if newValue != settings.fontSize {
            settings.fontSize = newValue
            notifyReader()
        }
    }
}

/// 标准化的排版滑块组件
struct TypographySlider: View {
    let title: String
    let systemImage: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(title, systemImage: systemImage)
                Spacer()
                Text(String(format: format, value))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            
            Slider(value: $value, in: range, step: step) { editing in
                // 性能优化核心：松手才触发核心引擎排版
                if !editing { notifyReader() }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(String(format: format, value))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: adjustValue(by: step)
            case .decrement: adjustValue(by: -step)
            @unknown default: break
            }
        }
    }

    /// VoiceOver 摇一摇（adjustable action）走这里；`children: .ignore` 之后
    /// 内部的 `Slider` 对无障碍树不可见，若不显式提供调节动作，该值对
    /// VoiceOver 用户将完全不可调节。
    /// （命名为 adjustValue 而非 step，避免和存储属性 `step: Double` 同名产生歧义）
    private func adjustValue(by amount: Double) {
        let newValue = min(range.upperBound, max(range.lowerBound, value + amount))
        guard newValue != value else { return }
        value = newValue
        notifyReader()
    }
}

// MARK: - 字体选择二级页

/// 字体选择二级菜单：以「所见即所得」的方式逐字展示候选字体，选中项打勾。
///
/// 与 `MarginSettingsView` 一样挂在 `NavigationLink` 下，符合系统设置的层级直觉：
/// 一级页只承担「当前值 + 入口」，把一长串单选搬到独立页里，既不挤占排版页空间，
/// 也避免 `.menu` picker 在小屏上被截断、且无法预览字型的问题。
///
/// 顶部工具栏提供「导入 TTF / OTF」入口；列表分「系统字体」与「已导入字体」两段，
/// 已导入字体支持左滑删除——删除当前选中项时自动回退到默认字体，避免正文渲染崩坏。
struct FontSelectionView: View {
    @Bindable var settings: AppSettings

    @State private var importedFonts: [ImportedFontMeta] = []
    @State private var showingImporter = false
    @State private var showingImportError = false
    @State private var importErrorMessage = ""

    /// `UTType` 没有 `.ttf` / `.otf` 这样的静态成员（那是自己编的，编译不过）；
    /// 系统里只声明了 `.font` 这个大类的 UTI。按扩展名反查具体类型，
    /// 并用 `compactMap` 兜底——理论上这两个系统 UTI 一定存在，
    /// 但按项目规范不对资源加载做强制解包。
    private static let importableFontTypes: [UTType] = {
        ["ttf", "otf"].compactMap { UTType(filenameExtension: $0) }
    }()

    var body: some View {
        List {
            // 内置字体：沿用 FontFamily 既有枚举，所见即所得
            Section {
                ForEach(FontFamily.allCases, id: \.rawValue) { font in
                    fontRow(token: font.rawValue,
                            displayName: font.displayName,
                            preview: font.swiftUIFont(ofSize: 17))
                }
            } header: {
                Text("系统字体")
            }

            // 用户导入字体：从文件系统动态加载，导入 / 删除即时刷新
            Section {
                ForEach(importedFonts) { font in
                    fontRow(token: font.token,
                            displayName: font.displayName,
                            preview: ImportedFontStore.swiftUIFont(token: font.token, size: 20))
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                deleteFont(font)
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                }
            } header: {
                Text("已导入字体")
            } footer: {
                if importedFonts.isEmpty {
                    Text("尚未导入字体。点击下方「导入字体」按钮，从「文件」添加 TTF / OTF。")
                } else {
                    Text("导入的字体仅本机可用；删除当前选中的字体会自动回退到默认字体。")
                }
            }

            // 导入入口：放在字体列表下方，比顶部工具栏更直观、也更好点击
            Section {
                Button {
                    showingImporter = true
                } label: {
                    Label("导入字体", systemImage: "plus")
                }
                .accessibilityLabel("导入字体文件")
                .accessibilityHint("从「文件」应用选择 TTF 或 OTF 字体文件")
            }
        }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: Self.importableFontTypes,
            allowsMultipleSelection: false
        ) { result in
            handleImport(result)
        }
        .alert("导入失败", isPresented: $showingImportError) {
            Button("好", role: .cancel) {}
        } message: {
            Text(importErrorMessage)
        }
        .onAppear {
            importedFonts = ImportedFontStore.all()
        }
    }

    // MARK: 行构造（系统 / 导入共用）

    private func fontRow(token: String, displayName: String, preview: Font) -> some View {
        Button {
            select(token: token)
        } label: {
            HStack(spacing: 12) {
                Text(displayName)
                    .font(preview)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer()
                if settings.fontFamily == token {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.tint)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 30)   // 1. 撑满宽度 + 最小 44pt（HIG 标准）
            .contentShape(Rectangle())                    // 3. 关键：让 Spacer/留白区域可命中
            // .border(.red)                              // 调试时用肉眼的最大值 🐞
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(displayName)
        .accessibilityAddTraits(settings.fontFamily == token ? .isSelected : [])
    }


    // MARK: 行为

    /// 选中某项字体；已选中的再点一次不重复触发重排。
    ///
    /// 这里必须直接 `notifyReader()`，而不是依赖 `TypographySettingsView` 的
    /// `onChange(of: settings.fontFamily)`——本视图一旦被 `NavigationLink` push，
    /// 父视图就从渲染树中移除，其 `onChange` 不再触发，选字后正文会纹丝不动。
    /// 因此通知责任收敛到「修改字体的地方」：`select`、`deleteFont`、`resetToDefaults`
    /// 各自显式通知，父视图不再对 `fontFamily` 挂 `onChange`，也顺带避免了双重通知。
    private func select(token: String) {
        guard settings.fontFamily != token else { return }
        settings.fontFamily = token
        notifyReader()
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        do {
            let urls = try result.get()
            guard let url = urls.first else { return }
            _ = try ImportedFontStore.importFont(from: url)
            importedFonts = ImportedFontStore.all()
        } catch {
            importErrorMessage = error.localizedDescription
            showingImportError = true
        }
    }

    /// 删除一个导入字体；若它正被选中，回退到默认字体并触发阅读器重排。
    private func deleteFont(_ font: ImportedFontMeta) {
        let wasSelected = settings.fontFamily == font.token
        try? ImportedFontStore.delete(font.id)
        importedFonts = ImportedFontStore.all()
        if wasSelected {
            // 回退默认字体同样是修改 fontFamily，需在此直接通知（原因见 select 的注释）。
            settings.fontFamily = FontFamily.LXGWWenKai.rawValue
            notifyReader()
        }
    }
}

// MARK: - 边距设置

struct MarginSettingsView: View {
    @Bindable var settings: AppSettings
    
    var body: some View {
        List {
            Section {
                MarginSlider(
                    title: "上边距",
                    icon: "arrow.up.to.line",
                    value: $settings.marginTop,
                    range: 10...200
                )
                
                MarginSlider(
                    title: "下边距",
                    icon: "arrow.down.to.line",
                    value: $settings.marginBottom,
                    range: 10...200
                )
                
                MarginSlider(
                    title: "左边距",
                    icon: "arrow.left.to.line",
                    value: $settings.marginLeft,
                    range: 10...50
                )
                
                MarginSlider(
                    title: "右边距",
                    icon: "arrow.right.to.line",
                    value: $settings.marginRight,
                    range: 10...50
                )
            } header: {
                Text("页面独立边距 (pt)")
            } footer: {
                Text("更宽的边距通常能带来更专注的阅读体验，但会减少单页可显示的文本量。")
            }
        }
        .navigationTitle("页边距")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct MarginSlider: View {
    let title: String
    let icon: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(title, systemImage: icon)
                Spacer()
                Text("\(Int(value))pt")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: $value, in: range, step: 5) { editing in
                if !editing { notifyReader() }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue("\(Int(value)) 磅")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: adjustValue(by: 5)
            case .decrement: adjustValue(by: -5)
            @unknown default: break
            }
        }
    }

    private func adjustValue(by amount: Double) {
        let newValue = min(range.upperBound, max(range.lowerBound, value + amount))
        guard newValue != value else { return }
        value = newValue
        notifyReader()
    }
}



// MARK: - 全局通知 Helper
fileprivate func notifyReader() {
    NotificationCenter.default.post(name: .appSettingsDidChange, object: nil)
}
