import SwiftUI
internal import Combine
import SwiftData
import UIKit

// MARK: - ViewModel

@MainActor
final class ContentsPanelViewModel: ObservableObject {

    // MARK: - Published State

    @Published private(set) var chapters: [Chapter] = []
    @Published private(set) var expandedChapters: Set<UUID> = []
    @Published private(set) var selectedSubChapterID: UUID? = nil
    @Published private(set) var currentSrc: String = ""
    @Published private(set) var tocJumpRequest: TOCJumpRequest?
    /// 修复：暴露加载状态，让 View 在解析期间显示骨架屏 / loading 指示
    @Published private(set) var isLoading: Bool = true
    /// 打不开这本书的原因。nil = 没有失败（加载中或已就绪）。
    @Published private(set) var loadFailure: ReaderLoadFailure?

    /// 供 PageView 使用的有序 src 列表。
    ///
    /// **缓存而非计算属性**：解析完成后 src 序列永不变化，但 SwiftUI 每次
    /// body 求值都要读它，`PageViewControllerRepresentable` 也每帧拿它跟上次
    /// 做全数组深比较。原先的 `flatMap` 版本等于每帧重建一次上千元素的数组，
    /// 大书首屏因此掉帧。现在只在 `rebuildIndex()` 里算一次。
    @Published private(set) var allSrcs: [String] = []

    /// 供阅读页顶部显示章节标题使用。同 `allSrcs`，只在解析完成后算一次。
    @Published private(set) var titleBySrc: [String: String] = [:]

    /// 上面两份派生数据的版本号。
    ///
    /// 它们只在 `rebuildIndex()` 里被整体替换，也就是每次打开一本书只变一次。
    /// 下游据此做 O(1) 判断，替掉原先每帧一次的全数组 / 全字典深比较。
    ///
    /// 刻意**不**加 `@Published`：它总是与 `allSrcs` / `titleBySrc` 同时更新，
    /// 而那两者已经是 `@Published`，会带动 body 重算；这里再广播一次只是
    /// 白白多触发一轮视图更新。
    private(set) var derivedVersion: Int = 0

    // MARK: - 书签状态

    /// 本书全部书签，按**阅读顺序**排列（目录次序 → 章节内字符偏移）。
    ///
    /// 按阅读顺序而不是创建时间：读者翻书签列表是为了找回"书里那一段"，
    /// 位置线索比时间线索有用得多。
    @Published private(set) var bookmarks: [Bookmark] = []

    /// 当前可见页的位置快照。nil = 当前页不可锚定（扉页 / 空白页 / 尚未上屏）。
    @Published private(set) var currentLocation: ReaderLocation?

    // MARK: - 标注状态

    /// 本书全部标注，按**阅读顺序**排列（目录次序 → 章节内字符偏移）。
    @Published private(set) var annotations: [ReaderAnnotation] = []

    /// 下发给阅读器的值类型快照。与 `annotations` 同批产出：
    /// UIKit 绘制层只吃值类型，不碰 SwiftData 对象。
    @Published private(set) var annotationSnapshots: [AnnotationSnapshot] = []

    /// 标注快照的版本号。刻意**不**加 `@Published`：它总是与
    /// `annotationSnapshots` 同时更新，后者已经会带动视图重算；
    /// 这里再广播一次只是白白多一轮。
    private(set) var annotationsVersion: Int = 0

    /// 从笔记列表跳转后的聚焦请求（让目标标注闪一下）。
    @Published private(set) var annotationFocusRequest: AnnotationFocusRequest?

    /// 当前页是否已有书签。书签按钮的填充态与"轻点移除"都依赖它。
    var isCurrentPageBookmarked: Bool {
        guard let location = currentLocation else { return false }
        return bookmarks.contains {
            $0.src == location.src && location.contains(characterOffset: $0.characterOffset)
        }
    }

    // MARK: - 计算属性

    var hasAnyExpanded: Bool { !expandedChapters.isEmpty }
    var chapterCount: Int { chapters.count }

    /// 目录和当前章节都解析出来后，阅读器才可以安全创建。
    ///
    /// 失败态必须单独判断：解析失败时 `isLoading` 也会归 false，
    /// 若这里只看「不在加载」，视图会拿空 src 去建阅读器。
    var canOpenReader: Bool {
        loadFailure == nil && !isLoading && !currentSrc.isEmpty && !allSrcs.isEmpty
    }

    // MARK: - 依赖注入

    // TODO: 将 bookItem 类型重命名为 BookItem（Swift 命名规范：类型名 UpperCamelCase）
    let book: bookItem
    private let modelContext: ModelContext

    // 修复：O(1) 查找表，替代高频 allSubChapters.first(where:) 的 O(n) 扫描
    private var subChapterIndex: [UUID: (ci: Int, si: Int)] = [:]
    /// 通过 src 直接定位 subChapter UUID，供 selectBySrc / 位置恢复使用。
    /// 重复 navPoint 取首次出现（与 allSrcs 同口径）。
    private var srcToSubID: [String: UUID] = [:]
    /// src → 它的**全部**目录项 UUID。一个文件可能被多个 navPoint 指向，
    /// 记已读时要一次覆盖全部条目；O(1) 查找，避免每次翻章全表扫描。
    private var srcToSubIDs: [String: [UUID]] = [:]

    /// 最近一次按可见页确认过的 src。避免同章每一页都触发一次“记已读”。
    private var lastConfirmedReadSrc: String?
    /// src → 目录次序。书签按阅读顺序排序用；与 `allSrcs` 同批产出。
    private var srcOrder: [String: Int] = [:]

