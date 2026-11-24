//
//  开源许可.swift
//  Mini Read
//
//  许可证清单。
//
//  两份数据、两个来源，都不写死：
//  - 本应用的许可证：仓库的 `/license` 接口（名称、SPDX、正文一次拿全）；
//  - 第三方依赖：仓库里的 `Package.resolved`，逐个点进去再按需取它的许可证。
//
//  为什么依赖不一次性全取：每条依赖都要一次接口调用，而用户通常只看一两条。
//  按需加载把「打开页面」的代价压到一次请求，也把配额留给真正要看的正文。
//

import SwiftUI
internal import Combine

// MARK: - 页面

struct LicensesView: View {
    @StateObject private var model = LicenseCatalogModel()

    var body: some View {
        List {
            Section {
                if let license = model.appLicense {
                    NavigationLink {
                        LicensePage(
                            title: license.displayName,
                            document: license,
                            footnote: "本应用以 \(license.displayName) 发布。"
                        )
                    } label: {
                        AboutValueRow(title: license.displayName, value: license.spdx)
                    }
                } else if model.isLoading {
                    loadingRow("正在读取许可证…")
                } else {
                    AboutExternalLinkRow(
                        title: "在 GitHub 查看 LICENSE",
                        destination: GitHubAboutEndpoint.webRepository.appending(path: "blob/main/LICENSE")
                    )
                }
            } header: {
                Text("本应用")
            }

            Section {
                ForEach(model.packages) { package in
                    NavigationLink {
                        DependencyLicenseView(package: package)
                    } label: {
                        AboutValueRow(
                            title: package.name,
                            subtitle: package.slug.map { "\($0.owner)/\($0.repo)" },
                            value: package.versionText
                        )
                    }
                }

                if model.packages.isEmpty, model.isLoading {
                    loadingRow("正在读取依赖清单…")
                }
            } header: {
                Text("第三方组件")
            }
//                footer: {
//                Text("列表取自仓库中的 Package.resolved，随依赖升级自动更新。Apple 系统框架随系统提供，不在本列表内。")
//            }

            if let errorMessage = model.errorMessage {
                Section {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Button("重试") {
                        Task { await model.reload() }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("开源许可")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.loadIfNeeded() }
        .refreshable { await model.reload() }
    }

    private func loadingRow(_ text: String) -> some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - 依赖的许可证

private struct DependencyLicenseView: View {
    let package: ThirdPartyPackage

    @State private var document: LicenseDocument?
    @State private var errorMessage: String?
    @State private var isLoading = false

    var body: some View {
        Group {
            if let document {
                LicensePage(
                    title: package.name,
                    document: document,
                    footnote: package.versionText.map { "版本 \($0)" }
                )
            } else if isLoading {
                ProgressView("正在读取许可证…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView {
                    Label("无法读取许可证", systemImage: "doc.questionmark")
                } description: {
                    Text(errorMessage ?? "请稍后重试。")
                } actions: {
                    Button("重试") {
                        Task { await load() }
                    }
                    Link("在 GitHub 查看", destination: package.location)
                }
            }
        }
        .navigationTitle(package.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        guard let slug = package.slug, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            document = try await GitHubAboutService()
                .fetchLicense(owner: slug.owner, repository: slug.repo)
        } catch {
            errorMessage = GitHubAboutError.map(error).errorDescription
        }
    }
}

// MARK: - 许可证正文

struct LicensePage: View {
    let title: String
    let document: LicenseDocument
    var footnote: String? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    if let spdx = document.spdx, !spdx.isEmpty {
                        Text(spdx)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color(.tertiarySystemFill)))
                    }

                    if let url = document.htmlURL {
                        Link("在 GitHub 查看", destination: url)
                            .font(.caption)
                    }

                    Spacer(minLength: 0)
                }

                if let footnote {
                    Text(footnote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text(document.body)
                    .font(.system(.footnote, design: .monospaced))
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(20)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - 数据

@MainActor
final class LicenseCatalogModel: ObservableObject {
    @Published private(set) var appLicense: LicenseDocument?
    @Published private(set) var packages: [ThirdPartyPackage] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private let service = GitHubAboutService()
    private var didStart = false

    func loadIfNeeded() async {
        guard !didStart else { return }
        didStart = true
        await reload()
    }

    func reload() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        var failures: [String] = []

        // 两个请求互不依赖，并发发出去；任一失败不连累另一个。
        async let licenseTask = service.fetchLicense(
            owner: GitHubAboutEndpoint.owner,
            repository: GitHubAboutEndpoint.repository
        )
        async let packagesTask = service.fetchDependencies()

        do {
            appLicense = try await licenseTask
        } catch {
            failures.append("许可证：\(GitHubAboutError.map(error).errorDescription ?? "读取失败")")
        }

        do {
            packages = try await packagesTask
        } catch {
            failures.append("依赖清单：\(GitHubAboutError.map(error).errorDescription ?? "读取失败")")
        }

        errorMessage = failures.isEmpty ? nil : failures.joined(separator: "\n")
    }
}

#Preview {
    NavigationStack {
        LicensesView()
    }
}
