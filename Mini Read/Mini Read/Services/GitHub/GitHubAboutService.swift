//
//  GitHubAboutService.swift
//  Mini Read
//
//  「关于」页的全部线上数据来源（GitHub REST API）。
//
//  ## 为什么要有这一层
//  「关于」页的每一项都是会漂移的事实：版本号、更新日志、许可证、依赖清单。
//  写死在代码里，发一次版本就得手动改一次，很快就会对不上。所以这里把
//  GitHub 当成唯一事实来源，App 只负责展示。
//
//  ## 四条硬约束
//  1. **不阻塞 UI**：全部 async；页面先用磁盘缓存铺满首屏，再后台对齐。
//  2. **不浪费配额**：未登录时 GitHub 只给 60 次/小时（同一出口 IP 共享，
//     很容易被邻居用光）。因此：
//     - 结果落盘，15 分钟内不再请求（`cacheLifetime`）；
//     - 请求带 `If-None-Match`，304 响应**不计入**配额；
//     - 同一时刻的多次刷新在 ViewModel 侧合并成一次。
//  3. **不崩**：所有响应字段按「可能缺失」解码，缺字段只让对应行消失，
//     不让整页解析失败。仓库改名、字段调整都不会白屏。
//  4. **不静默失败**：错误映射成可读中文，由 UI 展示并提供重试。
//
//  ## 可选：提高配额
//  在 Info.plist 里加一个 `GitHubAPIToken`（个人访问令牌，只读 public_repo 即可），
//  配额会从 60 次/小时提到 5000 次/小时。**不要把这个令牌提交到仓库**：
//  Info.plist 会随包分发，任何拿到 ipa 的人都能读出来。仅供本地调试使用。
//

import Foundation

// MARK: - 端点

/// GitHub 上的固定地址。仓库换了位置只需要改这里的两个常量。
enum GitHubAboutEndpoint {
    static let owner = "piedness"
    static let repository = "Mini-Read-6"

    private static let webRoot = "https://github.com/\(owner)/\(repository)"
    private static let apiRoot = "https://api.github.com/repos/\(owner)/\(repository)"

    // 网页地址：交给系统浏览器打开
    static let webRepository = URL(string: webRoot)!
    static let webReleases = URL(string: "\(webRoot)/releases")!
    static let webNewIssue = URL(string: "\(webRoot)/issues/new/choose")!

    // 接口地址
    static let apiRepository = URL(string: apiRoot)!
    static let apiReleases = URL(string: "\(apiRoot)/releases?per_page=30")!

    /// 依赖清单在仓库里的候选路径（第一个命中即用）。
    ///
    /// 之所以要候选而不是写死一条：仓库根目录下还有一层与工程同名的文件夹，
    /// 工程曾经在根目录与子目录之间挪过。多列一条的成本是一行字符串，
    /// 换来的是工程目录结构微调后这一页不会直接空白。
    static let dependencyManifestPaths = [
        "Mini Read/Mini Read.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved",
        "Mini Read.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
    ]

    static func apiContents(_ path: String) -> URL {
        var components = URLComponents(string: "\(apiRoot)/contents")!
        components.path += "/" + path
        return components.url!
    }
}

// MARK: - 模型

/// 仓库概要。只取「关于」页真正会展示的字段。
struct GitHubRepoSummary: Codable, Sendable, Hashable {
    var fullName: String
    var description: String?
    var htmlURL: URL
    var stargazersCount: Int
    var forksCount: Int
    var pushedAt: Date?
    var license: License?

    struct License: Codable, Sendable, Hashable {
        var name: String?
        var spdxId: String?

        enum CodingKeys: String, CodingKey {
            case name
            case spdxId = "spdx_id"
        }
    }

    enum CodingKeys: String, CodingKey {
        case description, license
        case fullName = "full_name"
        case htmlURL = "html_url"
        case stargazersCount = "stargazers_count"
        case forksCount = "forks_count"
        case pushedAt = "pushed_at"
    }

