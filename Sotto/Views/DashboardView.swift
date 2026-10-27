import SwiftUI
import Combine

struct DashboardView: View {
    let appState: AppState
    let onNavigate: (SottoRoute) -> Void
    @State private var statistics: UsageStatistics = .empty
    @State private var recentTranscripts: [TranscriptionEntry] = []
    @State private var containerWidth: CGFloat = 700
    /// L15: voice vs keyboard for the last 7 days; nil when typing counting is off.
    @State private var voiceVsKeyboard: TypingStats.Summary?
    private let historyManager = TranscriptionHistoryManager.shared

    private let accentColor = SottoDesign.accent

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 24) {
                    readinessSection
                    recentTranscriptsSection
                    statsGrid
                    if let voiceVsKeyboard {
                        VoiceVsKeyboardCard(summary: voiceVsKeyboard)
                    }
                    activityAndSourcesSection
                }
                .padding(responsivePadding(for: geometry.size.width))
            }
            .onAppear {
                containerWidth = geometry.size.width
                loadData()
            }
            .onChange(of: geometry.size.width) { _, newWidth in
                containerWidth = newWidth
            }
            .onChange(of: historyManager.entries) { loadData() }
            .onChange(of: AppSettings.shared.countTypingEnabled) { loadData() }
            .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in loadData() }
            .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { _ in
                if AppSettings.shared.countTypingEnabled { loadData() }
            }
        }
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - Responsive Helpers

    private func responsivePadding(for width: CGFloat) -> CGFloat {
        switch width {
        case ..<400: return 12
        case ..<600: return 16
        default: return 24
        }
    }

    private func adaptiveColumns(for width: CGFloat) -> [GridItem] {
        switch width {
        case ..<400: return [GridItem(.flexible())]
        case ..<550: return Array(repeating: GridItem(.flexible()), count: 2)
        case ..<750: return Array(repeating: GridItem(.flexible()), count: 3)
        default: return Array(repeating: GridItem(.flexible()), count: 4)
        }
    }

    private var readinessSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            LiveDictationStatusView(appState: appState, onNavigate: onNavigate, announcesChanges: true)
            Divider()
            SottoShortcutHint(keys: AppSettings.shared.hotkeyDisplayName, instruction: "Hold to dictate into the app you’re using.")
            SottoShortcutHint(keys: "2×", instruction: "Double-tap your shortcut for hands-free dictation.")
        }
        .sottoSurface()
    }

    // MARK: - Stats Grid

    private var statsGrid: some View {
        LazyVGrid(columns: adaptiveColumns(for: containerWidth), spacing: 16) {
            StatCard(title: "Words · 30 days", value: formatNumber(statistics.totalWords), icon: "text.word.spacing", color: accentColor)
            StatCard(title: "Time Saved", value: formatDuration(statistics.timeSaved), icon: "clock.arrow.circlepath", color: .green)
            StatCard(title: "Transcripts", value: "\(statistics.transcriptCount)", icon: "doc.text.fill", color: .blue)
            StatCard(title: "Avg. Speed", value: String(format: "%.0f WPM", statistics.averageWPM), icon: "speedometer", color: .purple)
            StatCard(title: "Lifetime", value: formatNumber(statistics.lifetimeWords), icon: "infinity", color: .orange)
            StatCard(title: "Current streak", value: "\(statistics.currentStreak) days", icon: "calendar", color: .secondary)
        }
    }

    // MARK: - Activity & Sources Section

    @ViewBuilder
    private var activityAndSourcesSection: some View {
        if containerWidth < 550 {
            // Stack vertically on narrow screens
            VStack(spacing: 20) {
                activityChart
                topSourcesCard
            }
        } else {
            // Side by side on wider screens
            HStack(alignment: .top, spacing: 20) {
                activityChart
                topSourcesCard
            }
        }
    }

    // MARK: - Activity Chart

    private var activityChart: some View {
        let chartHeight: CGFloat = containerWidth < 500 ? 100 : (containerWidth > 800 ? 150 : 120)
        let barWidth: CGFloat = containerWidth < 400 ? 24 : (containerWidth > 800 ? 40 : 32)

        return VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Activity")
                    .font(.headline)
                Spacer()
                Text("Last 7 days")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            HStack(alignment: .bottom, spacing: containerWidth < 400 ? 4 : 8) {
                ForEach(statistics.dailyActivity) { day in
                    VStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(barColor(for: day))
                            .frame(width: barWidth, height: barHeight(for: day, maxHeight: chartHeight - 40))

                        Text(dayLabel(for: day.date))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .frame(height: chartHeight)
            .frame(maxWidth: .infinity)

            HStack {
                Circle().fill(accentColor).frame(width: 8, height: 8)
                Text("\(statistics.dailyActivity.reduce(0) { $0 + $1.wordCount }) words this week")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(containerWidth < 400 ? 16 : 20)
        .background(cardBackground)
        .frame(maxWidth: .infinity)
    }

    private func barHeight(for day: DailyActivity, maxHeight: CGFloat = 80) -> CGFloat {
        let maxWords = statistics.dailyActivity.map(\.wordCount).max() ?? 1
        guard maxWords > 0 else { return 8 }
        return max(8, CGFloat(day.wordCount) / CGFloat(maxWords) * maxHeight)
    }

    private func barColor(for day: DailyActivity) -> Color {
        if day.wordCount == 0 { return Color.gray.opacity(0.2) }
        return Calendar.current.isDateInToday(day.date) ? accentColor : accentColor.opacity(0.6)
    }

    private func dayLabel(for date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "Today" }
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE"
        return formatter.string(from: date)
    }

    // MARK: - Top Sources

    private var topSourcesCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Top Apps")
                .font(.headline)

            if statistics.topSources.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "app.badge.checkmark")
                        .font(.largeTitle)
                        .foregroundColor(.secondary.opacity(0.5))
                    Text("No data yet")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 12) {
                    ForEach(statistics.topSources.prefix(4)) { source in
                        HStack {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(appColor(for: source.appName))
                                .frame(width: 28, height: 28)
                                .overlay(Text(String(source.appName.prefix(1))).font(.system(size: 14, weight: .semibold)).foregroundColor(.white))

                            Text(source.appName)
                                .font(.subheadline)
                                .lineLimit(1)

                            Spacer()

                            Text(formatNumber(source.wordCount))
                                .font(.subheadline)
                                .fontWeight(.medium)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            Spacer()
        }
        .padding(containerWidth < 400 ? 16 : 20)
        .background(cardBackground)
        .frame(minWidth: 180, idealWidth: 220, maxWidth: containerWidth < 550 ? .infinity : 300)
        .frame(minHeight: 180, idealHeight: 200)
    }

    private func appColor(for name: String) -> Color {
        let colors: [Color] = [.blue, .purple, .green, .orange, .pink, .cyan]
        return colors[abs(name.hashValue) % colors.count]
    }

    // MARK: - Recent Transcripts

    private var recentTranscriptsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Recent Transcripts")
                    .font(.headline)
                Spacer()
                Button("View All") { onNavigate(.destination(.transcripts)) }
                    .buttonStyle(.plain)
                    .foregroundColor(accentColor)
            }

            if recentTranscripts.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "waveform.circle")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary.opacity(0.5))
                    Text("No transcripts yet")
                        .font(.headline)
                        .foregroundColor(.secondary)
                    Text("Press your shortcut to start dictating")
                        .font(.caption)
                        .foregroundColor(.secondary.opacity(0.7))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
            } else {
                VStack(spacing: 1) {
                    ForEach(recentTranscripts.prefix(5)) { entry in
                        TranscriptRow(entry: entry, historyManager: historyManager)
                    }
                }
            }
        }
        .padding(20)
        .background(cardBackground)
    }

    // MARK: - Helpers

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: SottoDesign.cornerRadius)
            .fill(Color(NSColor.controlBackgroundColor))
            .overlay(RoundedRectangle(cornerRadius: SottoDesign.cornerRadius).strokeBorder(Color.primary.opacity(0.1)))
    }

    private func loadData() {
        var measuredTypingWPM: Double?
        if AppSettings.shared.countTypingEnabled {
            let typing = TypingCounterService.shared.days
            let dictations = historyManager.dictationVolume
            voiceVsKeyboard = TypingStats.summary(typing: typing, dictations: dictations, days: 7)
            measuredTypingWPM = TypingStats.summary(typing: typing, dictations: dictations, days: 30).typingWPM
        } else {
            voiceVsKeyboard = nil
        }
        statistics = historyManager.getStatistics(days: 30, typingWPM: measuredTypingWPM)
        recentTranscripts = Array(historyManager.entries.prefix(5))
    }

    private func formatNumber(_ number: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: number)) ?? "\(number)"
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "\(Int(seconds))s" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        return "\(Int(seconds / 3600))h \(Int((seconds.truncatingRemainder(dividingBy: 3600)) / 60))m"
    }
}

