//
//  EPUBNavigation.swift
//  TheNewVellium
//
//  EPUB 目录解析的唯一入口（2026-10-30）。
//
//  修复的四个根因：
//  1. 只认 NCX。EPUB3 只带 nav.xhtml 的书 `opf.spine.toc == nil`，
//     `EPUBBook.ncx` 因此为 nil，目录恒为空，`canOpenReader` 永远 false，
//     读者看到的是无限 ProgressView。现在 nav 优先、NCX 兜底。
//  2. 目录只展开两层。nav / NCX 都允许任意深度，第 3 层起整段丢弃。
//     现在按文档顺序拍平，保留层级编号（1.2.3）与 depth 缩进。
//  3. nav 的 href 相对 **nav 文档**而不是 OPF：`../Text/ch%201.xhtml`。
//     直接 appendingPathComponent 会拼出不存在的路径。现在统一解码、
//     解析 `..`、剥离 fragment/query，再归一化到 OPF 目录。
//  4. 没有任何目录的书（或目录项全部指向 spine 之外）。现在按 spine
//     生成兜底目录，阅读器仍然能打开——目录可以退化，正文不能。
//
//  另一个结构性问题在这里一并收口：**阅读顺序的唯一真值是 spine，不是目录**。
//  目录只负责"跳到哪儿"，不负责"有哪些内容"。原先 `allSrcs` 由目录叶子派生，
//  一本 nav 只列了 3 个「部」的书，阅读器就真的只排 3 个文件，其余正文
//  永远翻不到。spine 才是 EPUB 规范定义的阅读顺序。
//
//  2026-11-16 补第五个根因：**fragment 被丢弃**。`chapter.xhtml#sec2` 归一化时
//  连 `#sec2` 一起剥掉，同一文件里的多个目录项因此全部塌到章首——单文件 EPUB
//  （整本一个 xhtml）点任何一章都回到第 1 页。现在 fragment 随目录项一起保留，
//  由阅读器解析成字符偏移（见 ChapterHTMLParser / ChapterTypography）。
//

import Foundation
import Kanna

// MARK: - 原始目录项

/// 从 nav.xhtml / NCX 读出的**原始**目录项。
///
/// href 保持文档里的形态（可能百分号编码、带 fragment、相对来源文档），
/// 由 `EPUBNavigationParser` 按来源文档所在目录统一归一化。
public struct RawTOCEntry {
    public var title: String?
    public var href: String?
    public var children: [RawTOCEntry]

    public init(title: String?, href: String?, children: [RawTOCEntry] = []) {
        self.title = title
        self.href = href
        self.children = children
    }
}

// MARK: - 归一化后的目录

/// 目录来源。只用于日志诊断，不参与阅读逻辑。
enum EPUBTOCSource: String {
    case nav
    case ncx
    case spine

    var displayName: String {
        switch self {
        case .nav:   return "EPUB3 nav"
        case .ncx:   return "NCX"
        case .spine: return "spine 兜底"
        }
    }
}

/// 一条可渲染的目录项。
///
/// `src` 已相对 OPF 目录、百分号解码、去 fragment，并且**保证存在于阅读顺序中**。
/// 纯分组项（`<span>第一部</span>`）会借用第一个子项的 src：标题不能丢，
/// 点下去也应该落在这一部开头。只有整棵子树都没有可用正文时 src 才为 nil。
///
/// `fragment` 是 href 里 `#` 之后的部分（已解码）。同一文件里的多个目录项
/// 靠它区分落点——单文件 EPUB 的整本书就是一个 xhtml，没有它所有目录项
/// 都会落在第 1 页。
struct EPUBTOCEntry {
    let title: String
    let src: String?
    let fragment: String?
    let children: [EPUBTOCEntry]
}

/// 一次目录解析的完整产物。纯值类型，可安全跨线程回传。
struct EPUBTOC {
    /// 目录树（可能为空：书里没有任何 nav/NCX 项）。
    let entries: [EPUBTOCEntry]
    /// 阅读顺序：相对 OPF 目录的正文路径，已去重、只含真实存在的文件。
    let readingOrder: [String]
    let source: EPUBTOCSource
    /// 解析过程中放弃的内容。只进日志，不打扰读者。
    let warnings: [String]

