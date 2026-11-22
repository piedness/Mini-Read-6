//
//  阅读背景.swift
//  TheNewVellium
//
//  阅读背景设置页。
//
//  页面的职责只有三件：让用户**看见**当前纸面、**挑**一张新纸面、**退回**默认。
//  所有解析规则与预设定义都在 `ReadingBackground.swift`，
//  这里只负责呈现，不重复任何回退逻辑。
//
//  Created by Max Piednes on 2026/2/16.
//

import SwiftUI
import SwiftData
import UIKit

// MARK: - 模式展示名

extension ReadingBackgroundMode {
    var shortName: String {
        switch self {
        case .solidColor: return "纯色"
        case .image:      return "纸张纹理"
        }
    }
}

// MARK: - 阅读背景

struct ThemeColorSettingsView: View {
    @Bindable var settings: AppSettings

    /// 上一次已经同步给阅读器的色值。
    ///
    /// 取色盘拖动是连续事件，这里记下"已送达"的值，把中间的连续变更合并成一次重排。
    @State private var syncedColorHex: String?

    private var mode: ReadingBackgroundMode {
        ReadingBackgroundMode(rawValue: settings.readingBackgroundMode) ?? ReadingBackgroundDefaults.mode
    }

    private var selectedColorHex: String { settings.readingBackgroundColorHex }

    // MARK: - Body

    var body: some View {
        List {
            Section {
                Picker("背景类型", selection: $settings.readingBackgroundMode) {
                    ForEach(ReadingBackgroundMode.allCases) { mode in
                        Text(mode.shortName).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .padding(.vertical, 4)
            } header: {
                Text("背景类型")
            }

            if mode == .image {
                paperSections
            } else {
                solidColorSections
            }

            Section {
                Button(role: .destructive) {
                    resetToDefaults()
                } label: {
                    HStack {
                        Spacer()
                        Text("恢复默认背景")
                        Spacer()
                    }
                }
                .accessibilityLabel("恢复默认阅读背景")
            }
        }
        .modifier(CustomListModifier(title: "阅读背景"))
        .onChange(of: settings.readingBackgroundMode) { _, _ in
            postChange()
        }
        .task(id: settings.readingBackgroundColorHex) {
            await syncColorChange()
        }
    }

    // MARK: - 纯色

    @ViewBuilder
    private var solidColorSections: some View {
        Section {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 78), spacing: 12)], spacing: 14) {
                ForEach(ReadingSolidPreset.all) { preset in
                    SolidColorSwatch(
                        preset: preset,
                        isSelected: isSelected(preset)
                    ) {
                        select(preset)
                    }
                }
            }
            .padding(.vertical, 8)
            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
        } header: {
            Text("预设纸色")
        }

        Section {
            ColorPicker(
                "自定义颜色",
                selection: customColorBinding,
                supportsOpacity: false
            )
        } header: {
            Text("自定义")
        }
    }

    // MARK: - 纸张纹理

    @ViewBuilder
    private var paperSections: some View {
        Section {
            
            HStack {
                ForEach(ReadingPaperPreset.allCases) { preset in
                    PaperPresetCard(
                        preset: preset,
                        isSelected: settings.readingBackgroundImageSource == preset.rawValue
                    ) {
                        select(preset)
                    }
                }
            }
            .padding(8)
            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
        } header: {
            Text("内置纸张")
        }
    }

    // MARK: - 选择

    private func isSelected(_ preset: ReadingSolidPreset) -> Bool {
        selectedColorHex.caseInsensitiveCompare(preset.hex) == .orderedSame
    }

    private func select(_ preset: ReadingSolidPreset) {
        guard !isSelected(preset) || mode != .solidColor else { return }

        settings.readingBackgroundMode     = ReadingBackgroundMode.solidColor.rawValue
        settings.readingBackgroundColorHex = preset.hex
        syncedColorHex                     = preset.hex

        triggerHaptic(.light)
        postChange()
    }

    private func select(_ preset: ReadingPaperPreset) {
        let alreadyApplied = mode == .image && settings.readingBackgroundImageSource == preset.rawValue
        guard !alreadyApplied else { return }

        settings.readingBackgroundMode        = ReadingBackgroundMode.image.rawValue
        settings.readingBackgroundImageSource = preset.rawValue

        // 先把位图解好，真正进书时建页发生在缓存命中之后
        ReadingBackgroundImageLoader.shared.prewarm(preset)

        triggerHaptic(.light)
        postChange()
    }

    // MARK: - 色盘同步

    /// 尾随去抖：拖动停止 0.5s 后才通知阅读器重排。
    ///
    /// `task(id:)` 在新值到来时会取消上一个任务，因此天然只保留最后一次。
    private func syncColorChange() async {
        guard let synced = syncedColorHex else {
            syncedColorHex = settings.readingBackgroundColorHex   // 首帧只建立基线
            return
        }
        guard synced != settings.readingBackgroundColorHex else { return }

        try? await Task.sleep(nanoseconds: ReadingBackgroundTiming.changeDebounceNanoseconds)
        guard !Task.isCancelled else { return }

        syncedColorHex = settings.readingBackgroundColorHex
        triggerHaptic(.light)
        postChange()
    }

    private var customColorBinding: Binding<Color> {
        Binding(
            get: { Color(hex: settings.readingBackgroundColorHex) ?? .white },
            set: { newValue in
                settings.readingBackgroundColorHex = UIColor(newValue).srgbHexString
                    ?? ReadingBackgroundDefaults.colorHex
            }
        )
    }

    // MARK: - 重置

    private func resetToDefaults() {
        settings.resetReadingBackgroundToDefaults()
        syncedColorHex = ReadingBackgroundDefaults.colorHex
        triggerHaptic(.light)
        postChange()
    }

    // MARK: - 通知

    // 这里原本有一个判断开关的 `haptic()` 包装，现已删除：
    // 开关的判断收进了 `triggerHaptic` 内部（见 `Utils/Haptics.swift`），
    // 各页再包一层就是第二份真值，迟早会和总闸不一致。
    private func postChange() {
        NotificationCenter.default.post(name: .appSettingsDidChange, object: nil)
    }
}