    /// 目录项按阅读顺序排好的 (次序, id)。
    ///
    /// 用途只有一个：读者停在**没有目录项**的文件上时（spine 比目录多），
    /// 目录面板要定位到它前面最近的一条目录项，而不是弹回第一章。
    /// 排序在 `rebuildIndex` 里做一次，打开面板时二分查找。
    private var orderedSubEntries: [(order: Int, id: UUID)] = []

    // 修复：防抖持久化，将连续多次操作（如连续翻页）合并为一次磁盘写入
    private var saveTask: Task<Void, Never>?

    /// 这本书已被移出书库。删除后所有写入/回调都必须停手：
    /// 对一个已删除的 SwiftData 模型赋值，轻则无效，重则把上下文留在坏状态。
    private var isDiscarded = false

    // MARK: - 转场静默窗（写入闸门）

    // 为什么需要这道闸：阅读器与书库共享同一个 `ModelContext`，这里的每一次写入
    // 都会让书库的 `@Query` 失效，触发书架**整屏重绘** —— 而书卡 body 里是同步的
    // 封面读盘（`BookCardView` 的 `UIImage(contentsOfFile:)`，且它读的
    // `readingProgress` 正好依赖 `totalChapterCount` / `progressRecords`）。
    //
    // 于是"阅读器写一个字段"变成了"整屏卡片重新解一遍封面"。若此刻 zoom 转场
    // 还在跑，两者争抢同一帧的主线程预算，就得掉帧。
    //
    // 注意：解析本身并没有阻塞主线程（`loadEPUBAsync` 用的是全局队列），
    // 真正的问题是**解析结果触发的写入**。所以闸门挡的是写入，不是解析。

    /// 转场是否仍在进行。阅读器一建立就处于静默窗内，直到第一页真正上屏。
    private var isTransitionQuiet = true

    /// 静默窗内登记的写入，按登记顺序执行。
    private var deferredWrites: [() -> Void] = []

    /// `markOpenedIfNeeded` 是否已登记过。窗口内 `book.lastOpenedAt` 还没真正赋值，
    /// 不能靠它挡重复登记，得单独记一笔。
    private var hasRegisteredOpenedAt = false

    // MARK: - Init

    init(book: bookItem, modelContext: ModelContext) {
        self.book         = book
        self.modelContext = modelContext
        // init 只做轻量赋值；EPUB 解析（重 I/O）推迟到异步 bootstrap
        Task { await self.bootstrap() }
    }

    // MARK: - 异步启动流程（修复：不在 init 阻塞 @MainActor 队列）

    private func bootstrap() async {
        await loadEPUBAsync(at: book.bookExtrSubdir)
        // 打不开时不再往下走：restoreProgress 需要非空目录，
        // 而失败态本身已经把「为什么 / 怎么办」交给视图了。
        guard loadFailure == nil, !isDiscarded else {
            isLoading = false
            return
        }
        // 修复：restoreProgress 已涵盖自动展开逻辑，不再单独调用 autoExpandInProgressChapter
        restoreProgress()
        // 书签只读一次：列表与「当前页是否已加书签」都靠它。
        // 放在目录解析之后——排序要用 `srcOrder`，早于它拿不到阅读顺序。
        refreshBookmarks()
        // 标注同理：一次读全，按 src 分组后下发给阅读器。
        refreshAnnotations()
        // 这里不再 save：以上写入都经 `writeThroughGate` 登记，
        // 由 `openWriteGateAndCommit()` 在第一页上屏时统一提交。
        isLoading = false
    }

    /// 失败后的重试入口。重新走完整的「解析 → 还原位置」流程。
    ///
    /// 解析在后台队列，`isLoading` 立刻翻转，视图会从错误卡片切回加载态。
    func retryLoading() {
        guard !isLoading else { return }
        isLoading = true
        loadFailure = nil
        Task { await bootstrap() }
    }

