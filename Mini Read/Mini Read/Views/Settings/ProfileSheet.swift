import SwiftUI
import PhotosUI
import UIKit
import SwiftData

struct ProfileView: View {

    @Query private var books: [bookItem]
    @Query private var progressRecords: [ReadingProgressRecord]
    @Query private var readingSessions: [ReadingSession]

    @Environment(\.dismiss) private var dismiss

    @Bindable var settings: AppSettings

    // 动画状态控制：用于递进式出场动效
    @State private var appearStep: Int = 0

    private var themeColor: Color {
        Color(hex: settings.appTintColorHex) ?? .blue
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    
                    // 1. 视差头像 (带向下拖拽放大效果)
                    parallaxAvatar
                        .offset(y: appearStep > 0 ? 0 : 20)
                        .opacity(appearStep > 0 ? 1 : 0)
                    
                    // 2. 热力图
                    heatmapSection
                        .padding(.horizontal)
                        .offset(y: appearStep > 1 ? 0 : 20)
                        .opacity(appearStep > 1 ? 1 : 0)
                    
                    // 3. 统计网格
                    statsGrid
                        .padding(.horizontal)
                        .offset(y: appearStep > 2 ? 0 : 20)
                        .opacity(appearStep > 2 ? 1 : 0)
                        .padding(.bottom, 40)
                }
                .padding(.top)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") {
                        triggerHaptic(.light)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .onAppear {
                triggerEntranceAnimation()
            }
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
    }
    
    // MARK: - 触发递进动画
    
    private func triggerEntranceAnimation() {
        let spring = Animation.spring(response: 0.5, dampingFraction: 0.8, blendDuration: 0)
        
        withAnimation(spring.delay(0.05)) { appearStep = 1 }
        withAnimation(spring.delay(0.15)) { appearStep = 2 }
        withAnimation(spring.delay(0.25)) { appearStep = 3 }
        
        // 界面加载完毕后给一个轻微的震动反馈，建立潜意识的物理连接
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            triggerHaptic(.medium)
        }
    }
    
    // MARK: - 视差头像包装
    
    private var parallaxAvatar: some View {
        GeometryReader { proxy in
            let minY = proxy.frame(in: .scrollView).minY
            // 向下拉动时放大，向上滑动时平滑跟随移出
            let scale = minY > 0 ? 1 + (minY / 100) : 1.0
            let offset = minY > 0 ? -minY : 0

            AvatarHeader(themeColor: themeColor)
                .scaleEffect(scale)
                .offset(y: offset)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .frame(height: 120) // 固定占位高度，防止 GeometryReader 坍塌
    }
}

// MARK: - Stats UI

extension ProfileView {

    private var statsGrid: some View {

        let s = profileStats

        return LazyVGrid(
            columns: [
                GridItem(.flexible(), spacing: 16),
                GridItem(.flexible(), spacing: 16)
            ],
            spacing: 16
        ) {

            statCard(
                value: "\(s.booksFinished)",
                label: "已读完",
                icon: "book.closed.fill"
            )

            statCard(
                value: formatK(s.totalChapters),
                label: "已读章节",
                icon: "text.book.closed.fill"
            )

            statCard(
                value: "\(s.totalHours)h",
                label: "总时长",
                icon: "hourglass"
            )

            statCard(
                value: "\(s.currentStreak)天",
                label: "连续阅读",
                icon: "flame.fill"
            )
        }
    }

    private func statCard(
        value: String,
        label: String,
        icon: String
    ) -> some View {

        Button(action: {
            triggerHaptic(.light)
        }) {
            HStack(spacing: 14) {

                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(themeColor)
                    .frame(width: 32)

                VStack(alignment: .leading, spacing: 4) {

                    Text(value)
                        .font(.system(.title3, design: .rounded).weight(.bold))
                        .foregroundStyle(.primary)

                    Text(label)
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }
            .padding(.vertical, 18)
            .padding(.horizontal, 16)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
                    .shadow(color: Color.black.opacity(0.03), radius: 8, x: 0, y: 4)
            )
        }
        .buttonStyle(TactileCardStyle())
    }
}

// MARK: - Heatmap

extension ProfileView {

