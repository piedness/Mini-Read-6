//
//  BriefCard.swift
//  vellium1218
//
//  Redesigned — refined dark glass, serif-first, layered animations
//

import SwiftUI
import SwiftData

// MARK: - Main Card

struct BriefCardView: View {
    @Query private var books: [bookItem]
    @Query private var readingSessions: [ReadingSession]
    @State private var selectedPeriod: BriefPeriod = .week
    @State private var appeared = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerSection
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 14)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 6)
                .animation(.easeOut(duration: 0.4).delay(0.05), value: appeared)

            statsRow
                .padding(.horizontal, 14)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 8)
                .animation(.easeOut(duration: 0.4).delay(0.12), value: appeared)

            elegantDivider
                .padding(.top, 18)
                .padding(.bottom, 16)
                .opacity(appeared ? 1 : 0)
                .animation(.easeOut(duration: 0.5).delay(0.2), value: appeared)

            librarySection
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 6)
                .animation(.easeOut(duration: 0.4).delay(0.25), value: appeared)
        }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(cardBorder)
        .shadow(color: .black.opacity(0.18), radius: 2, x: 0, y: 1)
        .shadow(color: .black.opacity(0.12), radius: 16, x: 0, y: 8)
        .shadow(color: .black.opacity(0.06), radius: 32, x: 0, y: 20)
        .padding(.horizontal, 16)
        .onAppear { appeared = true }
    }


    private var cardBorder: some View {
        RoundedRectangle(cornerRadius: 24, style: .continuous)
            .strokeBorder(
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.18),
                        Color.white.opacity(0.06),
                        Color.white.opacity(0.03)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 0.75
            )
    }

    // MARK: Header

    private var headerSection: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Brief")
                    .font(.system(size: 26, weight: .light, design: .serif))
                    .foregroundStyle(.primary)
            }

            Spacer()
            CustomPeriodPicker(selection: $selectedPeriod)
        }
    }


    // MARK: Stats Row

    private var statsRow: some View {
        let stats = currentStats
        return HStack(spacing: 8) {
            // Reading Time — primary stat, slightly wider
            StatBlockView(
                label: "READING",
                value: formattedMinutes(stats.totalMinutes),
                unit: "minutes",
                icon: "book.pages",
                isPrimary: true
            )

            // Sessions
            StatBlockView(
                label: "SESSIONS",
                value: "\(stats.totalSessions)",
                unit: "sessions",
                icon: "rectangle.stack",
                isPrimary: false
            )

            // Completion ring takes fixed width
            CompletionRingView(rate: stats.completionRate)
                .frame(width: 80)
        }
    }

    private func formattedMinutes(_ minutes: Int) -> String {
        if minutes >= 60 {
            let h = minutes / 60
            let m = minutes % 60
            return m > 0 ? "\(h)h \(m)m" : "\(h)h"
        }
        return "\(minutes)"
    }

    // MARK: Divider

    private var elegantDivider: some View {
        HStack(spacing: 8) {
            // Left fade-in line
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [.clear, Color.white.opacity(0.1)],
                        startPoint: .leading, endPoint: .trailing
                    )
                )
                .frame(height: 0.5)
                .frame(width: 24)

            // Center segment — stronger
            Rectangle()
                .fill(Color.white.opacity(0.1))
                .frame(height: 0.5)

            // Right fade-out line
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [Color.white.opacity(0.1), .clear],
                        startPoint: .leading, endPoint: .trailing
                    )
                )
                .frame(height: 0.5)
                .frame(width: 24)
        }
        .padding(.horizontal, 20)
    }

    // MARK: Library

    private var librarySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            libraryHeader

            if topPublishers.isEmpty {
                emptyLibraryView
            } else {
                libraryGrid
            }
        }
    }

    private var libraryHeader: some View {
        HStack(alignment: .center) {
            HStack(spacing: 5) {
                Image(systemName: "books.vertical.fill")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .opacity(0.4)
                Text("LIBRARY")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(1.0)
                    .foregroundStyle(.secondary)
                    .opacity(0.4)
            }
            Spacer()
            if !topPublishers.isEmpty {
                let total = books.count
                HStack(spacing: 3) {
                    Text("\(total)")
                        .font(.system(size: 10, weight: .semibold, design: .serif))
                        .foregroundStyle(.secondary)
                        .opacity(0.5)
                    Text("books")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .opacity(0.35)
                }
            }
        }
    }

    private var libraryGrid: some View {
        let display = Array(topPublishers.prefix(4))
        return HStack(spacing: 6) {
            ForEach(Array(display.enumerated()), id: \.element.name) { index, cat in
                LibraryItemView(
                    name: cat.name,
                    count: cat.count,
                    icon: iconForCategory(cat.name),
                    delay: Double(index) * 0.06 + 0.3
                )
            }
        }
    }

    private func iconForCategory(_ name: String) -> String {
        let n = name.lowercased()
        if n.contains("fiction")    { return "sparkles" }
        if n.contains("science")    { return "atom" }
        if n.contains("history")    { return "clock.arrow.circlepath" }
        if n.contains("tech")       { return "cpu" }
        if n.contains("art")        { return "paintbrush" }
        if n.contains("bio")        { return "person.circle" }
        if n.contains("self")       { return "brain.head.profile" }
        if n.contains("travel")     { return "globe" }
        if n.contains("cook")       { return "fork.knife" }
        return "bookmark"
    }

    private var emptyLibraryView: some View {
        HStack {
            Spacer()
            VStack(spacing: 10) {
                Image(systemName: "books.vertical")
                    .font(.system(size: 22, weight: .ultraLight))
                    .foregroundStyle(.secondary)
                    .opacity(0.3)
                Text("No books yet")
                    .font(.system(size: 11, design: .serif))
                    .foregroundStyle(.secondary)
                    .opacity(0.3)
            }
            .padding(.vertical, 20)
            Spacer()
        }
    }

    private var currentStats: BriefStatSnapshot {
        let periodRange = selectedPeriod.dateRange()
        let sessionsInRange = readingSessions.filter { session in
            session.endedAt >= periodRange.lowerBound && session.startedAt <= periodRange.upperBound
        }
        let totalSeconds = sessionsInRange.reduce(0) { partial, session in
            let overlapStart = max(session.startedAt, periodRange.lowerBound)
            let overlapEnd = min(session.endedAt, periodRange.upperBound)
            return partial + max(0, Int(overlapEnd.timeIntervalSince(overlapStart)))
        }
        let totalMinutes = totalSeconds / 60

        // 分母未知的（导入后还没打开统计过目录的）不计入，免得把均值拉偏。
        // 顺带修正口径：progressRecords 只存已读记录，旧写法恒等于 100%。
        let completionRates = books.compactMap(\.readingProgress)
        let completionRate = completionRates.isEmpty
            ? 0
            : completionRates.reduce(0, +) / Double(completionRates.count)

        return BriefStatSnapshot(
            totalMinutes: totalMinutes,
            totalSessions: sessionsInRange.count,
            completionRate: completionRate
        )
    }

    private var topPublishers: [LibraryGroup] {
        let grouped = Dictionary(grouping: books) { book in
            let publisher = book.bookPublisher.trimmingCharacters(in: .whitespacesAndNewlines)
            return publisher.isEmpty ? "Unknown" : publisher
        }
        return grouped
            .map { LibraryGroup(name: $0.key, count: $0.value.count) }
            .sorted { lhs, rhs in
                if lhs.count == rhs.count { return lhs.name < rhs.name }
                return lhs.count > rhs.count
            }
    }
}

