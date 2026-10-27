import AppKit
import SwiftUI

// MARK: - Prompts

/// A clickable capsule state: an icon, a short message, and buttons (e.g. "Cancelled · Undo",
/// L2 "Add “Kubernetes” to Vocabulary?"). The panel takes clicks only while a prompt is up and
/// never activates Sotto, so focus stays in the user's app.
struct CapsulePrompt {
    struct Action {
        let title: String
        var isPrimary = true
        let handler: () -> Void
    }

    var icon: String
    var iconColor: Color = .secondary
    var text: String
    var actions: [Action]
    /// Adds an × button that calls this.
    var onDismiss: (() -> Void)? = nil
}

/// The audio level alone, so the 20 Hz meter updates don't rebuild the whole capsule.
final class CapsuleLevel: ObservableObject {
    @Published var value: Float = 0
    init(value: Float = 0) { self.value = value }
}

// MARK: - SwiftUI View

struct NotchCapsuleView: View {
    let level: CapsuleLevel
    let isProcessing: Bool
    var statusText = ""
    var prompt: CapsulePrompt? = nil
    var contextCaptured = false
    var modeName: String? = nil
    var liveText: String? = nil

    private var status: SottoStatusPresentation {
        RecordingOverlayStatus.make(isProcessing: isProcessing, message: statusText)
    }

