//
//  AnnotationState.swift
//  TheNewVellium
//
//  一章的标注投影：SwiftData 里的持久化记录 → 当前排版下可直接绘制的区间。
//
//  为什么需要这一层：
//  - 持久化锚点是"写入时的字符偏移"，绘制需要的是"这一章当前正文上的偏移"。
//    两者在正常情况下相等；书被重导入、排版内容模型升级后会漂移，
//    重锚定只应发生一次（章节加载时），不能塞进每帧的 draw。
//  - 同一章的每一页（TextRenderView）共享同一份投影，跨页标注在双页模式下
//    两页都能画出来；与 `SelectionState` 一样用弱观察者表通知重绘。
//
//  只做投影，不做持久化：写入永远回到 `ContentsPanelViewModel`，
//  避免 UIKit 层与 SwiftData 上下文产生第二条写路径。
//

import UIKit

// MARK: - 观察者

protocol AnnotationStateObserver: AnyObject {
    func annotationStateDidChange()
}

// MARK: - 投影项

/// 一处已解析到当前正文的标注。绘制层只认这个值类型。
struct AnnotationItem: Identifiable, Equatable {

    let id: UUID
    let range: NSRange
    let quote: String
    let note: String
    let style: AnnotationStyle
    let color: AnnotationColor

    var hasNote: Bool {
        !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

// MARK: - 章内投影

final class ChapterAnnotationState {

    /// 已解析、按起始偏移升序排列。
    private(set) var items: [AnnotationItem] = []

    /// 原始快照。排版对象还没挂上时先存着，等 `attach(layout:)` 再解析。
    private var snapshots: [AnnotationSnapshot] = []

    /// 弱持有：`ChapterLayout` 归 `ChapterLRUCache` 管，投影不能延长它的寿命。
    private weak var layout: ChapterLayout?

    /// 本章每一页的观察者（`TextRenderView` / `AnnotationMarginView`）。
    /// 弱引用表保证页面被 LRU 淘汰后自动退出，不需要手动反注册。
    private let observers = NSHashTable<AnyObject>.weakObjects()

    // MARK: 生命周期

    func attach(layout: ChapterLayout) {
        self.layout = layout
        rebuild()
    }

    func apply(_ new: [AnnotationSnapshot]) {
        // 书里任何一处标注变化都会走一次全量下发；内容没变的章不必重新
        // 桥接整章文本再解析一遍。
        guard new != snapshots else { return }
        snapshots = new
        rebuild()
    }

    func addObserver(_ observer: AnnotationStateObserver) {
        observers.add(observer)
    }

    // MARK: 查询

    /// 与某个字符区间相交的标注。一章的标注通常只有个位数到几十条，
    /// 直接过滤比维护"按结束位置排序"的第二索引更简单，也不会算错重叠区间。
    func items(intersecting range: NSRange) -> [AnnotationItem] {
        guard range.length > 0, !items.isEmpty else { return [] }
        return items.filter { NSIntersectionRange($0.range, range).length > 0 }
    }

    /// 某个字符位置落在哪些标注里。重叠时取**最短**的一条：
    /// 读者点在一段被整段高亮的文字里的某个短语上，想要的是那个短语。
    func item(atCharacter index: Int) -> AnnotationItem? {
        items
            .lazy
            .filter { NSLocationInRange(index, $0.range) }
            .min { $0.range.length < $1.range.length }
    }

    /// 与给定区间有交集的标注（菜单里判断"移除标注"用）。
    func item(overlapping range: NSRange) -> AnnotationItem? {
        items.first { NSIntersectionRange($0.range, range).length > 0 }
    }

    func item(id: UUID) -> AnnotationItem? {
        items.first { $0.id == id }
    }

    // MARK: 解析

    private func rebuild() {
        guard let layout else {
            if !items.isEmpty {
                items = []
                notify()
            }
            return
        }

        let text = layout.textStorage.string as NSString
        let resolved: [AnnotationItem] = snapshots.compactMap { snapshot in
            guard let range = AnnotationResolver.resolve(snapshot, in: text),
                  range.length > 0
            else { return nil }

            return AnnotationItem(
                id: snapshot.id,
                range: range,
                quote: snapshot.quote,
                note: snapshot.note,
                style: snapshot.style,
                color: snapshot.color
            )
        }

        let sorted = resolved.sorted { lhs, rhs in
            if lhs.range.location != rhs.range.location {
                return lhs.range.location < rhs.range.location
            }
            return lhs.range.length < rhs.range.length
        }

        #if DEBUG
        if resolved.count != snapshots.count {
            print("⚠️ [Annotation] \(snapshots.count - resolved.count) 处标注无法定位到当前正文（已保留记录，不绘制）")
        }
        #endif

        guard sorted != items else { return }
        items = sorted
        notify()
    }

    private func notify() {
        for observer in observers.allObjects {
            (observer as? AnnotationStateObserver)?.annotationStateDidChange()
        }
    }
}
