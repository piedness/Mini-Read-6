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
//  - **编辑页顶部是「身份卡」，不是一排控件**：封面 + 用衬线体排出的书名/作者，
//    边输入边更新。用户真正在改的是"这本书在书架上长什么样"，而不是三个字符串；
//    只给表单，他得自己想象改动后的结果，改完回到书架才发现书名被截断成两行。
//  - **自定义封面写进书自己的解压目录**（`<书>/VelliumCover-xxxxxxxx.jpg`）。
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
            } header: {
                // 段头交代"这一屏有多少本"。书多的用户滚到一半会怀疑自己漏了哪本，
                // 一个总数比无限长的列表更能给人边界感；搜索时则换成命中数。
                Text(listHeader)
            }
        }
        .listStyle(.insetGrouped)
        // 搜索键盘会盖住大半个列表；一滚动就收，别让用户先找"完成"。
        .scrollDismissesKeyboard(.immediately)
    }

    private var listHeader: String {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return "全部书籍 · \(books.count) 本" }
        return "搜索结果 · \(filteredBooks.count) 本"
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
            // 40×58 比默认的 34×48 多给一点识别面积：这一屏就是用来"认封面"的，
            // 缩略图太小就退化成只能靠书名找书。仍走 `MiniCover` 的
            // ImageIO 降采样 + 共享缓存，几十上百行滚动不会逐行解码原图。
            MiniCover(book: book, size: CGSize(width: 40, height: 58))
                .shadow(color: .black.opacity(0.16), radius: 2.5, x: 0, y: 1.5)
                .overlay {
                    // 浅色封面在白底上会"化掉"，一道细边把轮廓收回来。
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                }

            VStack(alignment: .leading, spacing: 3) {
                Text(book.bookTitle)
                    .font(.system(.subheadline, design: .serif, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(metaParts.isEmpty ? .tertiary : .secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 3)
        // 合成一个元素：VoiceOver 一次读出「书名，作者，出版社」，而不是三块碎片。
        .accessibilityElement(children: .combine)
        .accessibilityHint("打开这本书的信息编辑")
    }

    /// 作者与出版社的可见片段。空串先剔掉：只填了出版社的书不该出现一个孤零零的" · "。
    private var metaParts: [String] {
        [book.bookAuthor, book.bookPublisher]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private var subtitle: String {
        metaParts.isEmpty ? "未填写作者与出版社" : metaParts.joined(separator: " · ")
    }
}

// MARK: - 编辑页

struct BookMetadataEditorView: View {

    /// 身份卡封面的开本（2:3）。宽高只在这里写一次：
    /// 封面图与相机角标都以它为准。
    private static let coverSize = CGSize(width: 84, height: 126)

    let book: bookItem

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    // 草稿。初值取自模型，之后只由用户输入改变。
    @State private var title: String
    @State private var author: String
    @State private var publisher: String

    /// 用户新选的封面。非 nil 表示"保存时用它替换"。
    @State private var pickedCover: UIImage?
    /// 「还原为原始信息」取回的封面 URL；保存时写回模型并清掉自定义封面文件。
    @State private var restoredCoverURLs: [URL]?
    /// 「还原」是否刚被用过。只驱动那一行"已取回，待保存"的反馈——
    /// 还原是静默改值，不给回执的话用户会怀疑按钮没生效。
    @State private var didRestoreFromEPUB = false

    @State private var isPickingCover = false
    @State private var isSaving = false
    @State private var isConfirmingDiscard = false
    @State private var isConfirmingRestore = false
    @State private var errorMessage = ""
    @State private var isShowingError = false

    /// 键盘焦点。只服务两件事：给键盘挂一条「完成」，以及还原后主动收键盘。
    ///
    /// 三个字段都是 `axis: .vertical` 的多行输入（中文书名动辄二十字，单行输入框
    /// 只会把它滚成一条缝），所以回车是换行、不是"下一项"——不做焦点串联，
    /// 免得用户按回车期待跳转却多出一个空行。
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case title, author, publisher
    }

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
        // 表单里滚动时顺手收键盘，是 iOS 设置类界面的默认手感。
        .scrollDismissesKeyboard(.interactively)
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
                saveButton
            }
        }
        .interactiveDismissDisabled(hasChanges || isSaving)
        .fullScreenCover(isPresented: $isPickingCover) {
            PhotoPickerView { image in
                guard let image else { return }
                // 只覆盖草稿里的"新封面"。刻意不清掉 `restoredCoverURLs`：
                // 用户选完又点「撤销更换」时，应当退回还原后的那张，而不是书库里那张旧的。
                withAnimation(.snappy(duration: 0.2)) { pickedCover = image }
                triggerHaptic(.light)
            }
            .ignoresSafeArea()
        }
        .alert("保存失败", isPresented: $isShowingError) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
        .alert("放弃未保存的修改？", isPresented: $isConfirmingDiscard) {
            Button("放弃修改", role: .destructive) { dismiss() }
            Button("继续编辑", role: .cancel) {}
        } message: {
            Text("返回后，刚才的改动不会保留。")
        }
        .alert("还原为 EPUB 原始信息？", isPresented: $isConfirmingRestore) {
            Button("还原") { restoreFromEPUB() }
            Button("取消", role: .cancel) {}
        }
    }

    /// 保存中把文字换成转圈：点下去到落库之间有一段真实的磁盘 I/O，
    /// 只让按钮变灰的话，用户会以为点空了而反复点。
    private var saveButton: some View {
        Button(action: save) {
            Text("保存")
                .fontWeight(.semibold)
        }
        .disabled(!canSave || isSaving)
        .accessibilityLabel(isSaving ? "正在保存" : "保存")
    }

    // MARK: - 封面

    /// 「身份卡」：左边是封面，右边是用书架同款衬线体排出的书名与作者。
    ///
    /// 没有把它做成居中的大封面：这一页的主任务是改书名，一张 300pt 高的封面
    /// 会把三个输入框全部挤到首屏之外。横排既保住了视觉分量，又没占掉表单。
    ///
    /// 右侧只有文字，没有任何按钮：换封面的唯一入口是点封面本身。
    /// 放一枚「更换封面」按钮，读起来就像"封面是附件"，而这里要传达的是
    /// "这本书长这样，点它可以换"；文字也才有机会和封面平视对齐。
    private var coverSection: some View {
        Section {
            HStack(alignment: .center, spacing: 16) {
                coverButton

                VStack(alignment: .leading, spacing: 6) {
                    Text(previewTitle)
                        .font(.system(.headline, design: .serif, weight: .semibold))
                        .foregroundStyle(trimmedTitle.isEmpty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                        .lineLimit(3)
                        // 只是所见即所得的预览，同样的内容下面三个输入框里都有；
                        // 让 VoiceOver 再念一遍只会把表单拖长一倍。
                        .accessibilityHidden(true)

                    Text(previewByline)
                        .font(.footnote)
                        .foregroundStyle(metaParts.isEmpty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
                        .lineLimit(2)
                        .accessibilityHidden(true)
                }
                // 书名短时文字块仍占满整列，靠 `HStack` 的居中对齐与封面成为一张卡；
                // 书名长时先长文字、封面保持 2:3 不动。
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 6)
        } header: {
            Text("封面")
        }
    }

    /// 封面本身就是更换入口。相机角标是唯一的视觉提示，
    /// 「轻点可以换」这件事由无障碍的 label / hint 交代。
    ///
    /// 「撤销更换」收进长按菜单：它是一次性的补救动作，常驻在卡片上会跟
    /// "点封面更换"抢注意力，也违背"右侧只留文字"的取舍。
    /// 只在真的选过新图时才挂菜单——空菜单长按会闪一下却什么都不出来。
    @ViewBuilder
    private var coverButton: some View {
        if pickedCover != nil {
            baseCoverButton
                .contextMenu {
                    Button {
                        withAnimation(.snappy(duration: 0.2)) { pickedCover = nil }
                        triggerHaptic(.light)
                    } label: {
                        Label("撤销更换", systemImage: "arrow.uturn.backward")
                    }
                }
        } else {
            baseCoverButton
        }
    }

    private var baseCoverButton: some View {
        Button {
            guard !isSaving else { return }
            triggerHaptic(.light)
            isPickingCover = true
        } label: {
            coverArtwork
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(.thickMaterial))
                        .overlay {
                            Circle().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                        }
                        .offset(x: 5, y: 5)
                        .accessibilityHidden(true)
                }
                .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isSaving)
        .accessibilityLabel("封面预览")
        .accessibilityValue(coverPreviewDescription)
        .accessibilityHint("轻点更换封面")
    }

    /// 草稿封面：新选的图 > 还原取回的原始封面 > 库里现有的那张。
    ///
    /// 现有封面走 `CoverThumbnailView`（后台降采样），不在这里 `UIImage(contentsOfFile:)`：
    /// 有些书的封面是整页大图，同步解码会在进入编辑页的第一帧上顿一下。
    @ViewBuilder
    private var coverArtwork: some View {
        let side = Self.coverSize

        Group {
            if let pickedCover {
                Image(uiImage: pickedCover)
                    .resizable()
                    .scaledToFill()
            } else {
                CoverThumbnailView(
                    url: previewCoverURL,
                    size: side,
                    cornerRadius: 5
                )
            }
        }
        .frame(width: side.width, height: side.height)
        // 没有封面时给一块极淡的底色：`CoverThumbnailView` 的空态只有一枚图标，
        // 落在表单行里会像"没画完"，加个底才读得出这是一张待填的封面位。
        .background {
            if pickedCover == nil, previewCoverURL == nil {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay {
            // 深色模式里封面和行背景可能同色，一道细边把轮廓交代清楚。
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        }
        // 这里不用 `premiumHardcoverStyle()`：它的 15pt 悬浮影在分组列表行里
        // 会被行边界裁掉一半，反而显脏。表单里给一道克制的接触影就够。
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.5 : 0.18), radius: 6, x: 0, y: 3)
        // 刻意**不**给这张图加 `accessibilityHidden`：它是按钮的 label，
        // 把 label 整棵子树隐藏掉，按钮本身也会从无障碍树里消失。
        // 图片没有自己的标签，本来就不会单独被念出来；语义由外层按钮给。
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
            fieldRow(
                "书名",
                icon: "textformat",
                text: $title,
                prompt: "必填",
                field: .title,
                errorText: trimmedTitle.isEmpty ? "书名不能为空" : nil
            )
            fieldRow("作者", icon: "person", text: $author, prompt: "未知作者", field: .author)
            fieldRow("出版社", icon: "building.columns", text: $publisher, prompt: "未知出版社", field: .publisher)
        } header: {
            Text("书籍信息")
        }
    }

    /// 标签在上、输入框在下的竖排字段。
    ///
    /// 不用 `LabeledContent` 的左右排法：中文书名动辄二十字，
    /// 右对齐的单行输入框只会把它滚成一条缝，用户看不见自己在改什么。
    ///
    /// 校验信息贴在字段正下方而不是段尾：段尾那行离输入框有半个屏幕，
    /// 用户清空书名后眼睛还在输入框上，看不到"不能为空"。
    private func fieldRow(
        _ label: String,
        icon: String,
        text: Binding<String>,
        prompt: String,
        field: Field,
        errorText: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .imageScale(.small)
                    .foregroundStyle(.tertiary)
                    .frame(width: 15, alignment: .leading)

                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            // 标签只是给眼睛看的：输入框自己带着 accessibilityLabel，
            // 两边都念一遍等于每次进字段前多听三个字。
            .accessibilityHidden(true)

            TextField(prompt, text: text, axis: .vertical)
                .lineLimit(1...3)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focusedField, equals: field)
                .accessibilityLabel(label)

            if let errorText {
                Label(errorText, systemImage: "exclamationmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .transition(.opacity)
            }
        }
        .padding(.vertical, 2)
        .animation(.easeInOut(duration: 0.18), value: errorText == nil)
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

            if didRestoreFromEPUB {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)

                    Text("已取回原始信息，保存后生效")
                        .foregroundStyle(.secondary)
                }
                .font(.footnote)
                .transition(.opacity)
            }
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

    /// 预览用的书名：空书名不该让卡片塌成一片空白，给一句占位更像"还没起名"。
    private var previewTitle: String {
        trimmedTitle.isEmpty ? "未命名书籍" : trimmedTitle
    }

    /// 预览用的副标题：把作者与出版社并成一行，正是书架与书单里的排法。
    private var metaParts: [String] {
        [trimmedAuthor, trimmedPublisher].filter { !$0.isEmpty }
    }

    private var previewByline: String {
        metaParts.isEmpty ? "未填写作者与出版社" : metaParts.joined(separator: " · ")
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

        // 失败时要还原的模型现值。`modelContext.save()` 抛错时，内存里的 `bookItem`
        // 已经被改过了，而下一次 autosave 会把这份"没保存成功"的草稿静默写进库：
        // 用户看到的是「保存失败」，重启后书名却变了。所以失败路径必须自己回滚。
        let originalTitle = book.bookTitle
        let originalAuthor = book.bookAuthor
        let originalPublisher = book.bookPublisher
        let originalCovers = book.coverImageURLs

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
            book.bookTitle = originalTitle
            book.bookAuthor = originalAuthor
            book.bookPublisher = originalPublisher
            book.coverImageURLs = originalCovers

            // 刚落盘的那张新封面已经没人引用了，顺手清掉；清不掉也不影响报错。
            if let newCoverURL {
                try? FileManager.default.removeItem(at: newCoverURL)
            }

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

        // 键盘此刻多半还举着，遮住的就是刚被改掉的那几行。先收起来再改值。
        focusedField = nil

        withAnimation(.easeInOut(duration: 0.2)) {
            title = original.title
            author = original.author
            publisher = original.publisher
            pickedCover = nil
            restoredCoverURLs = original.coverImageURLs
            didRestoreFromEPUB = true
        }

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
