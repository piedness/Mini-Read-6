//
//  ReadingStats.swift
//  TheNewVellium
//
//  Created by Max Piednes on 2026/4/25.
//

// ============================================================
// MARK: - Reading Stats Cards
// ============================================================

import SwiftUI
import SwiftData

// ============================================================
// MARK: - Color Tokens
// ============================================================
extension Color {
    static let primaryText   = Color(red: 0.110, green: 0.102, blue: 0.090)
    static let secondaryText = Color(red: 0.604, green: 0.580, blue: 0.549) // #9A948C
    static let accent        = Color(red: 0.784, green: 0.514, blue: 0.227) // #C8843A warm amber
}

// ============================================================
// MARK: - Font Helpers
// ============================================================
extension Font {
    static func appSerif(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .custom("Georgia", size: size).weight(weight)
    }
}


struct ReadingStatsRow: View {
    @Query private var books: [bookItem]
    @Query private var pageProgresses: [PageProgress]
    @Query private var progressRecords: [ReadingProgressRecord]
    @Query private var readingSessions: [ReadingSession]

    var body: some View {
        let todayMinutes = totalReadingMinutesToday
        let weekMinutes = totalReadingMinutesThisWeek
        let streak = readingStreakDays
        let todayNote = todayMinutes > 0 ? "\(todayMinutes) min log today" : ""
        let weekNote = "30d avg \(averageReadingMinutesLast30Days) min/day"

        HStack(spacing: 10) {
            statCard(label: "TODAY", value: "\(todayMinutes)", unit: "min", note: todayNote)
            statCard(label: "WEEK", value: "\(weekMinutes)", unit: "min", note: weekNote)
            
            Spacer()
        }
        
        
    }

    private func statCard(label: String, value: String, unit: String, note: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label)
                .font(.system(size: 14, weight: .semibold))
                .tracking(0.8)
                .foregroundColor(.secondaryText)
                .padding(.bottom, 6)

            HStack(alignment: .lastTextBaseline, spacing: 3) {
                Text(value)
                    .font(.appSerif(26, weight: .bold))
                    .kerning(-0.8)
                Text(unit)
                    .font(.system(size: 12))
                    .foregroundColor(.secondaryText)
            }
            .padding(.bottom, 5)

            Text(note)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.accent)
            
        }
        .padding(16)
        .frame(maxWidth: 200, alignment: .leading)
        .glassSurface(.regular, interactive: true, in: .rect(cornerRadius: 20))
        .shadow(color: .gray.opacity(0.8), radius: 1)
        
    }

    private var booksOpenedToday: Int {
        let start = Calendar.current.startOfDay(for: Date())
        return books.filter { ($0.lastOpenedAt ?? .distantPast) >= start }.count
    }

    private var totalReadingMinutesToday: Int {
        totalReadingSeconds(
            in: Calendar.current.startOfDay(for: Date()) ... Date()
        ) / 60
    }

    private var totalReadingMinutesThisWeek: Int {
        let calendar = Calendar.current
        let now = Date()
        let startOfWeek = calendar.dateInterval(of: .weekOfYear, for: now)?.start
            ?? calendar.startOfDay(for: now)
        return totalReadingSeconds(in: startOfWeek ... now) / 60
    }

    private var averageReadingMinutesLast30Days: Int {
        let calendar = Calendar.current
        let end = Date()
        let start = calendar.date(byAdding: .day, value: -29, to: calendar.startOfDay(for: end))
            ?? calendar.startOfDay(for: end)
        let totalMinutes = totalReadingSeconds(in: start ... end) / 60
        return totalMinutes / 30
    }

    private func totalReadingSeconds(in range: ClosedRange<Date>) -> Int {
        readingSessions.reduce(0) { partial, session in
            let overlapStart = max(session.startedAt, range.lowerBound)
            let overlapEnd = min(session.endedAt, range.upperBound)
            let overlap = max(0, Int(overlapEnd.timeIntervalSince(overlapStart)))
            return partial + overlap
        }
    }

    private var readingStreakDays: Int {
        let calendar = Calendar.current
        let activeDaysFromPages = pageProgresses.map { calendar.startOfDay(for: $0.updatedAt) }
        let activeDaysFromChapters = progressRecords.compactMap { record -> Date? in
            guard let readAt = record.readAt else { return nil }
            return calendar.startOfDay(for: readAt)
        }
        var activeDays = Set(activeDaysFromPages + activeDaysFromChapters)
        for book in books {
            if let openedAt = book.lastOpenedAt {
                activeDays.insert(calendar.startOfDay(for: openedAt))
            }
        }

        var cursor = calendar.startOfDay(for: Date())
        var streak = 0
        while activeDays.contains(cursor) {
            streak += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return streak
    }
}
