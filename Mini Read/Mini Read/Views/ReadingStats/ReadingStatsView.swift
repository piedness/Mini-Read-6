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
//  ## 为什么首屏只有三个数字
//  统计页最容易犯的错是把所有能算的数都摆上来。首屏只放「今日时长 /
//  连续天数 / 近 14 天趋势」，本周与累计退到一行小字里；其余按层展开——
//  用户是来看趋势的，不是来对账的。
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

    @Query(sort: \ReadingSession.endedAt)
    private var sessions: [ReadingSession]

    @Query private var books: [bookItem]
    @Query private var progressRecords: [ReadingProgressRecord]
    @Query private var bookmarks: [Bookmark]

    @State private var range: ReadingStatsRange = .month
    @State private var snapshot: ReadingStatsSnapshot?

    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var accent: Color {
        StatsPalette.accent(hex: settings.appTintColorHex)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ReadingStatsHero(overview: snapshot?.overview, accent: accent)

                if let current = snapshot?.overview.currentBook {
                    CurrentBookCard(book: current, accent: accent)
                }

                if snapshot?.hasData == true {
                    rangePicker

                    if let snapshot {
                        ReadingStatsTrendCard(
                            trend: snapshot.trend,
                            subtitle: snapshot.range.subtitle,
                            accent: accent,
                            reduceMotion: reduceMotion
                        )

                        ReadingStatsRhythmCard(
                            rhythm: snapshot.rhythm,
                            subtitle: "按周几 × 小时",
                            accent: accent
                        )

                        ReadingStatsSessionCard(
                            profile: snapshot.sessionProfile,
                            accent: accent
                        )

                        ReadingStatsBooksCard(
                            books: snapshot.books,
                            subtitle: snapshot.range.subtitle,
                            accent: accent,
                            overview: snapshot.overview,
                            completionRate: snapshot.insights.completionRate
                        )

                        ReadingStatsAuthorsCard(
                            authors: snapshot.authors,
                            subtitle: "按阅读时长",
                            accent: accent
                        )

                        ReadingStatsInsightsCard(
                            insights: snapshot.insights,
                            nightShare: snapshot.rhythm.nightShare,
                            accent: accent
                        )
                    }

                    privacyNote
                } else if snapshot != nil {
                    emptyState
                }
            }
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 48)
        }
        .scrollIndicators(.hidden)
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle("阅读数据")
        .toolbarTitleDisplayMode(.inline)
        .task(id: reloadKey) {
            await reload()
        }
    }

    // MARK: - 范围

    /// 大字号下 4 段的分段控件会截断成「7…」，换成菜单。
    @ViewBuilder
    private var rangePicker: some View {
        if typeSize.isAccessibilitySize {
            Menu {
                Picker("统计范围", selection: $range) {
                    ForEach(ReadingStatsRange.allCases) { range in
                        Text(range.subtitle).tag(range)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "calendar")
                    Text(range.subtitle)
                        .monospacedDigit()
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                }
                .font(.subheadline)
                .foregroundStyle(.primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color(.secondarySystemGroupedBackground))
                )
            }
            .accessibilityLabel("统计范围，当前 \(range.subtitle)")
        } else {
            Picker("统计范围", selection: $range) {
                ForEach(ReadingStatsRange.allCases) { range in
                    Text(range.title).tag(range)
                }
            }
            .pickerStyle(.segmented)
            .tint(accent)
            .accessibilityLabel("统计范围")
        }
    }

    // MARK: - 空状态

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(accent)

            Text("没有阅读记录")
                .font(.headline)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.vertical, 36)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .accessibilityElement(children: .combine)
    }

    private var privacyNote: some View {
        Text(footerNote)
            .font(.caption2)
            .monospacedDigit()
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 8)
    }

    /// 页脚只交代两件用户会关心的事：数据从什么时候开始、它在哪。
    private var footerNote: String {
        guard let overview = snapshot?.overview else {
            return "统计只在本机计算"
        }

        var parts: [String] = []
        if let first = overview.firstSession {
            parts.append("自 \(first.formatted(.dateTime.year().month())) 开始记录")
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