    /// 从书库移除这本书：删模型 + 清磁盘。
    ///
    /// 打不开的书需要一个出口。没有这个入口，读者只能一直看着错误页，
    /// 或者去书库长按删除——但书库里那张卡片的封面可能根本读不出来，
    /// 找起来比在错误页上直接移除难得多。
    ///
    /// 顺序：先停掉所有后台写入，再删模型落盘，最后清目录。
    /// 反过来做（先删文件）会让 `modelContext.save()` 与文件清理抢同一帧。
    func removeBookFromLibrary() {
        guard !isDiscarded else { return }
        isDiscarded = true

        saveTask?.cancel()
        saveTask = nil
        deferredWrites.removeAll()

        let directories = [book.bookExtrSubdir, book.bookBackupdir]
        // 页级进度与会话按 bookKey 挂在书外（不是 SwiftData 关系），
        // 不在这里清就会留下指向已删书的孤儿：阅读数据里仍有一本不存在的书。
        // 两套 key 的历史口径不同：PageProgress 用完整路径，ReadingSession 用目录名。
        let pageKey = book.bookExtrSubdir.path
        let sessionKey = book.bookExtrSubdir.lastPathComponent
        let pageDescriptor = FetchDescriptor<PageProgress>(
            predicate: #Predicate { $0.bookKey == pageKey }
        )
        let sessionDescriptor = FetchDescriptor<ReadingSession>(
            predicate: #Predicate { $0.bookKey == sessionKey }
        )
        for progress in (try? modelContext.fetch(pageDescriptor)) ?? [] {
            modelContext.delete(progress)
        }
        for session in (try? modelContext.fetch(sessionDescriptor)) ?? [] {
            modelContext.delete(session)
        }

        modelContext.delete(book)
        try? modelContext.save()

        for directory in directories {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func loadEPUBAsync(at url: URL) async {
        // EPUB 解析移到后台线程，主线程不冻结。
        // 只有纯值类型 EPUBTOC / ReaderLoadFailure 跨并发边界传回 @MainActor。
        let result: Result<EPUBTOC, ReaderLoadFailure> = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let epubBook = EPUBBook(contentsOf: url) else {
                    continuation.resume(returning: .failure(ReaderLoadFailure(
                        title: "无法打开这本书",
                        message: "书库里的书籍文件不完整或已损坏，读不出它的内容结构。你可以重试一次，或把这本书从书库移除后重新导入。"
                    )))
                    return
                }

                let toc = EPUBNavigationParser.parse(epubBook)
                guard !toc.isEmpty else {
                    continuation.resume(returning: .failure(ReaderLoadFailure(
                        title: "这本书没有可显示的正文",
                        message: "书籍的正文文件为空，或其中所有文件都已丢失。建议从书库移除后重新导入这本书。"
                    )))
                    return
                }
                continuation.resume(returning: .success(toc))
            }
        }

        // 读者可能在解析期间就退出了阅读器；此时不再写任何状态。
        guard !isDiscarded else { return }

        switch result {
        case .failure(let failure):
            chapters = []
            allSrcs = []
            titleBySrc = [:]
            srcOrder = [:]
            subChapterIndex = [:]
            srcToSubID = [:]
            srcToSubIDs = [:]
            orderedSubEntries = []
            derivedVersion &+= 1
            loadFailure = failure
            print("[ViewModel] ⚠️ 无法打开 EPUB: \(url.lastPathComponent)")

        case .success(let toc):
            loadFailure = nil
            chapters = toc.makeChapters()

            // 防御：解析层保证 entries 里每一项都有可用 src，理论上不会走到这里。
            // 但一旦走到，`currentSrc` 会一直为空、`canOpenReader` 永远 false——
            // 那正是这次要消灭的无限加载。宁可报错，也不能静默转圈。
            guard !chapters.isEmpty else {
                loadFailure = ReaderLoadFailure(
                    title: "这本书的目录无法使用",
                    message: "读到了正文文件，但没能生成任何可跳转的章节。建议从书库移除后重新导入这本书。"
                )
                allSrcs = []
                titleBySrc = [:]
                srcOrder = [:]
                orderedSubEntries = []
                derivedVersion &+= 1
                return
            }

            // 阅读顺序以 spine 为准（见 EPUBNavigation.swift 顶部说明）。
            rebuildIndex(readingOrder: toc.readingOrder)

            if !toc.warnings.isEmpty {
                print("[ViewModel] 目录 \(toc.source.displayName)：\(toc.warnings.joined(separator: "；"))")
            }

            // 借这次解析把子章节总数写回 SwiftData：书架要在不碰 EPUB 的前提下
            // 显示进度百分比，分母必须持久化（progressRecords 只记已读的，给不出总数）。
            // 老书第一次打开即自愈，之后书架就能算出真实百分比。
            //
            // 走写入闸门：`totalChapterCount` 正是书卡 `readingProgress` 的依赖项，
            // 赋值会让整个书架立刻重绘（含每张卡片的同步封面读盘）。
            // 分母与 `allSrcs` 同口径：阅读顺序里一个文件算一章。目录项重复
            // 指向同一个文件不会把分母撑大。
            let totalSubChapters = allSrcs.count
            guard totalSubChapters > 0 else { return }
            guard book.totalChapterCount != totalSubChapters else { return }
            writeThroughGate { [book] in
                book.totalChapterCount = totalSubChapters
            }
        }
    }

    // MARK: - 查找表维护（修复：所有查找降为 O(1)）

    /// 目录结构变化后的**唯一**重建点：查找表与两份派生缓存一起产出。
    ///
    /// - Parameter readingOrder: spine 定义的阅读顺序。`allSrcs` 直接采用它，
    ///   而不是从目录叶子派生——目录只说明「跳到哪儿」，不说明「有哪些内容」。
    ///   一本 nav 只列了几个「部」的书，正文其余文件仍必须能翻到。
    ///
    /// 挂在这一处而不是散落各处，是为了让"src 序列 / 标题表"只有一个真值来源。
    /// `markSubChapterRead` 只翻 `isRead`、不动 src 与标题，所以不必重建。
    private func rebuildIndex(readingOrder: [String]) {
        subChapterIndex = [:]
        srcToSubID      = [:]
        srcToSubIDs     = [:]

        var srcs: [String] = []
        var titles: [String: String] = [:]
        var order: [String: Int] = [:]
        var seenSrcs = Set<String>()

        // 1. 阅读顺序（spine）先落位。
        for src in readingOrder where !src.isEmpty {
            guard seenSrcs.insert(src).inserted else { continue }
            order[src] = srcs.count
            srcs.append(src)
        }

        // 2. 目录项建索引。目录项与 spine 已在解析层对齐；
        //    这里仍保留「不在 readingOrder 就追加到末尾」的兜底，
        //    避免任何一条目录项因为对齐失败变成点了没反应的死行。
        for (ci, chapter) in chapters.enumerated() {
            for (si, sub) in chapter.subChapters.enumerated() {
                subChapterIndex[sub.id]  = (ci, si)
                srcToSubIDs[sub.src, default: []].append(sub.id)
                // 同一个 src 可能出现在多个 navPoint（部/卷 + 首章是常见形态）。
                // `srcToSubID` 以**首次出现**为准；这里若后写覆盖，
                // 恢复进度、跨章翻页和书签跳转后的目录高亮会落到后一个同名项，
                // 甚至展开错的父章。点哪一项跳转仍由 `selectSubChapter(id)`
                // 保留各自的选择（那一条走 id，不走 src）。
                if srcToSubID[sub.src] == nil {
                    srcToSubID[sub.src] = sub.id
                }

                // 与旧实现同口径：空标题不收录；同一 src 首次出现的非空标题胜出。
                let title = sub.title.trimmingCharacters(in: .whitespacesAndNewlines)
                if !title.isEmpty, titles[sub.src] == nil {
                    titles[sub.src] = title
                }

                // 目录项不在阅读顺序里（正常情况下解析层已过滤掉）：
                // 追加到末尾，保证点击能跳、进度能记。
                if order[sub.src] == nil, seenSrcs.insert(sub.src).inserted {
                    order[sub.src] = srcs.count
                    srcs.append(sub.src)
                }
            }
        }

        allSrcs       = srcs
        titleBySrc    = titles
        srcOrder      = order
        orderedSubEntries = srcToSubID.compactMap { src, id in
            guard let index = order[src] else { return nil }
            return (index, id)
        }.sorted { $0.order < $1.order }
        derivedVersion &+= 1

        // 目录次序变了，书签的阅读顺序也要跟着重排。
        sortBookmarks()
    }

