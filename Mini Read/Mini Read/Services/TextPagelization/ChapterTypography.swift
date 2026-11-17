//
//  ChapterTypography.swift
//  TheNewVellium
//
//  段落实模型 → 整章 NSAttributedString（2026-10-13 随 P0-C 修复新建）。
//
//  从 MainViewController 迁出的原因：正文提取改产段落实模型后，排版需要
//  按块类型分别施加样式（标题字号/引用缩进/列表悬挂/图片附件），
//  不再是「一个样式刷全章」。这段纯函数（[ChapterBlock] + 配置 + 图片基准
//  URL → 富文本）不依赖 UIKit 控件栈，独立成类型后可被运行时探针逐字验证。
//
//  约定：
//  - 输入 blocks 来自 ChapterHTMLParser（见其文件头注释）；
//  - 图片按 src 相对章文件目录解析；解码失败/文件缺失时降级为文字占位，
//    不丢内容线索；
//  - 产物即 PaginationCache 的缓存单位（含 NSTextAttachment，归档体会变大，
//    这是图片从「整章丢失」变为「正常渲染」的必要代价）。
//

import UIKit

// MARK: - 排版配置（自 MainViewController 迁入）

/// 一次排版会话的全部可变参数。任一字段变化 → `stableDigest` 变化 →
/// 分页缓存自动失效重排（见 MainViewController 的两处构造点）。
struct PaginationConfig: Sendable {
    let pageWidth: CGFloat
    let pageHeight: CGFloat
    let fontSize: CGFloat
    /// 字体：存持久化字符串（内置枚举 rawValue 或 "custom:<id>"），进入摘要后
    /// 换字体天然会让分页缓存 key 变化从而重新排版；实际 UIFont 由 resolveReadingUIFont 解析。
    let fontFamily: String
    let lineSpacing: CGFloat
    let paragraphSpacing: CGFloat
    let firstLineIndent: Bool
    let letterSpacing: CGFloat
    let marginLeft: CGFloat
    let marginRight: CGFloat
    let marginTop: CGFloat
    let marginBottom: CGFloat
    /// 正文墨色。由纸面推导而来，进入摘要后换背景会自动让分页缓存失效，
    /// 不会出现"纸面换了、字还是旧颜色"的残留。
    let textTone: ReadingTextTone

    var usableSize: CGSize {
        CGSize(
            width:  pageWidth  - marginLeft - marginRight,
            height: pageHeight - marginTop  - marginBottom
        )
    }

    /// 本次排版实际使用的边距（已按页尺寸裁剪）。
    ///
    /// 视图必须用这组值建约束；若视图侧拿"当前设置"再算一次，而排版是用
    /// 加载开始时的配置快照，两者在设置变更的 0.35s 合并窗内会短暂不一致
    /// （正文被裁或贴边）。以配置里的快照为准，视图与分页永远同一口径。
    var margins: ReaderMargins {
        ReaderMargins(top: marginTop, bottom: marginBottom, left: marginLeft, right: marginRight)
    }

    /// 排版配置的**跨进程稳定**摘要，进 `PaginationKey` 与磁盘缓存文件名。
    ///
    /// **绝不能用 `hashValue`**：Swift 的 Hasher 每进程随机播种，同一套设置
    /// 每次启动都会算出不同的值——磁盘缓存文件名随之失效，冷启动必重排全书（P0-B）。
    /// 这里对全部影响排版的字段做 SHA-256 确定性摘要（首位是内容模型版本，
    /// 见 `contentSchemaVersion`）：任一字段变化 → 摘要变化 → 自动重排重绘。
    var stableDigest: String {
        StableHash.hexDigest([
            ChapterTypography.contentSchemaVersion,
            "\(pageWidth)", "\(pageHeight)", "\(fontSize)", fontFamily,
            "\(lineSpacing)", "\(paragraphSpacing)", "\(firstLineIndent)",
            "\(letterSpacing)", "\(marginLeft)", "\(marginRight)",
            "\(marginTop)", "\(marginBottom)", textTone.rawValue,
        ])
    }
}

// MARK: - 有效版心边距

