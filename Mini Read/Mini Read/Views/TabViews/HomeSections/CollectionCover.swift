//
//  CollectionCover.swift
//  TheNewVellium
//
//  书单封面：把成员封面拼成一张无缝方图（1 本整张、2 本取第一张、
//  3 本 1+2、4 本 2×2）。缩略图经 ImageIO 降采样 + NSCache，避免首页
//  一次解码几十张原图。
//

import SwiftUI
import UIKit
import ImageIO

// MARK: - 缩略图缓存

enum CoverThumbnail {

    /// NSCache 自身线程安全，且会在内存压力下自动回收。
    private nonisolated(unsafe) static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 300
        // 只靠 countLimit 不够：书单拼图与迷你封面只有几 KB，书架封面却是
        // 600×900 起步的位图（单张约 2.7MB）。两种量级混在同一个缓存里，
        // 300 条的上限等于没有上限——必须先撞到字节预算才开始回收。
        cache.totalCostLimit = 96 * 1024 * 1024
        return cache
    }()

    /// 封面开本比例的文件头缓存。
    ///
    /// 只存一个比例，不存位图：书架卡片要在**首帧**就知道开本，
    /// 否则骨架与真封面形状不同，图一到位整行高度会跳一下。
    private nonisolated(unsafe) static let aspectCache: NSCache<NSString, NSNumber> = {
        let cache = NSCache<NSString, NSNumber>()
        cache.countLimit = 500
        return cache
    }()

    /// 同步命中，用于首帧直接出图。
    nonisolated static func cached(url: URL, maxPixel: CGFloat, aspect: CGFloat) -> UIImage? {
        cache.object(forKey: cacheKey(url, maxPixel, aspect) as NSString)
    }

    // MARK: 原开本（不裁切）

    /// 书架封面用：保持原图宽高比，只做降采样，不裁切。
    ///
    /// 与 `load(url:maxPixel:aspect:)` 分开，是因为书架刻意让每本书以自己的
    /// 开本出现（见 `BookCardView` 的尺寸策略）；按格子比例裁切会把书名裁掉。
    nonisolated static func cachedNatural(url: URL, maxPixel: CGFloat) -> UIImage? {
        cache.object(forKey: naturalKey(url, maxPixel) as NSString)
    }

    /// 读盘 + 降采样，保持原开本。**不要在主线程调用**。
    nonisolated static func natural(url: URL, maxPixel: CGFloat) -> UIImage? {
        let key = naturalKey(url, maxPixel)
        if let hit = cache.object(forKey: key as NSString) { return hit }

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            // 尊重 EXIF 方向：手机拍的封面图可能是侧躺的
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(64, maxPixel)
        ]

        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }

        let image = UIImage(cgImage: thumbnail)
        cache.setObject(image, forKey: key as NSString, cost: byteCost(image))
        return image
    }

    /// 开本比例（宽 / 高）。
    ///
    /// 只解析文件头拿像素尺寸，**不解码像素**——比 `natural(...)` 便宜两个数量级，
    /// 因此可以放心在 `body` 里同步调用（首次之后全是字典命中）。
    /// 返回 `nil` 表示文件读不出来，调用方自行回退。
    nonisolated static func aspect(url: URL) -> CGFloat? {
        let key = url.path as NSString
        if let hit = aspectCache.object(forKey: key) { return CGFloat(hit.doubleValue) }

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return nil }

        let width  = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? 0
        let height = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 0
        guard width > 0, height > 0 else { return nil }

        // EXIF 方向 5–8 表示旋转了 90°：宽高要对调，否则横竖会判断反
        let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let rotated = (5...8).contains(orientation)
        let aspect = CGFloat(rotated ? height / width : width / height)

        aspectCache.setObject(NSNumber(value: Double(aspect)), forKey: key)
        return aspect
    }

    /// 解码后的真实字节数，作为 `NSCache` 的 cost。
    private nonisolated static func byteCost(_ image: UIImage) -> Int {
        guard let cgImage = image.cgImage else { return 1 }
        return max(1, cgImage.bytesPerRow * cgImage.height)
    }

    /// 读盘 + 降采样 + 顶部对齐裁切。**不要在主线程调用**。
    nonisolated static func load(url: URL, maxPixel: CGFloat, aspect: CGFloat) -> UIImage? {
        let key = cacheKey(url, maxPixel, aspect)
        if let hit = cache.object(forKey: key as NSString) { return hit }

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            // 尊重 EXIF 方向：手机拍的封面图可能是侧躺的
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(32, maxPixel)
        ]

        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }

        let image = UIImage(cgImage: crop(thumbnail, to: aspect))
        cache.setObject(image, forKey: key as NSString, cost: byteCost(image))
        return image
    }

    /// 按目标宽高比裁切；图比目标高时从底部裁（保住顶部书名），
    /// 比目标宽时左右居中裁。这样视图层只需 `scaledToFill`，不会二次裁切。
    private nonisolated static func crop(_ image: CGImage, to aspect: CGFloat) -> CGImage {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        guard width > 0, height > 0 else { return image }

        let target = min(max(aspect, 0.05), 20)
        let current = width / height
        guard abs(current - target) > 0.005 else { return image }

        let rect: CGRect
        if current > target {
            let newWidth = min(width, (height * target).rounded(.down))
            rect = CGRect(x: ((width - newWidth) / 2).rounded(.down), y: 0,
                          width: newWidth, height: height)
        } else {
            let newHeight = min(height, (width / target).rounded(.down))
            rect = CGRect(x: 0, y: 0, width: width, height: newHeight)
        }
        return image.cropping(to: rect.integral) ?? image
    }

    /// 像素尺寸按 64 的整数倍归档、比例按 0.01 归档，避免同一张封面因
    /// 首页/详情页尺寸略有差异而在缓存里留下多份。
    private nonisolated static func cacheKey(_ url: URL, _ maxPixel: CGFloat, _ aspect: CGFloat) -> String {
        let aspectBucket = Int((min(max(aspect, 0.05), 20) * 100).rounded())
        return "\(url.path)#\(pixelBucket(maxPixel))#\(aspectBucket)"
    }

    /// 原开本那条通道的键。带 `natural` 标记，与裁切通道不会撞键。
    private nonisolated static func naturalKey(_ url: URL, _ maxPixel: CGFloat) -> String {
        "\(url.path)#natural#\(pixelBucket(maxPixel))"
    }

    private nonisolated static func pixelBucket(_ maxPixel: CGFloat) -> Int {
        max(64, Int((maxPixel / 64).rounded(.up)) * 64)
    }
}

