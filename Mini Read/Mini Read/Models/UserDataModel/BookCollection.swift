//
//  BookCollection.swift
//  TheNewVellium
//
//  书单（Collection）——用户把书库里的一批书组织成一个阅读单元。
//
//  ## 为什么是一个真模型，而不是首页里的一个数组
//  旧实现的 `BookCollection` 是 `Collection.swift` 里的一个本地 struct，两条假数据、
//  没有任何写入路径——"把书加进书单"这件事在工程里根本不存在。要做这个功能，
//  书单必须先是可持久化的实体，否则每次冷启动都会退回到两条演示数据。
//
//  ## 与书籍的关系为什么是双向多对多
//  - 一本书可以属于多个书单（"今年想读"和"科幻"可以同时收录同一本）；
//  - 删除书单**不能**删书，删除书**必须**把它从所有书单里摘掉。
//  后者只能靠反向关系 + `.nullify` 保证：单向关系下，删书会留下指向已删除对象的
//  悬空引用，书单打开时就会崩。反向关系声明在本类（`inverse:`），
//  `bookItem.collections` 只是被动的一端。
//

import Foundation
import SwiftData

@Model
final class BookCollection {

    /// 书单名。允许重名——用户完全可以有两个"待读"，用创建时间区分先后。
    var name: String

    var createdAt: Date

    /// 首页横向货架上的排列顺序。用显式序号而不是 createdAt 排序：
    /// 将来做拖拽重排时只需要改这个值，不必伪造创建时间。
    var sortIndex: Int

    /// 封面取书的旋转种子。
    ///
    /// 封面是"从书单里挑最多 4 本拼一张方图"。当书单里的书多于 4 本时，
    /// 具体挑哪 4 本由这个种子决定（见 `CollectionCover`）——种子固定，
    /// 每次启动看到的就是同一张封面；用户点"换一张封面"时才 +1。
    var coverSeed: Int

    /// 手动指定的封面书（`bookItem.bookExtrSubdir.path`）。
    ///
    /// `nil` = 自动（按种子轮转挑 4 本）。用路径而不是 `importHash` 作键：
    /// 2026-10-13 之前导入的老书 `importHash` 是空串，拿它当键会让整批老书
    /// 都指向同一本；而 `bookExtrSubdir.path` 与 `Bookmark` / `PageProgress`
    /// 是同一套书身份口径，每本唯一。
    var coverBookKey: String?

    /// 是否是那个「默认书单」。
    ///
    /// 默认书单是长按书籍菜单里「加入我的收藏」的固定落点，所以它必须**永远可寻址**：
    /// 不允许改名（菜单文案与它绑定）、不允许删除（删了那条菜单就无处可去）。
    /// 用布尔标记而不是比对名字——名字是用户可见字符串，将来改文案或本地化都不会
    /// 影响身份判定。
    var isDefault: Bool = false

    /// 书单成员。删除书籍时由 SwiftData 置空（nullify），不会连带删掉书单。
    @Relationship(deleteRule: .nullify, inverse: \bookItem.collections)
    var books: [bookItem] = []

    init(
        name: String,
        sortIndex: Int = 0,
        createdAt: Date = .now,
        coverSeed: Int = 0,
        coverBookKey: String? = nil,
        isDefault: Bool = false
    ) {
        self.name = name
        self.sortIndex = sortIndex
        self.createdAt = createdAt
        self.coverSeed = coverSeed
        self.coverBookKey = coverBookKey
        self.isDefault = isDefault
    }
}

// MARK: - 成员与计数

extension BookCollection {

    /// 书单内书籍的**唯一**呈现顺序。
    ///
    /// SwiftData 的 to-many 关系在语义上是无序集合，不能依赖 `books` 的原生顺序
    /// （不同次启动可能不同，重排会表现为"书单里的书自己跳了位置"）。
    /// 这里按"加入书库的时间倒序 + 书名"定序：新书在前，同一批导入的按书名稳定排列。
    /// 结果对同一份数据恒定，不随 body 求值次数变化。
    var displayBooks: [bookItem] {
        books.sorted { lhs, rhs in
            if lhs.dateAdded != rhs.dateAdded { return lhs.dateAdded > rhs.dateAdded }
            return lhs.bookTitle.localizedStandardCompare(rhs.bookTitle) == .orderedAscending
        }
    }

    var bookCount: Int { books.count }

    /// "在读"的口径：已经开始、且还没读完。
    ///
    /// `readingProgress` 为 `nil` 表示这本书从未被打开统计过（分母未知），
    /// 按"没开始读"处理——与书架上不给新书盖 0% 戳是同一条规则。
    var readingCount: Int {
        books.reduce(into: 0) { count, book in
            guard let progress = book.readingProgress else { return }
            if progress > 0, progress < 0.999 { count += 1 }
        }
    }

