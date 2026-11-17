//
//  ReadingStatsEngine.swift
//  TheNewVellium
//
//  阅读数据的唯一聚合口径。
//
//  ## 为什么单独成层
//  统计页要回答三个问题：读了什么、读得怎么样、还想不想继续读。
//  这三个问题背后是同一批原始事件（`ReadingSession`），如果每个视图各算一遍，
//  「今日 42 分钟」和「近 7 天日均 30 分钟」迟早对不上。所以口径只写在这里，
//  视图层只取数与渲染。
//
//  ## 三条硬约束
//  1. **按本地日边界切分**：一条 session 可能跨午夜，整条算给开始那天，
//     会把「昨晚 23:50 读到 0:40」全记到今天。日聚合、周聚合、热力图都必须
//     先按边界拆开。
//  2. **一切以本地日历为准**：原始记录只有绝对时间戳，历史记录无法还原当时
//     的时区，这里统一用当前日历换算——这是现有模型的上限，不假装更精确。
//  3. **纯函数**：输入输出都是值类型快照，可在后台线程跑，主线程只负责取数。
//     聚合随数据量线性增长，一年几千条 session 也就几毫秒，但没必要压在主线程。
//

import Foundation

// MARK: - 统计范围

/// 统计页顶部的范围选择。
///
/// 范围只影响「趋势 / 节奏 / 书籍 / 洞察」，不影响「今日 / 连续 / 总时长」——
/// 后者是「此刻的状态」，不应该被一个下拉框改写。
nonisolated enum ReadingStatsRange: String, CaseIterable, Identifiable, Sendable {
    case week
    case month
    case quarter
    case year

    var id: String { rawValue }

    var title: String {
        switch self {
        case .week: return "7 天"
        case .month: return "30 天"
        case .quarter: return "12 周"
        case .year: return "12 月"
        }
    }

    var subtitle: String { "近 \(title)" }

    /// 柱状图每个柱子的时间粒度。
    var bucketComponent: Calendar.Component {
        switch self {
        case .week, .month: return .day
        case .quarter: return .weekOfYear
        case .year: return .month
        }
    }

    /// 「日均 / 周均 / 月均」里的那个字。
    var bucketNoun: String {
        switch self {
        case .week, .month: return "日"
        case .quarter: return "周"
        case .year: return "月"
        }
    }

    /// 当前窗口。`end` 可能落在未来（本周 / 本月尚未过完），
    /// 这样最后一根柱子是「进行中」的一格，而不是被截断成半格。
    func window(now: Date, calendar: Calendar) -> ReadingStatsWindow {
        let interval = currentInterval(now: now, calendar: calendar)
        let previous = DateInterval(
            start: interval.start.addingTimeInterval(-interval.duration),
            duration: interval.duration
        )
        return ReadingStatsWindow(
            interval: interval,
            previous: previous,
            buckets: makeBuckets(in: interval, calendar: calendar)
        )
    }

    private func currentInterval(now: Date, calendar: Calendar) -> DateInterval {
        switch self {
        case .week, .month:
            let endOfToday = calendar.date(
                byAdding: .day,
                value: 1,
                to: calendar.startOfDay(for: now)
            ) ?? now
            let days = self == .week ? 7 : 30
            let start = calendar.date(byAdding: .day, value: -days, to: endOfToday) ?? endOfToday
            return DateInterval(start: start, end: endOfToday)

        case .quarter:
            let weekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start
                ?? calendar.startOfDay(for: now)
            // 含本周在内共 12 格：起点要往前 11 周，不是 12 周。
            let start = calendar.date(byAdding: .weekOfYear, value: -11, to: weekStart) ?? weekStart
            let end = calendar.date(byAdding: .weekOfYear, value: 1, to: weekStart) ?? now
            return DateInterval(start: start, end: end)

        case .year:
            let monthStart = calendar.dateInterval(of: .month, for: now)?.start
                ?? calendar.startOfDay(for: now)
            // 含本月在内共 12 格。
            let start = calendar.date(byAdding: .month, value: -11, to: monthStart) ?? monthStart
            let end = calendar.date(byAdding: .month, value: 1, to: monthStart) ?? now
            return DateInterval(start: start, end: end)
        }
    }

    private func makeBuckets(in interval: DateInterval, calendar: Calendar) -> [ReadingStatsBucket] {
        var result: [ReadingStatsBucket] = []
        var cursor = interval.start
        var index = 0

        while cursor < interval.end {
            guard let next = calendar.date(byAdding: bucketComponent, value: 1, to: cursor),
                  next > cursor
            else { break }

            result.append(
                ReadingStatsBucket(
                    id: index,
                    start: cursor,
                    end: min(next, interval.end),
                    label: axisLabel(for: cursor, calendar: calendar),
                    accessibleLabel: accessibleLabel(for: cursor, calendar: calendar)
                )
            )

            cursor = next
            index += 1
        }

        return result
    }

    /// 轴标签要短：30 根柱子只放得下 4 个左右。
    private func axisLabel(for date: Date, calendar: Calendar) -> String {
        let month = calendar.component(.month, from: date)
        switch bucketComponent {
        case .day, .weekOfYear:
            return "\(month)/\(calendar.component(.day, from: date))"
        default:
            return "\(month)月"
        }
    }

    private func accessibleLabel(for date: Date, calendar: Calendar) -> String {
        let year = calendar.component(.year, from: date)
        let month = calendar.component(.month, from: date)
        let day = calendar.component(.day, from: date)
        switch bucketComponent {
        case .day:
            return "\(month) 月 \(day) 日"
        case .weekOfYear:
            return "\(year) 年 \(month) 月 \(day) 日当周"
        default:
            return "\(year) 年 \(month) 月"
        }
    }
}