    // MARK: - 进度恢复（修复：合并展开逻辑，明确优先级，消除执行顺序冲突）

    private func restoreProgress() {
        guard !chapters.isEmpty else { return }

        // 一次性自愈历史数据。
        //
        // 修复前 `markSubChapterRead` 从未被任何代码调用，`progressRecords` 因此
        // 对每一本书都是空的；但 `lastReadSrc` 一直在正常更新——它是老数据里唯一
        // 残存的"读到哪儿"的证据。对这类书按"读到 lastReadSrc"补记已读，
        // 否则读者打开一本早已读过一半的书，书架上只会显示 1/N。
        //
        // 只在一条记录都没有时触发，所以一旦有真实记录就永久退出，不会重复补。
        //
        // `backfillReadRecords` 返回它**将要**补的 src（写库动作已挂到闸门上，
        // 此刻尚未执行），下面必须把它们并进 readSet，否则本轮算出的
        // `isRead` 会漏掉这批章节，目录里的已读勾要等到下次打开才对。
        var backfilledSrcs: [String] = []
        if book.progressRecords.isEmpty, let lastSrc = book.lastReadSrc {
            backfilledSrcs = backfillReadRecords(upToSrc: lastSrc)
        }

        var readSet = Set(book.progressRecords.filter { $0.isRead }.map { $0.src })
        readSet.formUnion(backfilledSrcs)
        for ci in chapters.indices {
            for si in chapters[ci].subChapters.indices {
                chapters[ci].subChapters[si].isRead =
                    readSet.contains(chapters[ci].subChapters[si].src)
            }
            recalculateChapterProgress(at: ci)
        }

        if let lastSrc = book.lastReadSrc, allSrcs.contains(lastSrc) {
            // ── 有历史记录：还原上次位置 ──
            //
            // 只要求 lastSrc 在**阅读顺序**里，不要求它有目录项：
            // 目录稀疏的书（nav 只列「部」）里，读者上次停在的文件
            // 完全可能不在目录中，但它仍然是合法的正文位置。
            currentSrc = lastSrc
            if let subID = srcToSubID[lastSrc], let (ci, _) = subChapterIndex[subID] {
                selectedSubChapterID = subID
                expandedChapters.insert(chapters[ci].id)
            } else {
                selectedSubChapterID = nil
            }
            // 有历史记录时，不再执行 autoExpandInProgressChapter，
            // 避免"进行中章节"与"上次阅读章节"同时展开，造成视觉错位

        } else {
            // ── 首次打开：默认第一章第一节 ──
            if let firstSubChapter = chapters.first?.subChapters.first {
                currentSrc           = firstSubChapter.src
                selectedSubChapterID = firstSubChapter.id
                print("[ViewModel] 首次打开，默认显示: \(firstSubChapter.src)")
            }
            // 无历史记录时才自动展开"进行中"章节（通常是从外部导入的半读书籍）
            autoExpandInProgressChapter()
        }
    }

    /// 把 `upTo`（含）之前的子章节按目录顺序补记为已读。仅用于修复历史数据，
    /// 依据是 `lastReadSrc` —— 读者既然读到过这一章，之前的章节视为已读过。
    ///
    /// - Returns: 本次**将要**补记的 src 列表。写库动作已交给闸门，
    ///   返回值供调用方在本轮内存计算里使用（见 `restoreProgress`）。
    @discardableResult
    private func backfillReadRecords(upToSrc upTo: String) -> [String] {
        // 一个 src 只补一条记录：ReadingProgressRecord 的业务主键就是 src。
        // 用 `allSrcs`（阅读顺序）而不是目录项：读者停在的文件可能没有目录项，
        // 按目录补记会让这类书永远补不上。
        guard let end = allSrcs.firstIndex(of: upTo) else { return [] }
        let srcs = Array(allSrcs[...end])

        writeThroughGate { [book, modelContext] in
            for src in srcs {
                let record = ReadingProgressRecord(src: src)
                record.isRead = true
                record.readAt = .now
                modelContext.insert(record)
                book.progressRecords.append(record)
            }
        }
        print("[ViewModel] 进度自愈：按 lastReadSrc 补记 \(srcs.count) 个子章节")
        return srcs
    }

    private func autoExpandInProgressChapter() {
        if let inProgress = chapters.first(where: {
            $0.readingProgress > 0 && $0.readingProgress < 1.0
        }) {
            expandedChapters.insert(inProgress.id)
        }
    }

