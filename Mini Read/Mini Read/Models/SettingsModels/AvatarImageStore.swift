// MARK: - AvatarImageStore.swift
// 放在 个性化.swift 同目录，或新建文件均可

import UIKit
internal import Combine

/// 头像图片持久化管理器
/// 图片以 JPEG 存于 Documents/avatar.jpg，有无头像记录于 UserDefaults
final class AvatarImageStore: ObservableObject {

    static let shared = AvatarImageStore()
    private init() {}

    /// 没有自定义头像时的占位字母。
    /// 目前没有账号体系，只能给一个固定首字母；它是**视觉占位**，不是数据，
    /// 所以放在这里由 ProfileView 的大头像与导航栏的小头像共用——
    /// 两处各写一个字面量迟早会漂成两个字母。
    static let placeholderInitial = "M"

    /// 当前头像，nil 表示使用默认占位
    @Published private(set) var avatarImage: UIImage? = nil

    private let filename = "avatar.jpg"
    private let hasAvatarKey = "hasCustomAvatar"

    private var fileURL: URL {
        FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(filename)
    }

    // MARK: - 生命周期

    /// App 启动 / ProfileSheet 出现时调用
    func load() {
        guard UserDefaults.standard.bool(forKey: hasAvatarKey) else { return }
        guard let img = UIImage(contentsOfFile: fileURL.path) else {
            // 文件丢失时清理标记
            UserDefaults.standard.removeObject(forKey: hasAvatarKey)
            return
        }
        avatarImage = img
    }

    // MARK: - 写入

    /// 传入原始 Data，内部完成缩放 + JPEG 压缩后落盘
    @discardableResult
    func save(data: Data) async -> Bool {
        return await Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return false }
            guard
                let raw = UIImage(data: data),
                // 缩放到 400×400，足够头像清晰度，又不浪费磁盘
                let scaled = raw.preparingThumbnail(of: CGSize(width: 400, height: 400)),
                let jpeg = scaled.jpegData(compressionQuality: 0.88)
            else { return false }

            do {
                try await jpeg.write(to: self.fileURL, options: .atomic)
                return true
            } catch {
                print("[AvatarImageStore] 保存失败: \(error)")
                return false
            }
        }.value
    }

    /// 在主线程刷新 Published 属性并更新 UserDefaults（save 成功后调用）
    @MainActor
    func commit(data: Data) async {
        let ok = await save(data: data)
        guard ok, let img = UIImage(contentsOfFile: fileURL.path) else { return }
        avatarImage = img
        UserDefaults.standard.set(true, forKey: hasAvatarKey)
    }

    // MARK: - 清除

    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
        UserDefaults.standard.removeObject(forKey: hasAvatarKey)
        avatarImage = nil
    }
}