extension ReaderMargins {
    /// 从持久化设置解析有效边距。纯计算本身在 `ReaderMargins.swift`
    /// （不依赖 AppSettings，可独立验证）。
    static func resolved(_ settings: AppSettings, pageSize: CGSize) -> ReaderMargins {
        ReaderMargins(
            top:    CGFloat(settings.marginTop),
            bottom: CGFloat(settings.marginBottom),
            left:   CGFloat(settings.marginLeft),
            right:  CGFloat(settings.marginRight)
        )
        .clamped(to: pageSize, fontSize: CGFloat(settings.fontSize))
    }
}

extension PaginationConfig {
    /// 从持久化设置构造。放 extension 里是有意的：主声明中的自定义 init 会
    /// 抑制编译器合成的成员初始化器，而探针/预览需要按字段直接构造配置。
    init(_ s: AppSettings, pageSize: CGSize) {
        let margins = ReaderMargins.resolved(s, pageSize: pageSize)
        self.init(
            pageWidth:        pageSize.width,
            pageHeight:       pageSize.height,
            fontSize:         CGFloat(s.fontSize),
            fontFamily:       s.fontFamily,
            lineSpacing:      CGFloat(s.lineSpacing),
            paragraphSpacing: CGFloat(s.paragraphSpacing),
            firstLineIndent:  s.firstLineIndent,
            letterSpacing:    CGFloat(s.letterSpacing),
            marginLeft:       margins.left,
            marginRight:      margins.right,
            marginTop:        margins.top,
            marginBottom:     margins.bottom,
            textTone:         s.readingTextTone
        )
    }
}

// MARK: - 排版器

enum ChapterTypography {

    /// 内容模型版本号，进 `stableDigest` 的第一位。
    ///
    /// 排版产物的**结构**变化必须 bump 它：v1 是平铺文本（一个样式刷全章），
    /// v2 起是段落实模型（分级标题/图片附件/引用缩进），v3 新增前置页
    /// （版权页专用样式 + 扉页由阅读器单独成 VC），v4 起排版产物带目录锚点
    /// （元素 id → 字符偏移，见 `anchorOffsets`）。若不加这一位，
    /// 旧版写进磁盘缓存的富文本会在新键下被原样读回——读者看到的是
    /// 没有标题层级、图片消失的旧排版，且没有任何报错。
    /// v3 → v4 的额外理由：旧缓存里没有锚点表，读回来后 `chapter.xhtml#sec2`
    /// 会静默退回章首，正是本次要修的那个 bug 的残余。宁可让旧缓存失效一次，
    /// 也不要让"修好了但对老书无效"这种更难排查的状态存在。
    /// 旧版本缓存项届时只是不可达的死文件，由系统缓存压力或「清除缓存」回收。
    static let contentSchemaVersion = "chapter-blocks-v4"

    /// 版权页页首的饰纹行。
    ///
    /// 提成常量有两个用途：① 排版用它收口；② 阅读器在**缓存命中路径**上
    /// 要先把它从已排版文本里剥掉再做版权页检测（见 MainViewController
    /// loadChapterAsync 的注释）——两处引用同一个常量，不会各自漂移。
    static let copyrightOrnamentLine = "·  ·  ·"

    /// 段落实模型 → 整章富文本（共享 TextKit 链路：一个 NSTextStorage +
    /// 一组 NSTextContainer，每个 container 一页）。
    ///
    /// - Parameters:
    ///   - imageBase: 章文件所在目录，图片相对 href 的解析基准。
    static func attributedString(
        blocks: [ChapterBlock],
        config: PaginationConfig,
        imageBase: URL
    ) -> NSMutableAttributedString {
        typeset(blocks: blocks, config: config, imageBase: imageBase).attributedString
    }

    /// 一次排版的完整产物：富文本 + 每个块的起始字符偏移。
    struct TypographyResult {
        let attributedString: NSMutableAttributedString
        /// 与 `blocks` 等长：第 i 个块在整章文本中的起始字符偏移。
        ///
        /// 目录锚点靠它换算落点（见 `anchorOffsets`）。块偏移必须由**产出
        /// 富文本的同一趟循环**记录：项目符号、饰纹行、图片附件都会改变
        /// 文本长度，另起一趟按块类型重算必然漂移。
        let blockOffsets: [Int]
    }

