import SwiftUI
import AVFoundation
import Sparkle
import ServiceManagement

// Shared manager to allow AppDelegate to open windows and access updater
class WindowManager {
    static let shared = WindowManager()
    var openMainWindow: (() -> Void)?
    let navigation = SottoNavigation()

    // Sparkle updater controller for auto-updates
    let updaterController = SPUStandardUpdaterController(
        startingUpdater: ProcessInfo.processInfo.environment["SOTTO_TESTING"] != "1",
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    func openAppropriateWindow(route: SottoRoute? = nil) {
        if let route { navigation.open(route) }
        openMainWindow?()
    }
}

// App delegate to handle Dock icon clicks and app lifecycle
class SottoAppDelegate: NSObject, NSApplicationDelegate {
    /// Files dropped on the Dock icon / Open With (N13) and sotto:// links (N15).
    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in
            guard let appState = AppState.current else { return }
            let links = urls.filter { $0.scheme?.lowercased() == "sotto" }
            for link in links {
                appState.handleURL(link)
            }
            appState.importFiles(urls.filter(\.isFileURL))
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if ProcessInfo.processInfo.environment["SOTTO_TESTING"] == "1" { return }
        TypingCounterService.shared.flush()
        NotesManager.shared.flush()
        // L6: waiting agent hooks give up at once instead of at their timeout.
        try? FileManager.default.removeItem(at: AgentRelay.aliveFile)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // When Dock icon is clicked, show the main window
        WindowManager.shared.openAppropriateWindow()
        return false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if ProcessInfo.processInfo.environment["SOTTO_TESTING"] == "1" { return }
        // Services menu: "Add to Sotto Vocabulary" (NSServices in project.yml).
        NSApp.servicesProvider = VocabularyServiceProvider.shared
        NSUpdateDynamicServices()

        // Apply dock icon visibility setting on launch
        let settings = AppSettings.shared
        if settings.showDockIcon {
            NSApp.setActivationPolicy(.regular)
        } else {
            NSApp.setActivationPolicy(.accessory)
        }

        // Sync launch at login state (in case it was changed externally)
        if #available(macOS 13.0, *) {
            let currentStatus = SMAppService.mainApp.status
            let shouldLaunchAtLogin = settings.launchAtLogin

            // Only update if there's a mismatch
            if shouldLaunchAtLogin && currentStatus != .enabled {
                do {
                    try SMAppService.mainApp.register()
                } catch {
                    print("Failed to register launch at login: \(error)")
                }
            } else if !shouldLaunchAtLogin && currentStatus == .enabled {
                do {
                    try SMAppService.mainApp.unregister()
                } catch {
                    print("Failed to unregister launch at login: \(error)")
                }
            }
        }
    }
}

@main
struct SottoApp: App {
    @NSApplicationDelegateAdaptor(SottoAppDelegate.self) var appDelegate
    @State private var appState = AppState()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        // Main window (local-only: no auth gate)
        Window("Sotto", id: "main") {
            MainWindowView(
                appState: appState,
                settings: AppSettings.shared,
                onSave: {
                    appState.refreshHotkey()
                },
                navigation: WindowManager.shared.navigation
            )
            .task {
                // Store window action for AppDelegate / menu bar to use
                WindowManager.shared.openMainWindow = { [openWindow] in
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        .windowResizability(.automatic)
        .defaultPosition(.center)
        .defaultSize(width: 700, height: 500)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Import Audio or Video…") {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = FileTranscriber.contentTypes
                    panel.allowsMultipleSelection = true
                    panel.message = "Choose recordings to transcribe into Transcripts"
                    if panel.runModal() == .OK {
                        appState.importFiles(panel.urls)
                    }
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])
            }
        }

        // Menu bar extra (always visible)
        MenuBarExtra {
            MenuBarView(
                appState: appState,
                onOpenSettings: {
                    WindowManager.shared.openAppropriateWindow()
                },
                onOpenHistory: {
                    WindowManager.shared.openAppropriateWindow(route: .destination(.transcripts))
                },
                onNavigate: { route in
                    WindowManager.shared.openAppropriateWindow(route: route)
                }
            )
            .task {
                // Store window action from menu bar context
                WindowManager.shared.openMainWindow = { [openWindow] in
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
        } label: {
            Text("S")
                .font(.system(size: 14, weight: menuBarFontWeight, design: .serif))
                .italic()
        }
        .menuBarExtraStyle(.window)
    }

    private var menuBarFontWeight: Font.Weight {
        switch appState.recordingState {
        case .idle:
            return .medium
        case .recording:
            return .bold
        case .processing:
            return .medium
        }
    }
}