private struct LibraryGroup {
    let name: String
    let count: Int
}

private struct BriefStatSnapshot {
    let totalMinutes: Int
    let totalSessions: Int
    let completionRate: Double
}

// MARK: - Stat Block

struct StatBlockView: View {
    let label: String
    let value: String
    let unit: String
    let icon: String
    let isPrimary: Bool

    @State private var appeared = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Label row
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 7.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .opacity(0.4)
                Text(label)
                    .font(.system(size: 7.5, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(.secondary)
                    .opacity(0.4)
            }
            .padding(.bottom, 10)

            // Value
            Text(appeared ? value : "–")
                .font(.system(
                    size: isPrimary ? 28 : 24,
                    weight: .light,
                    design: .serif
                ))
                .foregroundStyle(.primary)
                .minimumScaleFactor(0.65)
                .lineLimit(1)
                .contentTransition(.numericText())
                .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.15), value: appeared)

            // Unit
            Text(unit)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .opacity(0.4)
                .padding(.top, 3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 14)
        .background(statBackground)
        .onAppear { appeared = true }
    }

    private var statBackground: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color.white.opacity(isPrimary ? 0.055 : 0.03))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(isPrimary ? 0.18 : 0.1),
                                Color.white.opacity(0.03)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.6
                    )
            )
    }
}

// MARK: - Completion Ring

struct CompletionRingView: View {
    let rate: Double
    @State private var animated = false

    private let trackLineWidth: CGFloat = 5.0
    private let ringSize: CGFloat = 52

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                // Outer faint track
                Circle()
                    .stroke(Color.white.opacity(0.07), lineWidth: trackLineWidth)

                // Tick marks (12 marks around the ring)
                ForEach(0..<12, id: \.self) { i in
                    let angle = Double(i) / 12.0 * 360.0 - 90.0
                    let isMajor = i % 3 == 0
                    Rectangle()
                        .fill(Color.white.opacity(isMajor ? 0.12 : 0.06))
                        .frame(width: isMajor ? 1.2 : 0.8,
                               height: isMajor ? 4 : 2.5)
                        .offset(y: -(ringSize / 2) + 2)
                        .rotationEffect(.degrees(angle))
                }