    var isEmpty: Bool { readingOrder.isEmpty }
}

// MARK: - 路径归一化

/// EPUB 内链归一化。nav / NCX / manifest 三处的 href 都有同一批脏数据：
/// 百分号编码、`../` 上跳、`#fragment`、`?query`、反斜杠、根相对路径。
enum EPUBPath {

    /// 把 href 变成**相对 resourceBase（OPF 目录）**的路径。
    ///
    /// - Parameters:
    ///   - href: 文档里的原始 href
    ///   - directory: href 的解析基准目录（nav/NCX 所在目录，或 OPF 目录）
    ///   - resourceBase: OPF 所在目录；返回值以它为根
    ///   - archiveRoot: 解压目录根；处理 `/images/a.jpg` 这类根相对路径
    static func relativePath(
        href: String,
        relativeTo directory: URL,
        resourceBase: URL,
        archiveRoot: URL
    ) -> String? {
        guard let cleaned = clean(href) else { return nil }

        let basePath = directory.standardizedFileURL.path
        let combined: String
        if cleaned.hasPrefix("/") {
            combined = archiveRoot.standardizedFileURL.path + "/" + cleaned.dropFirst()
        } else {
            combined = basePath + "/" + cleaned
        }

        let resolved = URL(fileURLWithPath: combined).standardizedFileURL
        let baseComponents = resourceBase.standardizedFileURL.pathComponents
        let resolvedComponents = resolved.pathComponents

        // 逐段比较而不是字符串前缀：container.xml 里的 OPF 目录大小写
        // 与磁盘上的真实目录不一致时（`OEBPS` vs `Oebps`），字符串前缀会把
        // 整本书的目录项全部判成「越界」；APFS 本身是大小写不敏感的。
        guard resolvedComponents.count > baseComponents.count,
              zip(baseComponents, resolvedComponents).allSatisfy({
                  $0.caseInsensitiveCompare($1) == .orderedSame
              })
        else { return nil }

        let relative = resolvedComponents
            .dropFirst(baseComponents.count)
            .joined(separator: "/")
        return relative.isEmpty ? nil : relative
    }

    /// 去掉 fragment / query、解百分号编码、统一分隔符；外链返回 nil。
    static func clean(_ href: String) -> String? {
        var raw = href.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }

        let lower = raw.lowercased()
        let externalSchemes = ["http://", "https://", "mailto:", "tel:", "data:", "javascript:"]
        if lower.hasPrefix("//") { return nil }
        if externalSchemes.contains(where: { lower.hasPrefix($0) }) { return nil }

        // 先切 fragment / query 再解码：文件名里的 `%23` 是字面量 `#`，不能被误切。
        if let hash = raw.firstIndex(of: "#") { raw = String(raw[..<hash]) }
        if let query = raw.firstIndex(of: "?") { raw = String(raw[..<query]) }
        raw = raw.replacingOccurrences(of: "\\", with: "/")
        guard !raw.isEmpty else { return nil }

