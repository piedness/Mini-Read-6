//
//  ReaderLoadingView.swift
//  TheNewVellium
//
//  阅读器「正在打开」的唯一界面（2026-11-22）。
//
//  与 `ReaderOpenFailureView` 同属「阅读页之前」的那一小段：一个负责
//  「马上就来」，一个负责「来不了」。两者的排版语言必须是一套，
//  否则读者会在几百毫秒里看到两个不同的 App。
//
//  ## 为什么不再用裸的 `ProgressView()`
//  改造前这里是系统转圈，浮在一个**没有任何背景**的 ZStack 上：
//  1. 转场期间透上来的是书库和封面，纸面要等阅读器建好才「啪」地出现；
//     暗纸面（夜读）最明显——先看到浅色，再翻成近黑，闪一下。
//  2. 系统转圈与失败页的衬线排版毫无关系，两个状态像两个 App。
//  3. VoiceOver 拿不到任何信息：不读书名，也不说在等什么。
//
//  ## 现在的做法：把纸面提前一帧铺好
//  - **背景就是阅读纸面**（纯色 / 纸纹同一套 `ReadingBackground`）。
//    封面 zoom 进来时落在**一张纸上**，而不是落在一个空白容器里；随后正文在
//    同色纸面上淡入，读者看到的只是「字出现了」，底色不跳变。
//    纸纹走 `ReadingBackgroundImageLoader` 异步解码，解码前用 `fillColor`
//    兜底——两者同色，看不出先后。
//  - **标题按扉页的规矩排**：阅读字体、正文墨色、居中、只用字号分层。
//    刻意不加粗：与 `CoverPageViewController` 同一个判断——单一字重的字体
//    （如霞鹜文楷）强求粗体只会糊，字号差已经够分层次。
//  - **指示器是一道墨线弧**：1.75pt 细线、纸面同源的墨色、慢速旋转。
//    30pt 的尺寸是克制的——它只需要说明「还在动」，不需要抢戏。
//  - **0.22s 淡入**：这一屏几乎总在转场静默窗结束时就被换掉
//    （见 `BookContent.coverTransitionSettleDelay`），淡入让它「浮上来」
//    而不是「闪一下」；慢书（首次解析大 EPUB）则稳稳停在这里等。
//

import SwiftUI

struct ReaderLoadingView: View {

    /// 书名与作者：来自 `bookItem`，允许为空（元数据缺失的 EPUB 很常见）。
    let title: String
    let author: String

    /// 已解析的阅读背景。**不在这里解释设置字段**，与阅读器取同一个结论，
    /// 这样加载页与第一页纸面逐像素一致（见 `AppSettings.readingBackground`）。
    let background: ReadingBackground

    /// 阅读字体族，让「书名」和随后正文用的是同一套字。
    let fontFamily: String

    // 字号跟随 Dynamic Type：基准对齐 `.title2` / `.footnote`。
    // 用 `@ScaledMetric` 而不是 `.system(.title2)`，是因为下面的字体来自
    // `resolveReadingSwiftUIFont`（自定义字体不会自动响应 Dynamic Type）。
    //
    // 基准 28 / 15 是「半扉页」的比例：标题比正文（默认 28）略高一档就够，
    // 不必追平扉页的 1.3 倍——这一屏只停 0.45s，太重会像开屏动画。
    @ScaledMetric(relativeTo: .title2) private var titleSize: CGFloat = 28
    @ScaledMetric(relativeTo: .footnote) private var authorSize: CGFloat = 15

    /// 纸纹位图。纯色纸面下始终为 nil。
    @State private var paperImage: UIImage?