                // Filled arc
                Circle()
                    .trim(from: 0, to: animated ? rate : 0)
                    .stroke(
                        AngularGradient(
                            colors: [
                                Color.white.opacity(0.95),
                                Color.white.opacity(0.55),
                                Color.white.opacity(0.25)
                            ],
                            center: .center,
                            startAngle: .degrees(-90),
                            endAngle: .degrees(270)
                        ),
                        style: StrokeStyle(
                            lineWidth: trackLineWidth,
                            lineCap: .round
                        )
                    )
                    .rotationEffect(.degrees(-90))
                    .animation(
                        .spring(response: 1.0, dampingFraction: 0.75).delay(0.2),
                        value: animated
                    )

                // Glint dot at arc tip
                if animated && rate > 0.02 {
                    Circle()
                        .fill(Color.white.opacity(0.9))
                        .frame(width: 3.5, height: 3.5)
                        .offset(y: -(ringSize / 2))
                        .rotationEffect(.degrees((rate * 360) - 90))
                        .animation(
                            .spring(response: 1.0, dampingFraction: 0.75).delay(0.2),
                            value: animated
                        )
                }

                // Center text
                VStack(spacing: 1) {
                    Text("\(Int(rate * 100))")
                        .font(.system(size: 14, weight: .semibold, design: .serif))
                        .foregroundStyle(.primary)
                    Text("%")
                        .font(.system(size: 7, weight: .medium))
                        .foregroundStyle(.secondary)
                        .opacity(0.5)
                }
            }
            .frame(width: ringSize, height: ringSize)
            .onAppear { animated = true }

            Text("DONE")
                .font(.system(size: 8, weight: .semibold))
                .tracking(0.7)
                .foregroundStyle(.secondary)
                .opacity(0.35)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.03))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [Color.white.opacity(0.1), Color.white.opacity(0.03)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 0.6
                        )
                )
        )
    }
}

// MARK: - Library Item

struct LibraryItemView: View {
    let name: String
    let count: Int
    let icon: String
    let delay: Double

    @State private var appeared = false

    var body: some View {
        VStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .light))
                .foregroundStyle(.secondary)
                .opacity(0.45)
                .padding(.bottom, 1)

            Text("\(count)")
                .font(.system(size: 18, weight: .light, design: .serif))
                .foregroundStyle(.primary)
                .contentTransition(.numericText())
                .animation(.spring(response: 0.5).delay(delay), value: appeared)

            Text(name)
                .font(.system(size: 8, weight: .medium))
                .tracking(0.3)
                .foregroundStyle(.secondary)
                .opacity(0.45)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(itemBackground)
        .opacity(appeared ? 1 : 0)
        .scaleEffect(appeared ? 1 : 0.94)
        .animation(.spring(response: 0.45, dampingFraction: 0.8).delay(delay), value: appeared)
        .onAppear { appeared = true }
    }

    private var itemBackground: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.white.opacity(0.04))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [Color.white.opacity(0.1), Color.white.opacity(0.03)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.5
                    )
            )
    }
}

// MARK: - Period Picker

struct CustomPeriodPicker: View {
    @Binding var selection: BriefPeriod
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 0) {
            ForEach(BriefPeriod.allCases, id: \.self) { period in
                periodButton(period)
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.07), lineWidth: 0.5)
                )
        )
    }

    @ViewBuilder
    private func periodButton(_ period: BriefPeriod) -> some View {
        let isSelected = selection == period

        Button {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                selection = period
            }
        } label: {
            Text(period.rawValue)
                .font(.system(
                    size: 10.5,
                    weight: isSelected ? .semibold : .regular
                ))
                .foregroundStyle(isSelected ? .primary : .secondary)
                .opacity(isSelected ? 1 : 0.45)
                .padding(.horizontal, 11)
                .padding(.vertical, 5)
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 6.5, style: .continuous)
                            .fill(Color.white.opacity(0.10))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6.5, style: .continuous)
                                    .strokeBorder(
                                        LinearGradient(
                                            colors: [
                                                Color.white.opacity(0.2),
                                                Color.white.opacity(0.05)
                                            ],
                                            startPoint: .top,
                                            endPoint: .bottom
                                        ),
                                        lineWidth: 0.5
                                    )
                            )
                            .matchedGeometryEffect(id: "pill", in: ns)
                    }
                }
        }
        .buttonStyle(.plain)
    }
}

enum BriefPeriod: String, CaseIterable {
    case day = "D", week = "W", month = "M", year = "Y"

    func dateRange(from now: Date = Date()) -> ClosedRange<Date> {
        let calendar = Calendar.current
        let start: Date
        switch self {
        case .day:
            start = calendar.startOfDay(for: now)
        case .week:
            start = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? calendar.startOfDay(for: now)
        case .month:
            start = calendar.dateInterval(of: .month, for: now)?.start ?? calendar.startOfDay(for: now)
        case .year:
            start = calendar.dateInterval(of: .year, for: now)?.start ?? calendar.startOfDay(for: now)
        }
        return start ... now
    }
}