    init(
        fullName: String,
        description: String? = nil,
        htmlURL: URL,
        stargazersCount: Int = 0,
        forksCount: Int = 0,
        pushedAt: Date? = nil,
        license: License? = nil
    ) {
        self.fullName = fullName
        self.description = description
        self.htmlURL = htmlURL
        self.stargazersCount = stargazersCount
        self.forksCount = forksCount
        self.pushedAt = pushedAt
        self.license = license
    }

    /// 缺字段一律退化：GitHub 调整响应格式时，这一页最多少显示几行，不会整体失败。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fullName = try container.decodeIfPresent(String.self, forKey: .fullName)
            ?? "\(GitHubAboutEndpoint.owner)/\(GitHubAboutEndpoint.repository)"
        description = try container.decodeIfPresent(String.self, forKey: .description)
        htmlURL = try container.decodeIfPresent(URL.self, forKey: .htmlURL)
            ?? GitHubAboutEndpoint.webRepository
        stargazersCount = try container.decodeIfPresent(Int.self, forKey: .stargazersCount) ?? 0
        forksCount = try container.decodeIfPresent(Int.self, forKey: .forksCount) ?? 0
        pushedAt = try container.decodeIfPresent(Date.self, forKey: .pushedAt)
        license = try container.decodeIfPresent(License.self, forKey: .license)
    }
}

/// 一条发布记录。
struct GitHubRelease: Codable, Sendable, Identifiable, Hashable {
    var id: Int
    var tagName: String
    var name: String?
    var body: String?
    var publishedAt: Date?
    var createdAt: Date?
    var htmlURL: URL
    var prerelease: Bool
    var draft: Bool

    enum CodingKeys: String, CodingKey {
        case id, name, body, prerelease, draft
        case tagName = "tag_name"
        case publishedAt = "published_at"
        case createdAt = "created_at"
        case htmlURL = "html_url"
    }

    init(
        id: Int,
        tagName: String,
        name: String? = nil,
        body: String? = nil,
        publishedAt: Date? = nil,
        createdAt: Date? = nil,
        htmlURL: URL = GitHubAboutEndpoint.webReleases,
        prerelease: Bool = false,
        draft: Bool = false
    ) {
        self.id = id
        self.tagName = tagName
        self.name = name
        self.body = body
        self.publishedAt = publishedAt
        self.createdAt = createdAt
        self.htmlURL = htmlURL
        self.prerelease = prerelease
        self.draft = draft
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(Int.self, forKey: .id) ?? 0
        tagName = try container.decodeIfPresent(String.self, forKey: .tagName) ?? ""
        name = try container.decodeIfPresent(String.self, forKey: .name)
        body = try container.decodeIfPresent(String.self, forKey: .body)
        publishedAt = try container.decodeIfPresent(Date.self, forKey: .publishedAt)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt)
        htmlURL = try container.decodeIfPresent(URL.self, forKey: .htmlURL)
            ?? GitHubAboutEndpoint.webReleases
        prerelease = try container.decodeIfPresent(Bool.self, forKey: .prerelease) ?? false
        draft = try container.decodeIfPresent(Bool.self, forKey: .draft) ?? false
    }

    /// `v1.0.6` → `1.0.6`。GitHub 的 tag 带前缀，界面上不该出现那个 `v`。
    var displayVersion: String {
        var text = tagName
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        return text.isEmpty ? "—" : text
    }

    /// 发布标题。仓库里的标题常常就是「Mini-Read 1.0.6」，与版本号重复，
    /// 这种时候返回 nil，让界面只显示版本号，不要一行里出现两遍 1.0.6。
    var conciseTitle: String? {
        guard let name else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard !trimmed.lowercased().contains(displayVersion.lowercased()) else { return nil }
        return trimmed
    }

    var notes: String? {
        guard let body else { return nil }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var dateText: String? {
        guard let date = publishedAt ?? createdAt else { return nil }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}

/// 一次成功同步的完整快照。落盘的就是它。
struct AboutSnapshot: Codable, Sendable {
    var repo: GitHubRepoSummary
    var releases: [GitHubRelease]
    var fetchedAt: Date

    /// 最新正式版；没有正式版时退回最新一条（可能是预发布）。
    var latestRelease: GitHubRelease? {
        releases.first { !$0.draft && !$0.prerelease } ?? releases.first { !$0.draft }
    }
}

/// 磁盘缓存文件：快照 + 两个端点的 ETag。
struct AboutCacheFile: Codable, Sendable {
    var snapshot: AboutSnapshot
    var repoETag: String?
    var releasesETag: String?
}

/// 许可证正文。
struct LicenseDocument: Sendable, Hashable {
    var name: String?
    var spdx: String?
    var body: String
    var htmlURL: URL?

    var displayName: String {
        if let name, !name.isEmpty { return name }
        if let spdx, !spdx.isEmpty { return spdx }
        return "许可证"
    }
}

/// 一条第三方依赖。来自仓库里的 `Package.resolved`。
struct ThirdPartyPackage: Sendable, Hashable, Identifiable {
    var identity: String
    var name: String
    var version: String?
    var revision: String?
    var location: URL

    var id: String { identity }

    /// 从仓库地址里取出 `owner/repo`，用来请求它的许可证。
    var slug: (owner: String, repo: String)? {
        let parts = location.path.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return nil }
        return (parts[0], parts[1].replacingOccurrences(of: ".git", with: ""))
    }

    var versionText: String? {
        if let version, !version.isEmpty { return version }
        guard let revision, revision.count >= 7 else { return nil }
        return String(revision.prefix(7))
    }
}