    /// 文字与指示器的淡入开关。纸面**不参与**淡入：它必须从第一帧就不透明。
    @State private var revealsContent = false

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedAuthor: String {
        author.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var inkColor: Color { background.textTone.swiftUIInk }
    private var secondaryInkColor: Color { background.textTone.swiftUISecondaryInk }

    var body: some View {
        ZStack {
            paper

            content
                .opacity(revealsContent ? 1 : 0)
        }
        .ignoresSafeArea()
        .task(id: background) { await loadPaperIfNeeded() }
        .onAppear {
            // 只改透明度、不位移：这一屏正压在 zoom 转场上，任何额外的位移
            // 都会和转场抢方向。时长与 `BookContent.readerRevealAnimation` 同长。
            withAnimation(.easeOut(duration: 0.22)) { revealsContent = true }
        }
        // 整屏作为一个元素朗读：标题、作者、指示器分开念会把一句话拆成三段。
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    // MARK: - 纸面

    /// 铺满整屏的纸面。
    ///
    /// 必须**从第一帧就完全不透明**：它承担的是「转场落点」，
    /// 一旦透明，zoom 过程中会先露出书库，再被纸面盖住——那正是要修的那个闪。
    private var paper: some View {
        Color(uiColor: background.fillColor)
            .overlay {
                if let paperImage {
                    Image(uiImage: paperImage)
                        .resizable()
                        .scaledToFill()
                        .transition(.opacity)
                }
            }
            // `scaledToFill` 会溢出容器；裁掉溢出部分。
            // 与 `PageBackgroundView` 的 `scaleAspectFill + clipsToBounds` 同构，
            // 两边铺同一张图、同一几何，切换时纹理不会错位。
            .clipped()
            .ignoresSafeArea()
    }

    // MARK: - 内容

    /// 版心与失败页共用一套度量（左右 32 / maxWidth 440，顺序也一致），
    /// 这样「正在打开」换成「打不开」时，书名停在同一行位置上。
    private var content: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)

            VStack(spacing: 10) {
                if !trimmedTitle.isEmpty {
                    Text(trimmedTitle)
                        .font(resolveReadingSwiftUIFont(fontFamily, size: titleSize))
                        .foregroundStyle(inkColor)
                        .lineSpacing(2)
                        .lineLimit(3)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !trimmedAuthor.isEmpty {
                    Text(trimmedAuthor)
                        .font(resolveReadingSwiftUIFont(fontFamily, size: authorSize))
                        .foregroundStyle(secondaryInkColor)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 32)
            .frame(maxWidth: 440)

            // 指示器挂在文字块下方 34pt：既属于同一组，又不贴住作者名。
            InkActivityIndicator(tint: inkColor)
                .padding(.top, 34)

            Spacer(minLength: 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 纸纹加载

    private func loadPaperIfNeeded() async {
        guard let preset = background.paperPreset else { return }

        // 首次取图要解码 2K 位图（几十毫秒）。绝不能同步落在主线程——
        // 这一帧正是 zoom 转场在跑的时候，见文件头的说明。
        let image = await ReadingBackgroundImageLoader.shared.imageAsync(for: preset)
        guard !Task.isCancelled else { return }

        // 纹理与兜底色同色，0.18s 的淡入几乎看不出来，只是避免它「突然出现」。
        withAnimation(.easeOut(duration: 0.18)) { paperImage = image }
    }

    // MARK: - Accessibility

    /// 一句话说清「在等什么」。
    ///
    /// 不加 `.updatesFrequently`：这一屏只出现一次，反复重读只会打断读者。
    private var accessibilityText: String {
        var text = trimmedTitle.isEmpty ? "正在打开" : "正在打开《\(trimmedTitle)》"
        if !trimmedAuthor.isEmpty {
            text += "，\(trimmedAuthor)"
        }
        return text
    }
}

// MARK: - 墨线指示器

/// 一道缓慢旋转的墨线弧。
///
/// 为什么自己画而不用 `ProgressView`：系统转圈是**蓝灰色**的固定配色，
/// 压在米白 / 松绿 / 夜读这些纸面上都会「跳出来」，而这里要的是
/// 「纸上的墨在动」——颜色必须跟着 `ReadingTextTone` 走。
private struct InkActivityIndicator: View {

    let tint: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isAnimating = false

    /// 视觉直径。30pt 是「看得见但不起眼」的档位：它出现在转场落点上，
    /// 再大会像失败页的图标，再小会被误认为纸上的一个圈。
    private let diameter: CGFloat = 30
    private let lineWidth: CGFloat = 1.75

    var body: some View {
        ZStack {
            // 极淡的一整圈：给弧一个参照，免得缺口看起来像「画歪了」。
            // 压到 0.12——再深就会读成一枚单选按钮。
            Circle()
                .stroke(tint.opacity(0.12), lineWidth: lineWidth)

            Circle()
                .trim(from: 0, to: 0.26)
                .stroke(
                    tint.opacity(0.85),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                // reduceMotion 下**不旋转**：只剩淡入淡出，不会有前庭刺激。
                .rotationEffect(.degrees(reduceMotion ? 0 : (isAnimating ? 360 : 0)))
        }
        .frame(width: diameter, height: diameter)
        .opacity(reduceMotion ? (isAnimating ? 0.5 : 1) : 1)
        .onAppear(perform: startAnimating)
    }

    private func startAnimating() {
        if reduceMotion {
            // 呼吸：1.1s 一个来回，幅度克制（1 → 0.5）。
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                isAnimating = true
            }
        } else {
            // 匀速旋转。1.0s 一圈比系统转圈慢，和「翻页」的节奏更接近。
            withAnimation(.linear(duration: 1.0).repeatForever(autoreverses: false)) {
                isAnimating = true
            }
        }
    }
}

// MARK: - 预览

#Preview("纯色纸面") {
    ReaderLoadingView(
        title: "漫长的告别",
        author: "雷蒙德·钱德勒",
        background: .color(hex: "#F8F2E8"),
        fontFamily: "LXGWWenKai"
    )
}

#Preview("夜读") {
    ReaderLoadingView(
        title: "漫长的告别",
        author: "雷蒙德·钱德勒",
        background: .color(hex: "#1B1B1E"),
        fontFamily: "系统默认"
    )
}