// MARK: - 输入快照

/// 一条阅读记录的值类型副本。视图层在主线程把 SwiftData 模型转成它，
/// 之后的所有计算都不再碰模型。
nonisolated struct ReadingStatsSession: Sendable {
    let bookKey: String
    let start: Date
    let end: Date
    let seconds: Int
}

nonisolated struct ReadingStatsBook: Sendable {
    let key: String
    let title: String
    let author: String
    let coverURL: URL?
    /// 0…1；`nil` = 全书章节数未知（导入后还没打开过）。
    let progress: Double?
}

nonisolated struct ReadingStatsInput: Sendable {
    let now: Date
    let calendar: Calendar
    let range: ReadingStatsRange
    let sessions: [ReadingStatsSession]
    let books: [ReadingStatsBook]
    /// 已读章节的 `readAt`（用于连续天数、章节节奏）。
    let chapterReadDates: [Date]
    /// 书签创建时间。
    let bookmarkDates: [Date]
    /// 书籍 `lastOpenedAt`：有些「读过」的日子没留下 session（秒退、崩溃）。
    let lastOpenedDates: [Date]
}

// MARK: - 输出快照

nonisolated struct ReadingStatsWindow: Sendable {
    let interval: DateInterval
    let previous: DateInterval
    let buckets: [ReadingStatsBucket]
}

nonisolated struct ReadingStatsBucket: Sendable, Identifiable {
    let id: Int
    let start: Date
    let end: Date
    /// 轴上的短标签。
    let label: String
    /// VoiceOver 读的完整标签。
    let accessibleLabel: String
    var seconds: Int = 0

    var minutes: Int { seconds / 60 }
}

nonisolated struct ReadingStatsDay: Sendable, Identifiable {
    var id: Date { date }
    let date: Date
    let seconds: Int
    let isToday: Bool
}

nonisolated struct ReadingStatsCurrentBook: Sendable {
    let key: String
    let title: String
    let author: String
    let coverURL: URL?
    let progress: Double?
    let remainingSeconds: Int?
    let lastRead: Date
    let isFinished: Bool
}

