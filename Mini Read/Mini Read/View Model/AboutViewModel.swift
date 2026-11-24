//
//  AboutViewModel.swift
//  Mini Read
//
//  「关于」页的状态机。把「什么时候该发请求」这件事从视图里拿出来，
//  视图只负责把 `snapshot` / `error` 画出来。
//
//  三条规则：
//  1. 先缓存后网络——首屏永远不空着等转圈。
//  2. 同一时刻只允许一次请求——`.task` 与 `.refreshable` 可能同时触发。
//  3. 刷新失败不清空已有内容——断网时用户看到的应该是「上次同步的内容 + 一句说明」，
//     而不是一片空白。
//

import Foundation
internal import Combine

/// 「检查更新」的结果。视图只关心这三种。
enum UpdateCheckOutcome: Sendable {
    case upToDate(latest: String)
    case updateAvailable(GitHubRelease)
    case failed(String)
}

@MainActor
final class AboutViewModel: ObservableObject {

    @Published private(set) var snapshot: AboutSnapshot?
    @Published private(set) var isRefreshing = false
    @Published private(set) var error: GitHubAboutError?

    let installedVersion = AppVersionInfo.current

    private let service: GitHubAboutService
    private var loadTask: Task<AboutSnapshot, Error>?
    private var didStartInitialLoad = false

    init(service: GitHubAboutService = GitHubAboutService()) {
        self.service = service
    }

    // MARK: - 派生状态

    var latestRelease: GitHubRelease? { snapshot?.latestRelease }

    var releaseCount: Int { snapshot?.releases.count ?? 0 }

    /// 本机版本是否落后于 GitHub 最新发布。
    var updateAvailable: Bool {
        guard let tag = latestRelease?.tagName else { return false }
        return installedVersion.isOlder(than: tag)
    }

    var lastSyncText: String? {
        guard let date = snapshot?.fetchedAt else { return nil }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    /// 有内容、但最近一次刷新失败了——此时页面是「缓存 + 提示」，不是空白。
    var isShowingStaleContent: Bool {
        snapshot != nil && error != nil
    }

    // MARK: - 加载

    /// 页面出现时调用。命中缓存有效期就不发请求。
    func loadIfNeeded() async {
        guard !didStartInitialLoad else { return }
        didStartInitialLoad = true

        if snapshot == nil {
            snapshot = await service.cachedSnapshot()
        }

        // 缓存还新鲜就到此为止：用户只是路过这一页，没必要打接口。
        if let snapshot,
           Date.now.timeIntervalSince(snapshot.fetchedAt) < GitHubAboutService.cacheLifetime {
            return
        }

        await reload(forceRefresh: false)
    }

    /// 用户主动刷新（下拉、点同步行）。
    func refresh() async {
        await reload(forceRefresh: true)
    }

    private func reload(forceRefresh: Bool) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            snapshot = try await performLoad(forceRefresh: forceRefresh)
            error = nil
        } catch {
            let mapped = GitHubAboutError.map(error)
            // 用户自己取消（离开页面）不算失败，别把红字留在屏幕上。
            if case .cancelled = mapped { return }
            self.error = mapped
        }
    }

    /// 检查更新。与普通刷新共用同一条请求管线，避免重复打接口。
    func checkForUpdate() async -> UpdateCheckOutcome {
        do {
            let fresh = try await performLoad(forceRefresh: true)
            snapshot = fresh
            error = nil

            guard let release = fresh.latestRelease else {
                return .upToDate(latest: installedVersion.display)
            }
            if installedVersion.isOlder(than: release.tagName) {
                return .updateAvailable(release)
            }
            return .upToDate(latest: release.displayVersion)
        } catch {
            return .failed(GitHubAboutError.map(error).errorDescription ?? "未知错误")
        }
    }

    /// 并发去重：正在请求时，后来者直接等同一个 Task 的结果。
    private func performLoad(forceRefresh: Bool) async throws -> AboutSnapshot {
        if let loadTask {
            return try await loadTask.value
        }

        let task = Task { try await service.loadSnapshot(forceRefresh: forceRefresh) }
        loadTask = task
        defer { loadTask = nil }
        return try await task.value
    }
}
