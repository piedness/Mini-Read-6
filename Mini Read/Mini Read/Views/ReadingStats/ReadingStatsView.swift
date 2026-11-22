//
//  ReadingStatsView.swift
//  TheNewVellium
//
//  阅读数据详情页。
//
//  ## 这一页要回答什么
//  不是「我累计读了多少小时」，而是三个闭环：
//  - 读了什么：当前在读、本期读过的书、作者偏好；
//  - 读得怎么样：趋势、时段、单次时长、章节节奏；
//  - 还想继续读：今日、连续天数、还需多久读完。
//
//  ## 布局
//  - **紧凑宽度**（iPhone、iPad 分屏窄栏）：单列。首屏只留一个主角——
//    今日时长 + 近 14 天；其下是当前在读与书架进度，再往下才是详细统计。
//  - **常规宽度 ≥ 900pt**（iPad 横屏 / 竖屏全屏）：仪表盘布局。首屏左侧
//    主数字，右侧「继续阅读 + 书架进度」；趋势图铺满整行；其余卡片分两列
//    （左：书籍、单次；右：时段、洞察、作者）。iPad 横屏下页面高度从
//    约三屏压到一屏半，且不需要在窄栏里反复上下找数字。
//  - **辅助功能字号**：无论多宽都退回单列。两列在 AX 字号下会被压成
//    两条竖线，宁可让用户多滚两下。
//
//  ## 数据从哪来
//  唯一来源是 `ReadingSession`（阅读器退出/切后台时写入）加上书籍本身的
//  进度与书签。聚合在后台线程完成（`ReadingStatsEngine`），主线程只做
//  模型 → 值类型快照的转换。
//

import SwiftUI
import SwiftData

struct ReadingStatsView: View {

    let settings: AppSettings
    /// 是否显示导航栏标题。
    ///
    /// iPhone 的详情页需要「阅读数据」交代位置；iPad 的 Home 本来就不设标题
    /// （见 `iPadOSTabs.swift`），详情页再冒出一个标题会和整套 iPad 导航语汇打架。
    /// 由调用方按平台决定，视图本身不读 `UIDevice`。
    var showsNavigationTitle: Bool = true

    @Query(sort: \ReadingSession.endedAt)
    private var sessions: [ReadingSession]

    @Query private var books: [bookItem]
    @Query private var progressRecords: [ReadingProgressRecord]
    @Query private var bookmarks: [Bookmark]

    @State private var range: ReadingStatsRange = .month
    @State private var snapshot: ReadingStatsSnapshot?
    @State private var viewWidth: CGFloat = 0
    /// 宽版右侧栏的自然高度。Hero 用它补齐，保证两张卡底边齐平。
    @State private var sideColumnHeight: CGFloat = 0

    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    private var accent: Color {
        StatsPalette.accent(hex: settings.appTintColorHex)
    }

    private var layout: StatsLayout {
        StatsLayout(width: viewWidth, typeSize: typeSize)
    }

