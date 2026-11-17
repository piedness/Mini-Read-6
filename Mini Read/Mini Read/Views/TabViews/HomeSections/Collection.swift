//
//  Collection.swift
//  TheNewVellium
//
//  首页「Collections」区块：横向专辑货架 + 新建 / 重命名 / 换封面 / 删除。
//
//  书单是"一组书的集合"，所以用专辑语汇表达：方形封面 + 名称 + 数量。
//  名字在封面下方独立成行，不叠在封面上；字号全部走文本样式，跟随动态字体。
//

import SwiftUI
import SwiftData

// MARK: - 首页书单区块

struct CollectionView: View {

    @Environment(\.horizontalSizeClass) private var hSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.modelContext) private var modelContext

    /// 只按 `sortIndex` 取；删除后的空洞不影响排序。
    @Query(sort: \BookCollection.sortIndex) private var collections: [BookCollection]

    /// 新建与重命名共用同一个输入弹窗：同一视图上多个 alert 只有最后一个生效。
    @State private var isEditorPresented = false
    /// nil = 新建；非 nil = 重命名这一条。
    @State private var editorTarget: BookCollection?
    @State private var draftName = ""

    /// 「减弱动态效果」下不执行 3D 翻面，改用无动画的全屏详情。
    /// 正常动效仍由每张卡自己的 FlipTransition 管理，两种呈现共用同一个详情视图。
    @State private var reducedMotionCollection: BookCollection?

    /// FlipTransition 的展示状态由源页面统一持有：展开时整个书单区域都不可点，
    /// 而不是只禁用被翻面的那一张小卡。
    @State private var isFlipDestinationPresented = false

    private var isCollectionDetailPresented: Bool {
        isFlipDestinationPresented || reducedMotionCollection != nil
    }

    /// iPhone 上 148 让"2 张多一点"露出来，提示可以横滑；iPad 上 168 一行约 5 张。
    private var tileSide: CGFloat { hSizeClass == .regular ? 168 : 148 }

    private var rowAnimation: Animation {
        reduceMotion ? .easeOut(duration: 0.15)
                     : .spring(duration: 0.4, bounce: 0.16)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader
                .padding(.bottom, 16)

            if collections.isEmpty {
                // 空态只给一句说明：新建入口就在标题右边，不再铺插画抢焦点。
                Text("Group books into collections — a reading list, a series, a mood.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                shelf
            }
        }
        // 透明区域不等于不可交互。封面展示期间，标题按钮、货架及 contextMenu
        // 全部退出命中测试；onDismiss 后再统一恢复。
        .allowsHitTesting(!isCollectionDetailPresented)
        .alert(editorTitle, isPresented: $isEditorPresented) {
            TextField("Name", text: $draftName)
                .textInputAutocapitalization(.words)
            Button("Save") { commitEditor() }
            Button("Cancel", role: .cancel) { editorTarget = nil }
        } message: {
            Text(editorTarget == nil
                 ? "Collections keep related books together."
                 : "Rename this collection.")
        }
        .fullScreenCover(item: $reducedMotionCollection) { collection in
            // 两种呈现共用显式关闭按钮；此分支也可下滑关闭。
            CollectionDetailView(collection: collection)
        }
    }

    private var editorTitle: String {
        editorTarget == nil ? "New Collection" : "Rename Collection"
    }

    // MARK: - 标题

    private var sectionHeader: some View {
        HStack(alignment: .center) {
            Text("Collections")
                .font(.title2)
                .fontDesign(.serif)
                .bold()

            Spacer()

            // 新建入口放在标题右侧而不是货架里：货架是已有书单的地方，
            // 混进去会像一个空书单；书单一多、滑走之后也再找不回来。
            Button(action: beginCreate) {
                Image(systemName: "pencil")
                    .font(.subheadline)
                    .fontDesign(.serif)
                    .fontWeight(.bold)
                    .foregroundStyle(.primary)
                    .padding(12)
                    .glassSurface(.regular, in: .rect(cornerRadius: 20))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("New Collection")
            .accessibilityHint("Creates an empty collection")
        }
    }

    // MARK: - 横向货架

    private var shelf: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 16) {
                ForEach(collections) { collection in
                    collectionTile(for: collection)
                    .contextMenu { menu(for: collection) }
                    .transition(
                        .asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.92)),
                            removal: .opacity.combined(with: .scale(scale: 0.88))
                        )
                    )
                }
            }
        }
        // 阴影不裁在滚动容器里；挂在 ScrollView 上才会对内容生效。
        .scrollClipDisabled()
        // 动画挂在容器上，value 取身份数组，换序时也能检测到。
        .animation(rowAnimation, value: collections.map(\.persistentModelID))
    }

    /// 书单的唯一打开入口。正常模式完全复用示例组件；Reduce Motion 下走无动画分支，
    /// 避免为了支持无障碍去改动 FlipTransition 的内部动画实现。
    @ViewBuilder
    private func collectionTile(for collection: BookCollection) -> some View {
        let tile = CollectionTile(collection: collection, side: tileSide)

        if reduceMotion {
            Button {
                presentReducedMotionCollection(collection)
            } label: {
                tile
            }
            .buttonStyle(CollectionTileButtonStyle())
        } else {
            FlipTransition(config: flipConfig, onPresentationChange: { isPresented in
                isFlipDestinationPresented = isPresented
            }) {
                tile
            } destination: { dismiss in
                CollectionDetailView(collection: collection, onClose: dismiss)
            } contextActions: {
            }
            // App 当前由 TheNewVelliumApp 强制深色；preferredColorScheme 不会改写
            // FlipTransition 读取的 colorScheme 环境值，必须显式传入，否则
            // ImageRenderer 会生成黑字快照，翻面时在深色背景上消失。
            .colorScheme(.dark)
        }
    }

    private var flipConfig: FlipTransitionConfig {
        var config = FlipTransitionConfig()
        config.sourceCornerRadius = 12
        config.destinationCornerRadius = 28
        // CollectionTile 本身是透明底，不要在翻面时补一块灰色卡片底色。
        config.sourceExtendedBackgroundColor = .clear
        return config
    }

    /// 显式关闭事务动画，避免 fullScreenCover 自带滑动在 Reduce Motion 下仍然出现。
    private func presentReducedMotionCollection(_ collection: BookCollection?) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            reducedMotionCollection = collection
        }
    }

    @ViewBuilder
    private func menu(for collection: BookCollection) -> some View {
        // 默认书单是「Add to My Favorite」的固定落点，不允许改名/删除。
        if !collection.isDefault {
            Button {
                beginRename(collection)
            } label: {
                Label("Rename", systemImage: "pencil")
            }
        }

        Button {
            shuffleCover(of: collection)
        } label: {
            Label("Shuffle Cover", systemImage: "shuffle")
        }

        if !collection.isDefault {
            Divider()

            Button(role: .destructive) {
                delete(collection)
            } label: {
                Label("Delete Collection", systemImage: "trash")
            }
        }
    }

    // MARK: - 编辑动作

    private func beginCreate() {
        // 动作层再兜一次，避免转场切换的同一帧或辅助功能动作误开编辑器。
        guard !isCollectionDetailPresented else { return }
        editorTarget = nil
        draftName = ""
        isEditorPresented = true
    }

    private func beginRename(_ collection: BookCollection) {
        editorTarget = collection
        draftName = collection.name
        isEditorPresented = true
    }

    /// 名字留空时给占位名而不是静默失败：弹窗按钮没有禁用态，
    /// 什么都不发生会让用户以为点漏了。
    private func commitEditor() {
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? "Untitled Collection" : trimmed

        if let target = editorTarget {
            target.name = name
        } else {
            let nextIndex = (collections.map(\.sortIndex).max() ?? -1) + 1
            modelContext.insert(BookCollection(name: name, sortIndex: nextIndex))
        }

        try? modelContext.save()
        editorTarget = nil
        triggerHaptic(.light)
    }

    private func shuffleCover(of collection: BookCollection) {
        withAnimation(rowAnimation) { collection.shuffleCover() }
        try? modelContext.save()
        triggerHaptic(.light)
    }

    private func delete(_ collection: BookCollection) {
        // 只删书单，不删书：反向关系是 nullify，书仍留在书库。
        withAnimation(rowAnimation) {
            modelContext.delete(collection)
        }
        try? modelContext.save()
        triggerHaptic(.medium)
    }
}

// MARK: - 书单卡片

/// 卡片按下时整块一起缩：卡上叠着四张封面，用户容易以为点的是某一本书。
struct CollectionTileButtonStyle: ButtonStyle {

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.92 : 1)
            .animation(.spring(duration: 0.22, bounce: 0), value: configuration.isPressed)
    }
}

/// 方形封面 + 名字 + 数量。首页货架与将来的"全部书单"页共用。
struct CollectionTile: View {

    let collection: BookCollection
    let side: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CollectionArtwork(
                books: CollectionCover.books(for: collection),
                side: side
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(collection.name)
                    .font(.system(.subheadline, design: .serif, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                Text(collection.summaryText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(width: side, alignment: .leading)
        }
        .frame(width: side)
        .contentShape(Rectangle())
        // 整张卡合成一个可访问性元素，一次读出「名称、几本、几本在读」。
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens this collection")
    }

    private var accessibilityLabel: String {
        let base = "\(collection.name), \(collection.bookCountText)"
        return collection.readingCount > 0
            ? "\(base), \(collection.readingCount) currently reading"
            : base
    }
}