nonisolated struct ReadingStatsOverview: Sendable {
    let todaySeconds: Int
    let weekSeconds: Int
    let totalSeconds: Int
    let currentStreak: Int
    let longestStreak: Int
    let activeDays: Int
    let firstSession: Date?
    let recentDays: [ReadingStatsDay]
    let currentBook: ReadingStatsCurrentBook?
    let finishedBooks: Int
    let startedBooks: Int
    let libraryCount: Int
}

nonisolated struct ReadingStatsTrend: Sendable {
    let points: [ReadingStatsBucket]
    let totalSeconds: Int
    let averageSeconds: Int
    let best: ReadingStatsBucket?
    /// `nil` = 上期没有任何数据，涨跌无从谈起（不是 0%，更不是 +∞）。
    let changeRatio: Double?
    let bucketComponent: Calendar.Component
    let bucketNoun: String
}

nonisolated struct ReadingStatsRhythmSlot: Sendable, Identifiable {
    var id: String { "\(weekday)-\(hour)" }
    /// 0 = 周一 … 6 = 周日。
    let weekday: Int
    let hour: Int
    let seconds: Int
}

nonisolated struct ReadingStatsReadingProfile: Sendable {
    let label: String
    /// 占比最大的那个时段的份额。
    let share: Double
}

nonisolated struct ReadingStatsRhythm: Sendable {
    /// `[7][24]`，周一在前。
    let grid: [[Int]]
    let peak: ReadingStatsRhythmSlot?
    let peakSlots: [ReadingStatsRhythmSlot]
    /// 23:00–05:00 占比。
    let nightShare: Double
    /// 「晨读型 / 夜读型 / …」；数据太少时为 nil，不硬贴标签。
    let profile: ReadingStatsReadingProfile?
}

nonisolated struct ReadingStatsSessionBucket: Sendable, Identifiable {
    let id: Int
    let label: String
    let count: Int
}

nonisolated struct ReadingStatsSessionProfile: Sendable {
    let buckets: [ReadingStatsSessionBucket]
    let count: Int
    let averageSeconds: Int
    let longestSeconds: Int
}

nonisolated struct ReadingStatsBookSlice: Sendable, Identifiable {
    let id: String
    let title: String
    let author: String
    let coverURL: URL?
    /// 本期阅读时长。
    let seconds: Int
    let sessionCount: Int
    let lastRead: Date
    let progress: Double?
    /// 按「本书全部阅读时长 ÷ 进度」推算的剩余时间，`nil` = 样本不足。
    let remainingSeconds: Int?
    let isFinished: Bool
}

nonisolated struct ReadingStatsAuthorSlice: Sendable, Identifiable {
    var id: String { name }
    let name: String
    let seconds: Int
    let bookCount: Int
}

nonisolated struct ReadingStatsInsights: Sendable {
    let completionRate: Double?
    let bookmarksInRange: Int
    let bookmarksTotal: Int
    /// 每小时书签数——比「书签总数」更能反映精读程度。
    let bookmarkDensity: Double?
    let chaptersInRange: Int
    /// 每小时读完的章节数。
    let chapterPace: Double?
    let activeDayShare: Double
    let activeDaysInRange: Int
    /// 窗口内已经过去的天数（今天算一天）。
    let elapsedDays: Int
}

nonisolated struct ReadingStatsSnapshot: Sendable {
    let range: ReadingStatsRange
    let generatedAt: Date
    let overview: ReadingStatsOverview
    let trend: ReadingStatsTrend
    let rhythm: ReadingStatsRhythm
    let sessionProfile: ReadingStatsSessionProfile
    let books: [ReadingStatsBookSlice]
    let authors: [ReadingStatsAuthorSlice]
    let insights: ReadingStatsInsights
    let hasData: Bool
}

// MARK: - 引擎

