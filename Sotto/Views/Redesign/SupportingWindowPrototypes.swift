#if DEBUG
import SwiftUI

struct SupportingWindowPrototype: View {
    enum Surface: String, CaseIterable, Identifiable {
        case menu = "Menu Bar", capsule = "Minimal Overlay", floating = "Floating Overlay", dot = "Dot Listener"
        case onboarding = "Onboarding", scratchpad = "Scratchpad"
        var id: Self { self }
    }
    let surface: Surface
    @State var phase: RedesignFixtures.Phase = .recording
    @State private var notice = ""
    @StateObject private var meter = CapsuleLevel(value: 0.65)
    @StateObject private var floatingModel = FloatingDictationModel()
    @State private var step = 0
    @State private var note = "A small idea worth keeping.\n\nMake the next step easy to see."
    @State private var selectedNote = "Today's ideas"
    private let steps = ["Microphone", "Accessibility", "Your Shortcut", "Try It", "Screen Context"]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch surface {
            case .menu: menu
            case .capsule: capsule
            case .dot: VStack(spacing: 16) { CursorIndicatorView(isProcessing: phase == .processing); Text("Dot near writing").font(.caption).foregroundStyle(.secondary) }.frame(maxWidth: .infinity)
            case .floating: FloatingDictationView(model: floatingModel, level: meter, onCancel: { simulate("Cancel") }, onPasteNow: { simulate("Paste") })
            case .onboarding: onboarding
            case .scratchpad: scratchpad
            }
            if !notice.isEmpty { Text(notice).font(.caption).foregroundStyle(.secondary) }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .tint(SottoDesign.accent)
        .onAppear { floatingModel.state = phase == .processing ? .processing() : .recording }
    }

    private var menu: some View {
        VStack(alignment: .leading, spacing: 16) {
            SottoStatusView(status: phase.presentation, onAction: { simulate("Open Speech Settings") })
            Divider()
            Button(phase == .recording ? "Stop Recording" : "Start Recording", systemImage: phase == .recording ? "stop.circle" : "mic") {
                phase = phase == .recording ? .processing : .recording
            }
            SottoShortcutHint(keys: "⌥ Space", instruction: "Hold or double-tap")
            Divider()
            Text("Last transcript").font(.caption).foregroundStyle(.secondary)
            Text(RedesignFixtures.transcripts[0].text).lineLimit(3)
            Button("Copy Last Transcript", systemImage: SottoSymbol.copy.rawValue) { simulate("Copy Last Transcript") }
            Button("Paste Last Transcript", systemImage: "doc.on.clipboard") { simulate("Paste Last Transcript") }
            Button("Read Last Transcript Aloud", systemImage: "speaker.wave.2") { simulate("Read Aloud") }
            Divider()
            Button("Transcripts", systemImage: SottoSymbol.transcripts.rawValue) { simulate("Open Transcripts") }
            Button("Scratchpad", systemImage: SottoSymbol.scratchpad.rawValue) { simulate("Open Scratchpad") }
            Button("Open Sotto", systemImage: "macwindow") { simulate("Open Sotto") }
            Button("Check for Updates…", systemImage: "arrow.triangle.2.circlepath") { simulate("Check for Updates") }
            Divider()
            Button("Quit Sotto", systemImage: "power") { simulate("Quit") }
        }
        .buttonStyle(.borderless)
    }

    private var capsule: some View {
        VStack(spacing: 24) {
            Text("Bottom listener · Synthetic recording").font(.caption).foregroundStyle(.secondary)
            NotchCapsuleView(level: meter, isProcessing: phase == .processing,
                             statusText: phase == .processing ? "Transcribing…" : "",
                             modeName: "Default", liveText: "Let’s keep the first version small…")
            NotchCapsuleView(level: meter, isProcessing: false,
                             prompt: .init(icon: "stop.circle", text: "Recording cancelled",
                                           actions: [.init(title: "Undo", handler: { simulate("Undo") })]))
        }
    }

    private var sampleMeter: some View {
        HStack(alignment: .center, spacing: 4) {
            ForEach(Array([8.0, 16, 24, 12, 20].enumerated()), id: \.offset) { _, height in
                Capsule().fill(SottoDesign.accent).frame(width: 4, height: height)
            }
        }
        .frame(height: 24)
        // Fixed synthetic levels: no timers, live capture or repeated announcements.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Sample audio level")
    }

    private var onboarding: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                Label("Set up Sotto", systemImage: "waveform")
                Spacer()
                Text("\(step + 1) of 5").foregroundStyle(.secondary)
            }.font(.callout)
            ProgressView(value: Double(step + 1), total: 5).accessibilityLabel("Setup progress")
            Text(steps[step]).font(.largeTitle.weight(.semibold))
            Text(stepDescription).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SottoSection(title: step == 4 ? "Optional" : "Preview status") {
                if step == 2 {
                    SottoShortcutHint(keys: "⌥ Space", instruction: "Hold to dictate; double-tap for hands-free.")
                } else if step == 3 {
                    Text("A short practice transcript will appear here.")
                } else {
                    Label(step == 4 ? "Screen Context is off" : "No permissions are requested in this preview", systemImage: step == 4 ? "rectangle.dashed" : "checkmark.shield")
                }
            }
            Spacer(minLength: 0)
            HStack {
                if step > 0 { Button("Back") { step -= 1 } }
                Spacer()
                Button(step == 4 ? "Finish Preview" : "Continue Preview") {
                    if step < 4 { step += 1 } else { simulate("Setup complete") }
                }.sottoPrimaryAction().keyboardShortcut(.defaultAction)
            }
        }
    }

    private var stepDescription: String {
        switch step {
        case 0: return "Sotto listens while you dictate and transcribes on this Mac. First, allow your microphone."
        case 1: return "Accessibility enables automatic paste. Without it, your transcript is copied so you can paste it yourself."
        case 2: return "Use your shortcut in the app where you want your words to appear."
        case 3: return "Try a short sentence. Release the shortcut to finish and review your words."
        default: return "Optionally read on-screen text to improve names and terms. You can enable Screen Context later in Settings."
        }
    }

    private var scratchpad: some View {
        NavigationSplitView {
            List(selection: $selectedNote) {
                Label("Today's ideas", systemImage: "pin").tag("Today's ideas")
                Label("Untitled note", systemImage: "note.text").tag("Untitled note")
            }.navigationSplitViewColumnWidth(min: 140, ideal: 170)
        } detail: {
            VStack(alignment: .leading, spacing: 12) {
                Text(selectedNote).font(.title2.weight(.semibold))
                Label("Sample note · Changes stay in this preview", systemImage: "checkmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $note).font(.body).accessibilityLabel("Note text")
            }.padding(16)
        }
        .toolbar {
            ToolbarItemGroup {
                Button("New Note", systemImage: "square.and.pencil") { selectedNote = "Untitled note"; note = "" }
                Button("Dictate into Note", systemImage: "mic") { simulate("Dictate into Note") }
                Button("Copy Note", systemImage: SottoSymbol.copy.rawValue) { simulate("Copy Note") }
            }
        }
    }

    private func simulate(_ action: String) { notice = "Preview: \(action). No live action performed." }
}

#Preview("Menu Bar · Ready") { SupportingWindowPrototype(surface: .menu, phase: .ready).frame(width: 340) }
#Preview("Menu Bar · Not Ready") { SupportingWindowPrototype(surface: .menu, phase: .missing).frame(width: 340) }
#Preview("Minimal Overlay · Glass") { SupportingWindowPrototype(surface: .capsule).frame(width: 500, height: 340) }
#Preview("Floating Overlay") { SupportingWindowPrototype(surface: .floating).frame(width: 350, height: 300) }
#Preview("Floating · Processing") { SupportingWindowPrototype(surface: .floating, phase: .processing).frame(width: 350, height: 300) }
#Preview("Onboarding") { SupportingWindowPrototype(surface: .onboarding).frame(width: 520, height: 480) }
#Preview("Scratchpad") { SupportingWindowPrototype(surface: .scratchpad).frame(width: 700, height: 500) }
#Preview("Opaque controls · Increased contrast") {
    SupportingWindowPrototype(surface: .capsule)
        .environment(\.sottoAccessibilityPreview, true)
        .frame(width: 500, height: 340)
}
#endif

#if DEBUG
#Preview("Dot listener") { SupportingWindowPrototype(surface: .dot).frame(width: 300, height: 180) }
#endif
