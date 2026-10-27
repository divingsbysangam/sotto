import SwiftUI

private struct SottoAccessibilityPreviewKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Preview-only simulation of our custom treatments; never changes system settings.
    var sottoAccessibilityPreview: Bool {
        get { self[SottoAccessibilityPreviewKey.self] }
        set { self[SottoAccessibilityPreviewKey.self] = newValue }
    }
}

/// Service-free building blocks shared by the redesign previews and future live adapters.
enum SottoDesign {
    static let accent = Color.teal
    static let spacing: CGFloat = 16
    static let cornerRadius: CGFloat = 12
    static let feedbackDuration = 0.15
    static let contentDuration = 0.2
}

struct SottoGroupBoxStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            configuration.label.font(.headline)
            configuration.content
        }
        .sottoSurface()
    }
}

struct SottoEditorStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .padding(8)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.25)))
    }
}

enum SottoSymbol: String {
    case dashboard = "square.grid.2x2"
    case transcripts = "doc.text"
    case appModes = "app.badge.checkmark"
    case vocabulary = "textformat.abc"
    case settings = "gearshape"
    case help = "questionmark.circle"
    case copy = "doc.on.doc"
    case details = "info.circle"
    case more = "ellipsis"
    case retry = "arrow.clockwise"
    case close = "xmark"
    case scratchpad = "note.text"

    var label: String {
        switch self {
        case .dashboard: return "Dashboard"
        case .transcripts: return "Transcripts"
        case .appModes: return "App Modes"
        case .vocabulary: return "Vocabulary"
        case .settings: return "Settings"
        case .help: return "Help"
        case .copy: return "Copy"
        case .details: return "Details"
        case .more: return "More actions"
        case .retry: return "Retry"
        case .close: return "Dismiss"
        case .scratchpad: return "Scratchpad"
        }
    }
}

/// A rendering input, not a readiness calculation. Live state mapping belongs in phase 2.
struct SottoStatusPresentation {
    enum Tone { case neutral, ready, attention, recording }
    let title: String
    let detail: String
    let symbol: String
    var tone: Tone = .neutral
    var progress: Double? = nil
    var actionTitle: String? = nil

    var color: Color {
        switch tone {
        case .neutral: return .secondary
        case .ready: return SottoDesign.accent
        case .attention: return .orange
        case .recording: return .red
        }
    }
}

struct SottoSurface: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.sottoAccessibilityPreview) private var accessibilityPreview

    func body(content: Content) -> some View {
        content
            .padding(SottoDesign.spacing)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Reading surfaces are opaque in every accessibility setting.
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: SottoDesign.cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: SottoDesign.cornerRadius)
                    .strokeBorder(Color.primary.opacity(contrast == .increased || accessibilityPreview ? 0.4 : 0.1))
            }
    }
}

extension View {
    func sottoSurface() -> some View { modifier(SottoSurface()) }
    func sottoFloatingControls() -> some View { modifier(SottoFloatingControls()) }
    func sottoPrimaryAction() -> some View { modifier(SottoPrimaryAction()) }
    func sottoEditor() -> some View { modifier(SottoEditorStyle()) }
}

/// Glass belongs to floating controls, rather than transcript reading surfaces.
/// https://developer.apple.com/documentation/SwiftUI/Applying-Liquid-Glass-to-custom-views
private struct SottoFloatingControls: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.sottoAccessibilityPreview) private var accessibilityPreview

    @ViewBuilder func body(content: Content) -> some View {
        if reduceTransparency || contrast == .increased || accessibilityPreview {
            content.background(Color(nsColor: .windowBackgroundColor), in: Capsule())
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.4)))
        } else if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: Capsule())
        } else {
            content.background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.15)))
        }
    }
}

private struct SottoPrimaryAction: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.sottoAccessibilityPreview) private var accessibilityPreview

    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26.0, *), !reduceTransparency, !accessibilityPreview {
            content.buttonStyle(.glassProminent)
        } else {
            content.buttonStyle(.borderedProminent)
        }
    }
}

/// Coordinates the two separate floating controls without merging them at rest.
struct SottoGlassControlGroup<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 16) { content() }
        } else {
            content()
        }
    }
}

struct SottoIconButton: View {
    let symbol: SottoSymbol
    var label: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(label ?? symbol.label, systemImage: symbol.rawValue)
                .labelStyle(.iconOnly)
                .frame(minWidth: 24, minHeight: 24)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(label ?? symbol.label)
        .help(label ?? symbol.label)
    }
}

struct SottoStatusView: View {
    let status: SottoStatusPresentation
    var onAction: (() -> Void)? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.sottoAccessibilityPreview) private var accessibilityPreview

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: status.symbol)
                    .font(.title2)
                    .foregroundStyle(status.color)
                    .frame(width: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(status.title).font(.headline)
                    Text(status.detail).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            if let progress = status.progress {
                ProgressView(value: progress)
                    .accessibilityLabel(status.title)
            }
            if let title = status.actionTitle, let onAction {
                Button(title, action: onAction)
            }
        }
        .animation(reduceMotion || accessibilityPreview ? nil : .easeInOut(duration: SottoDesign.feedbackDuration), value: status.title)
    }
}

struct SottoSection<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    var actionTitle: String? = nil
    var onAction: (() -> Void)? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline).accessibilityAddTraits(.isHeader)
                    if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 8)
                if let actionTitle, let onAction { Button(actionTitle, action: onAction).buttonStyle(.link) }
            }
            content()
        }
        .sottoSurface()
    }
}

struct SottoEmptyState: View {
    let symbol: SottoSymbol
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol.rawValue).font(.largeTitle).foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(title).font(.headline)
            Text(detail).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, minHeight: 140)
    }
}

struct SottoShortcutHint: View {
    let keys: String
    let instruction: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(keys).font(.system(.callout, design: .monospaced).weight(.semibold))
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))
            Text(instruction).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

struct SottoTranscriptPresentation: Identifiable {
    let id: String
    let text: String
    let source: String
    let metadata: String
    var failure: String? = nil
    var canRetry = false
}

struct SottoTranscriptRow: View {
    let transcript: SottoTranscriptPresentation
    let onCopy: () -> Void
    let onDetails: () -> Void
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(transcript.text).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
            ViewThatFits(in: .horizontal) {
                HStack { metadata; Spacer(); actions }
                VStack(alignment: .leading, spacing: 8) { metadata; actions }
            }
            if let failure = transcript.failure {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
    }

    private var metadata: some View {
        Text("\(transcript.source) · \(transcript.metadata)")
            .font(.caption).foregroundStyle(.secondary)
    }

    private var actions: some View {
        HStack(spacing: 12) {
            if transcript.canRetry { Button("Retry", action: onRetry) }
            SottoIconButton(symbol: .copy, label: "Copy transcript", action: onCopy)
                .disabled(transcript.failure != nil)
            SottoIconButton(symbol: .details, label: "Transcript details", action: onDetails)
        }
    }
}