nonisolated enum ReadingStatsEngine {

    private struct BookAggregate {
        var seconds: Int = 0
        var sessionCount: Int = 0
        var lastEnd: Date?
    }

    /// 会话时长分档（分钟）。档位是闭区间，最后一档无上限。
    private static let sessionBucketBounds: [(label: String, upper: Int?)] = [
        ("< 5 分", 5),
        ("5–15 分", 15),
        ("15–30 分", 30),
        ("30–60 分", 60),
        ("1 小时以上", nil)
    ]

    static func build(_ input: ReadingStatsInput) -> ReadingStatsSnapshot {
        let calendar = input.calendar
        let now = input.now
        let window = input.range.window(now: now, calendar: calendar)
        let interval = window.interval

        var daySeconds: [Date: Int] = [:]
        var hourGrid = Array(repeating: Array(repeating: 0, count: 24), count: 7)
        var perBook: [String: BookAggregate] = [:]
        var allTimeByBook: [String: Int] = [:]
        var rangeSeconds = 0
        var previousSeconds = 0
        var sessionDurations: [Int] = []
        var firstSessionStart: Date?
        var lastEndByBook: [String: Date] = [:]

        for session in input.sessions where session.seconds > 0 {
            if firstSessionStart == nil || session.start < firstSessionStart! {
                firstSessionStart = session.start
            }
            if session.end > (lastEndByBook[session.bookKey] ?? .distantPast) {
                lastEndByBook[session.bookKey] = session.end
            }

            allTimeByBook[session.bookKey, default: 0] += session.seconds
            distributeByDay(session, calendar: calendar, into: &daySeconds)

            let overlap = overlapSeconds(session, interval)
            if overlap > 0 {
                rangeSeconds += overlap

                var aggregate = perBook[session.bookKey] ?? BookAggregate()
                aggregate.seconds += overlap
                aggregate.sessionCount += 1
                if session.end > (aggregate.lastEnd ?? .distantPast) {
                    aggregate.lastEnd = session.end
                }
                perBook[session.bookKey] = aggregate

                addToHourGrid(session, interval: interval, calendar: calendar, grid: &hourGrid)
            }

            if session.start >= interval.start, session.start < interval.end {
                sessionDurations.append(session.seconds)
            }

            previousSeconds += overlapSeconds(session, window.previous)
        }

        // ── 趋势 ──────────────────────────────────────────────
        var buckets = window.buckets
        for (day, seconds) in daySeconds where day >= interval.start && day < interval.end {
            if let index = bucketIndex(containing: day, in: buckets) {
                buckets[index].seconds += seconds
            }
        }

        // ── 连续天数 ──────────────────────────────────────────
        var activeDays = Set(daySeconds.keys)
        for date in input.chapterReadDates {
            activeDays.insert(calendar.startOfDay(for: date))
        }
        for date in input.lastOpenedDates {
            activeDays.insert(calendar.startOfDay(for: date))
        }

        let todayStart = calendar.startOfDay(for: now)
        let todaySeconds = daySeconds[todayStart] ?? 0

        var weekSeconds = 0
        if let week = calendar.dateInterval(of: .weekOfYear, for: now) {
            for (day, seconds) in daySeconds where day >= week.start && day < week.end {
                weekSeconds += seconds
            }
        } else {
            weekSeconds = todaySeconds
        }

        let totalSeconds = daySeconds.values.reduce(0, +)
        let streak = currentStreak(activeDays: activeDays, today: todayStart, calendar: calendar)
        let longestStreak = longestStreak(activeDays: activeDays, calendar: calendar)

        var recentDays: [ReadingStatsDay] = []
        recentDays.reserveCapacity(14)
        for offset in stride(from: 13, through: 0, by: -1) {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: todayStart) else { continue }
            recentDays.append(
                ReadingStatsDay(date: day, seconds: daySeconds[day] ?? 0, isToday: offset == 0)
            )
        }

        // ── 书籍 ──────────────────────────────────────────────
        var booksByKey: [String: ReadingStatsBook] = [:]
        for book in input.books {
            if booksByKey[book.key] == nil { booksByKey[book.key] = book }
        }

        let finishedBooks = input.books.filter { ($0.progress ?? 0) >= 0.995 }.count
        let startedBooks = input.books.filter { ($0.progress ?? 0) > 0 }.count

        var slices: [ReadingStatsBookSlice] = []
        slices.reserveCapacity(perBook.count)
        for (key, aggregate) in perBook {
            guard let book = booksByKey[key] else { continue }
            let progress = book.progress
            let allTime = allTimeByBook[key] ?? aggregate.seconds

            slices.append(
                ReadingStatsBookSlice(
                    id: key,
                    title: book.title,
                    author: book.author,
                    coverURL: book.coverURL,
                    seconds: aggregate.seconds,
                    sessionCount: aggregate.sessionCount,
                    lastRead: aggregate.lastEnd ?? now,
                    progress: progress,
                    remainingSeconds: remainingSeconds(progress: progress, totalSeconds: allTime),
                    isFinished: (progress ?? 0) >= 0.995
                )
            )
        }
        slices.sort {
            $0.seconds == $1.seconds ? $0.title < $1.title : $0.seconds > $1.seconds
        }

        // ── 作者偏好 ──────────────────────────────────────────
        var authorSeconds: [String: Int] = [:]
        var authorBookKeys: [String: Set<String>] = [:]
        for slice in slices {
            let name = slice.author.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = name.isEmpty ? "未知作者" : name
            authorSeconds[key, default: 0] += slice.seconds
            authorBookKeys[key, default: []].insert(slice.id)
        }
        var authors: [ReadingStatsAuthorSlice] = []
        authors.reserveCapacity(authorSeconds.count)
        for (name, seconds) in authorSeconds {
            authors.append(
                ReadingStatsAuthorSlice(
                    name: name,
                    seconds: seconds,
                    bookCount: authorBookKeys[name]?.count ?? 0
                )
            )
        }
        authors.sort {
            $0.seconds == $1.seconds ? $0.name < $1.name : $0.seconds > $1.seconds
        }

        // ── 当前在读 ──────────────────────────────────────────
        // 「继续阅读」应该指向一本**还没读完**的书。最近一次阅读如果发生在
        // 一本刚读完的书上，直接拿它当当前在读，用户看到的会是「继续阅读 · 100%」。
        let unfinished = lastEndByBook
            .filter { key, _ in (booksByKey[key]?.progress ?? 0) < 0.995 }
            .max { $0.value < $1.value }
        let fallback = lastEndByBook.max { $0.value < $1.value }

        var currentBook: ReadingStatsCurrentBook?
        if let (key, end) = unfinished ?? fallback, let book = booksByKey[key] {
            currentBook = ReadingStatsCurrentBook(
                key: key,
                title: book.title,
                author: book.author,
                coverURL: book.coverURL,
                progress: book.progress,
                remainingSeconds: remainingSeconds(
                    progress: book.progress,
                    totalSeconds: allTimeByBook[key] ?? 0
                ),
                lastRead: end,
                isFinished: (book.progress ?? 0) >= 0.995
            )
        }

        // ── 节奏 ──────────────────────────────────────────────
        let gridTotal = hourGrid.reduce(0) { $0 + $1.reduce(0, +) }
        let peak = peakSlot(in: hourGrid)
        let nightSeconds = sumHours([23, 0, 1, 2, 3, 4], in: hourGrid)
        let morningSeconds = sumHours([5, 6, 7, 8], in: hourGrid)
        let eveningSeconds = sumHours([18, 19, 20, 21, 22], in: hourGrid)
        let afternoonSeconds = sumHours([12, 13, 14, 15, 16, 17], in: hourGrid)

        let rhythm = ReadingStatsRhythm(
            grid: hourGrid,
            peak: peak,
            peakSlots: topSlots(in: hourGrid, limit: 3),
            nightShare: share(nightSeconds, of: gridTotal),
            profile: readingProfile(
                gridTotal: gridTotal,
                night: nightSeconds,
                morning: morningSeconds,
                afternoon: afternoonSeconds,
                evening: eveningSeconds
            )
        )

        // ── 单次时长 ──────────────────────────────────────────
        var sessionBucketCounts = Array(repeating: 0, count: sessionBucketBounds.count)
        for duration in sessionDurations {
            sessionBucketCounts[sessionBucketIndex(duration)] += 1
        }
        let sessionProfile = ReadingStatsSessionProfile(
            buckets: sessionBucketBounds.enumerated().map { index, bound in
                ReadingStatsSessionBucket(id: index, label: bound.label, count: sessionBucketCounts[index])
            },
            count: sessionDurations.count,
            averageSeconds: sessionDurations.isEmpty
                ? 0
                : sessionDurations.reduce(0, +) / sessionDurations.count,
            longestSeconds: sessionDurations.max() ?? 0
        )

        // ── 洞察 ──────────────────────────────────────────────
        let bookmarksInRange = input.bookmarkDates.filter {
            $0 >= interval.start && $0 < interval.end
        }.count
        let chaptersInRange = input.chapterReadDates.filter {
            $0 >= interval.start && $0 < interval.end
        }.count
        let hours = Double(rangeSeconds) / 3600

        var activeInRange = 0
        for day in activeDays where day >= interval.start && day < interval.end {
            activeInRange += 1
        }
        let elapsedDays = max(
            1,
            (calendar.dateComponents([.day], from: interval.start, to: min(now, interval.end)).day ?? 0) + 1
        )

        let insights = ReadingStatsInsights(
            completionRate: startedBooks > 0 ? Double(finishedBooks) / Double(startedBooks) : nil,
            bookmarksInRange: bookmarksInRange,
            bookmarksTotal: input.bookmarkDates.count,
            bookmarkDensity: hours >= 1 ? Double(bookmarksInRange) / hours : nil,
            chaptersInRange: chaptersInRange,
            chapterPace: hours >= 1 ? Double(chaptersInRange) / hours : nil,
            activeDayShare: min(1, Double(activeInRange) / Double(elapsedDays)),
            activeDaysInRange: activeInRange,
            elapsedDays: elapsedDays
        )

        let overview = ReadingStatsOverview(
            todaySeconds: todaySeconds,
            weekSeconds: weekSeconds,
            totalSeconds: totalSeconds,
            currentStreak: streak,
            longestStreak: longestStreak,
            activeDays: activeDays.count,
            firstSession: firstSessionStart,
            recentDays: recentDays,
            currentBook: currentBook,
            finishedBooks: finishedBooks,
            startedBooks: startedBooks,
            libraryCount: input.books.count
        )

        let trend = ReadingStatsTrend(
            points: buckets,
            totalSeconds: rangeSeconds,
            averageSeconds: buckets.isEmpty ? 0 : rangeSeconds / buckets.count,
            best: buckets.max { $0.seconds < $1.seconds },
            changeRatio: previousSeconds > 0
                ? Double(rangeSeconds - previousSeconds) / Double(previousSeconds)
                : nil,
            bucketComponent: input.range.bucketComponent,
            bucketNoun: input.range.bucketNoun
        )

        return ReadingStatsSnapshot(
            range: input.range,
            generatedAt: now,
            overview: overview,
            trend: trend,
            rhythm: rhythm,
            sessionProfile: sessionProfile,
            books: slices,
            authors: Array(authors.prefix(5)),
            insights: insights,
            hasData: totalSeconds > 0
        )
    }

    // MARK: - 推算

    /// 剩余时间 = 已用时间 × (1 − 进度) ÷ 进度。
    ///
    /// 进度太小时这个外推会失真（读了 2 分钟、进度 1% 会推出 3 小时），
    /// 所以样本不足时宁可不显示——「还剩 320 页」那种假精确更糟。
    private static func remainingSeconds(progress: Double?, totalSeconds: Int) -> Int? {
        guard let progress,
              progress > 0.15,
              progress < 0.995,
              totalSeconds > 300
        else { return nil }
        return Int((Double(totalSeconds) * (1 - progress) / progress).rounded())
    }

    // MARK: - 时间切分

    /// 把一条 session 按本地日边界拆开。
    ///
    /// 用「已分配秒数」而不是「时间跨度」推进，保证总和精确等于 `seconds`；
    /// 跨天时按边界自然切分，剩余部分落到最后一天。
    private static func distributeByDay(
        _ session: ReadingStatsSession,
        calendar: Calendar,
        into daySeconds: inout [Date: Int]
    ) {
        var remaining = session.seconds
        var cursor = session.start
        var guardCount = 0

        while remaining > 0 && guardCount < 400 {
            guardCount += 1

            let dayStart = calendar.startOfDay(for: cursor)
            guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else {
                daySeconds[dayStart, default: 0] += remaining
                return
            }

            let sliceEnd = min(session.end, dayEnd)
            let span = Int(sliceEnd.timeIntervalSince(cursor))
            // 跨度不足 1 秒（session 恰好在午夜结束）时把余量一次记完，避免死循环。
            let take = span > 0 ? min(remaining, span) : remaining

            daySeconds[dayStart, default: 0] += take
            remaining -= take

            if sliceEnd <= cursor { break }
            cursor = sliceEnd
        }
    }

    /// 按小时累加到热力图。只统计落在当前窗口内的部分，
    /// 窗口外的比例按时间跨度折算，避免把窗口前读的时间算进来。
    private static func addToHourGrid(
        _ session: ReadingStatsSession,
        interval: DateInterval,
        calendar: Calendar,
        grid: inout [[Int]]
    ) {
        let totalSpan = session.end.timeIntervalSince(session.start)
        var cursor = max(session.start, interval.start)
        let limit = min(session.end, interval.end)
        guard limit > cursor, totalSpan > 0 else { return }

        var budget = Int(Double(session.seconds) * limit.timeIntervalSince(cursor) / totalSpan)
        budget = min(budget, session.seconds)
        var guardCount = 0

        while budget > 0 && cursor < limit && guardCount < 240 {
            guardCount += 1

            let weekdayIndex = mondayFirstIndex(for: cursor, calendar: calendar)
            let hour = calendar.component(.hour, from: cursor)
            let hourStart = calendar.dateInterval(of: .hour, for: cursor)?.start ?? cursor
            guard let hourEnd = calendar.date(byAdding: .hour, value: 1, to: hourStart) else { break }

            let sliceEnd = min(hourEnd, limit)
            let span = Int(sliceEnd.timeIntervalSince(cursor))
            let take = span > 0 ? min(budget, span) : budget

            grid[weekdayIndex][hour] += take
            budget -= take

            if sliceEnd <= cursor { break }
            cursor = sliceEnd
        }
    }

    private static func overlapSeconds(_ session: ReadingStatsSession, _ interval: DateInterval) -> Int {
        let start = max(session.start, interval.start)
        let end = min(session.end, interval.end)
        guard end > start else { return 0 }
        return min(Int(end.timeIntervalSince(start).rounded()), session.seconds)
    }

    private static func mondayFirstIndex(for date: Date, calendar: Calendar) -> Int {
        // Gregorian：1 = 周日 … 7 = 周六。减 2 再取模即得「周一 = 0」。
        let weekday = calendar.component(.weekday, from: date)
        return ((weekday + 5) % 7 + 7) % 7
    }

    private static func bucketIndex(
        containing date: Date,
        in buckets: [ReadingStatsBucket]
    ) -> Int? {
        guard !buckets.isEmpty else { return nil }
        var low = 0
        var high = buckets.count - 1
        var result: Int?

        while low <= high {
            let mid = (low + high) / 2
            if buckets[mid].start <= date {
                result = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }

        guard let index = result, date < buckets[index].end else { return nil }
        return index
    }

    // MARK: - 连续天数

    /// 今天还没读时，连续天数从昨天往前数——否则每天 0 点一过，
    /// 昨天攒的 20 天会瞬间清零，用户看到的是「惩罚」而不是「记录」。
    private static func currentStreak(
        activeDays: Set<Date>,
        today: Date,
        calendar: Calendar
    ) -> Int {
        var cursor = today
        if !activeDays.contains(cursor) {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: cursor) else { return 0 }
            cursor = yesterday
        }

        var streak = 0
        var guardCount = 0
        while activeDays.contains(cursor) && guardCount < 3_000 {
            guardCount += 1
            streak += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return streak
    }

    private static func longestStreak(activeDays: Set<Date>, calendar: Calendar) -> Int {
        guard !activeDays.isEmpty else { return 0 }
        let sorted = activeDays.sorted()

        var longest = 1
        var current = 1
        for index in 1..<sorted.count {
            let gap = calendar.dateComponents(
                [.day],
                from: sorted[index - 1],
                to: sorted[index]
            ).day ?? 0

            if gap == 1 {
                current += 1
                longest = max(longest, current)
            } else if gap > 1 {
                current = 1
            }
        }
        return longest
    }

    // MARK: - 节奏

    private static func sumHours(_ hours: [Int], in grid: [[Int]]) -> Int {
        var total = 0
        for row in grid {
            for hour in hours where hour >= 0 && hour < 24 {
                total += row[hour]
            }
        }
        return total
    }

    private static func share(_ part: Int, of total: Int) -> Double {
        total > 0 ? Double(part) / Double(total) : 0
    }

    private static func peakSlot(in grid: [[Int]]) -> ReadingStatsRhythmSlot? {
        var best: ReadingStatsRhythmSlot?
        for weekday in 0..<grid.count {
            for hour in 0..<grid[weekday].count {
                let seconds = grid[weekday][hour]
                guard seconds > 0 else { continue }
                if seconds > (best?.seconds ?? 0) {
                    best = ReadingStatsRhythmSlot(weekday: weekday, hour: hour, seconds: seconds)
                }
            }
        }
        return best
    }

    private static func topSlots(in grid: [[Int]], limit: Int) -> [ReadingStatsRhythmSlot] {
        var slots: [ReadingStatsRhythmSlot] = []
        for weekday in 0..<grid.count {
            for hour in 0..<grid[weekday].count where grid[weekday][hour] > 0 {
                slots.append(
                    ReadingStatsRhythmSlot(weekday: weekday, hour: hour, seconds: grid[weekday][hour])
                )
            }
        }
        slots.sort { $0.seconds > $1.seconds }
        return Array(slots.prefix(limit))
    }

    /// 只在样本够（30 分钟以上）时贴标签：读了 5 分钟就说人家是「夜读型」，
    /// 那是编故事，不是洞察。
    private static func readingProfile(
        gridTotal: Int,
        night: Int,
        morning: Int,
        afternoon: Int,
        evening: Int
    ) -> ReadingStatsReadingProfile? {
        guard gridTotal >= 30 * 60 else { return nil }
        let candidates: [(String, Int)] = [
            ("夜读型", night),
            ("晨读型", morning),
            ("午后型", afternoon),
            ("晚间型", evening)
        ]
        guard let top = candidates.max(by: { $0.1 < $1.1 }) else { return nil }
        let share = Double(top.1) / Double(gridTotal)
        return ReadingStatsReadingProfile(
            label: share >= 0.35 ? top.0 : "均衡型",
            share: share
        )
    }

    private static func sessionBucketIndex(_ seconds: Int) -> Int {
        let minutes = seconds / 60
        for (index, bound) in sessionBucketBounds.enumerated() {
            guard let upper = bound.upper else { return index }
            if minutes < upper { return index }
        }
        return sessionBucketBounds.count - 1
    }
}