    /// 首页卡片、详情页头、加书面板共用的数量文案。
    var bookCountText: String {
        bookCount == 1 ? "1 book" : "\(bookCount) books"
    }

    /// 数量 +（有在读成员时的）在读数。
    var summaryText: String {
        readingCount > 0 ? "\(bookCountText) · \(readingCount) reading" : bookCountText
    }

    func contains(_ book: bookItem) -> Bool {
        books.contains { $0.persistentModelID == book.persistentModelID }
    }

    /// 幂等加入。重复点击"加入书单"不会产生两条成员记录。
    func add(_ book: bookItem) {
        guard !contains(book) else { return }
        books.append(book)
    }

    func remove(_ book: bookItem) {
        books.removeAll { $0.persistentModelID == book.persistentModelID }
    }

    /// 勾选/取消勾选同一个入口，三个挑选面板不再各写一遍成员判断。
    func toggle(_ book: bookItem) {
        contains(book) ? remove(book) : add(book)
    }

    /// 换一张自动封面：清掉手动指定的封面，并推进旋转种子。
    func shuffleCover() {
        coverBookKey = nil
        coverSeed &+= 1
    }
}

// MARK: - 封面取书

/// 书单封面（方形专辑封面）的取书规则。
///
/// 单独抽出来是为了让它可预测、可测试：首页卡片、详情页大图、换封面都要
/// 得到**同一组**书，任何一处自己再写一遍排序就会对不上。
enum CollectionCover {

    /// 封面最多用几本。1 本整张、2 本取第一张、3 本 1+2、4 本 2×2；
    /// 多出来的不参与封面（只影响下方数量）。
    static let maxTiles = 4

    /// 当前应上封面的书（最多 4 本，已按拼图位置排好序）。
    static func books(for collection: BookCollection) -> [bookItem] {
        let ordered = collection.displayBooks
        guard !ordered.isEmpty else { return [] }

        // 手动指定了封面书：只显示它一张，铺满整块方图。
        if let key = collection.coverBookKey, !key.isEmpty,
           let pinned = ordered.first(where: { $0.bookExtrSubdir.path == key }) {
            return [pinned]
        }

        // 自动：把有序列表按种子旋转，再取前 4 本。
        // 旋转而不是随机抽样——随机会让封面在每次 body 求值时都可能变化。
        let count = ordered.count
        let start = ((collection.coverSeed % count) + count) % count
        let rotated = Array(ordered[start...]) + Array(ordered[..<start])
        return Array(rotated.prefix(maxTiles))
    }
}

// MARK: - 默认书单

/// 「my favorite」——长按书籍时那条「加入我的收藏」的固定落点。
///
/// ## 为什么要有一个默认书单
/// 收藏是最轻量的一次表达：用户不想为了收藏一本书先去建一个书单、再挑一次。
/// 有了固定落点，长按 → 一下，书就进去了；想整理再打开书单。
///
/// ## 为什么由代码保证它存在，而不是让用户自己建
/// 菜单项的目标是写死的，目标不存在时那一条菜单就会变成空操作。所以启动时
/// `ensure(in:)` 补齐——用户清库、迁移、误删之后它都会回来。
enum DefaultCollection {

    /// 书单名。用户可见，改这里就是改所有地方（菜单文案用的是另一套说法，
    /// 见 `BookCardView` 的「Add to My Favorite」）。
    static let name = "My Favorite"

    /// 取出默认书单；不存在就建一个。
    ///
    /// 新建时排在货架最前（`sortIndex` 取当前最小值 -1），因为它是每个用户
    /// 都有的那一本，不该被埋在别人后面。
    @discardableResult
    static func ensure(in context: ModelContext) -> BookCollection {
        if let existing = existing(in: context) { return existing }

        var firstDescriptor = FetchDescriptor<BookCollection>(
            sortBy: [SortDescriptor(\BookCollection.sortIndex)]
        )
        firstDescriptor.fetchLimit = 1
        let head = (try? context.fetch(firstDescriptor))?.first

        let created = BookCollection(
            name: name,
            sortIndex: (head?.sortIndex ?? 0) - 1,
            isDefault: true
        )
        context.insert(created)
        try? context.save()
        return created
    }

    /// 只查不建。给"读状态"用（菜单文案、是否显示删除项）。
    static func existing(in context: ModelContext) -> BookCollection? {
        var descriptor = FetchDescriptor<BookCollection>(
            predicate: #Predicate { $0.isDefault }
        )
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }
}