// MARK: - Stat Card

struct StatCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundColor(color)

            VStack(alignment: .leading, spacing: 4) {
                Text(value)
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                Text(title)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(NSColor.controlBackgroundColor))
                .shadow(color: .black.opacity(0.05), radius: 8, y: 2)
        )
    }
}

// MARK: - Transcript Row

struct TranscriptRow: View {
    let entry: TranscriptionEntry
    let historyManager: TranscriptionHistoryManager

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if entry.isFailed {
                Label("Dictation needs attention", systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline).foregroundStyle(.orange)
            } else {
                Text(entry.text).font(.subheadline).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text([timeString, entry.sourceApp, entry.isFailed ? nil : "\(historyManager.wordCount(for: entry.text)) words"]
                .compactMap { $0 }.joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 4)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
    }

    private var timeString: String {
        let calendar = Calendar.current
        let formatter = DateFormatter()

        if calendar.isDateInToday(entry.timestamp) {
            formatter.dateFormat = "h:mm a"
        } else if calendar.isDateInYesterday(entry.timestamp) {
            return "Yesterday"
        } else {
            formatter.dateFormat = "MMM d"
        }
        return formatter.string(from: entry.timestamp)
    }
}

#if DEBUG
#Preview {
    RedesignPrototype()
        .frame(width: 700, height: 800)
}
#endif

