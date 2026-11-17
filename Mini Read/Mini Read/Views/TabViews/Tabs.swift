import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// Tab 的身份。
///
/// 以前是裸字符串（`"Home"` / `"Library"`…）：拼错不会报错，只是运行时
/// 静默选不中任何一个 tab，而且 `selection: String` 把这类错误一路骗过
/// 编译器。升格成枚举后，`Tab(value:)` 与 `selection` 是同一个类型。
enum TabsTab: Hashable {
    case home
    case library
    case settings
    case search
}

/// 应用外壳：持有唯一一份跨 tab 状态与导入链路，再把「tab 怎么排」
/// 交给 `iPhoneOSTabs` / `iPadOSTabs` 两套骨架。
///
/// ## 为什么外壳和骨架要分开
/// 真正随设备不同的是顶部 chrome：iPhone 用大标题交代「我在哪」；
/// iPad 顶部已经有浮动 tab bar，再压一条大标题就是两层 chrome 抢同一条
/// 顶带，首屏白白少掉一截、信息量为零——所以 iPad 那套骨架不设
/// `navigationTitle`。
///
/// 而状态与设备无关，只能有一份：iPad 分屏、台前调度拖窗口都会即时改变
/// 尺寸类，两套状态并存就会在切换那一帧把「正在导入的那本书」「刚敲的
/// 搜索词」「当前 tab」全部丢掉。所以选中项、搜索词、导入链路留在这里。
///
/// ## 顶部 chrome 的所有权
/// 这里曾经是一条挂在 TabView 之上的 overlay 工具栏——它不参与布局，
/// 所以滚动内容会从按钮底下穿过去（统计卡、区块标题右端的玻璃按钮
/// 都会与它叠在一起），而它唯一的理由（push 后仍可导入）并没有兑现。
/// 现在没有第二份真值：安全区、滚动指示器 inset、命中测试、VoiceOver
/// 顺序、iPad 边距全部由系统导航栏负责。
struct TabsView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.modelContext) private var modelContext

    @State private var selection: TabsTab = .home
    @State private var searchText: String = ""

    @State private var openFile = false
    /// 导入结果提示（失败 / 已存在）。N8：导入链路不再静默失败。
    @State private var importNotice: ImportNotice?

    /// 保留 `@Query` 只为「设置变了 → 外壳重算 tint」。
    /// 设置实例一律走 `appSettings()`：不能自己从 `settings[0]` 挑一行，
    /// 否则可能与阅读器读到的不是同一条记录（见 ModelContext.appSettings）。
    @Query private var settings: [AppSettings]

    private var appSettings: AppSettings {
        modelContext.appSettings()
    }

    private var isRegular: Bool { horizontalSizeClass == .regular }

    var body: some View {
        Group {
            if isRegular {
                iPadOSTabs(
                    selection: $selection,
                    searchText: $searchText,
                    onImport: { openFile = true }
                )
            } else {
                iPhoneOSTabs(
                    selection: $selection,
                    searchText: $searchText,
                    onImport: { openFile = true }
                )
            }
        }
        .tint(Color(hex: appSettings.appTintColorHex))
        // 导入是「整个 App 的一件事」，不是某个 tab 的事：放在外壳上，
        // 两套骨架共用同一条链路、同一个结果提示，也就不用各存一份状态。
        .fileImporter(
            isPresented: $openFile,
            allowedContentTypes: [.epub],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let files):
                for file in files {
                    addItem(fileURL: file)
                }
            case .failure(let error):
                // 取消选择不是失败，不打扰用户（与「配置文件导入」同一口径）。
                let nsError = error as NSError
                let cancelled = (nsError.domain == NSCocoaErrorDomain && nsError.code == NSUserCancelledError)
                    || (nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled)
                if !cancelled {
                    importNotice = ImportNotice(
                        title: "无法选择文件",
                        message: error.localizedDescription
                    )
                }
            }
        }
        // 导入结果统一出口：重复跳过、导入失败都在此交代。
        .alert(item: $importNotice) { notice in
            Alert(
                title: Text(notice.title),
                message: Text(notice.message),
                dismissButton: .default(Text("好"))
            )
        }
    }

    // MARK: - 导入

    /// 导入结果提示（N8：失败与「已存在」都不再静默）。
    /// 取消安全作用域也走这里——那种失败用户必须知道原因。
    private struct ImportNotice: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    private func addItem(fileURL: URL) {
        openFile = false
        // ✅ 在主线程开启安全访问
        guard fileURL.startAccessingSecurityScopedResource() else {
            // 拿不到安全作用域访问权 = 这次导入根本没开始。
            // 这条路径原本只震一下，用户看到的是"点了导入、什么也没发生"。
            triggerNotificationHaptic(.error)
            importNotice = ImportNotice(
                title: "无法读取文件",
                message: "系统拒绝访问这个位置的文件。请把它移到「我的 iPhone」或 iCloud Drive 后再试。"
            )
            return
        }

        // 重活（内容哈希、复制、解压、结构预检、元数据解析）全部由导入服务
        // 在串行后台队列上完成；去重要查 SwiftData、写库要在主线程，
        // 所以拿回 Result 后回主线程再决策（见 handleImportSuccess）。
        Task.detached(priority: .userInitiated) {
            let result = await importEPUB(from: fileURL)
            await MainActor.run {
                fileURL.stopAccessingSecurityScopedResource()
            }
            switch result {
            case .success(let outcome):
                await MainActor.run {
                    handleImportSuccess(outcome)
                }
            case .failure(let error):
                await MainActor.run {
                    // 导入是耗时操作（解压 + 解析），失败必须有个明确交代。
                    triggerNotificationHaptic(.error)
                    importNotice = ImportNotice(
                        title: "导入失败",
                        message: error.errorDescription ?? error.localizedDescription
                    )
                }
            }
        }
    }

    /// 导入成功后的主线程收尾：判重 + 写库。
    ///
    /// 判重键是内容 SHA-256（`bookItem.importHash`）而不是文件名——
    /// 同名不同书不会误判为同一本，同一本书改个文件名也不会漏判。
    /// 除用户显式选择「保留两者」外，重复内容一律不产生第二条记录。
    @MainActor
    private func handleImportSuccess(_ outcome: EPUBImportOutcome) {
        // 先落到本地常量：#Predicate 宏只支持捕获「字面量/本地 let」，
        // 直接写 outcome.contentHash 会被误解析成 KeyPath。
        let contentHash = outcome.contentHash
        let descriptor = FetchDescriptor<bookItem>(
            predicate: #Predicate { $0.importHash == contentHash }
        )
        let existing = (try? modelContext.fetch(descriptor)) ?? []

        // 只有显式选择「保留两者」才允许同一内容进库两次；
        // 其余取值（默认「跳过」、旧版本遗留的 "overwrite" 或未知值）都按重复处理。
        // 宁可少一本，也不要让书架上出现两本一模一样的书。
        if appSettings.duplicateHandling != DuplicateHandling.keepBoth.rawValue,
           let duplicate = existing.first {
            // 删掉刚 staging 的产物，明确告知用户。
            // 原实现此时会静默生成一本重复书（并覆盖同名旧书的内容）。
            removeImportArtifacts(extrSubdir: outcome.extrSubdir, backupURL: outcome.backupURL)
            importNotice = ImportNotice(
                title: "已在书库中",
                message: "《\(duplicate.bookTitle)》已经在书库里了，已跳过这次导入。"
            )
            return
        }

        let newItem = bookItem(
            dateAdded: Date(),
            bookExtrSubdir: outcome.extrSubdir,
            bookBackupdir: outcome.backupURL,
            resourceBaseURL: outcome.resourceBaseURL,
            bookTitle: outcome.title,
            bookAuthor: outcome.author,
            bookPublisher: outcome.publisher,
            coverImageURLs: outcome.coverImageURLs,
            importHash: outcome.contentHash
        )
        modelContext.insert(newItem)
        do {
            // 导入是耗时操作（解压 + 解析），成功与否必须有个明确交代。
            // 成功用 .success：与失败/出错在触感上区分得开。
            try modelContext.save()
            triggerNotificationHaptic(.success)
        } catch {
            // 文件已落盘但书库记录没存上：告诉用户，别让书架与磁盘悄悄不一致。
            importNotice = ImportNotice(
                title: "导入失败",
                message: "书籍已解压到本地，但保存书库记录时出错：\(error.localizedDescription)"
            )
            triggerNotificationHaptic(.error)
        }
    }
}