    private var heatmapSection: some View {

        VStack(alignment: .center, spacing: 18) {

            VStack(alignment: .center, spacing: 4) {

                Text("阅读活跃度")
                    .font(.headline)

                Text("最近 84 天")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HeatmapGridView(
                data: heatmapActivities,
                themeColor: themeColor
            )

            heatmapLegend
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    private var heatmapLegend: some View {

        HStack(spacing: 6) {

            Text("少")
                .font(.caption2)
                .foregroundStyle(.secondary)

            ForEach(0..<5) { level in

                RoundedRectangle(cornerRadius: 3)
                    .fill(themeColor.opacity(opacity(for: level)))
                    .frame(width: 12, height: 12)
            }

            Text("多")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func opacity(for level: Int) -> Double {

        switch level {
        case 0: return 0.12
        case 1: return 0.28
        case 2: return 0.45
        case 3: return 0.7
        default: return 1.0
        }
    }
}

// MARK: - Data Logic

extension ProfileView {

    private var profileStats: ProfileStats {

        let totalSeconds = readingSessions.reduce(0) {
            $0 + max(0, $1.durationSeconds)
        }

        let totalHours = Int(round(Double(totalSeconds) / 3600.0))

        // 读完 = 进度 100%。旧判据是「有记录且记录全已读」，而记录只在标记已读时
        // 才 insert，条件恒真——只要翻开过一本就算读完，数量虚高。
        let booksFinished = books.filter { $0.readingProgress == 1.0 }.count

        let totalChapters = progressRecords.filter(\.isRead).count

        let activeDays = allReadingActiveDays

        return ProfileStats(
            booksFinished: booksFinished,
            totalChapters: totalChapters,
            totalHours: totalHours,
            currentStreak: currentStreakDays(from: activeDays),
            longestStreak: longestStreakDays(from: activeDays)
        )
    }

    private var allReadingActiveDays: [Date] {

        let calendar = Calendar.current

        let days = readingSessions.compactMap {
            session in
            calendar.startOfDay(for: session.startedAt)
        }

        return Array(Set(days)).sorted()
    }

    private var heatmapActivities: [DayActivity] {

        let calendar = Calendar.current

        let today = calendar.startOfDay(for: Date())

        guard let startDate = calendar.date(
            byAdding: .day,
            value: -83,
            to: today
        ) else {
            return []
        }

        var result: [DayActivity] = []

        for offset in 0..<84 {

            guard let day = calendar.date(
                byAdding: .day,
                value: offset,
                to: startDate
            ) else {
                continue
            }

            let dayStart = calendar.startOfDay(for: day)

            guard let dayEnd = calendar.date(
                byAdding: .day,
                value: 1,
                to: dayStart
            ) else {
                continue
            }

            let totalSeconds = readingSessions.reduce(0) {
                partial, session in

                let overlapStart = max(session.startedAt, dayStart)
                let overlapEnd = min(session.endedAt, dayEnd)

                let overlap = overlapEnd.timeIntervalSince(overlapStart)

                return partial + max(0, Int(overlap))
            }

            result.append(
                DayActivity(
                    date: dayStart,
                    minutes: totalSeconds / 60
                )
            )
        }

        return result
    }

    private func currentStreakDays(
        from activeDays: [Date]
    ) -> Int {

        let calendar = Calendar.current
        let activeSet = Set(activeDays)

        var streak = 0
        var cursor = calendar.startOfDay(for: Date())

        while activeSet.contains(cursor) {

            streak += 1

            guard let previous = calendar.date(
                byAdding: .day,
                value: -1,
                to: cursor
            ) else {
                break
            }

            cursor = previous
        }

        return streak
    }

    private func longestStreakDays(
        from activeDays: [Date]
    ) -> Int {

        let calendar = Calendar.current

        guard !activeDays.isEmpty else {
            return 0
        }

        var longest = 1
        var current = 1

        for index in 1..<activeDays.count {

            let previous = activeDays[index - 1]
            let currentDay = activeDays[index]

            let diff = calendar.dateComponents(
                [.day],
                from: previous,
                to: currentDay
            ).day ?? 0

            if diff == 1 {

                current += 1
                longest = max(longest, current)

            } else if diff > 1 {

                current = 1
            }
        }

        return longest
    }

    private func formatK(_ value: Int) -> String {

        if value >= 1000 {
            return String(
                format: "%.1fk",
                Double(value) / 1000.0
            )
        }

        return "\(value)"
    }
}

// MARK: - Heatmap Grid

private struct HeatmapGridView: View {

    let data: [DayActivity]
    let themeColor: Color

    private let rows = 7

    private var columns: [[DayActivity]] {

        stride(from: 0, to: data.count, by: rows).map {
            start in

            Array(
                data[start..<min(start + rows, data.count)]
            )
        }
    }

    var body: some View {

        let maxMinutes = max(
            data.map(\.minutes).max() ?? 0,
            1
        )

        HStack(alignment: .center, spacing: 10) {
            weekdayLabels
            
            HStack(alignment: .center, spacing: 5) {

                ForEach(columns.indices, id: \.self) {
                    columnIndex in

                    VStack(spacing: 5) {

                        let column = columns[columnIndex]

                        ForEach(column) {
                            item in

                            cell(
                                item: item,
                                maxMinutes: maxMinutes
                            )
                        }
                    }
                }
            }
            
        }
    }

    private var weekdayLabels: some View {

        VStack(spacing: 5) {

            ForEach(
                ["日", "一", "二", "三", "四", "五", "六"],
                id: \.self
            ) {
                day in

                Text(day)
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .frame(height: 16)
            }
        }
    }

    private func cell(
        item: DayActivity,
        maxMinutes: Int
    ) -> some View {

        let opacity = intensity(
            minutes: item.minutes,
            maxMinutes: maxMinutes
        )

        return RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(themeColor.opacity(opacity))
            .frame(width: 18, height: 18)
            .overlay {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(
                        Color.primary.opacity(0.04)
                    )
            }
    }

    private func intensity(
        minutes: Int,
        maxMinutes: Int
    ) -> Double {

        guard minutes > 0 else {
            return 0.12
        }

        let normalized = Double(minutes) / Double(maxMinutes)

        switch normalized {
        case 0..<0.2: return 0.25
        case 0.2..<0.4: return 0.4
        case 0.4..<0.6: return 0.6
        case 0.6..<0.8: return 0.8
        default: return 1.0
        }
    }
}

// MARK: - Avatar Header

private struct AvatarHeader: View {

    let themeColor: Color

    @ObservedObject
    private var avatarStore = AvatarImageStore.shared

    @State private var isSavingAvatar = false
    @State private var showPhotoPicker = false

    var body: some View {

        Button {
            triggerHaptic(.medium)
            showPhotoPicker = true
        } label: {

            avatarCircle
                .overlay(alignment: .bottomTrailing) {
                    
                    ZStack {
                        Circle()
                            .fill(.thickMaterial)
                            .frame(width: 32, height: 32)
                            .shadow(color: .black.opacity(0.1), radius: 4, y: 2)
                        
                        if isSavingAvatar {
                            ProgressView()
                                .tint(themeColor)
                                .scaleEffect(0.8)
                        } else {
                            Image(systemName: "camera.fill")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(themeColor)
                        }
                    }
                    .offset(x: 2, y: 2)
                }
        }
        .buttonStyle(TactileCardStyle())
        .fullScreenCover(isPresented: $showPhotoPicker) {

            PhotoPickerView { image in

                guard let image else {
                    return
                }

                handlePickedAvatar(image)
            }
            .ignoresSafeArea()
        }
    }

    @ViewBuilder
    private var avatarCircle: some View {

        ZStack {

            LinearGradient(
                colors: [
                    themeColor.opacity(0.5),
                    themeColor
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            if let image = avatarStore.avatarImage {

                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity.combined(with: .scale))

            } else {

                Text(AvatarImageStore.placeholderInitial)
                    .font(
                        .system(
                            size: 42,
                            weight: .bold,
                            design: .rounded
                        )
                    )
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.1), radius: 2, y: 1)
            }
        }
        .frame(width: 100, height: 100)
        .clipShape(Circle())
        .shadow(
            color: themeColor.opacity(0.25),
            radius: 20,
            x: 0,
            y: 10
        )
        .overlay(
            Circle()
                .stroke(Color.white.opacity(0.2), lineWidth: 0.5)
        )
        .animation(
            .spring(response: 0.4, dampingFraction: 0.7),
            value: avatarStore.avatarImage
        )
    }

    private func handlePickedAvatar(
        _ image: UIImage
    ) {

        isSavingAvatar = true

        Task {

            guard let data = image.jpegData(
                compressionQuality: 0.9
            ) else {

                await MainActor.run {
                    isSavingAvatar = false
                }

                return
            }

            await avatarStore.commit(data: data)

            await MainActor.run {

                withAnimation(.easeInOut) {
                    isSavingAvatar = false
                }
            }
        }
    }
}

// MARK: - Utilities & Models

/// 触觉反馈卡片样式，模拟真实物理按压
struct TactileCardStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .opacity(configuration.isPressed ? 0.9 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

// `triggerHaptic` 已移入 `Utils/Haptics.swift`：它现在承载「触觉反馈」开关的
// 判断，不再是本文件私有的小工具，放在视图文件里会让人误以为只有这里用。

private struct ProfileStats {

    let booksFinished: Int
    let totalChapters: Int
    let totalHours: Int

    let currentStreak: Int
    let longestStreak: Int
}

private struct DayActivity: Identifiable {

    let id = UUID()

    let date: Date
    let minutes: Int
}
