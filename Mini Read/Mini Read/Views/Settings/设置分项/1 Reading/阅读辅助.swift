//
//  阅读辅助.swift
//  vellium1218
//
//  Created by Max Piednes on 2026/2/16.
//
import SwiftUI
import SwiftData

// 阅读辅助
struct ReadingAssistView: View {
    @Bindable var settings: AppSettings

    // MARK: - 页码

    /// 页码位置（底部偏左 / 中间 / 偏右）。历史值由 ReaderChrome 归一。
    private var pageNumberPositionBinding: Binding<String> {
        Binding(
            get: { ReaderChrome.pageNumberPositionTag(settings.pageNumberPosition) },
            set: { settings.pageNumberPosition = $0; notifyReader() }
        )
    }

    private var pageNumberFormatBinding: Binding<String> {
        Binding(
            get: { ReaderChrome.PageNumberFormat(rawValue: settings.pageNumberFormat)?.rawValue
                    ?? ReaderChrome.PageNumberFormat.book.rawValue },
            set: { settings.pageNumberFormat = $0; notifyReader() }
        )
    }

    // MARK: - 章节标题

    /// 标题位置（顶部偏左 / 中间 / 偏右）。历史值由 ReaderChrome 归一。
    private var chapterTitlePositionBinding: Binding<String> {
        Binding(
            get: { ReaderChrome.chapterTitlePositionTag(settings.chapterTitlePosition) },
            set: { settings.chapterTitlePosition = $0; notifyReader() }
        )
    }

    var body: some View {
        List {
            // 页码
            Section {
                Toggle("显示页码", isOn: $settings.showPageNumber)

                if settings.showPageNumber {
                    Picker("位置", selection: pageNumberPositionBinding) {
                        Text("底部偏左").tag("bottom left")
                        Text("底部中间").tag("bottom center")
                        Text("底部偏右").tag("bottom right")
                    }
                    Picker("格式", selection: pageNumberFormatBinding) {
                        Text("当前页码 / 整书页数").tag(ReaderChrome.PageNumberFormat.book.rawValue)
                        Text("本章页码 / 本章页数").tag(ReaderChrome.PageNumberFormat.chapter.rawValue)
                        Text("仅当前页码").tag(ReaderChrome.PageNumberFormat.current.rawValue)
                    }
                }
            } header: {
                Text("页码")
            }

            // 章节标题
            Section {
                Toggle("显示章节标题", isOn: $settings.showChapterTitle)

                if settings.showChapterTitle {
                    Picker("位置", selection: chapterTitlePositionBinding) {
                        Text("顶部偏左").tag("top left")
                        Text("顶部中间").tag("top center")
                        Text("顶部偏右").tag("top right")
                    }
                }
            } header: {
                Text("章节标题")
            }

            // 沉浸模式
            Section {
                Toggle("自动隐藏工具栏", isOn: $settings.autoHideToolbar)

                if settings.autoHideToolbar {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("延迟时间")
                            Spacer()
                            Text("\(Int(settings.toolbarHideDelay))秒")
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $settings.toolbarHideDelay, in: 1...10, step: 1)
                    }
                }
                Toggle("阅读时保持屏幕常亮", isOn: $settings.keepScreenOn)
            } header: {
                Text("沉浸模式")
            }
        }
        .modifier(CustomListModifier(title: "辅助功能"))
    }
}

// MARK: - 通知 Helper

/// 页眉/页脚元素直接改变阅读页的布局与内容，改完必须让阅读器重排重绘。
/// （沉浸模式两项由 BookContent 的 @Query 自行观察，无需广播。）
fileprivate func notifyReader() {
    NotificationCenter.default.post(name: .appSettingsDidChange, object: nil)
}