// MARK: - Voice vs Keyboard (L15)

struct VoiceVsKeyboardCard: View {
    let summary: TypingStats.Summary

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Voice vs Keyboard", systemImage: "keyboard")
                    .font(.headline)
                Spacer()
                Text("Last 7 days")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // Share of characters: voice vs typed.
            GeometryReader { geo in
                HStack(spacing: 2) {
                    Rectangle()
                        .fill(Color(red: 0.31, green: 0.82, blue: 0.77))
                        .frame(width: max(geo.size.width * summary.voiceShare, summary.dictatedChars > 0 ? 4 : 0))
                    Rectangle()
                        .fill(Color.secondary.opacity(0.35))
                }
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .frame(height: 10)

            HStack(alignment: .top, spacing: 24) {
                metric("Dictated", Self.chars(summary.dictatedChars), summary.dictationWPM.map { String(format: "%.0f WPM", $0) } ?? "—")
                metric("Typed", Self.chars(summary.typedChars), summary.typingWPM.map { String(format: "%.0f WPM", $0) } ?? "Measuring…")
                Spacer()
            }

            Text(footnote)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(NSColor.controlBackgroundColor))
                .shadow(color: .black.opacity(0.05), radius: 8, y: 2)
        )
    }

    private var footnote: String {
        if let typing = summary.typingWPM, let voice = summary.dictationWPM, typing > 0 {
            let ratio = voice / typing
            return ratio >= 1.1
                ? String(format: "Dictation is %.1f× your typing speed. Time Saved now uses your measured typing speed.", ratio)
                : "Your typing is about as fast as dictation. Time Saved now uses your measured typing speed."
        }
        return "Typing speed appears after about 10 minutes of typing. Only character counts are kept, never what you type."
    }

    private func metric(_ title: String, _ value: String, _ speed: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 20, weight: .bold, design: .rounded))
            Text(speed)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.secondary)
        }
    }

    private static func chars(_ count: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return (formatter.string(from: NSNumber(value: count)) ?? "\(count)") + " chars"
    }
}
