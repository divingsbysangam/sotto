#if DEBUG
import SwiftUI

/// A separate preview shell. Nothing here constructs AppState, settings, stores or services.
struct RedesignPrototype: View {
    enum Destination: String, CaseIterable, Identifiable {
        case dashboard = "Dashboard", transcripts = "Transcripts", appModes = "App Modes"
        case vocabulary = "Vocabulary", settings = "Settings", help = "Help"
        var id: Self { self }
        var symbol: SottoSymbol {
            switch self {
            case .dashboard: return .dashboard
            case .transcripts: return .transcripts
            case .appModes: return .appModes
            case .vocabulary: return .vocabulary
            case .settings: return .settings
            case .help: return .help
            }
        }
    }

    @State var destination: Destination = .dashboard
    @State var phase: RedesignFixtures.Phase = .ready
    @State var emptyHistory = false
    @State var search = ""
    @State private var notice: String?
    @State private var detail: SottoTranscriptPresentation?
    @State private var settingsSection = "Transcription"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.sottoAccessibilityPreview) private var accessibilityPreview

    var body: some View {
        NavigationSplitView {
            List(Destination.allCases, selection: $destination) { item in
                Label(item.rawValue, systemImage: item.symbol.rawValue).tag(item)
            }
            .navigationSplitViewColumnWidth(min: 140, ideal: 160, max: 200)
            .safeAreaInset(edge: .bottom) {
                Label("On this Mac", systemImage: "desktopcomputer")
                    .font(.caption).foregroundStyle(.secondary).padding(12)
            }
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let notice {
                        HStack {
                            Label(notice, systemImage: "info.circle").font(.callout)
                            Spacer()
                            SottoIconButton(symbol: .close) { self.notice = nil }
                        }.sottoSurface()
                    }
                    switch destination {
                    case .dashboard: dashboard
                    case .transcripts: transcripts
                    case .settings: settings
                    case .appModes: appModes
                    case .vocabulary: vocabulary
                    case .help: help
                    }
                }
                .padding(16)
                .padding(.top, 24)
                .frame(maxWidth: 880)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle(destination.rawValue)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .tint(SottoDesign.accent)
        .toolbar {
            ToolbarItem {
                Button("Help", systemImage: SottoSymbol.help.rawValue) { destination = .help }
                    .help("Open Help")
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { previewControls }
        .animation(reduceMotion || accessibilityPreview ? nil : .easeInOut(duration: SottoDesign.contentDuration), value: destination)
        .sheet(item: $detail) { transcript in
            VStack(alignment: .leading, spacing: 16) {
                Text("Transcript details").font(.title2.weight(.semibold))
                Text("Synthetic example · Cleaned version").foregroundStyle(.secondary)
                Text(transcript.text).textSelection(.enabled)
                Text("Live integration will retain playback, raw text, versions and reprocessing.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Done") { detail = nil }.keyboardShortcut(.defaultAction)
            }.padding(24).frame(width: 380)
        }
    }

    private var dashboard: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 16) {
                SottoStatusView(status: phase.presentation, onAction: openRecoverySettings)
                Divider()
                SottoShortcutHint(keys: "⌥ Space", instruction: "Hold to dictate into the app you’re using.")
                SottoShortcutHint(keys: "2×", instruction: "Double-tap your shortcut for hands-free dictation.")
            }.sottoSurface()
            SottoSection(title: "Recent transcripts", actionTitle: "View All", onAction: { destination = .transcripts }) {
                if emptyHistory {
                    SottoEmptyState(symbol: .transcripts, title: "Your words will appear here", detail: "Use your shortcut in any app to create your first transcript.")
                } else {
                    ForEach(RedesignFixtures.transcripts.prefix(2)) { transcript in
                        transcriptRow(transcript)
                        if transcript.id != "sample-2" { Divider() }
                    }
                }
            }
            SottoSection(title: "Your activity", subtitle: "Last 30 days · Sample data") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), alignment: .leading)], alignment: .leading, spacing: 16) {
                    metric("Words", "2,480")
                    metric("Time saved", "1 hr 12 min")
                    metric("Transcripts", "42")
                    metric("Average speed", "138 WPM")
                    metric("Lifetime words", "12,860")
                    metric("Current streak", "3 days")
                }
                Divider()
                Text("Top sources: Notes · Mail · Scratchpad").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var transcripts: some View {
        VStack(alignment: .leading, spacing: 16) {
            TextField("Search transcripts", text: $search).textFieldStyle(.roundedBorder)
                .accessibilityLabel("Search transcripts")
            SottoSection(title: "On this Mac", subtitle: "Synthetic examples") {
                let shown = emptyHistory ? [] : RedesignFixtures.transcripts.filter {
                    search.isEmpty || $0.text.localizedCaseInsensitiveContains(search) || $0.source.localizedCaseInsensitiveContains(search)
                }
                if shown.isEmpty {
                    SottoEmptyState(symbol: .transcripts, title: search.isEmpty ? "No transcripts yet" : "No matching transcripts", detail: search.isEmpty ? "Dictate with your shortcut, or import a recording." : "Try another word or clear your search.")
                } else {
                    ForEach(shown) { transcript in
                        transcriptRow(transcript)
                        if transcript.id != shown.last?.id { Divider() }
                    }
                }
            }
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("Settings section", selection: $settingsSection) {
                Text("General").tag("General")
                Text("Transcription").tag("Transcription")
                Text("System").tag("System")
            }.pickerStyle(.segmented)
            if settingsSection == "Transcription" {
                SottoSection(title: "Speech engine", subtitle: "Speech stays on this Mac.") {
                    LabeledContent("Selected engine", value: "Parakeet TDT v3")
                    LabeledContent("Language", value: "Detect automatically")
                    Label("Using Whisper Turbo for automatic language detection.", systemImage: "arrow.triangle.branch")
                        .font(.callout).foregroundStyle(.secondary)
                    Divider()
                    SottoStatusView(status: phase.presentation, onAction: { notice = "Preview only: no model was loaded or downloaded." })
                    Text("Optional models download only when requested. Live preview uses Whisper.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                SottoSection(title: "Text cleanup") {
                    LabeledContent("Processing", value: "On-device")
                    Text("Apple Foundation Models when available; built-in cleanup otherwise.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            } else {
                SottoSection(title: settingsSection == "General" ? "Dictation shortcuts" : "Permissions") {
                    if settingsSection == "General" {
                        SottoShortcutHint(keys: "⌥ Space", instruction: "Hold or double-tap to dictate.")
                        Text("Output, sound and Screen Context controls will keep their existing behavior.").foregroundStyle(.secondary)
                    } else {
                        Label("Microphone allowed", systemImage: "checkmark.circle.fill")
                        Label("Accessibility off · Copy to clipboard available", systemImage: "doc.on.clipboard")
                        Text("These are sample permission states.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var appModes: some View {
        SottoSection(title: "App Modes", subtitle: "Choose how your words read in each app.") {
            LabeledContent("Default", value: "Clear, natural text")
            Divider()
            LabeledContent("Mail", value: "Friendly and concise")
            Button("Edit Mail Mode") { notice = "Preview only: existing mode matching and editors will be reused." }
        }
    }

    private var vocabulary: some View {
        SottoSection(title: "Vocabulary", subtitle: "Names and terms you use often.") {
            LabeledContent("Sotto", value: "Custom word")
            Divider()
            LabeledContent("on my way", value: "Replacement: omw")
            Text("Custom words, replacements, snippets and import/export remain available.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var help: some View {
        SottoSection(title: "Getting started") {
            SottoShortcutHint(keys: "⌥ Space", instruction: "Hold to speak. Release to finish.")
            SottoShortcutHint(keys: "Esc", instruction: "Cancel the current recording.")
            Text("Everything is transcribed and cleaned up on this Mac.").foregroundStyle(.secondary)
            Button("Replay Setup Preview") { notice = "Open the Onboarding preview to review the permission sequence." }
        }
    }

    private var previewControls: some View {
        ViewThatFits(in: .horizontal) {
            HStack { phasePicker; Spacer(); historyToggle }
            VStack(alignment: .leading, spacing: 8) { phasePicker; historyToggle }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .top) { Divider() }
    }

    private var phasePicker: some View {
        Picker("Sample state", selection: $phase) {
            ForEach(RedesignFixtures.Phase.allCases) { Text($0.rawValue).tag($0) }
        }.frame(maxWidth: 290)
    }

    private var historyToggle: some View { Toggle("Empty history", isOn: $emptyHistory).toggleStyle(.checkbox) }

    private func openRecoverySettings() {
        destination = .settings
        settingsSection = phase == .microphone ? "System" : "Transcription"
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(.system(.title3, design: .rounded).weight(.semibold)).monospacedDigit()
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func transcriptRow(_ transcript: SottoTranscriptPresentation) -> some View {
        SottoTranscriptRow(transcript: transcript, onCopy: {
            notice = "Preview only: copy action selected. Clipboard unchanged."
        }, onDetails: { detail = transcript }, onRetry: {
            notice = "Preview only: retry selected. No audio was processed."
        })
    }
}

#Preview("Dashboard · Light") { RedesignPrototype().preferredColorScheme(.light).frame(width: 700, height: 500) }
#Preview("Dashboard · Dark") { RedesignPrototype().preferredColorScheme(.dark).frame(width: 1100, height: 750) }
#Preview("Narrow · Microphone denied") { RedesignPrototype(phase: .microphone).frame(width: 500, height: 400) }
#Preview("Transcripts") { RedesignPrototype(destination: .transcripts).frame(width: 700, height: 500) }
#Preview("Empty transcripts") { RedesignPrototype(destination: .transcripts, emptyHistory: true).frame(width: 700, height: 500) }
#Preview("No search results") { RedesignPrototype(destination: .transcripts, search: "unmatched example").frame(width: 500, height: 400) }
#Preview("Clipboard fallback") { RedesignPrototype(phase: .copied).frame(width: 700, height: 500) }
#Preview("Speech settings · Failed") { RedesignPrototype(destination: .settings, phase: .failed).frame(width: 700, height: 500) }
#Preview("Reduced motion & transparency") {
    RedesignPrototype(phase: .downloading)
        .environment(\.sottoAccessibilityPreview, true)
        .frame(width: 700, height: 500)
}
#endif