/// 本机 App 版本，以及和 GitHub tag 的比较。
struct AppVersionInfo: Sendable, Hashable {
    var shortVersion: String
    var build: String

    static let current: AppVersionInfo = {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? ""
        return AppVersionInfo(shortVersion: short, build: build)
    }()

    var display: String {
        guard !build.isEmpty, build != "0" else { return shortVersion }
        return "\(shortVersion) (\(build))"
    }

    /// 本机版本是否低于某个 tag。按数字段逐位比较，`1.0` 与 `1.0.0` 视为相同。
    func isOlder(than tag: String) -> Bool {
        let lhs = Self.numericComponents(shortVersion)
        let rhs = Self.numericComponents(tag)
        guard !rhs.isEmpty else { return false }

        for index in 0..<max(lhs.count, rhs.count) {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    private static func numericComponents(_ raw: String) -> [Int] {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        return text.split(separator: ".").map { part in
            Int(part.prefix { $0.isNumber }) ?? 0
        }
    }
}

// MARK: - 错误

enum GitHubAboutError: LocalizedError, Equatable {
    case offline
    case timeout
    case network
    case rateLimited(resetAt: Date?)
    case notFound
    case server(status: Int)
    case malformed
    case cancelled
    case unknown

    var errorDescription: String? {
        switch self {
        case .offline:
            return "网络不可用"
        case .timeout:
            return "请求超时"
        case .network:
            return "网络请求失败"
        case .rateLimited(let resetAt):
            guard let resetAt else { return "GitHub 访问额度已用尽" }
            let time = resetAt.formatted(date: .omitted, time: .shortened)
            return "GitHub 访问额度已用尽，约 \(time) 后恢复"
        case .notFound:
            return "找不到该内容"
        case .server(let status):
            return "GitHub 返回异常（HTTP \(status)）"
        case .malformed:
            return "数据解析失败"
        case .cancelled:
            return "已取消"
        case .unknown:
            return "未知错误"
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .offline:
            return "请检查网络连接后重试。"
        case .timeout, .network:
            return "请稍后重试。"
        case .rateLimited:
            return "当前展示的是上次同步的内容，稍后会自动恢复。"
        case .notFound:
            return "项目可能已迁移或设为私有，也可能该文件已不在仓库中。"
        case .malformed:
            return "GitHub 返回了无法识别的数据，稍后再试。"
        case .cancelled:
            return nil
        case .server, .unknown:
            return "请稍后重试。"
        }
    }

    /// 把底层错误收敛成有限的几种，界面只需要处理这些。
    static func map(_ error: Error) -> GitHubAboutError {
        if let error = error as? GitHubAboutError { return error }
        if error is CancellationError { return .cancelled }
        if error is DecodingError { return .malformed }

        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff:
                return .offline
            case .timedOut:
                return .timeout
            case .cancelled:
                return .cancelled
            default:
                return .network
            }
        }
        return .unknown
    }
}