    // MARK: - 核心选中更新（修复：消除 selectSubChapter / selectBySrc 逻辑分叉）
    //
    // selectSubChapter（目录点击）和 selectBySrc（翻页手势）此前各自独立维护
    // "更新 currentSrc → 同步目录 → 持久化"的逻辑，容易出现遗漏和不一致。
    // 现在统一委托 updateSelection，两个公开方法只负责参数解析。

    private func updateSelection(src: String, id: UUID?) {
        currentSrc           = src
        selectedSubChapterID = id

        // 展开包含该子章节的父章节。id 为 nil = 这一章没有目录项
        // （目录稀疏的书），此时不展开任何父章是正确的。
        if let id, let (ci, _) = subChapterIndex[id] {
            expandedChapters.insert(chapters[ci].id)
        }

        book.lastReadSrc   = src
        book.lastOpenedAt  = .now
        persistDebounced()
    }

    // MARK: - 目录面板定位（修复：让目录面板围绕当前阅读位置展开并居中）

    /// 定位与 `src` 最近的目录项：先精确匹配，再取阅读顺序里它前面最近的一条。
    ///
    /// 目录可能比正文稀疏（nav 只列「部」，spine 里还有几十个文件）。
    /// 读者停在没有目录项的文件上时，目录面板应该停在他刚读过的那一节，
    /// 而不是弹回第一章。
    func nearestSubChapterID(for src: String) -> UUID? {
        if let exact = srcToSubID[src] { return exact }
        guard let target = srcOrder[src], !orderedSubEntries.isEmpty else { return nil }

        // 找最后一个 order <= target。
        var low = 0
        var high = orderedSubEntries.count
        while low < high {
            let mid = (low + high) / 2
            if orderedSubEntries[mid].order <= target {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low > 0 ? orderedSubEntries[low - 1].id : nil
    }

    /// 展开当前阅读位置所在的父章节。
    /// 只负责展开，不触发跳转/选中，避免目录面板打开时产生额外副作用。
    ///
    /// 幂等：已经展开就直接返回。`Set.insert` 即使元素已存在也会写一次属性，
    /// 于是 `@Published` 照样广播、`BookContentView.body` 照样整棵重算——
    /// 而目录面板每次打开都会调到这里，那次无意义的重算正好落在
    /// "面板正在插入 + 列表正在定位"的同一帧上。
    func revealCurrentChapter() {
        let targetID = selectedSubChapterID ?? nearestSubChapterID(for: currentSrc)
        guard let targetID, let (ci, _) = subChapterIndex[targetID] else { return }
        let parentID = chapters[ci].id
        guard !expandedChapters.contains(parentID) else { return }
        expandedChapters.insert(parentID)
    }

    // MARK: - 公开 Intent

    /// 记下"这本书被打开过"。仅在从未打开过时写一次。
    ///
    /// 走写入闸门：`lastOpenedAt` 是首页 Recent 横滑行的**排序依据**，
    /// 在转场期间写它，那一行会在最不该重排的时候当场重排。
    func markOpenedIfNeeded() {
        guard !hasRegisteredOpenedAt else { return }
        hasRegisteredOpenedAt = true
        guard book.lastOpenedAt == nil else { return }

        writeThroughGate { [book] in
            book.lastOpenedAt = .now
        }
    }

    func selectSubChapter(_ id: UUID) {
        // 修复：分离"找不到"错误与正常流程，而非混入同一 guard
        guard let (ci, si) = subChapterIndex[id] else {
            print("[ViewModel] ⚠️ selectSubChapter: 找不到 id \(id)")
            return
        }
        let sub = chapters[ci].subChapters[si]
        updateSelection(src: sub.src, id: id)
        // 带上章内锚点：同一文件里的多个目录项（单文件 EPUB、按小节切分的 nav）
        // 只有靠它才能落到各自的起点，否则全部回到章首。
        tocJumpRequest = TOCJumpRequest(id: UUID(), src: sub.src, anchorID: sub.anchor)
        print("[ViewModel] 目录选中: \(sub.src)\(sub.anchor.map { "#\($0)" } ?? "")")
    }

    func selectBySrc(_ src: String) {
        guard src != currentSrc else { return }

        if let subID = srcToSubID[src] {
            updateSelection(src: src, id: subID)
        } else if allSrcs.contains(src) {
            // 目录里没有这一章，但它在阅读顺序里（目录稀疏 / spine 兜底后
            // 目录被裁掉的文件）。位置必须照样更新，否则翻页到这里后
            // `lastReadSrc` 还停在上一章，退出再进会倒退一章。
            updateSelection(src: src, id: nil)
        } else {
            print("[ViewModel] ⚠️ selectBySrc: 找不到 src \(src)")
        }
    }

    /// 阅读器确认某一章的第一页真正上屏后调用。同一章只在首次确认时写一次；
    /// 之后同章的翻页（位置回调每页都会来）直接 O(1) 返回。
    func markChapterReadIfNeeded(forSrc src: String) {
        guard src != lastConfirmedReadSrc else { return }
        lastConfirmedReadSrc = src
        markSubChapterRead(forSrc: src)
    }

    /// 按 src 记已读。阅读流程手里只有 src（`onChapterChange` 给的就是 src），
    /// 不该让调用方再自己查一遍 UUID。
    ///
    /// 同一 src 的多个目录项要一起标记：它们指向同一段正文，只勾后一个会让
    /// 目录出现「同一章一半已读一半未读」的矛盾状态，父章进度环也偏小。
    /// 写库仍然按 src 唯一（`markSubChapterRead(id)` 会复用已有记录）。
    func markSubChapterRead(forSrc src: String) {
        if let ids = srcToSubIDs[src], !ids.isEmpty {
            for id in ids {
                markSubChapterRead(id)
            }
        } else {
            // 这一章没有目录项（目录稀疏 / spine 兜底后目录只覆盖了部分文件）。
            // 进度分母是阅读顺序的文件数，这里不写记录，全书进度就永远到不了 100%。
            writeReadRecord(forSrc: src)
        }
    }

    func markSubChapterRead(_ id: UUID) {
        // 修复：将"数据找不到"与"已读幂等退出"拆成两个独立 guard，便于调试
        guard let (ci, si) = subChapterIndex[id] else {
            print("[ViewModel] ⚠️ markSubChapterRead: 找不到 id \(id)")
            return
        }
        guard !chapters[ci].subChapters[si].isRead else { return }  // 幂等

        let src = chapters[ci].subChapters[si].src
        chapters[ci].subChapters[si].isRead = true
        recalculateChapterProgress(at: ci)

        // 内存态（`chapters`）立即更新——目录面板的已读勾要马上对；
        // 但**写库**走闸门：它会让书库 `@Query` 失效、触发书架整屏重绘。
        //
        // 这里刻意不走 persistDebounced()：进度是"读者以为已经记下"的东西，
        // 而防抖任务挂在 VM 上，读者退出阅读器时 VM 可能已被释放，那次保存会被放弃——
        // 现象就是"明明读了几章，书架上还是没进度"。写频率是章级（不是页级），
        // 每章一次同步落盘完全承受得起。
        writeReadRecord(forSrc: src)
    }

    /// 已读记录的唯一写入点。同一 src 复用同一条记录，重复调用幂等。
    private func writeReadRecord(forSrc src: String) {
        writeThroughGate { [book, modelContext] in
            if let record = book.progressRecords.first(where: { $0.src == src }) {
                record.isRead = true
                record.readAt = .now
            } else {
                let record = ReadingProgressRecord(src: src)
                record.isRead = true
                record.readAt = .now
                modelContext.insert(record)
                book.progressRecords.append(record)
            }
        }
    }

    func toggleChapter(_ id: UUID) {
        if expandedChapters.contains(id) { expandedChapters.remove(id) }
        else { expandedChapters.insert(id) }
    }

    func collapseAll()                  { expandedChapters.removeAll() }
    func isExpanded(_ id: UUID) -> Bool { expandedChapters.contains(id) }
    func isSelected(_ id: UUID) -> Bool { selectedSubChapterID == id }

    // 修复：利用 subChapterIndex 将 O(n) 搜索降为 O(1)
    func chapter(containing subID: UUID) -> Chapter? {
        guard let (ci, _) = subChapterIndex[subID] else { return nil }
        return chapters[ci]
    }

    // MARK: - 书签

    /// 阅读器上报可见页变化。等值不上报（阅读器侧已挡一次，这里再挡一次：
    /// 它是唯一写入点，不该依赖调用方守规矩）。
    func updateCurrentLocation(_ location: ReaderLocation?) {
        guard currentLocation != location else { return }
        currentLocation = location
    }

    /// 书签按钮的唯一入口：未加则加，已加则移除。
    ///
    /// 做成开关而不是"只加"：同一页反复点按会堆出一串锚点相同的记录，
    /// 列表里看起来像重复项；而读者在这个按钮上真正需要的第二个动作，
    /// 恰恰就是"撤掉"。
    func toggleBookmarkAtCurrentPage() {
        guard let location = currentLocation else { return }

        let existing = bookmark(at: location)
        // 反馈先发：后面紧跟一次同步落盘，震动不该排在磁盘后面等
        // （与 `BookCard.performDelete` 同一条理由）。
        // 撤销是"安静"的动作，用柔反馈与"加上了"的清脆一下区分开。
        triggerHaptic(existing == nil ? .light : .soft)

        if let existing {
            removeBookmark(existing)
        } else {
            addBookmark(at: location)
        }
    }

    /// 从书签列表跳转。只发出字符锚点，页码由阅读器按当前排版解析。
    func jumpToBookmark(_ bookmark: Bookmark) {
        // 先同步阅读位置：`currentSrc` 是 SwiftUI 侧的位置真值，
        // 不同步的话下一次视图求值会把页面拽回原章节（目录跳转同理，
        // 见 `selectSubChapter` → `updateSelection`）。
        if let subID = srcToSubID[bookmark.src] {
            updateSelection(src: bookmark.src, id: subID)
        } else {
            currentSrc        = bookmark.src
            book.lastReadSrc  = bookmark.src
            persistDebounced()
        }

        tocJumpRequest = TOCJumpRequest(
            id: UUID(),
            src: bookmark.src,
            characterOffset: bookmark.characterOffset
        )
    }

    func removeBookmark(_ bookmark: Bookmark) {
        // 先从关系里摘掉再删对象：cascade 关系里若仍留着已删对象，
        // 后续遍历（排序、计数）会碰到失效模型。
        book.bookmarks.removeAll { $0.persistentModelID == bookmark.persistentModelID }
        modelContext.delete(bookmark)
        saveBookmarks()
        refreshBookmarks()
    }

    // MARK: - 书签（私有）

    /// 本页已有书签（按锚点是否落在本页字符区间判定，见 `ReaderLocation.contains`）。
    private func bookmark(at location: ReaderLocation) -> Bookmark? {
        bookmarks.first {
            $0.src == location.src && location.contains(characterOffset: $0.characterOffset)
        }
    }

    private func addBookmark(at location: ReaderLocation) {
        let bookmark = Bookmark(
            bookKey: book.bookExtrSubdir.path,
            src: location.src,
            characterOffset: location.pageStartOffset,
            chapterTitle: (location.chapterTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            preview: location.preview
        )
        modelContext.insert(bookmark)
        book.bookmarks.append(bookmark)
        saveBookmarks()
        refreshBookmarks()
    }

    private func saveBookmarks() {
        do {
            try modelContext.save()
        } catch {
            print("[ViewModel] ⚠️ 书签保存失败: \(error)")
        }
    }

    /// 重新拉取本书书签并排序。
    ///
    /// 走 fetch 而不是直接读 `book.bookmarks`：关系数组的顺序由 SwiftData 决定，
    /// 而列表必须按目录次序呈现。
    private func refreshBookmarks() {
        let key = book.bookExtrSubdir.path
        let descriptor = FetchDescriptor<Bookmark>(predicate: #Predicate { $0.bookKey == key })
        bookmarks = ((try? modelContext.fetch(descriptor)) ?? []).sorted(by: isOrderedBefore)
    }

    private func sortBookmarks() {
        guard bookmarks.count > 1 else { return }
        bookmarks.sort(by: isOrderedBefore)
    }

    /// 阅读顺序：目录次序 → 章节内字符偏移 → 创建时间。
    /// 目录里找不到的 src（章节被重导出的旧书签）排在最后，不隐藏。
    private func isOrderedBefore(_ lhs: Bookmark, _ rhs: Bookmark) -> Bool {
        let leftChapter  = srcOrder[lhs.src] ?? Int.max
        let rightChapter = srcOrder[rhs.src] ?? Int.max
        if leftChapter != rightChapter { return leftChapter < rightChapter }
        if lhs.characterOffset != rhs.characterOffset {
            return lhs.characterOffset < rhs.characterOffset
        }
        return lhs.createdAt < rhs.createdAt
    }

    // MARK: - 标注

    func annotation(id: UUID) -> ReaderAnnotation? {
        annotations.first { $0.annotationID == id }
    }

    /// 与一次选区重叠的已有标注。
    ///
    /// 「添加笔记」必须先查这一步：否则编辑器拿到的是一张空白草稿，
    /// 保存时会把已有笔记静默覆盖掉——读者看不到自己原来写了什么。
    func annotation(overlapping selection: ReaderTextSelection) -> ReaderAnnotation? {
        annotations.first {
            $0.src == selection.src
                && NSIntersectionRange($0.range, selection.range).length > 0
        }
    }

    /// 新建一处高亮 / 笔记。
    ///
    /// 与已有标注重叠时**不新建**，而是更新已有那条的样式/颜色/笔记：
    /// 同一段文字叠两层半透明色块既难读，点击时也无法判断读者想编辑哪一条。
    /// 这与 Apple Books「一处文字只有一条标注」的行为一致。
    func addAnnotation(
        selection: ReaderTextSelection,
        style: AnnotationStyle,
        color: AnnotationColor,
        note: String = ""
    ) {
        guard !isDiscarded, selection.range.length > 0 else { return }

        if let existing = annotations.first(where: {
            $0.src == selection.src
                && NSIntersectionRange($0.range, selection.range).length > 0
        }) {
            // 新选区完整包住旧标注时扩展到新范围：读者显然想把整段都标上。
            // 部分重叠、或新选区落在旧标注内部时保留旧范围，只更新样式/颜色/笔记。
            if NSUnionRange(existing.range, selection.range) == selection.range {
                existing.charStart = selection.range.location
                existing.charLength = selection.range.length
                existing.quote = selection.quote
            }
            existing.styleRaw = style.rawValue
            existing.colorRaw = color.rawValue
            if !note.isEmpty { existing.note = note }
            existing.updatedAt = .now
            saveAnnotations()
            refreshAnnotations()
            return
        }

        let annotation = ReaderAnnotation(
            bookKey: book.bookExtrSubdir.path,
            src: selection.src,
            charStart: selection.range.location,
            charLength: selection.range.length,
            quote: selection.quote,
            note: note,
            style: style,
            color: color,
            chapterTitle: selection.chapterTitle
        )
        modelContext.insert(annotation)
        book.annotations.append(annotation)
        saveAnnotations()
        refreshAnnotations()
    }

    func addAnnotation(draft: AnnotationDraft) {
        guard let range = draft.range else { return }
        addAnnotation(
            selection: ReaderTextSelection(
                src: draft.src,
                range: range,
                quote: draft.quote,
                chapterTitle: draft.chapterTitle
            ),
            style: draft.style,
            color: draft.color,
            note: draft.note
        )
    }

    func updateAnnotation(draft: AnnotationDraft) {
        guard !isDiscarded,
              let id = draft.annotationID,
              let annotation = annotation(id: id)
        else { return }

        annotation.note = draft.note.trimmingCharacters(in: .newlines)
        annotation.styleRaw = draft.style.rawValue
        annotation.colorRaw = draft.color.rawValue
        annotation.updatedAt = .now
        saveAnnotations()
        refreshAnnotations()
    }

    func removeAnnotation(id: UUID) {
        guard !isDiscarded, let annotation = annotation(id: id) else { return }
        book.annotations.removeAll { $0.annotationID == id }
        modelContext.delete(annotation)
        saveAnnotations()
        refreshAnnotations()
    }

    /// 从笔记列表跳转。只发字符锚点，页码由阅读器按当前排版解析。
    func jumpToAnnotation(_ annotation: ReaderAnnotation) {
        if let subID = srcToSubID[annotation.src] {
            updateSelection(src: annotation.src, id: subID)
        } else {
            currentSrc = annotation.src
            book.lastReadSrc = annotation.src
            persistDebounced()
        }

        tocJumpRequest = TOCJumpRequest(
            id: UUID(),
            src: annotation.src,
            characterOffset: annotation.charStart
        )
        annotationFocusRequest = AnnotationFocusRequest(
            id: UUID(),
            annotationID: annotation.annotationID
        )
    }

    /// 导出 Markdown。放在 ViewModel 而不是 View 里：
    /// 排序、章节标题、笔记格式都属于「数据怎么组织」，与视图无关。
    func annotationsMarkdown() -> String {
        guard !annotations.isEmpty else { return "" }

        var lines: [String] = [
            "# \(book.bookTitle)",
            "",
            "> 共 \(annotations.count) 处标注",
            ""
        ]

        var lastSrc: String?
        for annotation in annotations {
            if annotation.src != lastSrc {
                let title = annotation.chapterTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                lines.append("## \(title.isEmpty ? "未命名章节" : title)")
                lines.append("")
                lastSrc = annotation.src
            }

            let quote = annotation.quote
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespaces)
            lines.append("> \(quote)")
            lines.append("")

            if annotation.hasNote {
                lines.append(annotation.note)
                lines.append("")
            }
        }

        return lines.joined(separator: "\n")
    }

    private func saveAnnotations() {
        do {
            try modelContext.save()
        } catch {
            print("[ViewModel] ⚠️ 标注保存失败: \(error)")
        }
    }

    /// 重新拉取本书标注并排序。
    ///
    /// 走 fetch 而不是直接读 `book.annotations`：关系数组的顺序由 SwiftData 决定，
    /// 而列表必须按阅读顺序呈现（与书签同一套理由）。
    private func refreshAnnotations() {
        let key = book.bookExtrSubdir.path
        let descriptor = FetchDescriptor<ReaderAnnotation>(
            predicate: #Predicate { $0.bookKey == key }
        )

        annotations = ((try? modelContext.fetch(descriptor)) ?? [])
            .sorted(by: isAnnotationOrderedBefore)
        annotationSnapshots = annotations.map(\.snapshot)
        annotationsVersion &+= 1
    }

    private func isAnnotationOrderedBefore(_ lhs: ReaderAnnotation, _ rhs: ReaderAnnotation) -> Bool {
        let leftChapter  = srcOrder[lhs.src] ?? Int.max
        let rightChapter = srcOrder[rhs.src] ?? Int.max
        if leftChapter != rightChapter { return leftChapter < rightChapter }
        if lhs.charStart != rhs.charStart { return lhs.charStart < rhs.charStart }
        return lhs.createdAt < rhs.createdAt
    }

    // MARK: - 私有工具

    /// 写入闸门：静默窗内只登记、不执行；窗外立即执行并落盘。
    ///
    /// **所有会惊动书库 `@Query` 的写入都必须走这里**——漏一处，那一处就会
    /// 在转场期间触发书架重绘，把这道闸白装。
    ///
    /// 窗内不逐个 save：登记的写入由 `openWriteGateAndCommit` 统一落一次盘，
    /// 否则又是"N 次同步磁盘写挤在同一帧"的老问题。
    private func writeThroughGate(_ write: @escaping () -> Void) {
        guard !isDiscarded else { return }
        guard !isTransitionQuiet else {
            deferredWrites.append(write)
            return
        }
        write()
        try? modelContext.save()
    }

    /// 结束静默窗并一次性提交登记的写入。
    ///
    /// 由 `BookContentView` 在**第一页真正上屏后**调用（经 `ViewController.showPages`
    /// 的 `markFirstPageShown` 回调）。刻意不选"转场刚结束"那一刻：那时正在构造整套
    /// UIKit 页面层级，两个重活叠在同一帧又会互相挤。
    ///
    /// 幂等：重复调用不会重复提交。若读者极快退出、第一页始终未上屏，
    /// `BookContentView.onDisappear` 也会兜底调一次，写入不会丢。
    func openWriteGateAndCommit() {
        // 初始值为 true，表示「闸门仍关闭」。只有在这里把它切到 false，
        // 静默窗内登记的写入才会真正执行；这个 guard 必须保持与初始值同向。
        guard isTransitionQuiet, !isDiscarded else { return }
        isTransitionQuiet = false

        let writes = deferredWrites
        deferredWrites.removeAll()
        guard !writes.isEmpty else { return }

        for write in writes { write() }
        // 登记的写入各自不再 save，统一在这里落一次盘。
        try? modelContext.save()
    }

    private func recalculateChapterProgress(at index: Int) {
        let subs = chapters[index].subChapters
        guard !subs.isEmpty else { return }
        chapters[index].readingProgress =
            Double(subs.filter { $0.isRead }.count) / Double(subs.count)
    }

    // 修复：防抖持久化，1.5s 内的多次调用（连续翻页、连续标记）只触发一次磁盘写入
    private func persistDebounced() {
        guard !isDiscarded else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled, let self, !self.isDiscarded else { return }
            do {
                try self.modelContext.save()
            } catch {
                print("[ViewModel] ⚠️ 持久化失败: \(error)")
            }
        }
    }

    /// 立即提交防抖窗内还没落盘的写入（阅读器关闭 / App 入后台时调用）。
    ///
    /// 防抖任务挂在 VM 上：读者在一次章切换后 1.5 秒内退出阅读器，VM 随之释放，
    /// 那次保存会被取消——`lastReadSrc` 停在上一章，下次打开回退一章
    /// （页级 `PageProgress` 只救得回章内页，救不了章选择）。
    func flushPendingPersistence() {
        guard !isDiscarded else { return }
        saveTask?.cancel()
        saveTask = nil
        try? modelContext.save()
    }
}
