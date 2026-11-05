import AppKit
import AVFoundation
import SwiftUI

struct MainWindowView: View {
    @Bindable var appState: AppState
    var settings: AppSettings
    var onSave: (() -> Void)?
    @Bindable var navigation: SottoNavigation
    @State private var microphoneAllowed = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    @State private var accessibilityAllowed = AXIsProcessTrusted()
    @State private var enginePhase = TranscriptionEngineManager.shared.engine.phase

    private var dictationStatus: SottoStatusPresentation {
        let manager = TranscriptionEngineManager.shared
        return DictationPresentation.make(recording: appState.recordingState,
                                         processingStatus: appState.processingStatus,
                                         microphoneAllowed: microphoneAllowed,
                                         accessibilityAllowed: accessibilityAllowed,
                                         engineName: manager.effectiveID.displayName,
                                         enginePhase: enginePhase,
                                         progress: manager.engine.progress,
                                         fallbackNotice: manager.fallbackNotice,
                                         error: appState.lastError,
                                         output: appState.dictationFeedback.result).primary.status
    }

    var body: some View {
        VStack(spacing: 0) {
            SottoTopNavigation(navigation: navigation, status: dictationStatus)
                .padding(.horizontal, SottoDesign.spacing)
                .padding(.vertical, SottoDesign.spacing / 2)

            if let fileImport = appState.fileImport {
                importBanner(fileImport)
                    .padding(.horizontal, SottoDesign.spacing)
            }

            destinationView
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            SottoWindowFooter(modelLoaded: enginePhase == .ready)
                .padding(.horizontal, SottoDesign.spacing * 1.5)
                .padding(.vertical, SottoDesign.spacing / 2)
        }
        .frame(minWidth: 700, minHeight: 500)
        .background(SottoDesign.charcoal)
        .tint(SottoDesign.accent)
        .groupBoxStyle(SottoGroupBoxStyle())
        .task {
            // Permissions and the speech engine do not all publish observable changes.
            while !Task.isCancelled {
                microphoneAllowed = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
                accessibilityAllowed = AXIsProcessTrusted()
                enginePhase = TranscriptionEngineManager.shared.engine.phase
                do { try await Task.sleep(nanoseconds: 2_000_000_000) }
                catch { return }
            }
        }
        .sheet(isPresented: $appState.showOnboarding) {
            OnboardingView(appState: appState) {
                appState.showOnboarding = false
            }
            .interactiveDismissDisabled()
        }
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

    @ViewBuilder private var destinationView: some View {
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

    private func importBanner(_ fileImport: AppState.FileImport) -> some View {
        HStack(spacing: SottoDesign.spacing / 2) {
            Image(systemName: "waveform")
                .foregroundStyle(SottoDesign.accent)
            VStack(alignment: .leading, spacing: SottoDesign.spacing / 4) {
                Text("Transcribing “\(fileImport.fileName)”" + (fileImport.queued > 0 ? " (+\(fileImport.queued) more)" : ""))
                    .font(.callout)
                    .lineLimit(1)
                ProgressView(value: fileImport.progress)
            }
            Button("Cancel") { appState.cancelImport() }
        }
        .sottoSurface()
    }
}
