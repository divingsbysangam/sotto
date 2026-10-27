import AppKit
import SwiftUI

// MARK: - SwiftUI View

struct CursorIndicatorView: View {
    let isProcessing: Bool

    var body: some View {
        ZStack {
            if isProcessing {
                Image(systemName: "ellipsis").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
            } else {
                Circle().fill(SottoDesign.accent).frame(width: 8, height: 8)
            }
        }
            .frame(width: 24, height: 24)
            .sottoFloatingControls()
            .accessibilityLabel(isProcessing ? "Preparing transcript" : "Listening")
    }
}

// MARK: - NSWindow

final class CursorIndicatorWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    private var isProcessing = false
    private let presentation = PanelPresentation()

    init() {
        let size: CGFloat = 24

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: size, height: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        self.isOpaque = false
        self.backgroundColor = .clear
        self.level = .floating
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        self.ignoresMouseEvents = true
        self.hasShadow = false

        updateContent()
    }

    /// Show at the given screen position (NSWindow bottom-left origin coords).
    /// Applies a small offset so the dot appears just below-right of the text caret.
    func show(at point: NSPoint) {
        presentation.renew()
        isProcessing = false
        updateContent()

        move(to: point)

        alphaValue = 0
        orderFront(nil)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : SottoDesign.feedbackDuration
            self.animator().alphaValue = 1
        }
    }

    func move(to point: NSPoint) {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main else { return }
        setFrameOrigin(RecordingIndicatorPlacement.dotOrigin(at: point, visibleFrame: screen.visibleFrame, size: frame.size))
    }

    func hide() {
        let generation = presentation.renew()
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : SottoDesign.feedbackDuration
            self.animator().alphaValue = 0
        }, completionHandler: {
            guard self.presentation.contains(generation) else { return }
            self.orderOut(nil)
        })
    }

    func setProcessing(_ processing: Bool) {
        isProcessing = processing
        updateContent()
    }

    private func updateContent() {
        let view = CursorIndicatorView(isProcessing: isProcessing)
        if let hostingView = self.contentView as? NSHostingView<CursorIndicatorView> {
            hostingView.rootView = view
        } else {
            self.contentView = NSHostingView(rootView: view)
        }
    }
}