// MARK: - 单格封面

/// 一格封面：按格子宽高比预裁，加载期间显示占位底色。
struct CoverThumbnailView: View {

    let url: URL?
    let size: CGSize
    var cornerRadius: CGFloat = 0

    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?

    private var aspect: CGFloat {
        guard size.width > 0, size.height > 0 else { return 2.0 / 3.0 }
        return size.width / size.height
    }

    /// 按 2:3 封面填满格子的最长边反推像素预算；只取 max(w,h) 会少算 1.5 倍。
    private var pixelBudget: CGFloat {
        max(size.height, size.width / (2.0 / 3.0)) * displayScale
    }

    /// 尺寸档位变化（横竖屏、分屏、iPad）时必须重新加载，否则旧图会被拉伸发糊。
    private var loadKey: String {
        "\(url?.path ?? "nil")#\(Int(pixelBudget.rounded()))#\(Int((aspect * 100).rounded()))"
    }

    /// `@State` 尚未回填时仍可直接读内存缓存。正常列表复用会少闪一次占位；
    /// 对 ImageRenderer 这类同步快照更关键——它不会等待 `.task` 完成。
    private var visibleImage: UIImage? {
        if let image { return image }
        guard let url else { return nil }
        return CoverThumbnail.cached(url: url, maxPixel: pixelBudget, aspect: aspect)
    }