        return raw.removingPercentEncoding ?? raw
    }

    /// 取 href 里的 fragment（`#` 之后），百分号解码；没有 / 为空 / 外链返回 nil。
    ///
    /// 与 `clean` 共用同一批脏数据规则：外链、`//host`、`\` 分隔符都先排除。
    /// 刻意**不**在这里校验它是不是合法 id——nav 里也可能出现 `epubcfi(...)`，
    /// 那种 fragment 在正文里找不到对应 id，由跳转层退回章首（见
    /// `ChapterLayout.characterOffset(forAnchor:)`）。
    static func fragment(_ href: String) -> String? {
        let raw = href.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }

        let lower = raw.lowercased()
        if lower.hasPrefix("//") { return nil }
        let externalSchemes = ["http://", "https://", "mailto:", "tel:", "data:", "javascript:"]
        if externalSchemes.contains(where: { lower.hasPrefix($0) }) { return nil }

        guard let hash = raw.firstIndex(of: "#") else { return nil }
        var fragment = String(raw[raw.index(after: hash)...])
        // `a.xhtml?q=1#sec` 已在 `#` 处切开；这里只防 fragment 自身带 `?`
        // 的畸形写法（`#sec?x=1`）。
        if let query = fragment.firstIndex(of: "?") { fragment = String(fragment[..<query]) }
        fragment = fragment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fragment.isEmpty else { return nil }

        return fragment.removingPercentEncoding ?? fragment
    }

    /// 文件系统匹配键：大小写与 Unicode 归一化都不敏感。
    /// APFS 默认大小写不敏感，但 zip 里的文件名与 OPF 声明可能只差一个 NFC/NFD。
    static func canonicalKey(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping.lowercased()
    }

    /// 没有目录标题时用文件名兜底：`Text/chapter01.xhtml` → `chapter01`。
    static func displayName(for path: String) -> String {
        ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    /// 在磁盘上找一个真实存在的变体（NFC / NFD）。
    /// 只在没有 spine 可对照时使用；有 spine 时以 spine 的写法为准。
    static func existingPath(_ path: String, under base: URL) -> String? {
        let candidates = [
            path,
            path.precomposedStringWithCanonicalMapping,
            path.decomposedStringWithCanonicalMapping,
        ]
        for candidate in candidates
        where FileManager.default.fileExists(atPath: base.appendingPathComponent(candidate).path) {
            return candidate
        }
        return nil
    }
}

// MARK: - 解析器

enum EPUBNavigationParser {

    /// 解析一本书的目录与阅读顺序。调用方负责放到后台队列。
    static func parse(_ book: EPUBBook) -> EPUBTOC {
        let base = book.resourceBaseURL.standardizedFileURL
        let archiveRoot = book.baseURL.standardizedFileURL
        var warnings: [String] = []

        // 1. 阅读顺序：spine 是规范定义的真值。
        var readingOrder = spineReadingOrder(book: book, base: base, archiveRoot: archiveRoot)
        if readingOrder.isEmpty {
            warnings.append("spine 中没有可读的 XHTML 文档")
        }

        let orderSet = Set(readingOrder)
        var foldedOrder: [String: String] = [:]
        for src in readingOrder where foldedOrder[EPUBPath.canonicalKey(src)] == nil {
            foldedOrder[EPUBPath.canonicalKey(src)] = src
        }

        /// 把归一化后的相对路径对齐到阅读顺序里的**原始写法**。
        /// 目录项的 src 必须与 `allSrcs` 逐字节相等，否则进度、书签、
        /// 章节高亮会各认一套 key。
        func canonicalSource(_ path: String) -> String? {
            if readingOrder.isEmpty {
                return EPUBPath.existingPath(path, under: base)
            }
            if orderSet.contains(path) { return path }
            return foldedOrder[EPUBPath.canonicalKey(path)]
        }

        // 2. EPUB3 nav 优先。
        if let navURL = book.navDocumentURL {
            let raw = navEntries(at: navURL, warnings: &warnings)
            let entries = resolve(
                raw,
                documentDirectory: navURL.deletingLastPathComponent(),
                resourceBase: base,
                archiveRoot: archiveRoot,
                canonicalSource: canonicalSource,
                warnings: &warnings
            )
            if !entries.isEmpty {
                if readingOrder.isEmpty {
                    readingOrder = orderedSources(entries)
                }
                return EPUBTOC(
                    entries: entries,
                    readingOrder: readingOrder,
                    source: .nav,
                    warnings: warnings
                )
            }
            warnings.append("nav 文档中没有可用目录项")
        }

        // 3. EPUB2 NCX 兜底。
        if let ncx = book.ncx {
            let entries = resolve(
                ncx.entries,
                documentDirectory: ncx.url.deletingLastPathComponent(),
                resourceBase: base,
                archiveRoot: archiveRoot,
                canonicalSource: canonicalSource,
                warnings: &warnings
            )
            if !entries.isEmpty {
                if readingOrder.isEmpty {
                    readingOrder = orderedSources(entries)
                }
                return EPUBTOC(
                    entries: entries,
                    readingOrder: readingOrder,
                    source: .ncx,
                    warnings: warnings
                )
            }
            warnings.append("NCX 中没有可用目录项")
        }

        // 4. 最后一档：按 spine 生成目录。
        //    书名页、版权页也会各占一行——这是没有目录的书唯一诚实的呈现。
        let entries = spineEntries(readingOrder, base: base)
        return EPUBTOC(
            entries: entries,
            readingOrder: readingOrder,
            source: .spine,
            warnings: warnings
        )
    }