    var body: some View {
        SottoGlassControlGroup {
            VStack(spacing: 8) {
                if let prompt {
                    HStack(spacing: 12) {
                        Image(systemName: prompt.icon).foregroundStyle(prompt.iconColor).accessibilityHidden(true)
                        Text(prompt.text).font(.callout).lineLimit(2).frame(maxWidth: 360, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                        ForEach(prompt.actions.indices, id: \.self) { index in
                            Button(prompt.actions[index].title, action: prompt.actions[index].handler)
                                .foregroundStyle(prompt.actions[index].isPrimary ? SottoDesign.accent : .primary)
                        }
                        if let dismiss = prompt.onDismiss {
                            SottoIconButton(symbol: .close, action: dismiss)
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .sottoFloatingControls()
                } else {
                    HStack(spacing: 12) {
                        Label(status.title, systemImage: status.symbol)
                            .font(.callout.weight(.medium)).foregroundStyle(status.color).lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        if !isProcessing { CapsuleAudioMeter(level: level) }
                        if let modeName, !isProcessing {
                            Text(modeName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        if contextCaptured, !isProcessing {
                            Image(systemName: "text.quote").foregroundStyle(SottoDesign.accent)
                                .accessibilityLabel("Using selected or copied text as context")
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .sottoFloatingControls()
                    if let liveText, !liveText.isEmpty, !isProcessing {
                        Text(liveText).font(.callout).lineLimit(2).truncationMode(.head)
                            .frame(width: 340, alignment: .leading).sottoSurface()
                    }
                }
            }
        }
        .tint(SottoDesign.accent)
        .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
        .fixedSize()
    }
}

// MARK: - NSWindow

final class NotchCapsuleWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    private var isProcessing = false
    private let meter = CapsuleLevel()
    private var statusText: String = ""
    private var prompt: CapsulePrompt?
    private var contextCaptured = false
    private var modeName: String?
    private var liveText: String?
    private var hostingView: FirstClickHostingView<AnyView>?
    private var preferredScreen: NSScreen?
    // Bumped on every show/hide so a finished hide animation doesn't order out a newer notice.
    private let presentation = PanelPresentation()

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        self.isOpaque = false
        self.backgroundColor = .clear
        self.level = .statusBar
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        self.ignoresMouseEvents = true
        self.hasShadow = false
        self.isMovableByWindowBackground = false

        updateContent()
        sizeToFitContent()
        positionAtBottom()
    }

    private func sizeToFitContent() {
        guard let hostingView = self.contentView else { return }
        let fittingSize = hostingView.fittingSize
        // Add generous padding for shadows
        let windowSize = NSSize(width: fittingSize.width + 50, height: fittingSize.height + 50)
        let currentOrigin = frame.origin
        setFrame(NSRect(origin: currentOrigin, size: windowSize), display: true)
    }

    private func positionAtBottom() {
        guard let screen = preferredScreen ?? NSScreen.main else { return }
        setFrameOrigin(RecordingIndicatorPlacement.bottomOrigin(in: screen.visibleFrame, size: frame.size))
    }

    func show(on screen: NSScreen? = nil) {
        preferredScreen = screen
        presentation.renew()
        contextCaptured = false
        modeName = nil
        liveText = nil
        isProcessing = false
        meter.value = 0
        statusText = ""
        setPrompt(nil)
        updateContent()
        sizeToFitContent()
        positionAtBottom()

        // Slide up from below
        let targetOrigin = frame.origin
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if !reduceMotion { setFrameOrigin(NSPoint(x: targetOrigin.x, y: targetOrigin.y - 12)) }
        alphaValue = 0
        orderFront(nil)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduceMotion ? 0 : SottoDesign.contentDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.animator().setFrameOrigin(targetOrigin)
            self.animator().alphaValue = 1
        }
    }

    func hide() {
        let hidingPresentation = presentation.renew()
        ignoresMouseEvents = true
        let currentOrigin = frame.origin
        NSAnimationContext.runAnimationGroup({ context in
            let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            context.duration = reduceMotion ? 0 : SottoDesign.contentDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            if !reduceMotion { self.animator().setFrameOrigin(NSPoint(x: currentOrigin.x, y: currentOrigin.y - 12)) }
            self.animator().alphaValue = 0
        }, completionHandler: {
            guard self.presentation.contains(hidingPresentation) else { return }
            self.prompt = nil
            self.orderOut(nil)
        })
    }

    /// "Cancelled · Undo" in place of the dictation capsule.
    func showUndo(onUndo: @escaping () -> Void) {
        showPrompt(CapsulePrompt(
            icon: "xmark.circle.fill",
            text: "Cancelled",
            actions: [.init(title: "Undo", handler: onUndo)]
        ))
    }

    /// A clickable state in place of the dictation capsule. The panel takes clicks only while
    /// it's up; it never activates Sotto, so focus stays in the user's app.
    func showPrompt(_ prompt: CapsulePrompt) {
        presentation.renew()
        isProcessing = false
        meter.value = 0
        statusText = ""
        liveText = nil
        setPrompt(prompt)
        updateContent()
        sizeToFitContent()
        positionAtBottom()
        alphaValue = 1
        orderFront(nil)
    }

    /// A prompt is showing (so a notice or a new recording shouldn't silently replace it).
    var isShowingPrompt: Bool { prompt != nil && isVisible }

    /// L1: the live preview under the recording row; nil hides it.
    func setLiveText(_ text: String?) {
        guard liveText != text else { return }
        liveText = text
        updateContent()
        sizeToFitContent()
        positionAtBottom()
    }

    func setModeName(_ name: String?) {
        guard modeName != name else { return }
        modeName = name
        updateContent()
        sizeToFitContent()
        positionAtBottom()
    }

    func setContextCaptured(_ captured: Bool) {
        guard contextCaptured != captured else { return }
        contextCaptured = captured
        updateContent()
        sizeToFitContent()
        positionAtBottom()
    }

    private func setPrompt(_ prompt: CapsulePrompt?) {
        self.prompt = prompt
        ignoresMouseEvents = prompt == nil
    }

    /// Only the meter redraws; the rest of the capsule is left alone.
    func updateAudioLevel(_ value: Float) {
        meter.value = value
    }

    func setProcessing(_ processing: Bool, status: String = "") {
        setPrompt(nil)
        isProcessing = processing
        meter.value = 0
        statusText = status
        if processing { liveText = nil }
        updateContent()
        sizeToFitContent()
        positionAtBottom()
    }

    /// Swaps the root view in place (no new hosting view), so `fittingSize` is current for
    /// the resize that follows.
    private func updateContent() {
        let swiftUIView = AnyView(NotchCapsuleView(
            level: meter,
            isProcessing: isProcessing,
            statusText: statusText,
            prompt: prompt,
            contextCaptured: contextCaptured,
            modeName: modeName,
            liveText: liveText
        )
        .fixedSize())

        if let hostingView {
            hostingView.rootView = swiftUIView
        } else {
            let hostingView = FirstClickHostingView(rootView: swiftUIView)
            hostingView.wantsLayer = true
            hostingView.layer?.backgroundColor = .clear
            self.contentView = hostingView
            self.hostingView = hostingView
        }
    }
}

/// The panel is never key, so without this the first click on Undo would be swallowed.
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
