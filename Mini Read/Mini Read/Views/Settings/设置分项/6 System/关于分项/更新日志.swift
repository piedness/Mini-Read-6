//
//  更新日志.swift
//  Mini Read
//
//  发布记录列表与单条详情。
//
//  数据直接来自 GitHub Releases：仓库打一个 tag、发一次 release，这里就多一条。
//  刻意不在 App 里维护一份手写 changelog——手写的版本迟早会和仓库对不上。
//

import SwiftUI

// MARK: - 列表

struct ChangelogView: View {
    @ObservedObject var model: AboutViewModel

    private var releases: [GitHubRelease] {
        (model.snapshot?.releases ?? []).filter { !$0.draft }
    }

    var body: some View {
        Group {
            if releases.isEmpty {
                emptyState
            } else {
                List {
                    Section {
                        ForEach(releases) { release in
                            NavigationLink {
                                ReleaseDetailView(release: release)
                            } label: {
                                ReleaseRow(
                                    release: release,
                                    isLatest: release.id == model.latestRelease?.id
                                )
                            }
                        }
                    } footer: {
                        Link("在 GitHub 查看全部发布", destination: GitHubAboutEndpoint.webReleases)
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("更新日志")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await model.refresh() }
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.isRefreshing {
            ProgressView("正在读取发布记录…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView {
                Label("没有发布记录", systemImage: "tag.slash")
            } description: {
                Text(model.error?.errorDescription ?? "仓库里还没有发布版本。")
            } actions: {
                Button("重试") {
                    Task { await model.refresh() }
                }
            }
        }
    }
}

// MARK: - 行

private struct ReleaseRow: View {
    let release: GitHubRelease
    let isLatest: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(release.displayVersion)
                    .font(.headline.monospacedDigit())

                if isLatest {
                    ReleaseBadge(text: "最新", isProminent: true)
                }
                if release.prerelease {
                    ReleaseBadge(text: "预发布", isProminent: false)
                }

                Spacer(minLength: 0)
            }

            if let title = release.conciseTitle {
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if let date = release.dateText {
                Text(date)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        var parts = ["版本 \(release.displayVersion)"]
        if isLatest { parts.append("最新发布") }
        if release.prerelease { parts.append("预发布") }
        if let date = release.dateText { parts.append("发布于 \(date)") }
        return parts.joined(separator: "，")
    }
}

private struct ReleaseBadge: View {
    let text: String
    let isProminent: Bool

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(isProminent ? Color.accentColor : Color.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(
                Capsule().fill(
                    isProminent ? Color.accentColor.opacity(0.12) : Color(.tertiarySystemFill)
                )
            )
    }
}

// MARK: - 详情

struct ReleaseDetailView: View {
    let release: GitHubRelease

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header

                Divider()

                if let notes = cleanedNotes {
                    RemoteMarkdownView(notes)
                } else {
                    Text("该版本没有提供更新说明。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Link(destination: detailURL) {
                    Label(detailLinkTitle, systemImage: "arrow.up.right.square")
                        .font(.callout)
                }
            }
            .padding(20)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(release.displayVersion)
        .navigationBarTitleDisplayMode(.inline)
        .textSelection(.enabled)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(release.displayVersion)
                    .font(.system(.largeTitle, design: .serif).weight(.semibold).monospacedDigit())

                if release.prerelease {
                    ReleaseBadge(text: "预发布", isProminent: false)
                }
            }

            if let title = release.conciseTitle {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 12) {
                if let date = release.dateText {
                    Label(date, systemImage: "calendar")
                }
                Text(release.tagName)
                    .font(.caption.monospaced())
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    /// GitHub 自动生成的说明里有一行 `**Full Changelog**: https://…/compare/…`。
    /// 这行在正文里又长又碍眼，摘出来单独做底部链接更合适。
    private var cleanedNotes: String? {
        guard let notes = release.notes else { return nil }

        let filtered = notes
            .components(separatedBy: .newlines)
            .filter { !Self.isFullChangelogLine($0) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return filtered.isEmpty ? nil : filtered
    }

    private var compareURL: URL? {
        guard let notes = release.notes else { return nil }
        for line in notes.components(separatedBy: .newlines) where Self.isFullChangelogLine(line) {
            guard let range = line.range(of: "https://") else { continue }
            let candidate = String(line[range.lowerBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let url = URL(string: candidate) { return url }
        }
        return nil
    }

    private var detailURL: URL { compareURL ?? release.htmlURL }

    private var detailLinkTitle: String {
        compareURL == nil ? "在 GitHub 查看此版本" : "查看完整变更"
    }

    private static func isFullChangelogLine(_ line: String) -> Bool {
        let lowercased = line.lowercased()
        return lowercased.contains("full changelog") && lowercased.contains("http")
    }
}

#Preview("列表") {
    NavigationStack {
        List {
            ReleaseRow(
                release: GitHubRelease(
                    id: 2,
                    tagName: "v1.0.6",
                    name: "Mini-Read 1.0.6",
                    publishedAt: .now
                ),
                isLatest: true
            )
        }
    }
}

#Preview("详情") {
    NavigationStack {
        ReleaseDetailView(
            release: GitHubRelease(
                id: 1,
                tagName: "v1.0.6",
                name: "Mini-Read 1.0.6",
                body: """
                ## 新增
                - 长按按**整句**选中，不跨段落
                - 标注样式与颜色可分别设置

                **Full Changelog**: https://github.com/piedness/Mini-Read-6/compare/v1.0.4...v1.0.6
                """,
                publishedAt: .now
            )
        )
    }
}
