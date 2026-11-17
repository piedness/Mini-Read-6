//
//  OPFManifest.swift
//  Bookbinder
//
//  Created by Stone Zhang on 4/21/19.
//  Copyright © 2019 Stone Zhang. All rights reserved.
//

import Kanna
import Foundation

// https://www.w3.org/Submission/2017/SUBM-epub-packages-20170125/#sec-manifest-elem
public struct OPFManifest {
    public private(set) var items = [String: ManifestItem]()

    init?(package: XMLElement) {
        guard let manifest = package.at_xpath("opf:manifest", namespaces: XPath.opf.namespace) else { return nil }
        let itemElements = manifest.xpath("opf:item", namespaces: XPath.opf.namespace)
        for itemElement in itemElements {
            guard let item = ManifestItem(itemElement) else { continue }
            items[item.id] = item
        }
    }
}

// https://www.w3.org/Submission/2017/SUBM-epub-packages-20170125/#elemdef-package-item
public struct ManifestItem {
    public let id: String
    public let href: String
    // https://idpf.github.io/epub-cmt/v3/
    public let mediaType: String
    // https://idpf.github.io/epub-vocabs/package/item/#sec-item-property-values
    public let properties: String?
    // duration [conditionally required]
    // fallback [conditionally required]
    // media-overlay [optional]

    init?(_ item: XMLElement) {
        guard let itemId = item["id"] else { return nil }
        guard let itemHref = item["href"] else { return nil }
        // media-type 规范要求必填，但漏写的坏书不少。按扩展名仍能判断它是不是
        // 正文（见 `isXHTML`），不该因为少一个属性就把整章从 spine 里删掉。
        let itemMediaType = item["media-type"] ?? ""
        id = itemId
        href = itemHref
        mediaType = itemMediaType
        properties = item["properties"]
    }

    /// `properties` 是空格分隔的 token 列表（`"cover-image svg"`、`"nav scripted"`），
    /// 不是单个值。旧代码用 `== "nav"` 比较，带第二个 token 的书全部漏掉。
    public var propertyTokens: [String] {
        properties?.split(whereSeparator: { $0.isWhitespace }).map(String.init) ?? []
    }

    public func hasProperty(_ token: String) -> Bool {
        propertyTokens.contains(token)
    }

    /// 能不能进阅读器当正文。media-type 偶尔带 `; charset=utf-8`，
    /// 也可能与扩展名不一致，两边都认。
    public var isXHTML: Bool {
        let type = mediaType.lowercased()
        if type.hasPrefix("application/xhtml+xml") || type.hasPrefix("text/html") {
            return true
        }
        let ext = (href as NSString).pathExtension.lowercased()
        return ["xhtml", "html", "htm"].contains(ext)
    }
}
