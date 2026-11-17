//
//  个性化.swift
//  TheNewVellium
//
//  Created by Max Piednes on 2026/5/3.
//

import SwiftUI
import SwiftData
internal import Combine

// MARK: - 图片历史记录管理器

/// 负责背景图片历史的增删查，文件存于 Documents，元数据存于 UserDefaults
final class BackgroundImageHistory: ObservableObject {

    static let shared = BackgroundImageHistory()
    private init() {}

    private let historyKey = "bgImageHistory"

    /// 历史文件名列表，顺序：最新在前
    @Published private(set) var filenames: [String] = []

    // MARK: 生命周期

    // BUG #2 修复：load() 增加 limit 参数，启动时同时裁剪超限图片
    func load(limit: Int) {
        filenames = (UserDefaults.standard.array(forKey: historyKey) as? [String]) ?? []
        filenames = filenames.filter { fileExists($0) }
        trim(to: limit)
        persist()
    }

    // MARK: 读写

    func add(filename: String, limit: Int) {
        filenames.removeAll { $0 == filename }
        filenames.insert(filename, at: 0)
        trim(to: limit)
        persist()
    }

    func remove(filename: String) {
        filenames.removeAll { $0 == filename }
        deleteFile(filename)
        persist()
    }

    func applyLimit(_ limit: Int) {
        trim(to: limit)
        persist()
    }

    // MARK: 工具

    func imageURL(for filename: String) -> URL {
        documentsURL.appendingPathComponent(filename)
    }

    func loadUIImage(filename: String) -> UIImage? {
        UIImage(contentsOfFile: imageURL(for: filename).path)
    }

    // MARK: 私有

    private var documentsURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private func fileExists(_ filename: String) -> Bool {
        FileManager.default.fileExists(atPath: imageURL(for: filename).path)
    }

    private func deleteFile(_ filename: String) {
        try? FileManager.default.removeItem(at: imageURL(for: filename))
    }

    private func trim(to limit: Int) {
        guard filenames.count > limit else { return }
        let toDelete = filenames.suffix(from: limit)
        toDelete.forEach { deleteFile($0) }
        filenames = Array(filenames.prefix(limit))
    }

    private func persist() {
        UserDefaults.standard.set(filenames, forKey: historyKey)
    }
}

// MARK: - 主视图

struct CustomizeSettingsView: View {
    @Bindable var settings: AppSettings

    // BUG #7 修复：单例应使用 @ObservedObject 而非 @StateObject
    // @StateObject 会在 View 重建时重新创建，与单例语义冲突
    @ObservedObject private var imageHistory = BackgroundImageHistory.shared

    @State private var showPhotoPicker = false
    @State private var isSavingImage = false

    @AppStorage("bgImageCacheLimit") private var cacheLimit: Int = 5
    
    @Environment(\.colorScheme) var colorScheme

    // MARK: - Body

    var body: some View {
        List {

            // ── Tint Color ────────────────────────────────────────────────
            Section {
                ColorPicker("强调色", selection: colorBinding($settings.appTintColorHex))
            } header: {
                Text("APP tint color")
            }

            // ── APP 背景 ──────────────────────────────────────────────────
            Section {
                modePicker
                animatedModeContent
            } header: {
                backgroundSectionHeader
            }
            
            

        }
        .modifier(CustomListModifier(title: "个性化"))
        .tint(Color(hex: settings.appTintColorHex) ?? .accentColor)
        .onAppear {
            // BUG #2 修复：load 时传入 cacheLimit，启动即裁剪
            imageHistory.load(limit: cacheLimit)
        }
    }

    // MARK: - Section Header