    var body: some View {
        ScrollView {
            Group {
                if let snapshot {
                    if snapshot.hasData {
                        content(snapshot, layout: layout)
                    } else {
                        emptyState
                            .frame(maxWidth: 560)
                            .frame(maxWidth: .infinity)
                            .padding(.top, layout.isWide ? 32 : 8)
                    }
                } else {
                    loadingState(layout: layout)
                }
            }
            .frame(maxWidth: layout.maxContentWidth)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, layout.horizontalPadding)
            .padding(.top, 8)
            .padding(.bottom, 48)
        }
        .scrollIndicators(.hidden)
        .background(StatsPalette.pageFill.ignoresSafeArea())
        .modifier(StatsNavigationTitle(showsTitle: showsNavigationTitle))
        .tint(accent)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            viewWidth = width
        }
        .task(id: reloadKey) {
            await reload()
        }
    }

    // MARK: - 内容

    @ViewBuilder
    private func content(_ snapshot: ReadingStatsSnapshot, layout: StatsLayout) -> some View {
        if layout.isWide {
            wideContent(snapshot, layout: layout)
        } else {
            compactContent(snapshot, layout: layout)
        }
    }

    // MARK: 紧凑宽度

    @ViewBuilder
    private func compactContent(_ snapshot: ReadingStatsSnapshot, layout: StatsLayout) -> some View {
        ReadingStatsHero(
            overview: snapshot.overview,
            accent: accent,
            sparklineHeight: layout.sparklineHeight
        )

        if let current = snapshot.overview.currentBook {
            CurrentBookCard(book: current, accent: accent)
        }

        LibraryProgressCard(overview: snapshot.overview, accent: accent)

        detailHeader(wide: false)

        trendCard(snapshot, layout: layout)
        booksCard(snapshot)
        rhythmCard(snapshot)
        sessionCard(snapshot)
        authorsCard(snapshot)
        insightsCard(snapshot)

        privacyNote(snapshot.overview)
    }

    // MARK: iPad 仪表盘

    @ViewBuilder
    private func wideContent(_ snapshot: ReadingStatsSnapshot, layout: StatsLayout) -> some View {
        VStack(alignment: .leading, spacing: layout.rowSpacing) {
            // 底对齐 + Hero 的 minHeight：右栏比 Hero 高时 Hero 补齐，
            // Hero 比右栏高时右栏贴底。两种情况下「书架进度」的底边
            // 都与「今日阅读」落在同一条线上。
            HStack(alignment: .bottom, spacing: layout.columnSpacing) {
                ReadingStatsHero(
                    overview: snapshot.overview,
                    accent: accent,
                    sparklineHeight: layout.sparklineHeight,
                    numberScale: 1.15,
                    minHeight: sideColumnHeight,
                    stretches: true
                )
                .frame(maxWidth: .infinity)

                VStack(spacing: layout.rowSpacing) {
                    if let current = snapshot.overview.currentBook {
                        CurrentBookCard(book: current, accent: accent)
                    }

                    LibraryProgressCard(overview: snapshot.overview, accent: accent)
                }
                .frame(width: layout.sideColumnWidth)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { height in
                    sideColumnHeight = height
                }
            }

            detailHeader(wide: true)

            trendCard(snapshot, layout: layout)

            // 左列：书籍（长）+ 单次（中）；右列：时段（长）+ 洞察（中）
            // + 作者（短）。两列高度接近，底部不会拖出一条大空白。
            HStack(alignment: .top, spacing: layout.columnSpacing) {
                VStack(spacing: layout.rowSpacing) {
                    booksCard(snapshot)
                    sessionCard(snapshot)
                }
                .frame(maxWidth: .infinity)

                VStack(spacing: layout.rowSpacing) {
                    rhythmCard(snapshot)
                    insightsCard(snapshot)
                    authorsCard(snapshot)
                }
                .frame(maxWidth: .infinity)
            }

            privacyNote(snapshot.overview)
        }
    }

    // MARK: - 卡片

    private func trendCard(
        _ snapshot: ReadingStatsSnapshot,
        layout: StatsLayout
    ) -> some View {
        ReadingStatsTrendCard(
            trend: snapshot.trend,
            subtitle: snapshot.range.subtitle,
            accent: accent,
            reduceMotion: reduceMotion,
            chartHeight: layout.chartHeight
        )
    }

    private func booksCard(_ snapshot: ReadingStatsSnapshot) -> some View {
        ReadingStatsBooksCard(
            books: snapshot.books,
            subtitle: snapshot.range.subtitle,
            accent: accent,
            overview: snapshot.overview,
            completionRate: snapshot.insights.completionRate
        )
    }

    private func rhythmCard(_ snapshot: ReadingStatsSnapshot) -> some View {
        ReadingStatsRhythmCard(
            rhythm: snapshot.rhythm,
            subtitle: "按周几 × 小时",
            accent: accent
        )
    }

    private func sessionCard(_ snapshot: ReadingStatsSnapshot) -> some View {
        ReadingStatsSessionCard(
            profile: snapshot.sessionProfile,
            accent: accent
        )
    }

    private func authorsCard(_ snapshot: ReadingStatsSnapshot) -> some View {
        ReadingStatsAuthorsCard(
            authors: snapshot.authors,
            subtitle: "按阅读时长",
            accent: accent
        )
    }

    private func insightsCard(_ snapshot: ReadingStatsSnapshot) -> some View {
        ReadingStatsInsightsCard(
            insights: snapshot.insights,
            nightShare: snapshot.rhythm.nightShare,
            accent: accent
        )
    }

    // MARK: - 详细统计标题

    /// 宽版把标题和范围选择并排放，范围选择像工具条而不是「页面中段
    /// 突然出现的筛选器」；窄版仍保持上下两行。
    @ViewBuilder
    private func detailHeader(wide: Bool) -> some View {
        if wide {
            HStack(alignment: .bottom, spacing: 24) {
                StatsSectionHeader(
                    title: "详细统计",
                    caption: "以下数据按所选范围统计"
                )

                Spacer(minLength: 24)

                StatsRangePicker(range: $range, accent: accent)
                    .frame(width: 360)
            }
        } else {
            VStack(alignment: .leading, spacing: 12) {
                StatsSectionHeader(
                    title: "详细统计",
                    caption: "以下数据按所选范围统计"
                )

                StatsRangePicker(range: $range, accent: accent)
            }
            .padding(.top, 4)
        }
    }

    // MARK: - 空状态

    private var emptyState: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(accent.opacity(colorScheme == .dark ? 0.22 : 0.12))
                    .frame(width: 68, height: 68)

                Image(systemName: "book.pages")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(StatsPalette.readable(accent))
            }
            .accessibilityHidden(true)

            Text("还没有阅读记录")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)

            Text("打开一本书读上几分钟，阅读时长、进度和习惯都会记在这里。")
                .font(.subheadline)
                .foregroundStyle(StatsPalette.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Text("统计只在本机计算")
                .font(.caption)
                .foregroundStyle(StatsPalette.tertiaryText)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 28)
        .padding(.vertical, 44)
        .statsCardSurface(cornerRadius: 22)
        .accessibilityElement(children: .combine)
    }

    // MARK: - 加载

    /// 聚合通常在几十毫秒内完成，这里不做转圈，只留一个骨架——
    /// 转圈会让人以为在等网络，而这份数据就在本机。
    @ViewBuilder
    private func loadingState(layout: StatsLayout) -> some View {
        Group {
            if layout.isWide {
                VStack(alignment: .leading, spacing: layout.rowSpacing) {
                    HStack(alignment: .top, spacing: layout.columnSpacing) {
                        ReadingStatsHero(
                            overview: nil,
                            accent: accent,
                            sparklineHeight: layout.sparklineHeight,
                            numberScale: 1.15
                        )
                        .frame(maxWidth: .infinity)

                        VStack(spacing: layout.rowSpacing) {
                            skeletonCard(title: "继续阅读", lines: 2)
                            skeletonCard(title: "书架进度", lines: 3)
                        }
                        .frame(width: layout.sideColumnWidth)
                    }

                    skeletonCard(title: "阅读趋势", lines: 3)
                }
            } else {
                VStack(alignment: .leading, spacing: 18) {
                    ReadingStatsHero(
                        overview: nil,
                        accent: accent,
                        sparklineHeight: layout.sparklineHeight
                    )

                    skeletonCard(title: "详细统计", lines: 2)
                    skeletonCard(title: "阅读趋势", lines: 3)
                }
            }
        }
        .redacted(reason: .placeholder)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("正在统计阅读数据")
        .accessibilityAddTraits(.updatesFrequently)
    }

    private func skeletonCard(title: String, lines: Int) -> some View {
        StatsCard(title: title) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(0..<lines, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.primary.opacity(0.10))
                        .frame(height: index == 0 ? 16 : 10)
                        .frame(
                            maxWidth: index == 0 ? .infinity : 220,
                            alignment: .leading
                        )
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - 页脚

    private func privacyNote(_ overview: ReadingStatsOverview) -> some View {
        Text(footerNote(overview))
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(StatsPalette.tertiaryText)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 6)
    }

    /// 页脚只交代两件用户会关心的事：数据从什么时候开始、它在哪。
    private func footerNote(_ overview: ReadingStatsOverview) -> String {
        var parts: [String] = []
        if let first = overview.firstSession {
            parts.append("自 \(StatsFormat.monthYear(first)) 开始记录")
        }
        if overview.activeDays > 0 {
            parts.append("\(overview.activeDays) 天有阅读")
        }
        parts.append("只在本机计算")
        return parts.joined(separator: " · ")
    }

    // MARK: - 取数

    /// 只用一个 key 驱动重算：条数 + 最后一条的结束时间覆盖「新增」和「合并」，
    /// 其余计数覆盖书籍、章节与书签的变化。
    private var reloadKey: String {
        let lastEnd = sessions.last?.endedAt.timeIntervalSince1970 ?? 0
        return [
            range.rawValue,
            "\(sessions.count)",
            "\(lastEnd)",
            "\(books.count)",
            "\(progressRecords.count)",
            "\(bookmarks.count)"
        ].joined(separator: "|")
    }

    private func reload() async {
        let input = ReadingStatsInput(
            now: Date(),
            calendar: .current,
            range: range,
            sessions: sessions.map {
                ReadingStatsSession(
                    bookKey: $0.bookKey,
                    start: $0.startedAt,
                    end: $0.endedAt,
                    seconds: $0.durationSeconds
                )
            },
            books: books.map {
                ReadingStatsBook(
                    key: $0.bookExtrSubdir.lastPathComponent,
                    title: $0.bookTitle,
                    author: $0.bookAuthor,
                    coverURL: $0.coverImageURLs.first,
                    progress: $0.readingProgress
                )
            },
            chapterReadDates: progressRecords.compactMap { $0.isRead ? $0.readAt : nil },
            bookmarkDates: bookmarks.map(\.createdAt),
            lastOpenedDates: books.compactMap(\.lastOpenedAt)
        )

        let requestedRange = range

        let result = await Task.detached(priority: .userInitiated) {
            ReadingStatsEngine.build(input)
        }.value

        // 范围在聚合期间被改过：这份结果已经过期，丢掉。
        guard !Task.isCancelled, requestedRange == range else { return }
        snapshot = result
    }
}

