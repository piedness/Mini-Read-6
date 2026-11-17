//
//  关于.swift
//  vellium1218
//
//  Created by Max Piednes on 2026/2/16.
//
import SwiftUI
import SwiftData


// 关于
struct AboutView: View {
    var body: some View {
        List {
            // 应用信息
            Section {
                InfoRow(title: "版本号", value: "0.1029")
                NavigationLink("更新日志") {
                    Text("版本更新记录")
                }
                NavigationLink("开源许可") {
                    Text("第三方开源组件")
                }
                Button("检查更新") {
                    // 检查更新
                }
            } header: {
                Text("应用信息")
            }
            
            // 帮助与支持
            Section {
                NavigationLink("使用教程") {
                    Text("新手引导")
                }
                NavigationLink("常见问题") {
                    Text("FAQ")
                }
                Button("反馈与建议") {
                    // 打开反馈表单
                }
                Button("评分App") {
                    // 跳转App Store
                }
            } header: {
                Text("帮助与支持")
            }
            
        }
        .modifier(CustomListModifier(title: "关于与帮助"))
    }
}


#Preview {
    AboutView()
}
