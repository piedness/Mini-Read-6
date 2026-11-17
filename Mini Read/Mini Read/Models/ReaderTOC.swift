//
//  ReaderTOC.swift
//  TheNewVellium
//
//  阅读器目录的 UI 模型（2026-10-30）。
//
//  这些类型原先和 `ContentsPanelViewModel` 挤在同一个文件里，但它们只是
//  纯值类型：不依赖 SwiftUI / SwiftData / UIKit。独立出来后：
//  - 目录解析层可以在没有 UI 的环境里被单独验证（Tests / 命令行夹具）；
//  - `EPUBTOC → [Chapter]` 的拍平规则只有一个入口，不会被视图层重复实现。
//

import Foundation

// MARK: - 章节

struct Chapter: Identifiable {
    let id = UUID()
    let number: Int
    let title: String
    let src: String
    var subChapters: [SubChapter]
    var readingProgress: Double = 0.0

    /// 这一章在目录里只有一个「自己指向自己」的子项。
    ///
    /// 两种来源都会长成这样：NCX 里没有子节点的顶层 navPoint，以及 spine 兜底目录。
    /// 目录面板据此把父行本身变成可跳转的章节行，不再展开出第二条一模一样的标题。
    var isLeaf: Bool {
        guard subChapters.count == 1, let only = subChapters.first else { return false }
        // 标题也要一致：一个「部」下只挂了一章、且两者都指向同一个文件时，
        // 标题通常不同（「第一部」vs「第一章」），那不是叶子，父行应该展开。
        return only.src == src
            && only.title.trimmingCharacters(in: .whitespacesAndNewlines)
                == title.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct SubChapter: Identifiable {
    let id = UUID()
    let number: String
    let title: String
    let src: String
    /// 目录层级：1 = 大章下的第一层。深层目录被拍平后靠它做缩进，
    /// 读者仍然看得出「这一节属于上一节」。
    var depth: Int = 1
    var isRead: Bool = false
    /// 章内锚点（`chapter.xhtml#sec2` 的 `sec2`）。
    ///
    /// nil = 目录项只指到文件（跳章首，既有语义）。
    /// 非 nil 时阅读器把它解析成字符偏移再落页——同一文件里的多个目录项
    /// 靠它区分落点，否则全部落在第 1 页。
    var anchor: String? = nil
}

// MARK: - 跳转意图

/// 目录点击产生的独立跳转请求。
/// 使用独立 token，避免“点击当前章节”这类 currentSrc 不变的情况被忽略。
struct TOCJumpRequest: Equatable {
    let id: UUID
    let src: String

    /// 书签跳转用的**字符锚点**；nil = 章节首屏（目录点击的既有语义）。
    ///
    /// 刻意不传页码：页码随字号/旋转漂移，字符偏移不会。由阅读器在
    /// 本章当前排版结果上把偏移解析成页码（见 `ViewController.jumpTo`）。
    var characterOffset: Int? = nil

    /// 目录项自带的**章内锚点**（EPUB 的 `#fragment`）。
    ///
    /// 与 `characterOffset` 互斥：书签直接用偏移，目录用 id。
    /// 阅读器把 id 解析成本章当前排版下的字符偏移，解析不到就退回章首——
    /// 这与本功能上线前的行为一致，不会跳错位置。
    var anchorID: String? = nil
}

// MARK: - 打开失败

/// 阅读器打不开这本书的原因。
///
/// 失败态是产品的一部分：读者必须看到**为什么**打不开，以及**能做什么**。
/// 原先解析失败只 `print`，界面永远停在 ProgressView——这是比打不开更糟的状态。
struct ReaderLoadFailure: Equatable, Error {
    let title: String
    let message: String
}

// MARK: - 目录 → 章节（拍平）

extension EPUBTOC {

    /// 把归一化目录拍平成两级 UI 模型。
    ///
    /// `Chapter` 仍是顶层分组，`SubChapter` 收纳**所有**后代：
    /// 第 3 层起不再丢弃，按文档顺序排在同一章下，编号保留层级路径
    /// （1.2.3），缩进由 `SubChapter.depth` 决定。
    func makeChapters() -> [Chapter] {
        entries.enumerated().compactMap { index, entry in
            let chapterNumber = index + 1
            var subChapters: [SubChapter] = []

            func append(_ item: EPUBTOCEntry, path: [Int], depth: Int) {
                if let src = item.src, !src.isEmpty {
                    let number = ([chapterNumber] + path).map(String.init).joined(separator: ".")
                    subChapters.append(
                        SubChapter(
                            number: number,
                            title: item.title,
                            src: src,
                            depth: depth,
                            anchor: item.fragment
                        )
                    )
                }
                for (childIndex, child) in item.children.enumerated() {
                    append(child, path: path + [childIndex + 1], depth: depth + 1)
                }
            }

            if entry.children.isEmpty {
                // 叶子：把自己包装成唯一的子项，保持「点目录项 = 跳到 src」的语义。
                guard let src = entry.src else { return nil }
                subChapters = [
                    SubChapter(
                        number: "\(chapterNumber)",
                        title: entry.title,
                        src: src,
                        depth: 1,
                        anchor: entry.fragment
                    )
                ]
            } else {
                for (childIndex, child) in entry.children.enumerated() {
                    append(child, path: [childIndex + 1], depth: 1)
                }
                // 父项有子项、但子项全部没有可用 src（纯分组标题）：
                // 退回父项自身，至少给读者一个能点的入口。
                if subChapters.isEmpty, let src = entry.src {
                    subChapters = [
                        SubChapter(
                            number: "\(chapterNumber)",
                            title: entry.title,
                            src: src,
                            depth: 1,
                            anchor: entry.fragment
                        )
                    ]
                }
            }

            guard !subChapters.isEmpty else { return nil }
            return Chapter(
                number: chapterNumber,
                title: entry.title,
                src: entry.src ?? subChapters[0].src,
                subChapters: subChapters
            )
        }
    }
}