// MARK: - 纯色色卡

private struct SolidColorSwatch: View {
    let preset: ReadingSolidPreset
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(preset.color)
                        .frame(height: 56)
                        .overlay {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                        }

                    if isSelected {
                        // 对勾用该色自身的对比墨色画：白纸上画深勾、夜读上画浅勾
                        Image(systemName: "checkmark")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(
                                ReadingTextTone(contrastingFor: preset.hex).swiftUIInk
                            )
                            .transition(.scale.combined(with: .opacity))
                    }
                }

                Text(preset.name)
                    .font(.caption2)
                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.28, dampingFraction: 0.7), value: isSelected)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(preset.name)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - 纸张纹理卡片

private struct PaperPresetCard: View {
    let preset: ReadingPaperPreset
    let isSelected: Bool
    let onTap: () -> Void

    @State private var thumbnail: UIImage?

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 8) {
                ZStack {
                    Rectangle()
                        .fill(Color(hex: preset.fallbackColorHex) ?? .white)

                    if let thumbnail {
                        Image(uiImage: thumbnail)
                            .resizable()
                            .scaledToFill()
                            .transition(.opacity)
                    }
                }
                .frame(width: 80, height: 80)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(
                            isSelected ? Color.accentColor : Color.primary.opacity(0.12),
                            lineWidth: isSelected ? 2.5 : 1
                        )
                }

                HStack(spacing: 4) {
                    Text(preset.displayName)
                        .font(.footnote)
                        .foregroundStyle(isSelected ? Color.primary : Color.secondary)

                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(Color.accentColor)
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.28, dampingFraction: 0.72), value: isSelected)
        .task {
            thumbnail = await ReadingBackgroundImageLoader.shared.imageAsync(
                for: preset,
                pixelDimension: ReadingBackgroundImageLoader.thumbnailPixelDimension
            )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(preset.displayName)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}