    /// 段落实模型 → 整章富文本，并记录每个块的起始偏移。
    static func typeset(
        blocks: [ChapterBlock],
        config: PaginationConfig,
        imageBase: URL
    ) -> TypographyResult {
        let result = NSMutableAttributedString()
        let bodyFont = resolveReadingUIFont(config.fontFamily, size: config.fontSize)
        var blockOffsets: [Int] = []
        blockOffsets.reserveCapacity(blocks.count)

        for block in blocks {
            blockOffsets.append(result.length)

            switch block {
            case .heading(let level, let text):
                result.append(
                    NSAttributedString(
                        string: text + "\n",
                        attributes: headingAttributes(level: level, base: bodyFont, config: config)
                    )
                )

            case .paragraph(let text):
                result.append(
                    NSAttributedString(
                        string: text + "\n",
                        attributes: bodyAttributes(indentFirstLine: config.firstLineIndent,
                                                   font: bodyFont, config: config)
                    )
                )

            case .quote(let text):
                result.append(
                    NSAttributedString(
                        string: text + "\n",
                        attributes: quoteAttributes(font: bodyFont, config: config)
                    )
                )

            case .listItem(let text):
                // 项目符号 + 悬挂缩进：换行后与首行文字对齐，而不是回到版心左缘。
                let indent = config.fontSize * 1.6
                let style = NSMutableParagraphStyle()
                style.lineSpacing        = config.lineSpacing
                style.paragraphSpacing   = config.paragraphSpacing
                style.alignment          = .left
                style.headIndent         = indent
                style.firstLineHeadIndent = -indent
                result.append(
                    NSAttributedString(
                        string: "•  " + text + "\n",
                        attributes: [
                            .font: bodyFont,
                            .paragraphStyle: style,
                            .kern: config.letterSpacing,
                            .foregroundColor: config.textTone.inkColor,
                        ]
                    )
                )

            case .image(let src, let alt):
                let style = NSMutableParagraphStyle()
                style.alignment = .center
                style.paragraphSpacing = config.paragraphSpacing
                let styleAttrs: [NSAttributedString.Key: Any] = [
                    .font: bodyFont,
                    .paragraphStyle: style,
                    .foregroundColor: config.textTone.inkColor,
                ]

                if let attachment = imageAttachment(src: src, alt: alt,
                                                    imageBase: imageBase, config: config) {
                    // 段落样式必须盖在**附件字符自身**上：TextKit 取段首字符的
                    // 段落样式排版整段，只给后面的换行符加样式不会让附件居中。
                    let para = NSMutableAttributedString(attachment: attachment)
                    para.addAttributes(styleAttrs, range: NSRange(location: 0, length: max(1, para.length)))
                    para.append(NSAttributedString(string: "\n", attributes: styleAttrs))
                    result.append(para)
                } else {
                    // 图片文件读不到：留一个文字占位，读者至少知道这里缺了什么
                    let label = alt.isEmpty ? "［图片］" : "［图片：\(alt)］"
                    result.append(NSAttributedString(string: label + "\n", attributes: styleAttrs))
                }

            case .separator:
                let style = NSMutableParagraphStyle()
                style.alignment = .center
                style.paragraphSpacing = config.paragraphSpacing
                result.append(NSAttributedString(string: "·  ·  ·\n", attributes: [
                    .font: bodyFont,
                    .paragraphStyle: style,
                    .foregroundColor: config.textTone.secondaryInkColor,
                ]))
            }
        }
        return TypographyResult(attributedString: result, blockOffsets: blockOffsets)
    }

    // MARK: 目录锚点

    /// 把「元素 → 块下标」翻译成「元素 id → 字符偏移」。
    ///
    /// 块下标越界（锚点元素在章末、且一个块都没产出）时夹到文本末尾：
    /// `ChapterLayout.pageIndex(forCharacterOffset:)` 会把越界偏移夹到最后一页，
    /// 读者落在章末总比被弹回章首更接近他点的位置。
    static func anchorOffsets(
        anchors: [ChapterAnchor],
        blockOffsets: [Int],
        textLength: Int
    ) -> [String: Int] {
        guard !anchors.isEmpty else { return [:] }

        var offsets: [String: Int] = [:]
        offsets.reserveCapacity(anchors.count)
        for anchor in anchors where offsets[anchor.id] == nil {
            if anchor.blockIndex < blockOffsets.count {
                offsets[anchor.id] = blockOffsets[anchor.blockIndex]
            } else {
                offsets[anchor.id] = textLength
            }
        }
        return offsets
    }

    // MARK: 版权页（前置页）排版