// MARK: - 缓存

/// 落盘缓存。
///
/// 放在 `Caches` 而不是 `Documents`：这是**可再生**的数据，系统清理磁盘时
/// 可以随手删掉，下一次打开「关于」会自动重新拉一遍，不该占用用户的备份空间。
actor AboutCacheStore {
    static let shared = AboutCacheStore()

    private let fileURL: URL
    private var memory: AboutCacheFile?
    private var didLoadFromDisk = false

    init(fileName: String = "github-about.json") {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = base.appending(path: "About", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appending(path: fileName)
    }

    func load() -> AboutCacheFile? {
        if didLoadFromDisk { return memory }
        didLoadFromDisk = true

        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        memory = try? decoder.decode(AboutCacheFile.self, from: data)
        return memory
    }

    func save(_ file: AboutCacheFile) {
        memory = file
        didLoadFromDisk = true

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(file) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    func clear() {
        memory = nil
        didLoadFromDisk = true
        try? FileManager.default.removeItem(at: fileURL)
    }
}

// MARK: - 服务

struct GitHubAboutService: Sendable {

    /// 缓存有效期。15 分钟是「够新」和「不浪费配额」之间的折中：
    /// 用户连点几次「关于」不会每次都打接口，隔一天再来又能看到新版本。
    static let cacheLifetime: TimeInterval = 15 * 60

    private let session: URLSession
    private let cache: AboutCacheStore
    private let token: String?

    init(cache: AboutCacheStore = .shared) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
        self.cache = cache

        let raw = Bundle.main.object(forInfoDictionaryKey: "GitHubAPIToken") as? String
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        token = trimmed.isEmpty ? nil : trimmed
    }

    // MARK: 快照

    /// 只读磁盘缓存，不发请求。用于首屏先把内容铺上。
    func cachedSnapshot() async -> AboutSnapshot? {
        await cache.load()?.snapshot
    }

    /// 取一份快照。
    ///
    /// - Parameter forceRefresh: 用户主动刷新时传 `true`，跳过有效期直接对齐；
    ///   ETag 仍然会带上，内容没变时只花一次 304（不占配额）。
    func loadSnapshot(forceRefresh: Bool) async throws -> AboutSnapshot {
        let cachedFile = await cache.load()

        if !forceRefresh,
           let cachedFile,
           Date.now.timeIntervalSince(cachedFile.snapshot.fetchedAt) < Self.cacheLifetime {
            return cachedFile.snapshot
        }

        async let repoTask = fetchRepository(etag: cachedFile?.repoETag)
        async let releasesTask = fetchReleases(etag: cachedFile?.releasesETag)

        // 仓库信息是这一页的骨架，拿不到就当作整体失败（由 UI 决定显示缓存还是错误）。
        let repoOutcome = try await repoTask
        // 发布列表是锦上添花：它挂了就沿用上次的，不连累整页。
        let releasesOutcome = try? await releasesTask

        let repo: GitHubRepoSummary
        var repoETag = cachedFile?.repoETag
        switch repoOutcome {
        case .fresh(let value, let etag):
            repo = value
            repoETag = etag
        case .notModified:
            guard let cached = cachedFile?.snapshot.repo else { throw GitHubAboutError.malformed }
            repo = cached
        }

        var releases = cachedFile?.snapshot.releases ?? []
        var releasesETag = cachedFile?.releasesETag
        if case .fresh(let value, let etag)? = releasesOutcome {
            releases = value
            releasesETag = etag
        }

        let snapshot = AboutSnapshot(repo: repo, releases: releases, fetchedAt: .now)
        await cache.save(
            AboutCacheFile(snapshot: snapshot, repoETag: repoETag, releasesETag: releasesETag)
        )
        return snapshot
    }

    // MARK: 许可证

    /// 取某个仓库的许可证全文。`/license` 一次返回「名称 + SPDX + 正文」。
    func fetchLicense(owner: String, repository: String) async throws -> LicenseDocument {
        guard let url = URL(string: "https://api.github.com/repos/\(owner)/\(repository)/license") else {
            throw GitHubAboutError.malformed
        }
        guard case .ok(let data, _) = try await data(for: url, etag: nil) else {
            throw GitHubAboutError.malformed
        }

        let payload = try Self.decode(LicensePayload.self, from: data)
        guard let body = payload.decodedBody else { throw GitHubAboutError.malformed }
        return LicenseDocument(
            name: payload.license?.name,
            spdx: payload.license?.spdxId,
            body: body,
            htmlURL: payload.htmlURL
        )
    }

    // MARK: 依赖清单

    /// 从仓库里的 `Package.resolved` 读出依赖列表。
    ///
    /// 为什么不写死在代码里：依赖会升级，写死的版本号迟早变成谎话。
    /// 仓库里这份文件是 Xcode 自动维护的，天然与工程一致。
    func fetchDependencies() async throws -> [ThirdPartyPackage] {
        var lastError: GitHubAboutError = .notFound

        for path in GitHubAboutEndpoint.dependencyManifestPaths {
            do {
                let raw = try await fetchRaw(GitHubAboutEndpoint.apiContents(path))
                guard let data = raw.data(using: .utf8) else { throw GitHubAboutError.malformed }
                let manifest = try Self.decode(PackageResolvedFile.self, from: data)
                return manifest.packages
            } catch let error as GitHubAboutError {
                lastError = error
                if case .notFound = error { continue }
                throw error
            }
        }
        throw lastError
    }

    // MARK: - 私有：单端点

    private enum HTTPOutcome {
        case ok(Data, etag: String?)
        case notModified
    }

    private enum FetchOutcome<Value> {
        case fresh(Value, etag: String?)
        case notModified
    }

    private func fetchRepository(etag: String?) async throws -> FetchOutcome<GitHubRepoSummary> {
        switch try await data(for: GitHubAboutEndpoint.apiRepository, etag: etag) {
        case .ok(let data, let newETag):
            return .fresh(try Self.decode(GitHubRepoSummary.self, from: data), etag: newETag)
        case .notModified:
            return .notModified
        }
    }

    private func fetchReleases(etag: String?) async throws -> FetchOutcome<[GitHubRelease]> {
        switch try await data(for: GitHubAboutEndpoint.apiReleases, etag: etag) {
        case .ok(let data, let newETag):
            let releases = try Self.decode([GitHubRelease].self, from: data)
            return .fresh(releases.filter { !$0.tagName.isEmpty }, etag: newETag)
        case .notModified:
            return .notModified
        }
    }

    /// 取一个纯文本端点（目前只有 Package.resolved）。
    ///
    /// 用 `application/vnd.github.raw` 直接要原文，省掉「base64 解码」这一步，
    /// 也省掉一层可能出错的 JSON 包装。
    private func fetchRaw(_ url: URL) async throws -> String {
        guard case .ok(let data, _) = try await data(for: url, etag: nil, accept: "application/vnd.github.raw")
        else { throw GitHubAboutError.malformed }
        guard let text = String(data: data, encoding: .utf8) else { throw GitHubAboutError.malformed }
        return text
    }

    // MARK: - 私有：HTTP

    private func data(
        for url: URL,
        etag: String?,
        accept: String = "application/vnd.github+json"
    ) async throws -> HTTPOutcome {
        do {
            return try await performRequest(url: url, etag: etag, accept: accept)
        } catch let error as URLError where error.isRetryable {
            // 只对「可能自己好」的错误重试一次。断网不重试——重试也连不上，
            // 白白让用户多等一个超时。
            try? await Task.sleep(for: .milliseconds(600))
            return try await performRequest(url: url, etag: etag, accept: accept)
        }
    }

    private func performRequest(url: URL, etag: String?, accept: String) async throws -> HTTPOutcome {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = "GET"
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("MiniRead-About/1.0", forHTTPHeaderField: "User-Agent")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw GitHubAboutError.network }

        switch http.statusCode {
        case 200..<300:
            return .ok(data, etag: http.value(forHTTPHeaderField: "ETag"))
        case 304:
            return .notModified
        case 403, 429:
            // 403 有两种：配额用尽、被风控拦截。只有前者能给出明确恢复时间。
            if let limitError = Self.rateLimitError(from: http) { throw limitError }
            throw GitHubAboutError.server(status: http.statusCode)
        case 404:
            throw GitHubAboutError.notFound
        default:
            throw GitHubAboutError.server(status: http.statusCode)
        }
    }

    private static func rateLimitError(from response: HTTPURLResponse) -> GitHubAboutError? {
        guard response.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0" else { return nil }
        var resetAt: Date?
        if let raw = response.value(forHTTPHeaderField: "X-RateLimit-Reset"),
           let seconds = TimeInterval(raw) {
            resetAt = Date(timeIntervalSince1970: seconds)
        }
        return .rateLimited(resetAt: resetAt)
    }

    // MARK: - 私有：解码

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        // GitHub 的时间戳是 ISO8601，但个别字段带小数秒；两种都要能解。
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            if let date = iso8601WithFractional.date(from: raw) ?? iso8601.date(from: raw) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "无法解析时间：\(raw)"
            )
        }
        do {
            return try decoder.decode(type, from: data)
        } catch let error as DecodingError {
            #if DEBUG
            print("[About] 解码失败：\(error)")
            #endif
            throw GitHubAboutError.malformed
        }
    }

    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let iso8601WithFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