    private var backgroundSectionHeader: some View {
        HStack(spacing: 8) {
            Text("APP 背景")

            Spacer()

            // 重置按钮
            Button {
                resetBackground()
            } label: {
                Text("重置")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
        }
        .textCase(nil)
    }

    // MARK: - 背景模式选择器

    private var modePicker: some View {
        Picker("背景模式", selection: $settings.appBackgroundMode) {
            Text("纯色").tag("color")
            Text("渐变").tag("gradient")
            Text("图片").tag("image")
        }
        .pickerStyle(.segmented)
        .padding(.vertical, 4)
        .onChange(of: settings.appBackgroundMode) { _, _ in
            showPhotoPicker = false
        }
    }

    // MARK: - 模式内容（带动画切换）

    @ViewBuilder
    private var animatedModeContent: some View {
        let mode = settings.appBackgroundMode

        Group {
            switch mode {
            case "gradient":
                ColorPicker("渐变起点", selection: colorBinding($settings.appBackgroundGradientStartHex))
                ColorPicker("渐变终点", selection: colorBinding($settings.appBackgroundGradientEndHex))

            case "image":
                imageModeContent

            default: // "color"
                ColorPicker("纯色背景", selection: colorBinding($settings.appBackgroundColorHex))
            }
        }
        .animation(.easeInOut(duration: 0.22), value: mode)
    }

    // MARK: - 图片模式内容

    @ViewBuilder
    private var imageModeContent: some View {
        let currentSource = settings.appBackgroundImageSource

        // ── 历史图片横向滚动网格 ────────────────────────────────────
        if !imageHistory.filenames.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(imageHistory.filenames, id: \.self) { filename in
                            HistoryThumbnailView(
                                filename:     filename,
                                isSelected:   currentSource == filename,
                                tintColor:    Color(hex: settings.appTintColorHex) ?? .accentColor,
                                imageHistory: imageHistory,
                                onSelect: {
                                    withAnimation(.spring(duration: 0.25)) {
                                        settings.appBackgroundImageSource = filename
                                    }
                                },
                                onDelete: {
                                    withAnimation {
                                        if currentSource == filename {
                                            settings.appBackgroundImageSource =
                                                imageHistory.filenames.first(where: { $0 != filename }) ?? ""
                                        }
                                        imageHistory.remove(filename: filename)
                                    }
                                }
                            )
                        }
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 1)
                }
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 4, trailing: 16))
        }

        // ── 从相册添加新图片 ────────────────────────────────────────
        Button {
            showPhotoPicker = true
        } label: {
            HStack {
                Label(
                    imageHistory.filenames.isEmpty ? "从相册选择背景图片" : "从相册添加新图片",
                    systemImage: "photo.badge.plus"
                )
                .foregroundStyle(.primary)
                Spacer()
                if isSavingImage {
                    ProgressView()
                } else {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .buttonStyle(.plain)
        .fullScreenCover(isPresented: $showPhotoPicker) {
            PhotoPickerView { image in
                handlePickedImage(image)
            }
            .ignoresSafeArea()
        }

        // ── 缓存张数上限 ────────────────────────────────────────────
        HStack {
            Label("保留历史图片", systemImage: "tray.2")
            Spacer()
            // BUG #3 修复：Stepper 尾部闭包是 onEditingChanged（手指抬起/落下触发），
            // 不是每次 +/- 值变化时触发，改用 .onChange(of: cacheLimit) 确保每次变化都响应
            Stepper("\(cacheLimit) 张", value: $cacheLimit, in: 3...20)
                .fixedSize()
                .onChange(of: cacheLimit) { _, newLimit in
                    imageHistory.applyLimit(newLimit)
                    let src = settings.appBackgroundImageSource
                    if !src.isEmpty, !imageHistory.filenames.contains(src) {
                        settings.appBackgroundImageSource = imageHistory.filenames.first ?? ""
                    }
                }
        }
    }

    // MARK: - 重置背景

    private func resetBackground() {
        withAnimation {
            if colorScheme == .light{
                settings.appBackgroundColorHex = "#FBFBF5"
                settings.appBackgroundGradientStartHex = "#F8FAFF"
                settings.appBackgroundGradientEndHex = "#E2E9F7"
            }else{
                settings.appBackgroundColorHex = settings.appBackgroundColorHex_Dark
                settings.appBackgroundGradientStartHex = settings.appBackgroundGradientStartHex_Dark
                settings.appBackgroundGradientEndHex = settings.appBackgroundGradientEndHex_Dark
            }
            
            
            settings.appBackgroundMode = "color"
            settings.appBackgroundImageSource = ""
        }
    }

    // MARK: - Color Binding

    private func colorBinding(_ hex: Binding<String>) -> Binding<Color> {
        return Binding<Color>(
            get:  { Color(hex: hex.wrappedValue) ?? .gray },
            set:  { hex.wrappedValue = $0.toHex() ?? "#000000" }
        )
    }

    // MARK: - 图片保存

    private func handlePickedImage(_ image: UIImage?) {
        guard let image else { return }

        isSavingImage = true

        Task {
            let filename = UUID().uuidString + ".jpg"
            let fileURL = FileManager.default
                .urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent(filename)

            do {
                let scaled = await Task.detached(priority: .utility) {
                    image.preparingThumbnail(of: CGSize(width: 1170, height: 2532))
                }.value
                let jpegData = (scaled ?? image).jpegData(compressionQuality: 0.88)

                if let jpegData {
                    try jpegData.write(to: fileURL, options: .atomic)
                } else {
                    throw CocoaError(.fileWriteUnknown)
                }

                await MainActor.run {
                    imageHistory.add(filename: filename, limit: cacheLimit)
                    settings.appBackgroundImageSource = filename
                    isSavingImage = false
                }
            } catch {
                print("图片保存失败: \(error)")
                await MainActor.run { isSavingImage = false }
            }
        }
    }
}

// MARK: - 历史图片缩略图

private struct HistoryThumbnailView: View {
    let filename:     String
    let isSelected:   Bool
    let tintColor:    Color
    let imageHistory: BackgroundImageHistory
    let onSelect:     () -> Void
    let onDelete:     () -> Void

    @State private var thumbnail: UIImage? = nil
    @State private var showDeleteBadge = false

    private let size: CGFloat = 72

    var body: some View {
        // BUG #5 修复：对齐方式改为 .topTrailing，让角标显示在右上角
        // 原来 .center 会让对勾和删除按钮浮在图片正中央
        ZStack(alignment: .topTrailing) {

            // ── 缩略图本体 ────────────────────────────────────────
            Group {
                if let img = thumbnail {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                } else {
                    Rectangle()
                        .fill(Color(.tertiarySystemFill))
                        .overlay {
                            ProgressView().scaleEffect(0.7)
                        }
                }
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(
                        isSelected ? tintColor : Color(.separator),
                        lineWidth: isSelected ? 2.5 : 0.5
                    )
            }
            .shadow(
                color: .black.opacity(isSelected ? 0.18 : 0.06),
                radius: isSelected ? 6 : 3,
                y: 2
            )
            .scaleEffect(showDeleteBadge ? 0.92 : 1.0)
            .animation(.spring(response: 0.28, dampingFraction: 0.65), value: showDeleteBadge)

            // ── 选中对勾角标（右上角）──────────────────────────────
            if isSelected && !showDeleteBadge {
                Circle()
                    .fill(tintColor)
                    .frame(width: 18, height: 18)
                    .overlay {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    .offset(x: 4, y: -4)
                    .transition(.scale.combined(with: .opacity))
            }

            // ── 长按后显示的删除角标（右上角）────────────────────────
            if showDeleteBadge {
                Button {
                    showDeleteBadge = false
                    onDelete()
                } label: {
                    Circle()
                        .fill(.red)
                        .frame(width: 20, height: 20)
                        .overlay {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                        }
                }
                .offset(x: 4, y: -4)
                .transition(.scale.combined(with: .opacity))
                .buttonStyle(.plain)
            }
        }
        .onTapGesture {
            if showDeleteBadge {
                withAnimation { showDeleteBadge = false }
            } else {
                onSelect()
            }
        }
        .onLongPressGesture(minimumDuration: 0.4) {
            withAnimation(.spring(response: 0.25)) {
                showDeleteBadge = true
            }
        }
        .task {
            guard thumbnail == nil else { return }
            if let img = imageHistory.loadUIImage(filename: filename) {
                let thumb = await Task.detached(priority: .utility) {
                    img.preparingThumbnail(of: CGSize(width: 144, height: 144))
                }.value
                await MainActor.run { thumbnail = thumb ?? img }
            }
        }
    }
}