    /// 版权页段落实模型 → 富文本（扉页之后的第二页，正文之前）。
    ///
    /// 与正文章节共用同一个 `ChapterLayout` / 分页管线：长版权页会自然
    /// 续页，不需要也不应该为「一页装不下」写特殊逻辑。封面页（扉页）
    /// 由阅读器单独成 VC，不计入本 layout 的页数。
    ///
    /// 美化规则——**原文一条行都不删**，版权页的信息价值高于美观：
    /// 1. 丢掉页面自带的 h1/h2 标题（「版权申明」类）：它与阅读页眉的
    ///    章节名重复，大标题还会让整页信息密度失衡；
    /// 2. `<br>` 拆出的行逐行成段，行距放宽到正文的 1.6 倍；
    /// 3. 关键行（©/版权/Copyright/ISBN/书名）正文墨色、字号 0.92 倍；
    ///    次要行（出版信息、地址、印次）辅助墨色、字号 0.8 倍——
    ///    版权页最需要的「一眼分层」由此而来；
    /// 4. 对齐跟随文字属性：中日韩字符过半 → 居中（中文版权页惯例），
    ///    否则左对齐（英文版权页惯例），不做花活的混排；
    /// 5. 首段加约 3.5 倍字号的段前距：纸质版权页从不贴着上边距排；
    /// 6. 页首一枚居中「· · ·」收口，替代纸质书的饰纹线。
    ///
    /// 判定是否走这条路由 `ChapterRender.outcome` 的 `frontMatter` 给出；
    /// 这里只负责「确定是版权页之后怎么排得好看」。
    static func copyrightString(
        blocks: [ChapterBlock],
        config: PaginationConfig
    ) -> NSMutableAttributedString {
        let result = NSMutableAttributedString()
        let bodyFont = resolveReadingUIFont(config.fontFamily, size: config.fontSize)

        // 1. 页面自带标题不进排版（页眉已交代章节名；版权类标题一律丢）
        let contentBlocks = blocks.filter { block in
            if case .heading(let level, let text) = block, level <= 2 {
                return !FrontMatterDetector.isCopyrightTitle(text)
            }
            return true
        }

        // 4. 对齐方式按主导文字属性判定
        let alignment: NSTextAlignment = FrontMatterDetector.predominantlyCJK(
            FrontMatterDetector.plainText(contentBlocks)
        ) ? .center : .left

        // 6. 页首分隔符
        let ornament = NSMutableParagraphStyle()
        ornament.alignment = alignment
        ornament.paragraphSpacingBefore = config.fontSize * 2
        ornament.paragraphSpacing = config.fontSize * 0.5
        result.append(NSAttributedString(string: copyrightOrnamentLine + "\n", attributes: [
            .font: bodyFont.withSize(config.fontSize * 0.9),
            .paragraphStyle: ornament,
            .foregroundColor: config.textTone.secondaryInkColor,
        ]))

        // 2. 内容行逐行成段（<br> 早已被解析成 \n，这里按行拆开）
        var lines: [String] = []
        for block in contentBlocks {
            switch block {
            case .heading(_, let text), .paragraph(let text), .quote(let text), .listItem(let text):
                text.components(separatedBy: "\n").forEach { line in
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { lines.append(trimmed) }
                }
            case .image(_, let alt):
                let trimmed = alt.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { lines.append(trimmed) }
            case .separator:
                break
            }
        }

        for (index, line) in lines.enumerated() {
            // 3. 关键行 / 次要行的墨色与字号分层
            let isKey = FrontMatterDetector.isKeyLine(line)
            let style = NSMutableParagraphStyle()
            style.lineSpacing      = config.lineSpacing * 1.6
            style.paragraphSpacing = config.fontSize * 0.5
            style.alignment        = alignment
            // 5. 首行下沉：内容块落在页面上三分之一处
            if index == 0 { style.paragraphSpacingBefore = config.fontSize * 3.5 }

            result.append(NSAttributedString(string: line + "\n", attributes: [
                .font: bodyFont.withSize(isKey ? config.fontSize * 0.92 : config.fontSize * 0.8),
                .paragraphStyle: style,
                .kern: config.letterSpacing,
                .foregroundColor: isKey ? config.textTone.inkColor : config.textTone.secondaryInkColor,
            ]))
        }
        return result
    }

    // MARK: 样式

