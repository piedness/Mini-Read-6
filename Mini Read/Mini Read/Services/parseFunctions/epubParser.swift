//
//  EPUBBook.swift
//  Bookbinder
//
//  Created by Stone Zhang on 5/1/19.
//  Copyright © 2019 Stone Zhang. All rights reserved.
//

import Foundation

open class EPUBBook {
    public let identifier: String
    public let baseURL: URL
    public let resourceBaseURL: URL
    public let container: ContainerDocument
    public let opf: OPFDocument

    // accessor

    // https://www.w3.org/Submission/2017/SUBM-epub-packages-20170125/#sec-metadata-elem-identifiers-uid
    public lazy var uniqueID: String? = {
        let uniqueIdentifierID = opf.uniqueIdentifierID
        let identifiers = opf.metadata.identifiers
        for identifier in identifiers where identifier.id == uniqueIdentifierID {
            return identifier.text
        }
        return nil
    }()

    // https://www.w3.org/Submission/2017/SUBM-epub-packages-20170125/#sec-metadata-elem-identifiers-pid
    public lazy var releaseID: String? = {
        guard let id = uniqueID else { return nil }
        guard let date = opf.metadata.modifiedDate else {
            return id
        }
        return id + "@" + date
    }()

    public lazy var publicationDate: Date? = {
        guard let date = opf.metadata.date else { return nil }
        return ISO8601DateFormatter().date(from: date)
    }()

    // http://idpf.org/forum/topic-715
    public lazy var coverImageURLs: [URL] = {
        var urls = [URL]()
        // properties 是**空格分隔的列表**（如 "cover-image svg"），
        // 用 == 比较会漏掉所有带第二个 token 的书。
        for item in opf.manifest.items.values where item.hasProperty("cover-image") {
            urls.append(resourceURL(forHref: item.href))
        }
        guard let imageID = opf.metadata.coverImageID, let path = opf.manifest.items[imageID]?.href else {
            return urls
        }
        urls.append(resourceURL(forHref: path))
        return urls
    }()

    /// EPUB3 的导航文档（`properties="nav"`）。
    ///
    /// 找不到时按文件名兜底：properties 漏写是坏书里最常见的一类，
    /// 而 `nav.xhtml` / `toc.xhtml` 的命名约定足够稳定，值得多试一次。
    public lazy var navDocumentURL: URL? = {
        for item in opf.manifest.items.values where item.hasProperty("nav") {
            return resourceURL(forHref: item.href)
        }

        let conventionalNames = ["nav.xhtml", "nav.html", "toc.xhtml", "toc.html", "contents.xhtml"]
        for name in conventionalNames {
            let url = resourceBaseURL.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        for item in opf.manifest.items.values where item.isXHTML {
            let name = (item.href as NSString).lastPathComponent.lowercased()
            if conventionalNames.contains(name) { return resourceURL(forHref: item.href) }
        }
        return nil
    }()

    /// 兼容旧调用名：目录入口现在统一走 `navDocumentURL`。
    public lazy var tocURL: URL? = navDocumentURL

    /// NCX（EPUB2）。
    ///
    /// `spine@toc` 缺失时按 media-type / 扩展名再找一次：EPUB3 书里
    /// 同时附带 NCX 作为向后兼容是常态，而 spine@toc 常常被省略。
    public lazy var ncx: NCXDocument? = {
        var item: ManifestItem?
        if let ncxID = opf.spine.toc {
            item = opf.manifest.items[ncxID]
        }
        if item == nil {
            item = opf.manifest.items.values.first {
                $0.mediaType.lowercased().hasPrefix("application/x-dtbncx+xml")
                    || ($0.href as NSString).pathExtension.lowercased() == "ncx"
            }
        }
        guard let item else { return nil }
        return NCXDocument(url: resourceURL(forHref: item.href))
    }()

    /// manifest href → 磁盘 URL。href 可能是百分号编码（`Text/ch%201.xhtml`），
    /// 直接拼会得到一个字面量 `%20` 的路径。
    func resourceURL(forHref href: String) -> URL {
        resourceBaseURL
            .appendingPathComponent(href.removingPercentEncoding ?? href)
            .standardizedFileURL
    }

    public required init?(identifier: String? = nil, contentsOf baseURL: URL) {
        self.identifier = identifier ?? UUID().uuidString
        self.baseURL = baseURL
        // parse container file
        let containerURL = baseURL.appendingPathComponent("META-INF/container.xml")
        guard let container = ContainerDocument(xmlurl: containerURL) else { return nil }
        self.container = container
        // parse opf fitle
        let opfPath = container.opfPath.removingPercentEncoding ?? container.opfPath
        let opfURL = baseURL.appendingPathComponent(opfPath).standardizedFileURL
        resourceBaseURL = opfURL.deletingLastPathComponent()
        guard let opf = OPFDocument(url: opfURL) else { return nil }
        self.opf = opf
    }
}

/// 应用 EPUBBook类 的案例
///
//{
//    // 文件路径
//    let baseURL = getEpubExtrpath().appendingPathComponent("xin")
//
//    // 实例化EPUBBook
//    if let epubBook = EPUBBook(contentsOf: baseURL) {
//        // 访问唯一ID
//        if let uniqueID = epubBook.uniqueID {
//            print("Unique ID: \(uniqueID)")
//        } else {
//            print("Unique ID not found")
//        }
//
//        // 访问发布ID
//        if let releaseID = epubBook.releaseID {
//            print("Release ID: \(releaseID)")
//        } else {
//            print("Release ID not found")
//        }
//
//        // 访问出版日期
//        if let publicationDate = epubBook.publicationDate {
//            print("Publication Date: \(publicationDate)")
//        } else {
//            print("Publication Date not found")
//        }
//
//        // 访问封面图片URLs
//        let coverImages = epubBook.coverImageURLs
//        for url in coverImages {
//            print("Cover Image URL: \(url)")
//        }
//
//        // 访问目录URL
//        if let tocURL = epubBook.tocURL {
//            print("TOC URL: \(tocURL)")
//        } else {
//            print("TOC URL not found")
//        }
//
//        // 访问NCX文档
//        if let ncxDoc = epubBook.ncx {
//            // 处理NCX文档
//            print("NCX Document found")
//        } else {
//            print("NCX Document not found")
//        }
//
//        // 访问页面URL
//        if let pages = epubBook.pages {
//            for page in pages {
//                print("Page URL: \(page)")
//            }
//        } else {
//            print("Pages not found")
//        }
//        
//        
//        //let noname = epubBook.
//        
//    } else {
//        print("Failed to initialize EPUBBook")
//    }
//}
