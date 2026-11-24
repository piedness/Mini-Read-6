//
//  关于.swift
//  vellium1218
//
//  Created by Max Piednes on 2026/2/16.
//
//  「关于与帮助」。
//
//  这一页的每一个事实都来自 GitHub 仓库（https://github.com/piedness/Mini-Read-6）：
//  版本号看 tag、更新日志看 release、许可证看 LICENSE、依赖看 Package.resolved。
//  代码里不写死任何会过期的内容，仓库改了这里就跟着改。
//
//  数据的取用顺序是「缓存 → 网络」：打开页面先用上次同步的结果铺满，
//  再在后台对齐，所以弱网下也不会看到空白或长时间的转圈。
//

import SwiftUI

struct AboutView: View {
    @StateObject private var model = AboutViewModel()
    @Environment(\.openURL) private var openURL

    @State private var updatePrompt: UpdatePrompt?
    @State private var isCheckingUpdate = false

    var body: some View {
        List {
            headerSection
            applicationSection
            supportSection
            syncSection
        }
        .listStyle(.insetGrouped)
        .modifier(CustomListModifier(title: "关于与帮助"))
        .task { await model.loadIfNeeded() }
        .refreshable { await model.refresh() }
        .alert(item: $updatePrompt) { prompt in
            alert(for: prompt)
        }
    }

    // MARK: - 头部

