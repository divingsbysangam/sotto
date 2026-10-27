import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// L9: Import… / Export All… for the App Modes footer.
struct ModeImportExportButtons: View {
    var settings: AppSettings
    /// Called after an import changed the saved modes.
    let onImported: () -> Void

    @State private var preview: [ModeTransferService.PreviewItem]?
    @State private var previewSource = ""
    @State private var errorMessage: String?

    var body: some View {
        HStack {
            Button("Import…") { importModes() }
                .font(.caption)
            Button("Export All…") { ModeExport.run(settings.appModes) { errorMessage = $0 } }
                .font(.caption)
        }
        .sheet(isPresented: Binding(get: { preview != nil }, set: { if !$0 { preview = nil } })) {
            if let preview {
                ModeImportSheet(source: previewSource, items: preview) { chosen in
                    if !chosen.isEmpty {
                        settings.appModes = ModeTransferService.apply(chosen, to: settings.appModes)
                        onImported()
                    }
                    self.preview = nil
                }
            }
        }
        .alert("Import Failed", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func importModes() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let modes = try ModeTransferService.load(from: url)
            previewSource = url.lastPathComponent
            preview = ModeTransferService.preview(modes, against: settings.appModes)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

enum ModeExport {
    /// Asks where to save and writes `modes`; `onError` gets a message on failure.
    static func run(_ modes: [AppMode], onError: (String) -> Void) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = ModeTransferService.suggestedFileName(for: modes)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try ModeTransferService.export(modes, to: url)
        } catch {
            onError(error.localizedDescription)
        }
    }
}

/// Preview before importing: new and changed modes are checked; identical ones aren't.
private struct ModeImportSheet: View {
    let source: String
    let items: [ModeTransferService.PreviewItem]
    let onDone: ([ModeTransferService.PreviewItem]) -> Void
    @State private var selected: Set<UUID> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import App Modes from \(source)")
                .font(.headline)
            Text("Modes are added after yours, so your existing modes keep matching first. Only instructions, examples, and matches are read; imported files can't run anything.")
                .font(.caption)
                .foregroundColor(.secondary)

            List(items) { item in
                Toggle(isOn: Binding(
                    get: { selected.contains(item.id) },
                    set: { if $0 { selected.insert(item.id) } else { selected.remove(item.id) } }
                )) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.mode.name)
                            Text(summary(item.mode))
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        status(item.status)
                    }
                }
            }
            .frame(minHeight: 220)

            HStack {
                Button("Cancel") { onDone([]) }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Import \(selected.count) Mode\(selected.count == 1 ? "" : "s")") {
                    onDone(items.filter { selected.contains($0.id) })
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selected.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear { selected = Set(items.filter(\.isCheckedByDefault).map(\.id)) }
    }

    private func summary(_ mode: ModeTransferService.ExportedMode) -> String {
        let matches = mode.matchedApps + mode.matchedWebsites
        return matches.isEmpty ? "No matches" : matches.joined(separator: ", ")
    }

    @ViewBuilder
    private func status(_ status: ModeTransferService.PreviewItem.Status) -> some View {
        switch status {
        case .new:
            EmptyView()
        case .identical:
            Text("Already added").font(.caption).foregroundColor(.secondary)
        case .replaces:
            Text("Replaces yours").font(.caption).foregroundColor(.orange)
        case .copyOfBuiltIn(let name):
            Text("Adds “\(name)”").font(.caption).foregroundColor(.secondary)
        }
    }
}
