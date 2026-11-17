import UIKit

// MARK: - ChapterLRUCache

/// LRU（最近最少使用）章节缓存
///
/// 最多在内存中保留 `capacity` 个章节的 UIViewController 数组。
/// 超出容量时，自动淘汰最久未访问的章节，释放关联 View 占用的内存。
///
/// - 读（get）：将访问的 key 移至队列末尾（最近使用）
/// - 写（put）：若超出容量，移除队列头部（最久未用）
/// - 线程安全：仅在主线程访问，无需加锁
final class ChapterLRUCache {

    // MARK: - Properties

    private let capacity: Int
    private var dict:  [String: [UIViewController]] = [:]
    private var order: [String] = []      // 尾部 = 最近使用

    /// 正在上屏的章。淘汰永远跳过它们。
    ///
    /// 为什么必须 pin：VC 数组被淘汰时 `onEvict` 会删掉 `vcIndexMap` 里的位置，
    /// 但 `pageVC` 仍然持有并显示那些 VC。若当前章被淘汰，`findLocation` 从此
    /// 返回 nil —— 手势/音量键翻页、进度写回、书签上报全部静默失效，而且不会自愈。
    /// 预取是异步的：读者连点几个目录项时，旧章晚到的 put 足以把屏幕上的章挤出容量。
    private var pinned: Set<String> = []

    /// 淘汰回调：参数为被淘汰章节的 src 和对应的 VC 数组
    var onEvict: ((String, [UIViewController]) -> Void)?

    // MARK: - Init

    init(capacity: Int = 5) {
        precondition(capacity > 0, "LRU capacity 必须大于 0")
        self.capacity = capacity
    }

    // MARK: - Interface

    /// 获取章节页面数组；命中时更新 LRU 顺序
    func get(_ key: String) -> [UIViewController]? {
        guard let value = dict[key] else { return nil }
        touch(key)
        return value
    }

    /// 存入章节页面数组；超容量时淘汰最久未用的章节
    func put(_ key: String, value: [UIViewController]) {
        if dict[key] != nil {
            dict[key] = value
            touch(key)
            return
        }

        dict[key] = value
        order.append(key)

        if dict.count > capacity {
            // 跳过 pinned（屏幕上正在显示的那一章），也不要把**刚插入的**
            // 这一章当作淘汰对象。若其余条目全被 pin，宁可临时超出容量一格，
            // 也不能把当前页或刚加载好的页删掉。
            if let evictIndex = order.firstIndex(where: { $0 != key && !pinned.contains($0) }) {
                let evicted = order.remove(at: evictIndex)
                let evictedVCs = dict.removeValue(forKey: evicted)
                if let vcs = evictedVCs { onEvict?(evicted, vcs) }
                print("♻️ LRU 淘汰章节: \(evicted)（当前缓存 \(dict.count)/\(capacity)）")
            }
        }
    }

    func contains(_ key: String) -> Bool { dict[key] != nil }

    /// 把某一章加入保护集合（可叠加）。用于 `spineLocationFor` 这类
    /// 还在确认当前章的场景；确认后调用 `pinOnly` 收敛成单章。
    func pin(_ key: String) {
        pinned.insert(key)
    }

    /// 只保护这一章（阅读器上屏后的通常口径）。
    func pinOnly(_ key: String) {
        pinned = [key]
    }

    func removeAll() {
        dict.removeAll()
        order.removeAll()
        pinned.removeAll()
    }

    // MARK: - Private

    private func touch(_ key: String) {
        order.removeAll { $0 == key }
        order.append(key)
    }
}
