//
//  SentenceRangeResolver.swift
//  TheNewVellium
//
//  长按选中时的"默认一句"：以句末标点为界，且不跨段落。
//
//  纯函数层（只依赖 Foundation）：手势层只负责把落点换算成字符下标，
//  "这一句从哪到哪"全部在这里决定。句首句尾的空白、句末引号、段落边界、
//  整段没有句号这些情况因此都能脱离 UIKit 单独验证。
//

import Foundation

enum SentenceRangeResolver {

    // MARK: - 标点集合

    /// 句末终止符。
    ///
    /// 以中文句号为主，问号 / 叹号 / 省略号一并算：中文里"你吃了吗？我吃了。"
    /// 是两句，只认句号会把整段对话一起选进来。半角标点同样收下，英文书
    /// 才有可用的默认范围。
    private static let terminators = CharacterSet(charactersIn: "。！？…!?.")

    /// 收尾标点：跟在终止符后面的引号与括号。
    ///
    /// 它们属于前一句——选下一句时不能被起点吃进来（"……。”然后"），
    /// 选本句时又要跟着一起选中（"他说：“走吧。”"）。
    private static let closers = CharacterSet(charactersIn: "”’」』）】》〉〕｝")

    /// 段落分隔符。正文里每个块都以 "\n" 收尾（见 ChapterTypography），
    /// 因此它是句子不可越过的硬边界。
    private static let newlines = CharacterSet.newlines

    /// 向两侧找段落边界的上限（字符）。
    ///
    /// 句子不可能有两千字，没必要为"整章没有换行"的畸形单段逐字扫过几十万字：
    /// 桥接后的 NSString 逐字访问约 80ns，三十万字就是二十多毫秒的主线程卡顿。
    /// 超限时把窗口边缘当成段落边界，选区仍然落在合理位置。
    private static let maxScanDistance = 2_048

    // MARK: - 入口

