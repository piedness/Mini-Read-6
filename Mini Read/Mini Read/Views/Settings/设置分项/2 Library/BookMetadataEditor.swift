//
//  BookMetadataEditor.swift
//  TheNewVellium
//
//  「导入与格式 → 手动编辑元数据」的完整实现：先挑书，再改书名 / 作者 / 出版社 / 封面。
//
//  设计取舍：
//  - **两段式**（列表 → 编辑页）。元数据编辑是低频、针对单本书的操作，
//    直接在设置页塞一堆文本框会逼用户先想"我在改哪本书"；先给书架式的列表，
//    封面 + 书名一眼定位，点进去才进入表单。
//  - **草稿语义**。编辑页上的一切改动都留在 `@State` 里，只有「保存」才落库；
//    返回时若有未保存改动，先问一句再丢。误触返回丢掉十分钟的整理是最难受的失败模式。
//  - **自定义封面写进书自己的解压目录**（`<书>/VelliumCover.jpg`）。
//    这样删书时封面随目录一起消失，不需要再维护一套"孤儿封面"回收逻辑；
//    也不碰 EPUB 原件，导出/重导入仍然是原书。
//  - **还原靠重新解析 EPUB**，而不是记一份"原始值"快照：快照要进 schema、
//    要给存量书补数据，而解析一次 container.xml + OPF 只是毫秒级的事。
//

import SwiftUI
import SwiftData
import UIKit

// MARK: - 书库挑选

/// 元数据编辑的入口：按书库顺序列出全部书籍，点一本进入编辑页。
///
/// 两个入口共用这一个组件：
/// - 设置页（`导入与格式 → 手动编辑元数据`）不传 `initialBook`，先给列表让用户挑；
/// - 书架长按菜单（`Edit…`）传 `initialBook`，直接进这本书的编辑页——
///   用户已经在书上长按了，再让他从列表里找一遍是多余的一步。
struct BookMetadataLibraryView: View {

    /// 非 nil 时跳过列表，直接编辑这本书。
    var initialBook: bookItem? = nil

    var body: some View {
        NavigationStack {
            if let initialBook {
                BookMetadataEditorView(book: initialBook)
            } else {
                BookMetadataPickerList()
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(28)
    }
}

// MARK: - 挑选列表

/// 列表本身单独成一个视图：`@Query` 只在这里存在。
///
/// 从书架菜单直接进编辑页时，这个视图根本不会被构造，也就不会为了"根本没显示的列表"
/// 把整个书库 fetch 一遍——书多的用户对那一帧的卡顿是有感觉的。
private struct BookMetadataPickerList: View {

    @Environment(\.dismiss) private var dismiss

    /// 与书架同一套顺序（最近导入在前），用户不必重新找一遍书在哪。
    @Query(sort: [SortDescriptor(\bookItem.dateAdded, order: .reverse)])
    private var books: [bookItem]

    @State private var query = ""

    var body: some View {
        Group {
            if books.isEmpty {
                ContentUnavailableView(
                    "书库还是空的",
                    systemImage: "books.vertical",
                    description: Text("导入 EPUB 之后，就能在这里修改书名、作者与封面。")
                )
            } else if filteredBooks.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                bookList
            }
        }
        .navigationTitle("编辑书籍信息")
        .navigationBarTitleDisplayMode(.inline)
        // 搜索框常驻：书多的用户进来就是为了找某一本，不该先点一下放大镜。
        .searchable(
            text: $query,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "搜索书名、作者或出版社"
        )
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("完成") { dismiss() }
                    .fontWeight(.semibold)
            }
        }
    }

    private var bookList: some View {
        List {
            Section {
                ForEach(filteredBooks) { book in
                    NavigationLink {
                        BookMetadataEditorView(book: book)
                    } label: {
                        BookMetadataRow(book: book)
                    }
                }
            } footer: {
                Text("修改只影响本机书库里的显示信息，不会改动 EPUB 文件本身。")
            }
        }
        .listStyle(.insetGrouped)
    }

    /// 书名 / 作者 / 出版社三处都参与搜索：用户记得哪一条就搜哪一条。
    /// `localizedStandardContains` 而非 `contains`：忽略大小写与变音符号，
    /// 搜 "dumas" 能命中 "Dumas"，搜 "é" 也不会漏掉 "e"。
    private var filteredBooks: [bookItem] {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return books }

        return books.filter { book in
            book.bookTitle.localizedStandardContains(keyword)
                || book.bookAuthor.localizedStandardContains(keyword)
                || book.bookPublisher.localizedStandardContains(keyword)
        }
    }
}