// MARK: - 接口响应

private struct LicensePayload: Decodable {
    struct Meta: Decodable {
        var name: String?
        var spdxId: String?

        enum CodingKeys: String, CodingKey {
            case name
            case spdxId = "spdx_id"
        }
    }

    var license: Meta?
    var content: String?
    var encoding: String?
    var htmlURL: URL?

    enum CodingKeys: String, CodingKey {
        case license, content, encoding
        case htmlURL = "html_url"
    }

    var decodedBody: String? {
        guard let content else { return nil }
        if encoding == "base64",
           let data = Data(base64Encoded: content, options: .ignoreUnknownCharacters) {
            return String(data: data, encoding: .utf8)
        }
        return content
    }
}

/// `Package.resolved` 的结构（Xcode 14+ 的 v2/v3 格式）。
private struct PackageResolvedFile: Decodable {
    struct Pin: Decodable {
        struct State: Decodable {
            var version: String?
            var revision: String?
        }

        var identity: String
        var location: String?
        var state: State?
    }

    var pins: [Pin]

    var packages: [ThirdPartyPackage] {
        pins.compactMap { pin in
            guard let location = pin.location, let url = URL(string: location) else { return nil }
            let name = url.lastPathComponent.replacingOccurrences(of: ".git", with: "")
            return ThirdPartyPackage(
                identity: pin.identity,
                name: name.isEmpty ? pin.identity : name,
                version: pin.state?.version,
                revision: pin.state?.revision,
                location: url
            )
        }
    }
}

private extension URLError {
    /// 值得重试一次的错误：连接层抖了一下，重试往往就好了。
    var isRetryable: Bool {
        switch code {
        case .timedOut, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost:
            return true
        default:
            return false
        }
    }
}
