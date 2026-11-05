import SwiftUI

// MARK: - Replacements

/// Vocabulary → Replacements: add, edit in place, delete. Saved as you type.
struct ReplacementsEditor: View {
    var settings: AppSettings

    @State private var replacements: [TextReplacement] = []
    @State private var spoken = ""
    @State private var written = ""

    private var canAdd: Bool {
        !spoken.trimmingCharacters(in: .whitespaces).isEmpty && !written.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SottoDesign.spacing / 2) {
            VStack(alignment: .leading, spacing: SottoDesign.spacing / 2) {
                Text("Replacements").font(.subheadline.weight(.semibold))
                Text("Always write a spoken word or phrase a set way. Applied to every transcript before AI cleanup.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: SottoDesign.spacing / 2) {
                    TextField("When I say…", text: $spoken)
                        .textFieldStyle(.roundedBorder)
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    TextField("Write…", text: $written)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(add)
                    Button("Add", systemImage: "plus", action: add)
                        .sottoPrimaryAction()
                        .disabled(!canAdd)
                }
            }
            .sottoSurface()

            if replacements.isEmpty {
                SottoEmptyState(symbol: .vocabulary, title: "No replacements yet",
                                detail: "For words Sotto gets wrong, add a spoken phrase and how to write it.")
                    .frame(height: 140)
                    .sottoSurface()
            } else {
                VStack(spacing: SottoDesign.spacing / 2) {
                    ForEach($replacements) { $replacement in
                        HStack(spacing: SottoDesign.spacing / 2) {
                            TextField("Spoken", text: $replacement.spoken)
                                .textFieldStyle(.roundedBorder)
                            Image(systemName: "arrow.right").foregroundStyle(.secondary)
                            TextField("Written", text: $replacement.written)
                                .textFieldStyle(.roundedBorder)
                            Button {
                                replacements.removeAll { $0.id == replacement.id }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Delete")
                        }
                    }
                }
                .sottoSurface()
            }

            HStack {
                Text("\(replacements.count) replacement\(replacements.count == 1 ? "" : "s")")
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Stored locally").foregroundStyle(.secondary)
            }
            .font(.caption)
        }
        .onAppear { replacements = settings.replacements }
        .onChange(of: replacements) { settings.replacements = replacements }
        // Imports (and other windows) change the stored list too.
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            let stored = settings.replacements
            if stored != replacements { replacements = stored }
        }
    }

    /// Adding a phrase that already exists updates it instead of duplicating it.
    private func add() {
        let key = spoken.trimmingCharacters(in: .whitespaces)
        guard canAdd else { return }
        if let index = replacements.firstIndex(where: { $0.spoken.caseInsensitiveCompare(key) == .orderedSame }) {
            replacements[index].written = written
        } else {
            replacements.append(TextReplacement(spoken: key, written: written))
        }
        spoken = ""
        written = ""
    }
}

// MARK: - Snippets

/// Vocabulary → Snippets: a spoken cue that expands to a block of text.
struct SnippetsEditor: View {
    var settings: AppSettings

    @State private var snippets: [TextSnippet] = []
    @State private var editing: TextSnippet?

    var body: some View {
        VStack(alignment: .leading, spacing: SottoDesign.spacing / 2) {
            VStack(alignment: .leading, spacing: SottoDesign.spacing / 2) {
                HStack {
                    VStack(alignment: .leading, spacing: SottoDesign.spacing / 4) {
                        Text("Snippets").font(.subheadline.weight(.semibold))
                        Text("Say a short cue to insert a longer block of text. AI cleanup never rewords a snippet.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Add Snippet", systemImage: "plus") {
                        editing = TextSnippet(cue: "", text: "")
                    }
                    .sottoPrimaryAction()
                }
            }
            .sottoSurface()

            if snippets.isEmpty {
                SottoEmptyState(symbol: .vocabulary, title: "No snippets yet",
                                detail: "Say “my calendar link” to insert a URL, or “sign off” for a signature.")
                    .frame(height: 140)
                    .sottoSurface()
            } else {
                VStack(spacing: SottoDesign.spacing / 2) {
                    ForEach(snippets) { snippet in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("“\(snippet.cue)”")
                                    .fontWeight(.medium)
                                Text(snippet.text)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(2)
                            }
                            Spacer()
                            Button("Edit") { editing = snippet }
                                .buttonStyle(.plain)
                            Button {
                                snippets.removeAll { $0.id == snippet.id }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Delete")
                        }
                        .padding(.vertical, SottoDesign.spacing / 4)
                        if snippet.id != snippets.last?.id { Divider() }
                    }
                }
                .sottoSurface()
            }

            HStack {
                Text("\(snippets.count) snippet\(snippets.count == 1 ? "" : "s")")
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Stored locally").foregroundStyle(.secondary)
            }
            .font(.caption)
        }
        .onAppear { snippets = settings.snippets }
        .onChange(of: snippets) { settings.snippets = snippets }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            let stored = settings.snippets
            if stored != snippets { snippets = stored }
        }
        .sheet(item: $editing) { snippet in
            SnippetEditSheet(snippet: snippet) { saved in
                if let index = snippets.firstIndex(where: { $0.id == saved.id }) {
                    snippets[index] = saved
                } else {
                    snippets.append(saved)
                }
            }
        }
    }
}