    // MARK: - Spine

    /// 按 spine 顺序取正文文件。
    ///
    /// 只保留真实存在、且是 XHTML/HTML 的条目：
    /// - 图片、音频、PDF 进阅读器只会是一页空白；
    /// - 文件缺失（解压不完整）进 `allSrcs` 会让页码前缀和整体偏移。
    private static func spineReadingOrder(book: EPUBBook, base: URL, archiveRoot: URL) -> [String] {
        let primary = book.opf.spine.itemrefs.filter(\.isPrimary)
        // linear="no" 被整本误标的坏书：primary 为空时退回全部 itemref，
        // 否则阅读顺序为空、书直接打不开。
        let refs = primary.isEmpty ? book.opf.spine.itemrefs : primary

        var seen = Set<String>()
        var sources: [String] = []

        for ref in refs {
            guard let item = book.opf.manifest.items[ref.idref], item.isXHTML else { continue }
            guard let src = EPUBPath.relativePath(
                href: item.href,
                relativeTo: base,
                resourceBase: base,
                archiveRoot: archiveRoot
            ) else { continue }
            guard FileManager.default.fileExists(
                atPath: base.appendingPathComponent(src).path
            ) else { continue }
            guard seen.insert(src).inserted else { continue }
            sources.append(src)
        }
        return sources
    }

    // MARK: - nav.xhtml

    private static func navEntries(at url: URL, warnings: inout [String]) -> [RawTOCEntry] {
        guard let html = readText(at: url) else {
            warnings.append("nav 文档读取失败：\(url.lastPathComponent)")
            return []
        }
        guard let doc = try? HTML(html: html, encoding: .utf8) else {
            warnings.append("nav 文档无法解析：\(url.lastPathComponent)")
            return []
        }

        // 规范要求 `<nav epub:type="toc">`。缺 type 的书取第一个**没有声明类型**的
        // nav；如果所有 nav 都声明了别的类型（只有 landmarks / page-list），
        // 说明这本 nav 里根本没有目录，交给 NCX 或 spine，别把地标当目录。
        let navs = Array(doc.xpath("//nav"))
        let tocNav = navs.first(where: isTOCNav)
        let untypedNav = navs.first(where: { navType($0).isEmpty })
        let scope = tocNav ?? untypedNav ?? (navs.isEmpty ? doc.at_xpath("//body") : nil)
        guard let scope else { return [] }
        guard let list = scope.at_xpath(".//ol") ?? scope.at_xpath(".//ul") else { return [] }

        return parseNavList(list, depth: 0)
    }

    private static func navType(_ nav: Kanna.XMLElement) -> String {
        (nav["epub:type"] ?? nav["type"] ?? "").lowercased()
    }

    private static func isTOCNav(_ nav: Kanna.XMLElement) -> Bool {
        let type = navType(nav)
        if type.split(whereSeparator: { $0.isWhitespace }).contains(where: { $0 == "toc" }) {
            return true
        }
        let role = (nav["role"] ?? "").lowercased()
        return role.split(whereSeparator: { $0.isWhitespace }).contains(where: { $0 == "doc-toc" })
    }