    /// 正文段：两端对齐 + 段后距 + 可选首行缩进两字。
    private static func bodyAttributes(
        indentFirstLine: Bool,
        font: UIFont,
        config: PaginationConfig
    ) -> [NSAttributedString.Key: Any] {
        let style = NSMutableParagraphStyle()
        style.lineSpacing         = config.lineSpacing
        style.paragraphSpacing    = config.paragraphSpacing
        style.firstLineHeadIndent = indentFirstLine ? config.fontSize * 2 : 0
        style.alignment           = .justified
        return [
            .font: font,
            .paragraphStyle: style,
            .kern: config.letterSpacing,
            .foregroundColor: config.textTone.inkColor,
        ]
    }

    /// 标题：同族字体加大加粗、左对齐、段前距大段落距小。
    /// 加粗失败（单一字重字体，如霞鹜文楷）时不强求——字号与间距已足够分层。
    private static func headingAttributes(
        level: Int,
        base: UIFont,
        config: PaginationConfig
    ) -> [NSAttributedString.Key: Any] {
        let scale: CGFloat = switch level {
        case 1: 1.5
        case 2: 1.35
        case 3: 1.22
        default: 1.1
        }
        let size = config.fontSize * scale
        let font: UIFont
        if let bold = base.fontDescriptor.withSymbolicTraits(.traitBold) {
            // 新 SDK 上 UIFont(descriptor:size:) 非可失败；加粗拿不到 descriptor 时
            // （单一字重字体，如霞鹜文楷）走 else 分支，字号与间距已足够分层。
            font = UIFont(descriptor: bold, size: size)
        } else {
            font = base.withSize(size)
        }
        let style = NSMutableParagraphStyle()
        style.lineSpacing           = config.lineSpacing
        style.paragraphSpacing      = config.paragraphSpacing * 0.5
        style.paragraphSpacingBefore = config.fontSize * 0.9
        style.alignment             = .left
        return [
            .font: font,
            .paragraphStyle: style,
            .kern: config.letterSpacing,
            .foregroundColor: config.textTone.inkColor,
        ]
    }

    /// 引用：左右各缩进一字半，保持两端对齐。
    private static func quoteAttributes(
        font: UIFont,
        config: PaginationConfig
    ) -> [NSAttributedString.Key: Any] {
        let style = NSMutableParagraphStyle()
        style.lineSpacing      = config.lineSpacing
        style.paragraphSpacing = config.paragraphSpacing
        style.headIndent       = config.fontSize * 1.5
        style.tailIndent       = -config.fontSize * 1.5
        style.alignment        = .justified
        return [
            .font: font,
            .paragraphStyle: style,
            .kern: config.letterSpacing,
            .foregroundColor: config.textTone.inkColor,
        ]
    }

    // MARK: 图片

    /// 解析章节内图片 href 并构造 NSTextAttachment。
    ///
    /// href 形态与目录 / manifest 的 href 一样脏：相对路径、`../` 上跳、
    /// `%20` 百分号编码、根相对 `/images/a.jpg`。全部归一化后再读盘。
    private static func imageAttachment(
        src: String,
        alt: String,
        imageBase: URL,
        config: PaginationConfig
    ) -> NSTextAttachment? {
        // 去掉 fragment 与 query
        let clean = src.components(separatedBy: "#").first ?? src
        let noQuery = clean.components(separatedBy: "?").first ?? clean
        guard !noQuery.isEmpty else { return nil }
        let decoded = noQuery.removingPercentEncoding ?? noQuery
        // 根相对路径按「章节目录根」处理（EPUB 里少见，出现时按章目录拼最稳）
        let relative = decoded.hasPrefix("/") ? String(decoded.dropFirst()) : decoded

        let fileURL = imageBase.appendingPathComponent(relative).standardizedFileURL
        guard let image = UIImage(contentsOfFile: fileURL.path),
              image.size.width > 0, image.size.height > 0
        else { return nil }

        // 宽度收入版心；高度兜底不超过版心高度的 3/4，
        // 防止竖长图一页装不下把排版顶翻。
        let maxW = config.usableSize.width
        let maxH = config.usableSize.height * 0.75
        let aspect = image.size.width / image.size.height
        var w = min(image.size.width, maxW)
        var h = w / aspect
        if h > maxH { h = maxH; w = h * aspect }

        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = CGRect(x: 0, y: 0, width: w, height: h)
        return attachment
    }
}
