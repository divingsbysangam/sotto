import AppKit
import SwiftUI

/// Always nonactivating, including when the user clicks Cancel or Paste Now.
final class FloatingDictationWindow: NSPanel {
    private let model = FloatingDictationModel()
    private let meter = CapsuleLevel()
    private let presentation = PanelPresentation()
    private var onCancel: (() -> Void)?
    private var onPasteNow: (() -> Void)?

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        hasShadow = true
        isReleasedWhenClosed = false
        contentView = FloatingPanelHostingView(rootView: FloatingDictationView(
            model: model, level: meter,
            onCancel: { [weak self] in
                guard let self, self.model.isPresented else { return }
                self.hide()
                self.onCancel?()
            },
            onPasteNow: { [weak self] in
                guard let self, self.model.isPresented, case .readyToPaste = self.model.state else { return }
                self.hide()
                self.onPasteNow?()
            }
        ))
    }

    func configure(onCancel: @escaping () -> Void, onPasteNow: @escaping () -> Void) {
        self.onCancel = onCancel
        self.onPasteNow = onPasteNow
    }

    func show(state: DictationState, audioLevel: Float = 0) {
        let generation = presentation.renew()
        model.state = state
        meter.value = audioLevel
        model.generation = generation
        model.isPresented = true
        sizeAndPosition()
        orderFront(nil)
        scheduleLayout(for: generation)
    }

    func updateAudioLevel(_ level: Float) { meter.value = level }
    func setModeName(_ name: String?) { model.modeName = name; scheduleLayout(for: presentation.generation) }

    func updateState(_ state: DictationState) {
        guard model.state != state else { return }
        model.state = state
        model.generation = presentation.renew()
        scheduleLayout(for: presentation.generation)
    }

    func hide() {
        model.isPresented = false
        model.generation = presentation.renew()
        orderOut(nil)
    }

    private func scheduleLayout(for generation: UUID) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.presentation.contains(generation), self.model.isPresented else { return }
            self.sizeAndPosition()
        }
    }

    private func sizeAndPosition() {
        if let contentView {
            contentView.layoutSubtreeIfNeeded()
            let size = contentView.fittingSize
            setContentSize(NSSize(width: max(320, size.width), height: max(120, size.height)))
        }
        guard let screen = NSScreen.main else { return }
        setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - frame.width - 20,
                               y: screen.visibleFrame.midY - frame.height / 2))
    }
}

private final class FloatingPanelHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