// MARK: - 列表行

private struct BookMetadataRow: View {

    let book: bookItem

    var body: some View {
        HStack(spacing: 12) {
            // 与书单选择面板同一枚 34×48 迷你封面（ImageIO 降采样 + 共享缓存），
            // 几十上百行滚动时不会逐行解码原图。
            MiniCover(book: book)

            VStack(alignment: .leading, spacing: 2) {
                Text(book.bookTitle)
                    .font(.system(.subheadline, design: .serif, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(hasSubtitle ? .secondary : .tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
        // 合成一个元素：VoiceOver 一次读出「书名，作者，出版社」，而不是三块碎片。
        .accessibilityElement(children: .combine)
        .accessibilityHint("打开这本书的信息编辑")
    }

    private var subtitle: String {
        let parts = [book.bookAuthor, book.bookPublisher]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? "未填写作者与出版社" : parts.joined(separator: " · ")
    }

    private var hasSubtitle: Bool {
        ![book.bookAuthor, book.bookPublisher]
            .allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

// MARK: - 编辑页

struct BookMetadataEditorView: View {

    let book: bookItem

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    // 草稿。初值取自模型，之后只由用户输入改变。
    @State private var title: String
    @State private var author: String
    @State private var publisher: String

    /// 用户新选的封面。非 nil 表示"保存时用它替换"。
    @State private var pickedCover: UIImage?
    /// 「还原为原始信息」取回的封面 URL；保存时写回模型并清掉自定义封面文件。
    @State private var restoredCoverURLs: [URL]?

    @State private var isPickingCover = false
    @State private var isSaving = false
    @State private var isConfirmingDiscard = false
    @State private var isConfirmingRestore = false
    @State private var errorMessage = ""
    @State private var isShowingError = false

    init(book: bookItem) {
        self.book = book
        _title = State(initialValue: book.bookTitle)
        _author = State(initialValue: book.bookAuthor)
        _publisher = State(initialValue: book.bookPublisher)
    }

    var body: some View {
        Form {
            coverSection
            infoSection
            restoreSection
        }
        .navigationTitle("编辑信息")
        .navigationBarTitleDisplayMode(.inline)
        // 自绘返回：需要拦截"有未保存改动时直接退出"。
        // 代价是失去边缘侧滑返回，这是有意的——侧滑同样会丢草稿。
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("取消") { requestClose() }
                    .disabled(isSaving)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") { save() }
                    .fontWeight(.semibold)
                    .disabled(!canSave || isSaving)
            }
        }
        .interactiveDismissDisabled(hasChanges)
        .fullScreenCover(isPresented: $isPickingCover) {
            PhotoPickerView { image in
                guard let image else { return }
                // 只覆盖草稿里的"新封面"。刻意不清掉 `restoredCoverURLs`：
                // 用户选完又点「取消更换」时，应当退回还原后的那张，而不是书库里那张旧的。
                pickedCover = image
                triggerHaptic(.light)
            }
            .ignoresSafeArea()
        }
        .alert("保存失败", isPresented: $isShowingError) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
        .confirmationDialog("放弃未保存的修改？", isPresented: $isConfirmingDiscard, titleVisibility: .visible) {
            Button("放弃修改", role: .destructive) { dismiss() }
            Button("继续编辑", role: .cancel) {}
        } message: {
            Text("返回后，刚才的改动不会保留。")
        }
        .confirmationDialog("还原为 EPUB 原始信息？", isPresented: $isConfirmingRestore, titleVisibility: .visible) {
            Button("还原") { restoreFromEPUB() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将重新读取这本书自带的书名、作者、出版社与封面。改动要点「保存」才会生效。")
        }
    }

    // MARK: - 封面

    private var coverSection: some View {
        Section {
            VStack(spacing: 14) {
                coverPreview

                HStack(spacing: 10) {
                    Button {
                        isPickingCover = true
                    } label: {
                        Label("更换封面", systemImage: "photo")
                    }

                    if pickedCover != nil {
                        Button {
                            pickedCover = nil
                        } label: {
                            Label("取消更换", systemImage: "arrow.uturn.backward")
                        }
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isSaving)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
        }
    }

    /// 草稿封面：新选的图 > 还原取回的原始封面 > 库里现有的那张。
    ///
    /// 现有封面走 `CoverThumbnailView`（后台降采样），不在这里 `UIImage(contentsOfFile:)`：
    /// 有些书的封面是整页大图，同步解码会在进入编辑页的第一帧上顿一下。
    @ViewBuilder
    private var coverPreview: some View {
        let side = CGSize(width: 112, height: 168)

        Group {
            if let pickedCover {
                Image(uiImage: pickedCover)
                    .resizable()
                    .scaledToFill()
                    .frame(width: side.width, height: side.height)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            } else {
                CoverThumbnailView(
                    url: previewCoverURL,
                    size: side,
                    cornerRadius: 4
                )
            }
        }
        // 这里不用 `premiumHardcoverStyle()`：它的 15pt 悬浮影在分组列表行里
        // 会被行边界裁掉一半，反而显脏。表单里给一道克制的接触影就够。
        .shadow(color: .black.opacity(0.18), radius: 5, x: 0, y: 2)
        .accessibilityLabel("封面预览")
        .accessibilityValue(coverPreviewDescription)
    }

    /// 预览用的封面地址。还原后取 EPUB 里的那张（可能为空，此时显示占位图）。
    private var previewCoverURL: URL? {
        if let restoredCoverURLs { return restoredCoverURLs.first }
        return book.coverImageURLs.first
    }

    private var coverPreviewDescription: String {
        if pickedCover != nil { return "新选择的封面" }
        if restoredCoverURLs != nil { return "EPUB 原始封面" }
        return "当前封面"
    }

    // MARK: - 书籍信息

    private var infoSection: some View {
        Section {
            textField("书名", text: $title, prompt: "必填")
            textField("作者", text: $author, prompt: "未知作者")
            textField("出版社", text: $publisher, prompt: "未知出版社")
        } header: {
            Text("书籍信息")
        } footer: {
            if trimmedTitle.isEmpty {
                Text("书名不能为空。")
                    .foregroundStyle(.red)
            } else {
                Text("书库、扉页与目录面板都会使用这里的书名与作者。")
            }
        }
    }

    /// 标签在上、输入框在下的竖排字段。
    ///
    /// 不用 `LabeledContent` 的左右排法：中文书名动辄二十字，
    /// 右对齐的单行输入框只会把它滚成一条缝，用户看不见自己在改什么。
    private func textField(
        _ label: String,
        text: Binding<String>,
        prompt: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField(prompt, text: text, axis: .vertical)
                .lineLimit(1...3)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityLabel(label)
        }
        .padding(.vertical, 2)
    }

    // MARK: - 还原

    private var restoreSection: some View {
        Section {
            Button {
                isConfirmingRestore = true
            } label: {
                Label("还原为 EPUB 原始信息", systemImage: "arrow.uturn.backward")
            }
            .disabled(isSaving)
        } footer: {
            Text("重新读取这本书自带的信息，用来撤销改坏的书名或封面。仅修改书库记录，不改动 EPUB 文件。")
        }
    }

    // MARK: - 草稿状态

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedAuthor: String {
        author.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedPublisher: String {
        publisher.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 是否真的改过东西——决定「保存」能否点、返回要不要拦。
    /// 逐项与模型现值比较，而不是记一份"初始快照"：用户改回原样时按钮会自动变灰，
    /// 这正是「没有改动」的正确含义。
    private var hasChanges: Bool {
        pickedCover != nil
            || restoredCoverURLs != nil
            || trimmedTitle != book.bookTitle
            || trimmedAuthor != book.bookAuthor
            || trimmedPublisher != book.bookPublisher
    }

    private var canSave: Bool {
        !trimmedTitle.isEmpty && hasChanges
    }

    // MARK: - 行为

    private func requestClose() {
        if hasChanges {
            isConfirmingDiscard = true
        } else {
            dismiss()
        }
    }

    private func save() {
        // 在这里就把闸门放下，而不是等 Task 里再置位：
        // 连点两下「保存」时，第二个 Task 可能抢在第一个把 isSaving 置 true 之前启动。
        guard canSave, !isSaving else { return }
        isSaving = true

        Task { await performSave() }
    }

    private func performSave() async {
        defer { isSaving = false }

        // 顺序：写新封面文件 → 改模型 → 落库 → 清旧文件。
        //
        // 旧封面**不能在落库前删**：万一 `save()` 抛错（磁盘满、库损坏），
        // 内存里的模型仍指着旧文件，而那个文件已经被删了——
        // 下次启动这本书就成了永久空白封面。先写新、后删旧，最坏情况只是
        // 多留一张没人引用的图（下次更换或删书时一并清掉）。
        var newCoverURL: URL?

        do {
            if let pickedCover {
                let url = try await BookCoverStore.write(pickedCover, for: book)
                newCoverURL = url
                book.coverImageURLs = [url]
            } else if let restoredCoverURLs {
                book.coverImageURLs = restoredCoverURLs
            }

            book.bookTitle = trimmedTitle
            book.bookAuthor = trimmedAuthor
            book.bookPublisher = trimmedPublisher

            try modelContext.save()
        } catch {
            triggerNotificationHaptic(.error)
            errorMessage = "无法保存这本书的信息：\(error.localizedDescription)"
            isShowingError = true
            return
        }

        if newCoverURL != nil || restoredCoverURLs != nil {
            BookCoverStore.removeCustomCovers(for: book, keeping: newCoverURL)
        }

        triggerNotificationHaptic(.success)
        dismiss()
    }

    /// 重新解析 EPUB 取回原始信息。
    ///
    /// 解析走同步调用：`EPUBBook` 及其依赖在当前模块里被 `-default-isolation MainActor`
    /// 推断为主线程隔离，要挪到后台就得把整条解析栈（EPUBBook / OPFDocument /
    /// ContainerDocument / ManifestItem…）逐个标 `nonisolated`——为了读两个几 KB 的
    /// XML 动半层解析代码，不划算，而且那些类型本来就被导入队列在后台用过，
    /// 隔离标注该由专门的一次重构来收口。
    ///
    /// 代价是一次几毫秒的主线程停顿，且只发生在用户点「还原」并确认之后。
    private func restoreFromEPUB() {
        guard let original = EPUBMetadataReader.read(from: book.bookExtrSubdir) else {
            triggerNotificationHaptic(.error)
            errorMessage = "读不出这本书的原始信息，EPUB 内容可能已不完整。"
            isShowingError = true
            return
        }

        title = original.title
        author = original.author
        publisher = original.publisher
        pickedCover = nil
        restoredCoverURLs = original.coverImageURLs
        triggerHaptic(.light)
    }
}

// MARK: - 自定义封面存取

/// 用户自定义封面的唯一读写点。
///
/// 文件落在**书自己的解压目录**根部（`<书>/VelliumCover-xxxxxxxx.jpg`）：
/// 删书时目录整个消失，不需要另做孤儿清理；也不会碰到 EPUB 原件，
/// 用户把书导出或重装 App 后拿到的仍是原书。
///
/// 文件名每次更换都换一个（带随机后缀）而不是固定同名覆盖：
/// `CoverThumbnail` 的内存缓存以 URL 为键，同名覆盖会让书架继续显示上一张封面，
/// 直到 App 重启。换名字是让缓存自然失效的最省事的办法；
/// 旧文件在模型落库成功之后删掉，磁盘上不会攒下一堆封面。
enum BookCoverStore {

    /// 自定义封面的文件名前缀。清理时按它识别"这是本 App 写的封面"。
    private static let fileNamePrefix = "VelliumCover"

    static func customCoverURL(for book: bookItem) -> URL {
        book.bookExtrSubdir.appendingPathComponent("\(fileNamePrefix)-\(UUID().uuidString.prefix(8)).jpg")
    }

    /// 降采样后写盘，返回可写进 `coverImageURLs` 的 URL。
    ///
    /// 只负责写新文件，**不删旧文件**：调用方要等模型落库成功之后再清，
    /// 否则保存失败时旧封面已经没了、库里却还指着它（见 `performSave`）。
    ///
    /// 上限 1600px：足够 iPad 全屏扉页清晰，又不会把一张 12MP 相册图
    /// 原样塞进书库（那会让"存储管理"里凭空多出十几 MB）。
    @discardableResult
    static func write(_ image: UIImage, for book: bookItem) async throws -> URL {
        let maxEdge: CGFloat = 1600

        // 缩放与编码都在后台：大图解码是几十毫秒级的 CPU 活。
        let data = await Task.detached(priority: .userInitiated) {
            let scaled = image.preparingThumbnail(of: CGSize(width: maxEdge, height: maxEdge)) ?? image
            return scaled.jpegData(compressionQuality: 0.86)
        }.value

        guard let data else { throw CocoaError(.fileWriteUnknown) }

        let url = customCoverURL(for: book)
        try data.write(to: url, options: .atomic)
        return url
    }

    /// 删掉这本书的全部自定义封面（换封面后的旧文件、或「还原为原始信息」时）。
    ///
    /// 只扫书目录的**一层**：封面就写在这一层，没必要递归遍历整本书的资源树。
    static func removeCustomCovers(for book: bookItem, keeping kept: URL? = nil) {
        let directory = book.bookExtrSubdir
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return
        }

        for name in names where name.hasPrefix(fileNamePrefix) && name.hasSuffix(".jpg") {
            let url = directory.appendingPathComponent(name)
            if let kept, url.standardizedFileURL == kept.standardizedFileURL { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }
}

// MARK: - 原始信息读取

/// EPUB 自带元数据的值快照。
struct EPUBOriginalMetadata {
    let title: String
    let author: String
    let publisher: String
    let coverImageURLs: [URL]
}

enum EPUBMetadataReader {

    /// 从解压目录重新读出 OPF 元数据。
    ///
    /// 与导入时用的是同一套解析器（`EPUBBook`），因此「还原」拿到的就是当初导入时
    /// 写进书库的那份值，不存在两套口径。返回 nil 表示这本书的结构已经读不出来了
    /// （目录被删、OPF 损坏）。
    static func read(from directory: URL) -> EPUBOriginalMetadata? {
        guard let book = EPUBBook(contentsOf: directory) else { return nil }

        let metadata = book.opf.metadata
        return EPUBOriginalMetadata(
            title: metadata.titles.first ?? "",
            author: metadata.creators.first ?? "",
            publisher: metadata.publisher ?? "",
            coverImageURLs: book.coverImageURLs
        )
    }
}
