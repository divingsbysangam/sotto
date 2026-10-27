import AppKit
import SwiftUI

/// Standalone preview host. Compiled with only service-free design and overlay files.
/// It cannot load Sotto's app lifecycle, recording services, settings or history.
@main
@MainActor
final class RedesignPreviewHost: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var previewWindows: [NSWindow] = []

    static func main() {
        let app = NSApplication.shared
        let delegate = RedesignPreviewHost()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
        withExtendedLifetime(delegate) {}
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let index = CommandLine.arguments.firstIndex(of: "--snapshots"),
           CommandLine.arguments.count > index + 1 {
            let directory = URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
            Task { await snapshots(in: directory) }
        } else {
            let rawSurface = argument("--surface")
            let view: AnyView
            let size: NSSize
            if let surface = SupportingWindowPrototype.Surface.allCases.first(where: { $0.rawValue == rawSurface }) {
                view = AnyView(SupportingWindowPrototype(surface: surface))
                size = surface == .dot ? NSSize(width: 300, height: 180) : NSSize(width: 520, height: 500)
            } else {
                view = AnyView(RedesignPrototype())
                size = NSSize(width: 900, height: 680)
            }
            show(view, size: size, dark: CommandLine.arguments.contains("--dark"))
        }
    }

    private func argument(_ name: String) -> String? {
        guard let index = CommandLine.arguments.firstIndex(of: name), CommandLine.arguments.count > index + 1 else { return nil }
        return CommandLine.arguments[index + 1]
    }

    private func show(_ view: AnyView, size: NSSize, dark: Bool) {
        window?.orderOut(nil)
        let host = NSHostingController(rootView: view.preferredColorScheme(dark ? .dark : .light))
        host.sizingOptions = []
        let next = NSWindow(contentRect: .init(origin: .zero, size: size), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        next.contentViewController = host
        next.title = "Sotto · Design Preview · Synthetic Data"
        next.animationBehavior = .none
        next.toolbarStyle = .unifiedCompact
        if CommandLine.arguments.contains("--snapshots") {
            // Keep our own capture window out of the desktop's app-switching thumbnails.
            next.level = .floating
            next.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        }
        next.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        next.setContentSize(size)
        next.center()
        next.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        next.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = next
        // Retain earlier snapshot windows until capture finishes, avoiding close-triggered
        // application termination while also keeping each native toolbar independent.
        previewWindows.append(next)
    }

    private func snapshots(in directory: URL) async {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let examples: [(String, AnyView, NSSize, Bool)] = [
                ("dashboard-light-700", AnyView(RedesignPrototype()), .init(width: 700, height: 500), false),
                ("dashboard-dark-1100", AnyView(RedesignPrototype()), .init(width: 1100, height: 750), true),
                ("dashboard-narrow-500", AnyView(RedesignPrototype(phase: .microphone)), .init(width: 500, height: 400), false),
                ("transcripts-light", AnyView(RedesignPrototype(destination: .transcripts)), .init(width: 700, height: 500), false),
                ("transcripts-empty", AnyView(RedesignPrototype(destination: .transcripts, emptyHistory: true)), .init(width: 700, height: 500), true),
                ("transcripts-no-results", AnyView(RedesignPrototype(destination: .transcripts, search: "unmatched example")), .init(width: 500, height: 400), false),
                ("speech-settings-failed", AnyView(RedesignPrototype(destination: .settings, phase: .failed)), .init(width: 700, height: 500), false),
                ("speech-settings-downloading", AnyView(RedesignPrototype(destination: .settings, phase: .downloading)), .init(width: 700, height: 500), true),
                ("dashboard-accessibility", accessible(AnyView(RedesignPrototype(phase: .downloading))), .init(width: 700, height: 500), false),
                ("menu-ready", AnyView(SupportingWindowPrototype(surface: .menu, phase: .ready)), .init(width: 360, height: 640), false),
                ("menu-model-missing", AnyView(SupportingWindowPrototype(surface: .menu, phase: .missing)), .init(width: 360, height: 690), true),
                ("overlay-glass", AnyView(SupportingWindowPrototype(surface: .capsule)), .init(width: 500, height: 340), true),
                ("listener-dot", AnyView(SupportingWindowPrototype(surface: .dot)), .init(width: 300, height: 180), false),
                ("overlay-accessibility", accessible(AnyView(SupportingWindowPrototype(surface: .capsule))), .init(width: 500, height: 340), false),
                ("overlay-floating", AnyView(SupportingWindowPrototype(surface: .floating)), .init(width: 360, height: 340), false),
                ("onboarding", AnyView(SupportingWindowPrototype(surface: .onboarding)), .init(width: 520, height: 480), false),
                ("scratchpad", AnyView(SupportingWindowPrototype(surface: .scratchpad)), .init(width: 700, height: 500), true)
            ]
            for (name, view, size, dark) in examples {
                show(view, size: size, dark: dark)
                try await Task.sleep(nanoseconds: 1_500_000_000)
                guard let window else { continue }
                // Render only our own view tree; never request Screen Recording for a preview.
                // Window Server glass/vibrancy may be absent from these layout images.
                guard let view = window.contentView,
                      let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                    throw NSError(domain: "RedesignPreview", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not render preview view: \(name)"])
                }
                view.layoutSubtreeIfNeeded()
                view.cacheDisplay(in: view.bounds, to: bitmap)
                guard let png = bitmap.representation(using: .png, properties: [:]) else {
                    throw NSError(domain: "RedesignPreview", code: 2)
                }
                try png.write(to: directory.appendingPathComponent(name + ".png"))
                print("Rendered \(name)")
            }
            NSApp.terminate(nil)
        } catch {
            fputs("Preview capture failed: \(error)\n", stderr)
            exit(1)
        }
    }

    private func accessible(_ view: AnyView) -> AnyView {
        AnyView(view.environment(\.sottoAccessibilityPreview, true))
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
