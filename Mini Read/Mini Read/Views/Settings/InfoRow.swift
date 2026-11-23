//
//  InfoRow.swift
//  TheNewVellium
//
//  设置页通用的「标题 —— 值」只读行。
//
//  原先定义在 `笔记系统.swift` 里，但那个页面自己并不用它，真正的调用方是
//  「关于」与「存储管理」。页面下线后移到独立文件，避免为了一个 10 行的
//  视图把整页设置留住。
//

import SwiftUI

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
