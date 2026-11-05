import AppKit
import AVFoundation
import SwiftUI

/// This adapter reads live state. The renderer and presentation mapping remain service-free.
struct LiveDictationStatusView: View {
    let appState: AppState
    let onNavigate: (SottoRoute) -> Void
    var announcesChanges = false
    var compact = false
    var dashboard = false
    private let manager = TranscriptionEngineManager.shared
    @State private var microphoneAllowed = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    @State private var accessibilityAllowed = AXIsProcessTrusted()

    private var presentation: DictationPresentation {
        let effective = manager.engine(for: manager.effectiveID)
        return .make(recording: appState.recordingState,
                     processingStatus: appState.processingStatus,
                     microphoneAllowed: microphoneAllowed,
                     accessibilityAllowed: accessibilityAllowed,
                     engineName: manager.effectiveID.displayName,
                     enginePhase: effective.phase,
                     progress: effective.progress,
                     fallbackNotice: manager.fallbackNotice,
                     error: appState.lastError,
                     output: appState.dictationFeedback.result)
    }

    var body: some View {
        let state = presentation
        Group {
            if dashboard {
                dashboardStatus(state.primary)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    SottoStatusView(status: state.primary.status, onAction: state.primary.route.map { route in
                        { onNavigate(route) }
                    })
                    if let readiness = state.readiness,
                       !compact || readiness.status.actionTitle != nil {
                        Divider()
                        SottoStatusView(status: readiness.status, onAction: readiness.route.map { route in
                            { onNavigate(route) }
                        })
                    }
                }
            }
        }
        .task {
            // Permission changes made in System Settings aren't Observable. This reads only;
            // it never requests Microphone, Accessibility or Screen Recording permission.
            while !Task.isCancelled {
                microphoneAllowed = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
                accessibilityAllowed = AXIsProcessTrusted()
                do { try await Task.sleep(nanoseconds: 2_000_000_000) }
                catch { return }
            }
        }
        .onChange(of: state.primary.status.title) { _, title in
            guard announcesChanges else { return }
            NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
                .announcement: title,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue
            ])
        }
    }

    private func dashboardStatus(_ item: DictationPresentation.Item) -> some View {
        let status = item.status
        return HStack(spacing: SottoDesign.spacing / 2) {
            Group {
                if status.tone == .ready {
                    Circle()
                        .fill(SottoDesign.accent)
                        .frame(width: 8, height: 8)
                } else {
                    Image(systemName: status.symbol)
                        .foregroundStyle(status.color)
                }
            }
            .frame(width: SottoDesign.spacing)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(status.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(SottoDesign.cream)
                Text(status.detail)
                    .font(.caption)
                    .foregroundStyle(SottoDesign.cream.opacity(0.55))
                    .lineLimit(2)
            }
            Spacer(minLength: SottoDesign.spacing)

            if let actionTitle = status.actionTitle, let route = item.route {
                Button(actionTitle) { onNavigate(route) }
                    .buttonStyle(.borderless)
            } else if status.tone == .ready {
                HStack(spacing: SottoDesign.spacing / 2) {
                    Text("Hold")
                    Text(AppSettings.shared.hotkeyDisplayName)
                        .font(.system(.caption2, design: .monospaced))
                        .padding(.horizontal, SottoDesign.spacing / 4)
                        .background(SottoDesign.cream.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
                    Text("to dictate")
                    Divider().frame(height: SottoDesign.spacing)
                    Text("Double-tap for hands-free")
                }
                .font(.caption)
                .foregroundStyle(SottoDesign.cream.opacity(0.55))
            }
        }
        .sottoSurface()
    }
}

struct DictationPermissionSettings: View {
    @State private var microphone = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var accessibility = AXIsProcessTrusted()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Permissions").font(.headline)
            Text("Microphone access enables recording. Accessibility enables automatic paste; clipboard output is available without it.")
                .font(.callout).foregroundStyle(.secondary)
            Label(microphone == .authorized ? "Microphone: Allowed" : "Microphone: Not allowed",
                  systemImage: microphone == .authorized ? "checkmark.circle.fill" : "mic.slash.fill")
                .foregroundStyle(microphone == .authorized ? Color.primary : .secondary)
            if microphone != .authorized {
                Button("Open Microphone Settings") { open("Privacy_Microphone") }
            }
            Label(accessibility ? "Accessibility: Allowed" : "Accessibility: Not allowed",
                  systemImage: accessibility ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(accessibility ? Color.primary : .secondary)
            if !accessibility {
                Button("Open Accessibility Settings") { open("Privacy_Accessibility") }
            }
        }
        .task {
            while !Task.isCancelled {
                microphone = AVCaptureDevice.authorizationStatus(for: .audio)
                accessibility = AXIsProcessTrusted()
                do { try await Task.sleep(nanoseconds: 2_000_000_000) }
                catch { return }
            }
        }
    }

    private func open(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }
}