    private var headerSection: some View {
        Section {
            VStack(spacing: 12) {
                AppIconBadge()

                VStack(spacing: 3) {
                    Text(appName)
                        .font(.system(.title2, design: .serif).weight(.semibold))
                        .foregroundStyle(.primary)

                    Text("版本 \(model.installedVersion.display)")
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                if let tagline {
                    Text(tagline)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 12)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(appName)，版本 \(model.installedVersion.display)")
        }
    }

    // MARK: - 应用信息

    private var applicationSection: some View {
        Section {
            AboutValueRow(title: "当前版本", value: model.installedVersion.display)

            if let release = model.latestRelease {
                NavigationLink {
                    ReleaseDetailView(release: release)
                } label: {
                    AboutValueRow(
                        title: "最新发布",
                        subtitle: release.dateText,
                        value: release.displayVersion,
                        badge: model.updateAvailable ? "可更新" : nil
                    )
                }
            }

            NavigationLink {
                ChangelogView(model: model)
            } label: {
                AboutValueRow(
                    title: "更新日志",
                    value: model.releaseCount > 0 ? "\(model.releaseCount) 个版本" : nil
                )
            }

            NavigationLink {
                LicensesView()
            } label: {
                AboutValueRow(title: "开源许可", value: licenseBadge)
            }

            Button {
                Task { await checkForUpdate() }
            } label: {
                HStack(spacing: 8) {
                    Text("检查更新")
                        .foregroundStyle(.primary)
                    Spacer(minLength: 8)
                    if isCheckingUpdate {
                        ProgressView()
                            .controlSize(.small)
                    } else if model.updateAvailable, let version = model.latestRelease?.displayVersion {
                        Text("可更新至 \(version)")
                            .font(.footnote)
                            .foregroundStyle(Color.accentColor)
                    }
                }
            }
            .disabled(isCheckingUpdate)
            .accessibilityHint("与 GitHub 上的最新发布比较版本号")
        } header: {
            Text("应用信息")
        }
    }

    // MARK: - 帮助与支持

    private var supportSection: some View {
        Section {
            AboutExternalLinkRow(
                title: "反馈与建议",
                destination: GitHubAboutEndpoint.webNewIssue
            )

            AboutExternalLinkRow(
                title: "GitHub 仓库",
                destination: GitHubAboutEndpoint.webRepository,
                subtitle: lastPushText,
                value: starCountText
            )
        } header: {
            Text("帮助与支持")
        }
    }

    // MARK: - 同步状态

    private var syncSection: some View {
        Section {
            Button {
                Task { await model.refresh() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: statusIcon)
                        .font(.body)
                        .foregroundStyle(statusTint)
                        .frame(width: 22)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(statusTitle)
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)

                        if let statusDetail {
                            Text(statusDetail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    Spacer(minLength: 8)

                    if model.isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .disabled(model.isRefreshing)
            .accessibilityHint("重新从 GitHub 同步")
        }
    }

    // MARK: - 派生文案

    private var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Mini Read"
    }

    /// 仓库简介。GitHub 上的写法是「Mini Read 6 ： 一款……」，标题下面再出现一遍
    /// 应用名很啰嗦，所以把冒号前那截应用名去掉，只留真正的描述。
    private var tagline: String? {
        guard var text = model.snapshot?.repo.description?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !text.isEmpty
        else { return nil }

        if let separator = text.range(of: "：") ?? text.range(of: ":") {
            let head = text[text.startIndex..<separator.lowerBound].lowercased()
            if head.contains("mini read") {
                text = String(text[separator.upperBound...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return text.isEmpty ? nil : text
    }

    private var licenseBadge: String? {
        guard let license = model.snapshot?.repo.license else { return nil }
        return license.spdxId ?? license.name
    }

    private var starCountText: String? {
        guard let count = model.snapshot?.repo.stargazersCount else { return nil }
        return "\(count) 星标"
    }

    /// 仓库最近一次推送的时间。它比「星标数」更能说明这个项目还在往前走。
    private var lastPushText: String? {
        guard let date = model.snapshot?.repo.pushedAt else { return nil }
        return "最近更新 \(date.formatted(date: .abbreviated, time: .omitted))"
    }

    private var statusIcon: String {
        if model.error != nil { return "exclamationmark.icloud" }
        return model.snapshot == nil ? "icloud.slash" : "checkmark.icloud"
    }

    private var statusTint: Color {
        model.error != nil ? .orange : .secondary
    }

    private var statusTitle: String {
        if model.isRefreshing, model.snapshot == nil {
            return "正在从 GitHub 同步…"
        }
        if model.error != nil {
            return model.isShowingStaleContent ? "同步失败，显示的是缓存内容" : "同步失败"
        }
        return model.snapshot == nil ? "尚未同步" : "数据来自 GitHub"
    }

    private var statusDetail: String? {
        if let error = model.error {
            return [error.errorDescription, error.recoverySuggestion]
                .compactMap { $0 }
                .joined(separator: "。")
        }
        guard let last = model.lastSyncText else { return nil }
        return "上次同步 \(last)"
    }

    // MARK: - 检查更新

    private func checkForUpdate() async {
        guard !isCheckingUpdate else { return }
        isCheckingUpdate = true
        defer { isCheckingUpdate = false }

        triggerHaptic(.light)

        switch await model.checkForUpdate() {
        case .upToDate(let latest):
            triggerNotificationHaptic(.success)
            updatePrompt = .upToDate(latest)
        case .updateAvailable(let release):
            triggerNotificationHaptic(.warning)
            updatePrompt = .available(release)
        case .failed(let message):
            triggerNotificationHaptic(.error)
            updatePrompt = .failed(message)
        }
    }

    private func alert(for prompt: UpdatePrompt) -> Alert {
        switch prompt {
        case .upToDate(let latest):
            return Alert(
                title: Text("已是最新版本"),
                message: Text("当前 \(model.installedVersion.display)，GitHub 最新发布为 \(latest)。"),
                dismissButton: .default(Text("好"))
            )

        case .available(let release):
            return Alert(
                title: Text("发现新版本 \(release.displayVersion)"),
                message: Text(release.dateText.map { "发布于 \($0)。" } ?? "GitHub 上已有新的发布。"),
                primaryButton: .default(Text("查看")) {
                    openURL(release.htmlURL)
                },
                secondaryButton: .cancel(Text("稍后"))
            )

        case .failed(let message):
            return Alert(
                title: Text("检查更新失败"),
                message: Text(message),
                dismissButton: .default(Text("好"))
            )
        }
    }
}

// MARK: - 检查更新的弹窗状态

private enum UpdatePrompt: Identifiable {
    case upToDate(String)
    case available(GitHubRelease)
    case failed(String)

    var id: String {
        switch self {
        case .upToDate(let latest): return "up-to-date-\(latest)"
        case .available(let release): return "available-\(release.id)"
        case .failed(let message): return "failed-\(message)"
        }
    }
}

// MARK: - 通用行

/// 「标题（副标题） —— 值」的只读行。与 `InfoRow` 的区别是多了副标题与徽标，
/// 用来承载「最新发布 2026年11月23日 1.0.6 可更新」这类信息。
struct AboutValueRow: View {
    let title: String
    var subtitle: String? = nil
    var value: String? = nil
    var badge: String? = nil

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .foregroundStyle(.primary)

                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)

            if let badge {
                Text(badge)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.accentColor.opacity(0.12)))
            }

            if let value {
                Text(value)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// 打开外部网页的行。统一用「右上箭头」表示会离开 App，
/// 比把文字染成蓝色更安静，也和列表里的其它行同一套排版。
struct AboutExternalLinkRow: View {
    let title: String
    let destination: URL
    var subtitle: String? = nil
    var value: String? = nil

    var body: some View {
        Link(destination: destination) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .foregroundStyle(.primary)

                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 8)

                if let value {
                    Text(value)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Image(systemName: "arrow.up.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .accessibilityHint("在浏览器中打开")
    }
}

// MARK: - 应用图标

/// 应用图标。
///
/// 工程用的是 Icon Composer 的 `.icon` 资源，运行时拿不到 `UIImage`，
/// 所以这里先尝试常见命名，取不到就画一个同色系的占位——
/// 占位也要体面，不要放一个灰方块。
struct AppIconBadge: View {
    @ScaledMetric(relativeTo: .title) private var side: CGFloat = 76

    var body: some View {
        Group {
            if let icon = Self.bundledIcon {
                Image(uiImage: icon)
                    .resizable()
                    .scaledToFit()
            } else {
                placeholder
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: side * 0.225, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: side * 0.225, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.16), radius: 10, y: 5)
        .accessibilityHidden(true)
    }

    private static var bundledIcon: UIImage? {
        for name in ["AppIcon", "AppIcon60x60"] {
            if let image = UIImage(named: name) { return image }
        }
        return nil
    }

    private var placeholder: some View {
        // 按 `Resources/miniread.icon/icon.json` 里记录的配方复刻：
        // 鼠尾草绿 → 暖粉的竖向渐变，上面叠一层 50% 的羊皮纸纹理。
        // 数字直接取自该文件（display-p3 分量），图标改版时同步改这里。
        ZStack {
            LinearGradient(
                colors: [
                    Color(.displayP3, red: 0.80831, green: 0.88902, blue: 0.71426),
                    Color(.displayP3, red: 0.96783, green: 0.81227, blue: 0.78878)
                ],
                startPoint: UnitPoint(x: 0.5, y: 1),
                endPoint: UnitPoint(x: 0.5, y: 0.3)
            )

            Image("PaperParchment")
                .resizable()
                .scaledToFill()
                .opacity(0.5)
        }
        .clipped()
    }
}

#Preview {
    NavigationStack {
        AboutView()
    }
}
