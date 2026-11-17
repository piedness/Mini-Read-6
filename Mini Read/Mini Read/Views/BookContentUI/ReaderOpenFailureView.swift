//
//  ReaderOpenFailureView.swift
//  TheNewVellium
//
//  阅读器打开失败时的唯一界面（2026-10-30）。
//
//  在此之前，解析失败只会让 `canOpenReader` 永远停在 false，读者看到的是
//  一个没有终点、没有解释、没有出口的 ProgressView。失败态必须回答三个问题：
//  1. 发生了什么（标题 + 一句人话）；
//  2. 我能做什么（重试）；
//  3. 我不想再看到这本书（从书库移除）。
//

import SwiftUI

struct ReaderOpenFailureView: View {
    let bookTitle: String
    let failure: ReaderLoadFailure
    let onRetry: () -> Void
    let onRemove: () -> Void
    let onClose: () -> Void

    @State private var showsRemoveConfirmation = false

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    Spacer(minLength: 24)

                    icon

                    Text(bookTitle)
                        .font(.system(.footnote, design: .serif).weight(.medium))
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .padding(.top, 22)

                    Text(failure.title)
                        .font(.system(.title2, design: .serif).weight(.semibold))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.center)
                        .padding(.top, 6)
                        .accessibilityAddTraits(.isHeader)

                    Text(failure.message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 12)

                    actions
                        .padding(.top, 28)

                    Spacer(minLength: 24)
                }
                .padding(.horizontal, 32)
                .frame(maxWidth: 440)
                .frame(maxWidth: .infinity)
                // 大字号下内容会超过一屏：给一个最小高度让它在常规字号下垂直居中，
                // 超出时自然变成可滚动，而不是被裁掉。
                .frame(minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(Color(uiColor: .systemBackground))
        .confirmationDialog(
            "从书库移除「\(bookTitle)」？",
            isPresented: $showsRemoveConfirmation,
            titleVisibility: .visible
        ) {
            Button("移除", role: .destructive, action: onRemove)
            Button("取消", role: .cancel) {}
        } message: {
            Text("书籍文件和阅读记录会一起删除，此操作无法撤销。")
        }
    }

    // MARK: - 视觉

    private var icon: some View {
        ZStack {
            Circle()
                .fill(Color.secondary.opacity(0.10))
                .frame(width: 76, height: 76)

            Image(systemName: "book.closed")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.secondary)
        }
        .accessibilityHidden(true)
    }

    private var actions: some View {
        VStack(spacing: 12) {
            Button(action: onRetry) {
                Text("重试")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 46)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle(radius: 12))
            .accessibilityHint("重新读取这本书的文件")

            Button(role: .destructive) {
                showsRemoveConfirmation = true
            } label: {
                Text("从书库移除")
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 44)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.roundedRectangle(radius: 12))

            Button("返回书库", action: onClose)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(minHeight: 44)
                .accessibilityHint("关闭阅读器，回到书架")
        }
    }
}
