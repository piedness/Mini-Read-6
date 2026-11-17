//
//  NCXDocument.swift
//  Bookbinder
//
//  Created by Stone Zhang on 5/1/19.
//  Copyright © 2019 Stone Zhang. All rights reserved.
//
//  2026-10-30 重写：只做「NCX → RawTOCEntry」，不再直接生成 UI 层的 Chapter。
//
//  原实现的三个硬伤：
//  1. `playOrder` 缺失就整条丢弃——相当一部分 EPUB2 的 NCX 不写 playOrder；
//  2. 没有 navLabel 或 content 就整条丢弃，父级分组项跟着消失，子树全丢；
//  3. 只展开两层（顶层 → subPoints），第 3 层起静默丢失。
//
//  现在：解析宽松、层级完整，归一化与拍平交给 EPUBNavigationParser。
//

import Kanna
import Foundation

// http://www.idpf.org/epub/20/spec/OPF_2.0.1_draft.htm#Section2.4.1
public struct NCXDocument {
    /// `<docTitle>`，仅用于诊断。
    public let title: String?
    /// NCX 文件位置。href 相对它所在目录解析。
    public let url: URL
    /// navMap 的原始树（href 未归一化）。
    public let entries: [RawTOCEntry]

    public let document: Kanna.XMLDocument

    init?(url: URL) {
        guard let data = try? Data(contentsOf: url) else { return nil }

        // NCX 是 XML，正常应带命名空间。坏书会漏声明，甚至写成 HTML 风格；
        // 依次退回 XML 无命名空间 → HTML 容错解析，别让整本书的目录消失。
        let xml = try? Kanna.XML(xml: data, encoding: .utf8)
        let html = xml == nil ? (try? Kanna.HTML(html: data, encoding: .utf8)) : nil
        guard let document = xml ?? html else { return nil }

        let ns = XPath.ncx.namespace
        guard let ncx = document.at_xpath("/ncx:ncx", namespaces: ns)
            ?? document.at_xpath("//ncx:ncx", namespaces: ns)
            ?? document.at_xpath("//ncx")
        else { return nil }

        self.url = url
        self.document = document
        self.title = (ncx.at_xpath("ncx:docTitle/ncx:text", namespaces: ns)?.text
            ?? ncx.at_xpath(".//docTitle/text")?.text
            ?? ncx.at_xpath(".//doctitle/text")?.text)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let navMap = ncx.at_xpath("ncx:navMap", namespaces: ns)
            ?? ncx.at_xpath(".//navMap")
            ?? ncx.at_xpath(".//navmap")
        else { return nil }

        self.entries = NCXDocument.parsePoints(in: navMap, namespaces: ns, depth: 0)
    }

    /// 读取一层 navPoint。`playOrder` 不参与解析：它只是阅读顺序提示，
    /// 而文档顺序本身就是目录顺序，缺它不该让条目消失。
    private static func parsePoints(
        in parent: Kanna.XMLElement,
        namespaces: [String: String]?,
        depth: Int
    ) -> [RawTOCEntry] {
        guard depth < 12 else { return [] }

        var points = Array(parent.xpath("ncx:navPoint", namespaces: namespaces))
        if points.isEmpty { points = Array(parent.xpath("./navPoint")) }
        if points.isEmpty { points = Array(parent.xpath("./navpoint")) }   // HTML 解析器会把标签小写化

        return points.compactMap { point in
            let label = point.at_xpath("ncx:navLabel/ncx:text", namespaces: namespaces)?.text
                ?? point.at_xpath("./navLabel/text")?.text
                ?? point.at_xpath("./navlabel/text")?.text
            let href = point.at_xpath("ncx:content/@src", namespaces: namespaces)?.text
                ?? point.at_xpath("./content/@src")?.text
            let children = parsePoints(in: point, namespaces: namespaces, depth: depth + 1)

            // 没有 label、没有 href、也没有子项 —— 这条 navPoint 提供不了任何信息。
            let hasLabel = !(label?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            let hasHref = !(href?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            guard hasLabel || hasHref || !children.isEmpty else { return nil }

            return RawTOCEntry(title: label, href: href, children: children)
        }
    }
}
