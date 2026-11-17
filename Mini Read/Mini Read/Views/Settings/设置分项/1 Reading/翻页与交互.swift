//
//  翻页与交互.swift
//  vellium1218
//
//  Created by Max Piednes on 2026/2/16.
//

import SwiftUI
import SwiftData

// 翻页与交互
struct PageTurningSettingsView: View {
    @Bindable var settings: AppSettings
    
    var body: some View {
        List {
            // 翻页方式
            Section {
                // tag 直接取 `PageTurnStyle.rawValue`：枚举与持久化值只此一处对应，
                // 手写字符串很容易改了一边忘了另一边，而那种错位的表现是
                // "点了没反应，也没有任何日志"。
                Picker("翻页方式", selection: $settings.pageTransitionStyle) {
                    ForEach(PageTurnStyle.allCases) { style in
                        Label(style.displayName, systemImage: style.systemImage)
                            .tag(style.rawValue)
                    }
                }
            } header: {
                Text("翻页方式")
            } footer: {
                Text("开启「降低动态效果」时自动改用连续滑动；iPad 双页模式固定使用仿真翻页。")
            }
            
            // 手势控制
            Section {
                Toggle("音量键翻页", isOn: $settings.volumeKeysTurn)
            } header: {
                Text("手势控制")
            } footer: {
                Text("暂时接管音量键，无法调节音量，下拉控制中心可短暂解除")
            }
        }
        .modifier(CustomListModifier(title: "翻页与交互"))
        // 归一化无法识别的存量值（旧版本的 "scroll"、外部导入的配置文件）。
        // 不归一会让 Picker 停在"没有任何一行被选中"的状态——看起来像设置坏了。
        .onAppear {
            guard PageTurnStyle(rawValue: settings.pageTransitionStyle) == nil else { return }
            settings.pageTransitionStyle = PageTurnStyle.curl.rawValue
            postChange()
        }
        // 翻页样式是 `UIPageViewController` 的 init 参数，阅读器必须整只换掉容器
        // 才能生效。它靠这条广播被唤起——本页此前**从未**广播过任何变更，
        // 所以音量键那个开关一直是等下次 `viewDidAppear` 才生效的。
        // 翻页样式不能等：用户改完抬头就要看到效果。
        .onChange(of: settings.pageTransitionStyle) { _, _ in
            postChange()
        }
    }

    // MARK: - 通知

    private func postChange() {
        NotificationCenter.default.post(name: .appSettingsDidChange, object: nil)
    }
}