    /// 递归读取 `ol > li`。深度上限 12：坏书的自嵌套不该把解析拖死。
    private static func parseNavList(_ list: Kanna.XMLElement, depth: Int) -> [RawTOCEntry] {
        guard depth < 12 else { return [] }

        return list.xpath("./li").compactMap { li in
            let anchor = li.at_xpath("./a") ?? li.at_xpath("./span")
            var title = anchor?.text
            let href = anchor?["href"]

            var children: [RawTOCEntry] = []
            for sub in li.xpath("./ol") {
                children.append(contentsOf: parseNavList(sub, depth: depth + 1))
            }
            if children.isEmpty {
                for sub in li.xpath("./ul") {
                    children.append(contentsOf: parseNavList(sub, depth: depth + 1))
                }
            }
            // 少数书把嵌套列表包在 div 里。
            if children.isEmpty, let nested = li.at_xpath("./div/ol") {
                children = parseNavList(nested, depth: depth + 1)
            }

            // label 不在 a/span 里，而是 li 的直属文本（非标准但常见）。
            if title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
                title = li.at_xpath("./span")?.text
            }

            return RawTOCEntry(title: title, href: href, children: children)
        }
    }

    // MARK: - 归一化目录项

    private static func resolve(
        _ raw: [RawTOCEntry],
        documentDirectory: URL,
        resourceBase: URL,
        archiveRoot: URL,
        canonicalSource: (String) -> String?,
        warnings: inout [String],
        depth: Int = 0,
        dropped: inout Int
    ) -> [EPUBTOCEntry] {
        guard depth < 12 else { return [] }

        return raw.compactMap { item in
            let children = resolve(
                item.children,
                documentDirectory: documentDirectory,
                resourceBase: resourceBase,
                archiveRoot: archiveRoot,
                canonicalSource: canonicalSource,
                warnings: &warnings,
                depth: depth + 1,
                dropped: &dropped
            )

            var src: String?
            // fragment 只在 src 落地后才有意义：src 为 nil 的项跳不过去，
            // 留着一个孤立的 `#sec` 只会让下游误以为它有落点。
            var fragment: String?
            if let href = item.href,
               !href.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if let relative = EPUBPath.relativePath(
                    href: href,
                    relativeTo: documentDirectory,
                    resourceBase: resourceBase,
                    archiveRoot: archiveRoot
                ) {
                    src = canonicalSource(relative)
                }

                // 坏书常见写法：nav 放在 `nav/` 子目录，href 却按 OPF 目录写
                // （`Text/ch1.xhtml` 而不是 `../Text/ch1.xhtml`）。按规范解析失败时，
                // 再用 OPF 目录试一次——能救回整本目录，且不会影响规范书。
                if src == nil, documentDirectory.standardizedFileURL != resourceBase.standardizedFileURL,
                   let fallback = EPUBPath.relativePath(
                       href: href,
                       relativeTo: resourceBase,
                       resourceBase: resourceBase,
                       archiveRoot: archiveRoot
                   ) {
                    src = canonicalSource(fallback)
                }

                if src == nil {
                    dropped += 1
                } else {
                    // 同一文件的多个目录项（单文件 EPUB、按小节切分的 nav）
                    // 靠它区分落点；取不到就当章首。
                    fragment = EPUBPath.fragment(href)
                }
            }

            // 纯分组项（`<span>第一部</span>`）没有自己的 href。丢掉标题会让
            // 读者只看到一串 1.2.1 而不知道它们属于哪一部；让它指向第一个
            // 子项的正文，既保留标题，点下去也落在合理的起点。
            //
            // fragment 一起借：子项自己也是「同一个文件里的某一节」时，
            // 只借 src 会把父项钉回文件开头，读者点「第一部」却回到全书第一页。
            if src == nil, let first = children.first(where: { $0.src != nil }) {
                src = first.src
                fragment = first.fragment
            }

            // 没有正文、也没有子项 → 这一项点了没反应，不能进目录。
            guard src != nil || !children.isEmpty else { return nil }

            let title = cleanTitle(item.title)
                ?? src.map(EPUBPath.displayName(for:))
                ?? "未命名章节"

            return EPUBTOCEntry(title: title, src: src, fragment: fragment, children: children)
        }
    }

    private static func resolve(
        _ raw: [RawTOCEntry],
        documentDirectory: URL,
        resourceBase: URL,
        archiveRoot: URL,
        canonicalSource: (String) -> String?,
        warnings: inout [String]
    ) -> [EPUBTOCEntry] {
        var dropped = 0
        let entries = resolve(
            raw,
            documentDirectory: documentDirectory,
            resourceBase: resourceBase,
            archiveRoot: archiveRoot,
            canonicalSource: canonicalSource,
            warnings: &warnings,
            dropped: &dropped
        )
        if dropped > 0 {
            warnings.append("目录中有 \(dropped) 项指向阅读顺序之外的文件，已跳过")
        }
        return entries
    }

    // MARK: - Spine 兜底目录

    private static func spineEntries(_ sources: [String], base: URL) -> [EPUBTOCEntry] {
        var entries: [EPUBTOCEntry] = []

        for src in sources {
            let probe = inspectChapter(at: base.appendingPathComponent(src))
            // 纯空文件（既无文字也无图片）不进目录：点进去只会是一页空白。
            // 它仍留在 readingOrder 里，翻页到它时由阅读器自己处理。
            guard probe.hasContent else { continue }
            let title = probe.title ?? "第 \(entries.count + 1) 章"
            entries.append(EPUBTOCEntry(title: title, src: src, fragment: nil, children: []))
        }

        // 极端情况：所有文件都探测为空。宁可给一份「第 N 章」的目录，
        // 也不能返回空目录——那会把读者重新推回无限加载。
        guard entries.isEmpty else { return entries }
        return sources.enumerated().map { index, src in
            EPUBTOCEntry(title: "第 \(index + 1) 章", src: src, fragment: nil, children: [])
        }
    }

    private struct ChapterProbe {
        let title: String?
        let hasContent: Bool
    }

    /// 从章节文件里取一个能当目录标题的字符串，并判断它是否有可显示内容。
    ///
    /// 只读前 96KB：目录标题要么在 `<head><title>`，要么在正文开头的 h1-h3。
    /// 为一本书的几百章各读一遍全文，会让「打开一本没有目录的书」多等好几秒。
    private static func inspectChapter(at url: URL) -> ChapterProbe {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return ChapterProbe(title: nil, hasContent: false)
        }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 96 * 1024), !data.isEmpty else {
            return ChapterProbe(title: nil, hasContent: false)
        }

        let html = String(decoding: data, as: UTF8.self)
        guard let doc = try? HTML(html: html, encoding: .utf8) else {
            // 解析不了也保留：让阅读器按自己的错误路径处理，别在目录阶段吞掉。
            return ChapterProbe(title: nil, hasContent: true)
        }

        // 正文标题优先：很多书的 <title> 是全书的书名，每一章都一样。
        var title: String?
        for tag in ["h1", "h2", "h3"] {
            if let text = doc.at_xpath("//\(tag)")?.text, let cleaned = cleanTitle(text) {
                title = cleaned
                break
            }
        }
        if title == nil, let text = doc.title {
            title = cleanTitle(text)
        }

        let bodyText = doc.body?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let hasImage = doc.at_xpath("//img") != nil
            || doc.at_xpath("//image") != nil
            || html.contains("<svg")
        // 只读了前 96KB：如果文件更长、而这段里既没有文字也没有图片，
        // 不能断定它是空章——正文可能在读取窗口之后。宁可保留。
        let truncated = data.count >= 96 * 1024
        return ChapterProbe(
            title: title,
            hasContent: !bodyText.isEmpty || hasImage || truncated
        )
    }

    // MARK: - 工具

    private static func readText(at url: URL) -> String? {
        if let text = try? String(contentsOf: url, encoding: .utf8) { return text }
        var encoding: String.Encoding = .utf8
        return try? String(contentsOf: url, usedEncoding: &encoding)
    }

    /// 目录标题清洗：折叠换行/连续空白，截到 200 字符。
    private static func cleanTitle(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let collapsed = raw
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "[ \\t\\r]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else { return nil }
        return String(collapsed.prefix(200))
    }

    /// 没有 spine 时，用目录项按文档顺序反推阅读顺序（去重）。
    private static func orderedSources(_ entries: [EPUBTOCEntry]) -> [String] {
        var seen = Set<String>()
        var sources: [String] = []
        func walk(_ items: [EPUBTOCEntry]) {
            for item in items {
                if let src = item.src, seen.insert(src).inserted {
                    sources.append(src)
                }
                walk(item.children)
            }
        }
        walk(entries)
        return sources
    }
}
