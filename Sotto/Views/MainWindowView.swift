import SwiftUI

struct MainWindowView: View {
    @Bindable var appState: AppState
    var settings: AppSettings
    var onSave: (() -> Void)?
    @Bindable var navigation: SottoNavigation

    var body: some View {
        NavigationSplitView {
            List(SottoDestination.allCases, id: \.self, selection: $navigation.destination) { tab in
                Label(tab.rawValue, systemImage: tab.symbol.rawValue)
                    .tag(tab)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 150, ideal: 180, max: 220)
        } detail: {
            VStack(spacing: 0) {
                if let fileImport = appState.fileImport {
                    importBanner(fileImport)
                    Divider()
                }
                switch navigation.destination {
                case .dashboard:
                    DashboardView(appState: appState, onNavigate: navigation.open)
                case .transcripts:
                    HistoryTab(appState: appState)
                case .appModes:
                    ModesTab(settings: settings)
                case .vocabulary:
                    VocabularyTab(settings: settings, onSave: onSave)
                case .settings:
                    SettingsTab(settings: settings, onSave: onSave, selectedSection: $navigation.settingsSection)
                case .help:
                    HelpTab(appState: appState)
                }
            }
        }
        .frame(minWidth: 500, minHeight: 400)
        .tint(SottoDesign.accent)
        .groupBoxStyle(SottoGroupBoxStyle())
        // N6: first-run setup (and "Run Setup Again" from Help).
        .sheet(isPresented: $appState.showOnboarding) {
            OnboardingView(appState: appState) {
                appState.showOnboarding = false
            }
            .interactiveDismissDisabled()
        }
        // N13: drop audio/video files anywhere in the window to transcribe them into Transcripts.
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in appState.importFiles([url]) }
                }
            }
            return true
        }
    }

    private func importBanner(_ fileImport: AppState.FileImport) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform")
                .foregroundColor(.accentColor)
            VStack(alignment: .leading, spacing: 4) {
                Text("Transcribing “\(fileImport.fileName)”" + (fileImport.queued > 0 ? " (+\(fileImport.queued) more)" : ""))
                    .font(.callout)
                    .lineLimit(1)
                ProgressView(value: fileImport.progress)
            }
            Button("Cancel") { appState.cancelImport() }
        }
        .padding(10)
        .background(.bar)
    }
}
