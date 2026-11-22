//
//  AnnotationResolver.swift
//  TheNewVellium
//
//  标注锚点的纯函数层：裁剪选区、取原文、把持久化锚点重新解析到当前正文。
//
//  只依赖 Foundation。分页、SwiftData、UIKit 都不参与，因此这些边界情况
//  （选区首尾的空白、换行、emoji 组合字符、书被重导入后的偏移漂移）
//  可以脱离阅读器单独验证。
//

import Foundation

// MARK: - 选中结果

/// 一次文本选中的完整描述。UIKit 手势层产出，SwiftUI / SwiftData 层消费。
struct ReaderTextSelection: Equatable {

    let src: String
    let range: NSRange
    let quote: String
    let chapterTitle: String
}

// MARK: - 解析器

enum AnnotationResolver {

    /// 裁剪选区首尾的空白与换行，并对齐到组合字符边界。
    ///
    /// 两件事都必须做：
    /// - 拖选经常把段尾换行带进来，不裁的话高亮会画出一条到行尾的整条色块；
    /// - 按 UTF-16 单步裁剪会把 emoji / 组合字符劈成半个，TextKit 绘制时出现乱码。
    static func trimmed(_ range: NSRange, in text: NSString) -> NSRange {
        guard text.length > 0 else { return NSRange(location: 0, length: 0) }

        var start = max(0, min(range.location, text.length))
        var end = max(start, min(NSMaxRange(range), text.length))
        guard start < end else { return NSRange(location: start, length: 0) }

        let whitespace = CharacterSet.whitespacesAndNewlines

        while start < end {
            let cluster = text.rangeOfComposedCharacterSequence(at: start)
            guard cluster.length > 0, NSMaxRange(cluster) <= end else { break }
            let piece = text.substring(with: cluster)
            guard !piece.isEmpty,
                  piece.unicodeScalars.allSatisfy({ whitespace.contains($0) })
            else { break }
            start = NSMaxRange(cluster)
        }

        while end > start {
            let cluster = text.rangeOfComposedCharacterSequence(at: end - 1)
            guard cluster.length > 0, cluster.location >= start else { break }
            let piece = text.substring(with: cluster)
            guard !piece.isEmpty,
                  piece.unicodeScalars.allSatisfy({ whitespace.contains($0) })
            else { break }
            end = cluster.location
        }

        return NSRange(location: start, length: end - start)
    }

    /// 取一段区间的原文。
    static func quote(in range: NSRange, text: NSString) -> String {
        guard range.length > 0,
              range.location >= 0,
              NSMaxRange(range) <= text.length
        else { return "" }
        return text.substring(with: range)
    }

    /// 把持久化锚点解析到**当前**正文。
    ///
    /// 顺序：
    /// 1. 偏移仍然落在原文上 → 直接采用（绝大多数情况，O(1)）；
    /// 2. 偏移漂了但 `quote` 在章内唯一 / 有最接近的一处 → 用那一处；
    /// 3. 都找不到 → nil，调用方把这条标注视为 orphaned，不绘制但保留数据。
    static func resolve(_ snapshot: AnnotationSnapshot, in text: NSString) -> NSRange? {
        guard text.length > 0 else { return nil }

        let clamped = NSRange(
            location: max(0, min(snapshot.range.location, text.length)),
            length: max(0, min(snapshot.range.length, text.length - max(0, min(snapshot.range.location, text.length))))
        )

        if clamped.length > 0,
           snapshot.quote.isEmpty || text.substring(with: clamped) == snapshot.quote {
            return clamped
        }

        guard !snapshot.quote.isEmpty else {
            return clamped.length > 0 ? clamped : nil
        }

        return closestOccurrence(of: snapshot.quote, to: snapshot.range.location, in: text)
    }

    /// 在章内找与期望位置最近的一处原文。
    ///
    /// 先在期望位置附近开一个窗口找：书被重排版后偏移通常只漂几百到几千字，
    /// 窗口内命中既快又不会把「的」「the」这种高频词匹配到别处。
    /// 窗口内没有（书被整体替换过）才退到全章。
    ///
    /// 两个方向各查一次（`backwards` 拿"前面最近的一处"，正向拿"后面最近的一处"），
    /// 取距离更小的。这样高频词也不会因为"扫描条数上限"而漏掉真正最近的那处。
    private static func closestOccurrence(
        of quote: String,
        to desiredLocation: Int,
        in text: NSString
    ) -> NSRange? {
        guard !quote.isEmpty, quote.count <= 2_000, text.length > 0 else { return nil }

        let desired = min(max(0, desiredLocation), text.length)

        func match(_ options: NSString.CompareOptions, in range: NSRange) -> NSRange? {
            guard range.length > 0 else { return nil }
            let found = text.range(of: quote, options: options, range: range)
            return found.location == NSNotFound ? nil : found
        }

        let quoteLength = (quote as NSString).length

        func nearest(in range: NSRange) -> NSRange? {
            // 反向搜索的区间要向后多留 `quoteLength - 1` 个字符：
            // 一处标注可能"起点在期望位置之前、终点在之后"（选区正好跨过
            // 期望位置），只查到 desired 会把这一处漏掉。
            let beforeEnd = min(NSMaxRange(range), desired + max(0, quoteLength - 1))
            let before = match(
                .backwards,
                in: NSRange(location: range.location, length: max(0, beforeEnd - range.location))
            )
            let after = match(
                [],
                in: NSRange(location: desired, length: max(0, NSMaxRange(range) - desired))
            )

            switch (before, after) {
            case let (before?, after?):
                return abs(before.location - desired) <= abs(after.location - desired) ? before : after
            case let (before?, nil):
                return before
            case let (nil, after?):
                return after
            default:
                return nil
            }
        }

        let radius = 4_000
        let windowStart = max(0, desired - radius)
        let windowEnd = min(text.length, desired + radius)

        if windowEnd > windowStart,
           let found = nearest(in: NSRange(location: windowStart, length: windowEnd - windowStart)) {
            return found
        }

        return nearest(in: NSRange(location: 0, length: text.length))
    }
}
