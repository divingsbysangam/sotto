import SwiftUI

struct SpeechEngineSettings: View {
    private let manager = TranscriptionEngineManager.shared

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text("Whisper Turbo").font(.headline)
                Text("Speech recognition runs on this Mac. Sotto downloads the Whisper model on first use and works offline afterward.")
                    .font(.caption).foregroundStyle(.secondary)
                let engine = manager.selectedEngine
                modelStatus(engine)
                if engine.verified {
                    Label("Verified against pinned checksums", systemImage: "checkmark.seal.fill")
                        .font(.caption).foregroundStyle(SottoDesign.accent)
                }
                if let error = manager.maintenanceError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
        }
    }

    @ViewBuilder private func modelStatus(_ engine: any TranscriptionEngine) -> some View {
        switch engine.phase {
        case .ready:
            Label("Model ready", systemImage: "checkmark.circle.fill").foregroundStyle(SottoDesign.accent)
        case .notInstalled:
            Text("Model not downloaded").font(.caption)
        case .downloading:
            ProgressView(value: engine.progress)
            Text(engine.statusMessage).font(.caption)
        case .loading, .verifying:
            HStack { ProgressView().controlSize(.small); Text(engine.statusMessage).font(.caption) }
        case .idle:
            Button("Load Model") { Task { await manager.prepare() } }
                .disabled(manager.operationCount > 0)
        case .failed(let message):
            Text(message).font(.caption).foregroundStyle(.red)
            Button("Retry") { Task { await manager.prepare(retry: true) } }
                .disabled(manager.operationCount > 0)
        }
    }
}