    /// 落点所在的那一句（字符区间）。
    ///
    /// 边界与回退顺序：
    /// 1. 同一段内，落点前最近一个终止符之后 → 落点后最近一个终止符（含它）；
    /// 2. 段首 / 段尾本身也是边界：段首没有上一个终止符就从段首算起，
    ///    段尾没有终止符就算到段尾（最后一句常常不带句号）；
    /// 3. 整段一个终止符都没有（标题、诗歌、对话碎片）→ 退回"标点之间的短语"，
    ///    与改造前一致，不至于一次选中几千字。
    ///
    /// - Parameters:
    ///   - index: 落点在本章文本中的字符下标（UTF-16，与 TextKit 一致）。
    ///   - text: 整章正文。
    static func sentenceRange(at index: Int, in text: NSString) -> NSRange {
        let length = text.length
        guard length > 0 else { return NSRange(location: 0, length: 0) }

        var cursor = min(max(0, index), length - 1)

        // 落点压在段落分隔符上：读者点的是那一行的行尾，归前一段。
        // 不先挪开的话，下面的短语兜底会顺势扫进下一段。
        while cursor > 0, contains(newlines, text.character(at: cursor)) {
            cursor -= 1
        }
        // 文首就是空行的极端情况：再向前落到第一段正文，别把空行当成段落。
        while cursor < length - 1, contains(newlines, text.character(at: cursor)) {
            cursor += 1
        }

        let paragraph = paragraphRange(containing: cursor, in: text)
        guard paragraph.length > 0 else { return phraseRange(at: cursor, in: text, within: paragraph) }

        let lineStart = paragraph.location
        let lineEnd = NSMaxRange(paragraph)

        // 落点压在句尾引号上（"……。”" 的右引号）：读者点的是前一句的收尾，
        // 把锚点挪回终止符，别把它当成下一句的开头。
        if contains(closers, text.character(at: cursor)) {
            var probe = cursor - 1
            while probe >= lineStart, contains(closers, text.character(at: probe)) {
                probe -= 1
            }
            if probe >= lineStart, contains(terminators, text.character(at: probe)) {
                cursor = probe
            }
        }

        var backwardFrom = cursor - 1
        var sentenceEnd: Int?

        if contains(terminators, text.character(at: cursor)) {
            // 落点正压在终止符上：这一句以它收尾，而不是从它后面另起一句。
            // "……"、"？！" 这类连用的终止符要整串吃掉，否则只会选中一个点。
            var runEnd = cursor
            while runEnd + 1 < lineEnd, contains(terminators, text.character(at: runEnd + 1)) {
                runEnd += 1
            }
            var runBegin = cursor
            while runBegin - 1 >= lineStart, contains(terminators, text.character(at: runBegin - 1)) {
                runBegin -= 1
            }
            backwardFrom = runBegin - 1
            sentenceEnd = runEnd + 1
        } else if let mark = firstIndex(
            of: terminators,
            in: NSRange(location: cursor, length: lineEnd - cursor),
            of: text
        ) {
            // 连用的终止符（"……"、"？！"）整串吃进来，别只选到第一个点。
            var runEnd = mark
            while runEnd + 1 < lineEnd, contains(terminators, text.character(at: runEnd + 1)) {
                runEnd += 1
            }
            sentenceEnd = runEnd + 1
        }

        // 上一句的终止符。找不到说明落点在本段第一句，段首就是边界。
        var lower = lineStart
        if let mark = lastIndex(
            of: terminators,
            in: NSRange(location: lineStart, length: max(0, backwardFrom + 1 - lineStart)),
            of: text
        ) {
            lower = mark + 1
        }

        // 整段没有任何终止符 → 短语兜底。判断放在这里而不是入口处：
        // 落点压在终止符上时 sentenceEnd 一定非 nil，不该被误判成"没有句号"。
        guard sentenceEnd != nil || lower > lineStart else {
            return phraseRange(at: cursor, in: text, within: paragraph)
        }

        var upper = sentenceEnd ?? lineEnd

        // 句首：跳过上一句留下的收尾引号与空白（"……。”然后" → "然后"）。
        while lower < upper, isSentenceLead(text.character(at: lower)) {
            lower += 1
        }
        // 句尾：句末引号、括号跟着本句一起选中（"他说：“走吧。”"）。
        while upper < lineEnd, contains(closers, text.character(at: upper)) {
            upper += 1
        }

        let range = AnnotationResolver.trimmed(
            NSRange(location: lower, length: max(0, upper - lower)),
            in: text
        )
        // 只剩标点或空白（例如落点压在一对孤零零的引号上）时也别返回空选区：
        // 空选区会让读者按了半天却看不到任何反馈。
        guard range.length > 0 else {
            return phraseRange(at: cursor, in: text, within: paragraph)
        }
        return range
    }

    // MARK: - 段落

    /// 落点所在段落（不含结尾的 "\n"）。
    ///
    /// 落点正压在 "\n" 上时归前一段：读者点的是那一行的行尾，
    /// 不是下一段的段首。向两侧最多看 `maxScanDistance` 个字符。
    private static func paragraphRange(containing index: Int, in text: NSString) -> NSRange {
        let length = text.length
        guard length > 0 else { return NSRange(location: 0, length: 0) }

        let anchor = min(max(0, index), length - 1)

        let backwardSpan = min(anchor, maxScanDistance)
        let before = lastIndex(
            of: newlines,
            in: NSRange(location: anchor - backwardSpan, length: backwardSpan),
            of: text
        )
        let start = before.map { $0 + 1 } ?? (anchor - backwardSpan)

        let forwardSpan = min(length - anchor, maxScanDistance + 1)
        let after = firstIndex(
            of: newlines,
            in: NSRange(location: anchor, length: forwardSpan),
            of: text
        )
        let end = after ?? min(length, anchor + forwardSpan)

        return NSRange(location: start, length: max(0, end - start))
    }

    /// 句首可以安全跳过的字符：空白，以及上一句遗留的收尾引号。
    private static func isSentenceLead(_ ch: unichar) -> Bool {
        if contains(closers, ch) { return true }
        return contains(.whitespacesAndNewlines, ch)
    }

    // MARK: - 批量扫描

