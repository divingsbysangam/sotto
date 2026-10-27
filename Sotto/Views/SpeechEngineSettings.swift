import SwiftUI

struct SpeechEngineSettings: View {
    var languageMode: DictationLanguageMode
    private let manager = TranscriptionEngineManager.shared
    private var effectiveID: SpeechEngineID {
        SpeechEngineID.effective(selected: manager.selectedID, languageMode: languageMode)
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text("Local Speech Engine").font(.headline)
                Picker("Engine", selection: Binding(get: { manager.selectedID }, set: { manager.select($0) })) {
                    ForEach(SpeechEngineID.allCases) { id in Text(id.displayName).tag(id) }
                }
                Text("Speech stays on this Mac. Optional models download only when you choose Download; recognition then works offline.")
                    .font(.caption).foregroundStyle(.secondary)
                if effectiveID != manager.selectedID {
                    Label("Using Whisper Turbo for automatic language detection and non-English dictation.", systemImage: "info.circle").font(.caption)
                }
                if manager.operationCount > 0 {
                    Text("Current work keeps its starting engine. Changes and removal take effect after it finishes.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if manager.selectedID == .cohere {
                    Text(ProcessInfo.processInfo.physicalMemory <= 16 * 1_073_741_824
                         ? "Cohere uses about 2.5 GB while loaded. On this Mac, close memory-heavy apps before loading it. Accuracy varies with your recording."
                         : "Cohere uses about 2.5 GB while loaded. Accuracy varies with your recording.")
                        .font(.caption).foregroundStyle(.orange)
                }
                let engine = manager.selectedEngine
                modelStatus(engine)
                if engine.verified {
                    Label("Verified against pinned checksums", systemImage: "checkmark.seal.fill")
                        .font(.caption).foregroundStyle(.green)
                }
                if let optional = engine as? OptionalSpeechEngine {
                    HStack {
                        if engine.phase == .downloading {
                            Button("Cancel Download") { optional.cancelDownload() }
                        } else {
                            Button(engine.phase == .notInstalled ? "Download" : "Verify / Repair Download") { optional.download() }
                                .disabled(engine.isReady || engine.phase == .loading || engine.phase == .verifying)
                            if SpeechModelStore.isInstalled(engine.id) {
                                Button("Remove Model", role: .destructive) { manager.requestRemoval(engine.id) }
                                    .disabled(manager.removalPending(engine.id))
                            }
                        }
                    }
                    if manager.removalPending(engine.id) {
                        Text("Removal queued until current work finishes.").font(.caption)
                    }
                }
                if let error = manager.maintenanceError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                Text("Language detection, non-English speech and translation fall back to Whisper Turbo. Live preview is available with Whisper; your preference is retained when using another engine.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private func modelStatus(_ engine: any TranscriptionEngine) -> some View {
        switch engine.phase {
        case .ready:
            Label("Model ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .notInstalled:
            Text("Model not downloaded").font(.caption)
        case .downloading:
            ProgressView(value: engine.progress)
            Text(engine.statusMessage).font(.caption)
        case .loading, .verifying:
            HStack { ProgressView().controlSize(.small); Text(engine.statusMessage).font(.caption) }
        case .idle:
            Button("Load Model") { Task { await manager.prepare() } }
                .disabled(manager.operationCount > 0 || effectiveID != engine.id)
        case .failed(let message):
            Text(message).font(.caption).foregroundStyle(.red)
            Button("Retry") { Task { await manager.prepare(retry: true) } }
                .disabled(manager.operationCount > 0 || effectiveID != engine.id)
        }
    }
}