    var body: some View {
        ZStack {
            if let visibleImage {
                Image(uiImage: visibleImage)
                    .resizable()
                    .scaledToFill()
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .padding(2)
            } else if url == nil {
                Image(systemName: "book.closed")
                    .font(.system(size: min(size.width, size.height) * 0.28, weight: .light))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .task(id: loadKey) { await loadImage() }
        .accessibilityHidden(true)
    }

    private func loadImage() async {
        guard let url else {
            image = nil
            return
        }

        let maxPixel = pixelBudget
        let targetAspect = aspect

        if let hit = CoverThumbnail.cached(url: url, maxPixel: maxPixel, aspect: targetAspect) {
            image = hit
            return
        }

        let loaded = await Task.detached(priority: .userInitiated) {
            CoverThumbnail.load(url: url, maxPixel: maxPixel, aspect: targetAspect)
        }.value

        // `.task(id:)` 在尺寸/URL 变化时会取消旧任务；不要让旧图覆盖新图。
        guard !Task.isCancelled else { return }
        image = loaded
    }
}

/// 列表行左侧的迷你封面（默认 34×48），与书单拼图共用降采样缓存。
///
/// 尺寸可调：元数据编辑列表要 40×58 —— 那一屏就是用来"认封面"的，
/// 34pt 宽缩略图太小，用户只能退化成靠书名找书。其余调用点保持默认值不变。
struct MiniCover: View {

    let book: bookItem
    var size: CGSize = CGSize(width: 34, height: 48)

    var body: some View {
        CoverThumbnailView(
            url: book.coverImageURLs.first,
            size: size,
            cornerRadius: 4
        )
    }
}

// MARK: - 书单封面（专辑封面）

/// 书单封面：一张填满的方图，不是"一叠书"。
///
/// 2 本时只显示第一本：左右各半会把 2:3 封面裁掉 25% 宽度、切掉书名首字母，
/// 宁可由下方数量交代还有一本。每格顶部对齐，优先保住书封上方的标题。
struct CollectionArtwork: View {

    let books: [bookItem]
    var side: CGFloat
    /// 首页 148pt 的卡片用 10；加书面板里的 44pt 缩略图需要更小的圆角。
    var cornerRadius: CGFloat = 10

    private var shown: [bookItem] { Array(books.prefix(4)) }

    var body: some View {
        layout
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                // 深色模式下载入中的封面与背景同色，需要一道细边界。
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            }
            // 接触影 + 很轻的环境影：让它像放在桌面上的实物。
            .shadow(color: .black.opacity(0.28), radius: 1.2, y: 1)
            .shadow(color: .black.opacity(0.12), radius: side * 0.04, y: side * 0.018)
            .contentShape(Rectangle())
            // 封面不承载信息；整张卡的可访问性由外层提供。
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var layout: some View {
        switch shown.count {
        case 0:
            emptyCover

        case 1, 2:
            cell(shown[0], width: side, height: side)

        case 3:
            HStack(spacing: 0) {
                cell(shown[0], width: side * 0.58, height: side)
                VStack(spacing: 0) {
                    cell(shown[1], width: side * 0.42, height: side / 2)
                    cell(shown[2], width: side * 0.42, height: side / 2)
                }
            }

        default:
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    cell(shown[0], width: side / 2, height: side / 2)
                    cell(shown[1], width: side / 2, height: side / 2)
                }
                HStack(spacing: 0) {
                    cell(shown[2], width: side / 2, height: side / 2)
                    cell(shown[3], width: side / 2, height: side / 2)
                }
            }
        }
    }

    private func cell(_ book: bookItem, width: CGFloat, height: CGFloat) -> some View {
        CoverThumbnailView(
            url: book.coverImageURLs.first,
            size: CGSize(width: width, height: height)
        )
    }

    private var emptyCover: some View {
        ZStack {
            Color.primary.opacity(0.2)

            Image(systemName: "books.vertical")
                .font(.system(size: side * 0.20, weight: .light))
                .foregroundStyle(.tertiary)
        }
        .frame(width: side, height: side)
    }
}