    /// 在 `range` 里找**第一个**属于 `set` 的字符。
    ///
    /// 用 `rangeOfCharacter` 而不是逐字 `character(at:)`：桥接后的 NSString
    /// 逐字访问约 80ns 一次，三十万字、整章没有换行的畸形单段会把主线程
    /// 卡住几十毫秒；原生批量扫描同样的范围不到 0.01ms。
    private static func firstIndex(
        of set: CharacterSet,
        in range: NSRange,
        of text: NSString
    ) -> Int? {
        guard range.length > 0 else { return nil }
        let found = text.rangeOfCharacter(from: set, options: [], range: range)
        return found.location == NSNotFound ? nil : found.location
    }

    /// 在 `range` 里找**最后一个**属于 `set` 的字符。
    private static func lastIndex(
        of set: CharacterSet,
        in range: NSRange,
        of text: NSString
    ) -> Int? {
        guard range.length > 0 else { return nil }
        let found = text.rangeOfCharacter(from: set, options: .backwards, range: range)
        return found.location == NSNotFound ? nil : found.location
    }

    /// 单个字符是否属于 `set`。
    ///
    /// 只用于连用标点、句首空白这类**很短的连续段**，逐字访问的成本可以忽略。
    private static func contains(_ set: CharacterSet, _ ch: unichar) -> Bool {
        guard let scalar = UnicodeScalar(ch) else { return false }
        return set.contains(scalar)
    }

    // MARK: - 兜底

    /// 段落里一个终止符都没有时的兜底：退回"标点之间的短语"。
    ///
    /// 与改造前一致的有界局部扫描（向两侧最多 48 个字符，遇空白或标点停），
    /// 不用 `NLTokenizer` 全章分词：三十万字的章节在主线程上分词会明显卡顿。
    /// 标题、诗歌、对话碎片这类段落，选中整段往往过长；一小段至少是读者
    /// 想要的那几个字，需要更多还可以拖手柄。
    ///
    /// 扫描严格限制在 `line` 之内——兜底同样不能跨段落。
    private static func phraseRange(at index: Int, in text: NSString, within line: NSRange) -> NSRange {
        let length = text.length
        guard length > 0 else { return NSRange(location: 0, length: 0) }

        let lowerBound = max(0, min(line.location, length))
        let upperBound = max(lowerBound, min(NSMaxRange(line), length))
        // 空段落（整章只有换行）：给一个最小非空区间，调用方裁剪后自然放弃。
        guard upperBound > lowerBound else {
            return NSRange(location: min(max(0, index), length - 1), length: 1)
        }

        let idx = min(max(lowerBound, index), upperBound - 1)
        let stops = CharacterSet.whitespacesAndNewlines
            .union(.punctuationCharacters)

        func cluster(at i: Int) -> NSRange {
            text.rangeOfComposedCharacterSequence(at: min(max(lowerBound, i), upperBound - 1))
        }
        func isBoundary(at i: Int) -> Bool {
            guard i >= lowerBound, i < upperBound else { return true }
            let piece = text.substring(with: cluster(at: i))
            return piece.unicodeScalars.allSatisfy { stops.contains($0) }
        }

        // 落点压在空白/标点上时，向前/后找一个最近的实字作为种子。
        // 否则会先选中一个空格，裁剪后又变成空选区。
        var seed = idx
        if isBoundary(at: idx) {
            var distance = 1
            while distance <= 24 {
                if idx + distance < upperBound, !isBoundary(at: idx + distance) {
                    seed = idx + distance
                    break
                }
                if idx - distance >= lowerBound, !isBoundary(at: idx - distance) {
                    seed = idx - distance
                    break
                }
                distance += 1
            }
        }

        var start = cluster(at: seed).location
        var steps = 0
        while start > lowerBound, steps < 48 {
            let previous = cluster(at: start - 1)
            guard !isBoundary(at: previous.location) else { break }
            start = previous.location
            steps += 1
        }

        var end = NSMaxRange(cluster(at: seed))
        steps = 0
        while end < upperBound, steps < 48 {
            let next = cluster(at: end)
            guard !isBoundary(at: next.location) else { break }
            end = NSMaxRange(next)
            steps += 1
        }

        if end <= start {
            end = min(upperBound, start + 1)
        }
        return NSRange(location: start, length: end - start)
    }
}
