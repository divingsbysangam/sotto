import Observation

enum SottoDestination: String, CaseIterable, Identifiable {
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

enum SettingsSection: String, CaseIterable {
    case general = "General", transcription = "Transcription", system = "System"
}

enum SottoRoute: Equatable {
    case destination(SottoDestination)
    case settings(SettingsSection)
}

/// Shared by the main window and menu bar, including requests made before the window opens.
@Observable
final class SottoNavigation {
    var destination: SottoDestination = .dashboard
    var settingsSection: SettingsSection = .general

    func open(_ route: SottoRoute) {
        switch route {
        case .destination(let destination): self.destination = destination
        case .settings(let section):
            settingsSection = section
            destination = .settings
        }
    }
}