private struct SnippetEditSheet: View {
    @State var snippet: TextSnippet
    let onSave: (TextSnippet) -> Void
    @Environment(\.dismiss) private var dismiss

    private var canSave: Bool {
        !snippet.cue.trimmingCharacters(in: .whitespaces).isEmpty && !snippet.text.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Snippet")
                .font(.headline)

            Text("When I say")
                .font(.subheadline)
                .foregroundColor(.secondary)
            TextField("e.g. my calendar link", text: $snippet.cue)
                .textFieldStyle(.roundedBorder)

            Text("Insert")
                .font(.subheadline)
                .foregroundColor(.secondary)
            TextEditor(text: $snippet.text)
                .font(.body)
                .frame(minHeight: 120)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    snippet.cue = snippet.cue.trimmingCharacters(in: .whitespaces)
                    onSave(snippet)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}

// MARK: - Import / Export (N11)

/// Import ▸ / Export ▸ menus for the Vocabulary header.
struct VocabularyImportExportMenus: View {
    @State private var preview: [VocabularyImportService.PreviewItem]?
    @State private var previewSource = ""
    @State private var errorMessage: String?

    var body: some View {
        HStack {
            Menu("Import") {
                Button("From superwhisper") { load(.superwhisper) }
                    .disabled(!FileManager.default.fileExists(atPath: VocabularyImportService.superwhisperURL.path))
                Button("From Wispr Flow") { load(.wisprFlow) }
                    .disabled(!FileManager.default.fileExists(atPath: VocabularyImportService.wisprFlowURL.path))
                Divider()
                Button("From a Sotto Export (JSON or CSV)…") {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [.json, .commaSeparatedText]
                    if panel.runModal() == .OK, let url = panel.url { load(.file(url)) }
                }
            }
            .fixedSize()
            Menu("Export") {
                Button("As JSON…") { export(json: true) }
                Button("As CSV…") { export(json: false) }
            }
            .fixedSize()
        }
        .tint(SottoDesign.cream.opacity(0.8))
        .sheet(isPresented: Binding(get: { preview != nil }, set: { if !$0 { preview = nil } })) {
            if let preview {
                VocabularyImportSheet(source: previewSource, items: preview) { self.preview = nil }
            }
        }
        .alert("Import Failed", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func load(_ source: VocabularyImportService.Source) {
        do {
            let bundle = try VocabularyImportService.load(source)
            guard !bundle.isEmpty else {
                errorMessage = "\(source.displayName) has no vocabulary to import."
                return
            }
            previewSource = source.displayName
            preview = VocabularyImportService.preview(bundle)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func export(json: Bool) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [json ? .json : .commaSeparatedText]
        panel.nameFieldStringValue = "Sotto Vocabulary." + (json ? "json" : "csv")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let bundle = VocabularyImportService.current
            if json { try VocabularyImportService.exportJSON(bundle, to: url) } else { try VocabularyImportService.exportCSV(bundle, to: url) }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Preview before importing: everything new is checked; items already in Sotto aren't.
private struct VocabularyImportSheet: View {
    let source: String
    let items: [VocabularyImportService.PreviewItem]
    let onDone: () -> Void
    @State private var selected: Set<UUID> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import from \(source)")
                .font(.headline)
            Text("Only vocabulary is read: words, replacements, and snippets. Items already in Sotto are unchecked.")
                .font(.caption)
                .foregroundColor(.secondary)

            List {
                ForEach(VocabularyImportService.PreviewItem.Kind.allKinds, id: \.self) { kind in
                    let rows = items.filter { $0.kind == kind }
                    if !rows.isEmpty {
                        Section(kind.rawValue + "s") {
                            ForEach(rows) { item in
                                Toggle(isOn: Binding(
                                    get: { selected.contains(item.id) },
                                    set: { if $0 { selected.insert(item.id) } else { selected.remove(item.id) } }
                                )) {
                                    HStack {
                                        Text(item.key)
                                        if !item.value.isEmpty {
                                            Image(systemName: "arrow.right").foregroundColor(.secondary)
                                            Text(item.value).lineLimit(1).foregroundColor(.secondary)
                                        }
                                        Spacer()
                                        if item.isDuplicate {
                                            Text("Already added").font(.caption).foregroundColor(.secondary)
                                        } else if item.updatesExisting {
                                            Text("Replaces yours").font(.caption).foregroundColor(.orange)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .frame(minHeight: 260)

            HStack {
                Button("Cancel", action: onDone)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Add \(selected.count) Item\(selected.count == 1 ? "" : "s")") {
                    VocabularyImportService.apply(items.filter { selected.contains($0.id) })
                    onDone()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selected.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear { selected = Set(items.filter { !$0.isDuplicate }.map(\.id)) }
    }
}

extension VocabularyImportService.PreviewItem.Kind {
    static let allKinds: [Self] = [.word, .replacement, .snippet]
}