// MARK: - 导航标题

/// 只在需要时挂标题。
///
/// 不用 `.navigationTitle("")` 表达「不要标题」：空字符串仍然会占住标题行，
/// 只是看起来没字；iPad 上应当干脆不设标题，把导航栏留给返回按钮。
private struct StatsNavigationTitle: ViewModifier {

    let showsTitle: Bool

    func body(content: Content) -> some View {
        if showsTitle {
            content
                .navigationTitle("阅读数据")
                .toolbarTitleDisplayMode(.inline)
        } else {
            content
        }
    }
}

// MARK: - 布局

/// 统计页的断点。
///
/// 用可用宽度而不是 `horizontalSizeClass`：iPad 分屏、Slide Over、横竖屏
/// 都是 `.regular`，尺寸类分不出「一列放不放得下」。900pt 是两列各自
/// 仍有约 400pt 的下限；再窄，书籍行与热力图就会开始互相挤。
private struct StatsLayout {

    let isWide: Bool
    let maxContentWidth: CGFloat
    let horizontalPadding: CGFloat
    let sideColumnWidth: CGFloat
    let chartHeight: CGFloat
    let sparklineHeight: CGFloat
    let columnSpacing: CGFloat
    let rowSpacing: CGFloat

    init(width: CGFloat, typeSize: DynamicTypeSize) {
        let wide = width >= 900 && !typeSize.isAccessibilitySize

        if wide {
            let contentWidth = min(max(width - 48, 0), 1180)

            isWide = true
            maxContentWidth = 1180
            horizontalPadding = 24
            // 右侧「继续阅读 + 书架进度」的宽度：书封 + 两行文字需要
            // 至少 320；再宽就会把主数字挤成一条。
            sideColumnWidth = min(max(contentWidth * 0.34, 320), 400)
            chartHeight = 230
            sparklineHeight = 56
            columnSpacing = 20
            rowSpacing = 20
        } else {
            isWide = false
            maxContentWidth = 680
            horizontalPadding = 20
            sideColumnWidth = 0
            chartHeight = 170
            sparklineHeight = 44
            columnSpacing = 0
            rowSpacing = 18
        }
    }
}
