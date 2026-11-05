import AppKit
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
                VStack(spacing: SottoDesign.spacing) {
                    header
                    readinessSection
                    statsGrid
                    recentTranscriptsSection
                    activityAndSourcesSection
                    if let voiceVsKeyboard {
                        VoiceVsKeyboardCard(summary: voiceVsKeyboard)
                    }
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
        default: return 16
        }
    }

    private var header: some View {
        SottoPageHeader(title: "Dashboard", subtitle: Date.now.formatted(.dateTime.weekday(.wide).day().month(.wide))) {
            Button { onNavigate(.destination(.transcripts)) } label: {
                Image(systemName: "magnifyingglass")
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.bordered)
            .foregroundStyle(SottoDesign.cream)
            .tint(SottoDesign.cream.opacity(0.2))
            .help("Search transcripts")
            .accessibilityLabel("Search transcripts")
            Button(action: importRecording) {
                Image(systemName: "square.and.arrow.up")
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.bordered)
            .foregroundStyle(SottoDesign.cream)
            .tint(SottoDesign.cream.opacity(0.2))
            .help("Import audio or video")
            .accessibilityLabel("Import audio or video")
        }
    }

    private func importRecording() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = FileTranscriber.contentTypes
        panel.allowsMultipleSelection = true
        panel.message = "Choose recordings to transcribe into Transcripts"
        if panel.runModal() == .OK { appState.importFiles(panel.urls) }
    }

    private var readinessSection: some View {
        LiveDictationStatusView(appState: appState, onNavigate: onNavigate, announcesChanges: true, dashboard: true)
    }

    // MARK: - Stats Grid

    private var statsGrid: some View {
        VStack(spacing: SottoDesign.spacing / 2) {
            HStack(spacing: SottoDesign.spacing / 2) {
                heroStat("Words · 30 days", value: formatNumber(statistics.totalWords))
                heroStat("Time Saved · 30 days", value: formatDuration(statistics.timeSaved))
            }
            HStack(spacing: SottoDesign.spacing / 2) {
                compactStat("Transcripts", value: "\(statistics.transcriptCount)")
                compactStat("Avg Speed", value: String(format: "%.0f", statistics.averageWPM), unit: "WPM")
                compactStat("Streak", value: "\(statistics.currentStreak)", unit: "days")
            }
        }
    }

    private func heroStat(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: SottoDesign.spacing / 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 34, weight: .semibold, design: .rounded)).minimumScaleFactor(0.7).lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
        .sottoSurface()
    }

    private func compactStat(_ title: String, value: String, unit: String = "") -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 4)
            Text(value).font(.title3.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.7)
            if !unit.isEmpty { Text(unit).font(.caption2).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, minHeight: 30)
        .sottoSurface()
    }

    // MARK: - Activity & Sources Section

    @ViewBuilder
    private var activityAndSourcesSection: some View {
        if containerWidth < 550 {
            // Stack vertically on narrow screens
            VStack(spacing: SottoDesign.spacing / 2) {
                activityChart
                topSourcesCard
            }
        } else {
            // Side by side on wider screens
            HStack(alignment: .top, spacing: SottoDesign.spacing / 2) {
                activityChart
                topSourcesCard
            }
        }
    }

    // MARK: - Activity Chart

    private var activityChart: some View {
        let chartHeight: CGFloat = containerWidth < 500 ? 100 : 120

        return VStack(alignment: .leading, spacing: SottoDesign.spacing / 2) {
            HStack {
                Text("Activity").font(.subheadline.weight(.semibold))
                Spacer()
                Text("Last 7 days · words")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            HStack(alignment: .bottom, spacing: SottoDesign.spacing / 3) {
                ForEach(statistics.dailyActivity) { day in
                    VStack(spacing: 4) {
                        if Calendar.current.isDateInToday(day.date), day.wordCount > 0 {
                            Text(formatNumber(day.wordCount))
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(SottoDesign.accent)
                        }
                        RoundedRectangle(cornerRadius: 4)
                            .fill(barColor(for: day))
                            .frame(maxWidth: 34)
                            .frame(height: barHeight(for: day, maxHeight: chartHeight - 34))

                        Text(dayLabel(for: day.date))
                            .font(.caption2)
                            .foregroundColor(Calendar.current.isDateInToday(day.date) ? .primary : .secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: chartHeight)
            .frame(maxWidth: .infinity)
        }
        .sottoSurface()
        .frame(maxWidth: .infinity)
    }

    private func barHeight(for day: DailyActivity, maxHeight: CGFloat = 80) -> CGFloat {
        let maxWords = statistics.dailyActivity.map(\.wordCount).max() ?? 1
        guard maxWords > 0 else { return 8 }
        return max(8, CGFloat(day.wordCount) / CGFloat(maxWords) * maxHeight)
    }

    private func barColor(for day: DailyActivity) -> Color {
        if day.wordCount == 0 { return SottoDesign.cream.opacity(0.08) }
        return Calendar.current.isDateInToday(day.date) ? accentColor : SottoDesign.cream.opacity(0.14)
    }

    private func dayLabel(for date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "Today" }
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE"
        return formatter.string(from: date)
    }

    // MARK: - Top Sources

    private var topSourcesCard: some View {
        VStack(alignment: .leading, spacing: SottoDesign.spacing / 2) {
            HStack {
                Text("Top Apps").font(.subheadline.weight(.semibold))
                Spacer()
                Text("Share of words · 30 days")
                    .font(.caption2).foregroundStyle(.secondary)
            }

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
                VStack(spacing: SottoDesign.spacing / 2) {
                    ForEach(statistics.topSources.prefix(4)) { source in
                        HStack(spacing: SottoDesign.spacing / 2) {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(SottoDesign.cream.opacity(0.08))
                                .frame(width: 24, height: 24)
                                .overlay(Text(String(source.appName.prefix(1))).font(.caption2.weight(.semibold)))

                            Text(source.appName)
                                .font(.caption)
                                .lineLimit(1)
                                .frame(width: 74, alignment: .leading)
                            GeometryReader { geometry in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(SottoDesign.cream.opacity(0.1))
                                    Capsule().fill(source.id == statistics.topSources.first?.id ? SottoDesign.accent : SottoDesign.cream.opacity(0.5))
                                        .frame(width: geometry.size.width * sourceShare(source))
                                }
                            }
                            .frame(height: 5)
                            Text("\(Int((sourceShare(source) * 100).rounded()))%")
                                .font(.caption2).foregroundStyle(.secondary)
                                .frame(width: 32, alignment: .trailing)
                        }
                    }
                }
            }
        }
        .sottoSurface()
        .frame(maxWidth: .infinity, minHeight: 170, alignment: .topLeading)
    }

    private func sourceShare(_ source: AppUsage) -> CGFloat {
        let total = statistics.topSources.reduce(0) { $0 + $1.wordCount }
        return total > 0 ? CGFloat(source.wordCount) / CGFloat(total) : 0
    }

    // MARK: - Recent Transcripts

    private var recentTranscriptsSection: some View {
        VStack(alignment: .leading, spacing: SottoDesign.spacing / 2) {
            HStack {
                Text("Recent Transcripts").font(.subheadline.weight(.semibold))
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
                VStack(spacing: 0) {
                    ForEach(recentTranscripts.prefix(3)) { entry in
                        TranscriptRow(entry: entry, historyManager: historyManager)
                        if entry.id != recentTranscripts.prefix(3).last?.id { Divider() }
                    }
                }
            }
        }
        .sottoSurface()
    }

    // MARK: - Helpers

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

// MARK: - Transcript Row

struct TranscriptRow: View {
    let entry: TranscriptionEntry
    let historyManager: TranscriptionHistoryManager

    var body: some View {
        HStack(spacing: SottoDesign.spacing / 2) {
            RoundedRectangle(cornerRadius: 6)
                .fill(SottoDesign.cream.opacity(0.08))
                .frame(width: 24, height: 24)
                .overlay(Text(String((entry.sourceApp ?? "S").prefix(1))).font(.caption2.weight(.semibold)))
                .accessibilityHidden(true)
            if entry.isFailed {
                Label("Dictation needs attention", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(SottoDesign.accent)
            } else {
                Text(entry.text.isEmpty ? "No transcript text" : entry.text).font(.caption).lineLimit(2)
                    .foregroundStyle(entry.text.isEmpty ? Color.secondary : Color.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text([entry.sourceApp, entry.isFailed ? nil : "\(historyManager.wordCount(for: entry.text)) words"]
                .compactMap { $0 }.joined(separator: " · "))
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            Text(timeString).font(.caption2).foregroundStyle(.secondary)
                .frame(minWidth: 54, alignment: .trailing)
        }
        .padding(.vertical, SottoDesign.spacing / 2)
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
