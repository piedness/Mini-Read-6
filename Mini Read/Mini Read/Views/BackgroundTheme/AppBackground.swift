//
//  AppBackgroundView.swift
//  TheNewVellium
//
//  Created by Max Piednes on 2026/5/3.
//

import SwiftUI

struct AppBackgroundView: View {

    @Bindable var settings: AppSettings
    
    let BGradius: CGFloat

    /// 图片缓存：避免每次 body 重算时重新读盘
    @State private var cachedImage: UIImage? = nil
    /// 上一次加载的文件名，用于判断是否需要重新读盘
    @State private var loadedFilename: String = ""

    var body: some View {
        Group {
            switch settings.appBackgroundMode {
            case "gradient":
                gradientBackground
            case "image":
                imageBackground
            default: // "color"
                colorBackground
            }
        }
        // 模式或来源变化时平滑过渡
        .animation(.easeInOut(duration: 0.35), value: settings.appBackgroundMode)
        .animation(.easeInOut(duration: 0.35), value: settings.appBackgroundImageSource)
        .ignoresSafeArea()
        // 当图片来源变化时重新加载
        .onAppear {
            loadImageIfNeeded(filename: settings.appBackgroundImageSource)
        }
        .onChange(of: settings.appBackgroundImageSource) { _, newFilename in
            loadImageIfNeeded(filename: newFilename)
        }
    }

    // MARK: - 纯色背景

    private var colorBackground: some View {
        let currentColor = Color(hex: settings.appBackgroundColorHex) ?? Color(.white)
        
        return RoundedRectangle(cornerRadius: BGradius)
            .fill(currentColor)
            .ignoresSafeArea()
    }

    // MARK: - 渐变背景

    private var gradientBackground: some View {
        RoundedRectangle(cornerRadius: BGradius)
            .fill(
                LinearGradient(
                    colors: [
                        Color(hex: settings.appBackgroundGradientStartHex) ?? Color(.systemBackground),
                        Color(hex: settings.appBackgroundGradientEndHex) ?? Color(.secondarySystemBackground)
                    ],
                    startPoint: .topLeading,
                    endPoint:   .bottomTrailing
                )
            )
    }

    // MARK: - 图片背景

    @ViewBuilder
    private var imageBackground: some View {
        if let uiImage = cachedImage {
            GeometryReader { geo in
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipShape(RoundedRectangle(cornerRadius: BGradius, style: .continuous))
                    .clipped()
                    .ignoresSafeArea()
                    .transition(.opacity)
            }
        } else {
            GeometryReader { geo in
                Image("AppBG.jpg")
                    .resizable()
                    .scaledToFill()
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipShape(RoundedRectangle(cornerRadius: BGradius, style: .continuous))
                    .clipped()
                    .ignoresSafeArea()
                    .transition(.opacity)
            }
        }
    }

    // MARK: - 图片读盘（后台线程）

    private func loadImageIfNeeded(filename: String) {
        // 文件名未变 → 跳过，复用缓存
        guard filename != loadedFilename else { return }
        loadedFilename = filename

        guard !filename.isEmpty else {
            cachedImage = nil
            return
        }

        Task.detached(priority: .utility) {
            let url = FileManager.default
                .urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent(filename)
            let image = UIImage(contentsOfFile: url.path)

            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.3)) {
                    cachedImage = image
                }
            }
        }
    }
}

// MARK: - 修饰符版本（便捷调用）

extension View {
    func appBackground(settings: AppSettings, radius: CGFloat) -> some View {
        self.background {
            AppBackgroundView(settings: settings, BGradius: radius)
        }
    }
}
