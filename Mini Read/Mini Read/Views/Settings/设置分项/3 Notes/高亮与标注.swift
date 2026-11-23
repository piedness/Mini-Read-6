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

    /// 线条粗细与指示器样式都存字符串：旧配置文件里可能是无法识别的值，
    /// 读取端统一回落到默认档，而不是让 Picker 空选一行。
    private var lineWeightBinding: Binding<AnnotationLineWeight> {
        Binding(
            get: { AnnotationLineWeight(rawValue: settings.annotationLineWeight) ?? .standard },
            set: { settings.annotationLineWeight = $0.rawValue; notifyReader() }
        )
    }

    private var indicatorStyleBinding: Binding<NoteIndicatorStyle> {
        Binding(
            get: { NoteIndicatorStyle(rawValue: settings.noteIndicatorStyle) ?? .bar },
            set: { settings.noteIndicatorStyle = $0.rawValue; notifyReader() }
        )
    }

    var body: some View {
        List {
            // 高亮颜色
            Section {
                Picker("默认高亮颜色", selection: $settings.defaultHighlightColor) {
                    // 直接遍历 `AnnotationColor`：色板、名称、色值只有一处定义，
                    // 以后加颜色不用再回来改这个 Picker。
                    ForEach(AnnotationColor.allCases) { color in
                        HStack(spacing: 10) {
                            Circle()
                                .fill(color.color)
                                .frame(width: 18, height: 18)
                            Text(color.displayName)
                        }
                        .tag(color.rawValue)
                    }
                }
                .onChange(of: settings.defaultHighlightColor) { _, _ in notifyReader() }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("底色透明度")
                        Spacer()
                        Text("\(Int(settings.highlightOpacity * 100))%")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: $settings.highlightOpacity, in: 0.1...0.7, step: 0.05)
                        .onChange(of: settings.highlightOpacity) { _, _ in notifyReader() }
                }
            } header: {
                Text("高亮颜色")
            }

            // 标注样式
            Section {
                Picker("默认标注样式", selection: $settings.defaultAnnotationStyle) {
                    ForEach(AnnotationStyle.allCases) { style in
                        Label(style.displayName, systemImage: style.systemImage)
                            .tag(style.rawValue)
                    }
                }
                .onChange(of: settings.defaultAnnotationStyle) { _, _ in notifyReader() }

                Picker("线条粗细", selection: lineWeightBinding) {
                    ForEach(AnnotationLineWeight.allCases) { weight in
                        Text(weight.displayName).tag(weight)
                    }
                }
            } header: {
                Text("标注样式")
            }

            // 标注交互
            Section {
                Toggle("显示笔记指示器", isOn: $settings.showNoteIndicators)
                    .onChange(of: settings.showNoteIndicators) { _, _ in notifyReader() }

                if settings.showNoteIndicators {
                    Picker("指示器样式", selection: indicatorStyleBinding) {
                        ForEach(NoteIndicatorStyle.allCases) { style in
                            Text(style.displayName).tag(style)
                        }
                    }
                }

            } header: {
                Text("标注交互")
            }

            // 笔记面板
            Section {
                Toggle("在「笔记」页签显示标注数量", isOn: $settings.showNoteCount)
            } header: {
                Text("笔记面板")
            }
        }
        .modifier(CustomListModifier(title: "高亮与标注"))
    }
}

/// 设置写入 SwiftData 后，正在阅读的 `MainViewController` 不会自动重读：
/// 透明度、线宽、指示器都是建页时捕获的绘制参数，必须显式通知它重建页面。
/// 与 `文字排版` / `阅读辅助` 里同名的私有函数是同一套约定。
fileprivate func notifyReader() {
    NotificationCenter.default.post(name: .appSettingsDidChange, object: nil)
}
