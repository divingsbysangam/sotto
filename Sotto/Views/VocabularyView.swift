import SwiftUI

// MARK: - Vocabulary Tab

struct VocabularyTab: View {
    var settings: AppSettings
    var onSave: (() -> Void)?

    enum Section: String, CaseIterable {
        case words = "Words"
        case replacements = "Replacements"
        case snippets = "Snippets"

        var description: String {
            switch self {
            case .words:
                return "Names, jargon, and product terms Sotto should always spell exactly like this. They’re used as hints for the on-device model."
            case .replacements:
                return "Always write a spoken word or phrase a set way. Applied to every transcript before AI cleanup."
            case .snippets:
                return "Say a short cue to insert a longer block of text, such as a link, address, or signature."
            }
        }
    }

    @State private var section: Section = .words
    @State private var customVocabulary: String = ""
    @State private var newWord: String = ""
    @State private var confirmsClearAll = false

    private var vocabularyList: [String] {
        VocabularyInput.additions(from: customVocabulary, existing: [])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SottoDesign.spacing / 2) {
            SottoPageHeader(title: "Vocabulary", subtitle: "Teach Sotto the words you use") {
                VocabularyImportExportMenus()
            }

            Picker("Vocabulary section", selection: $section) {
                ForEach(Section.allCases, id: \.self) { section in
                    Text(section.rawValue).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 360)

            switch section {
            case .words:
                wordsSection
            case .replacements:
                ReplacementsEditor(settings: settings)
            case .snippets:
                SnippetsEditor(settings: settings)
            }
            Spacer(minLength: 0)
        }
        .padding(SottoDesign.spacing)
        .background(SottoDesign.charcoal)
        .confirmationDialog("Remove all vocabulary words?", isPresented: $confirmsClearAll) {
            Button("Remove All Words", role: .destructive) {
                customVocabulary = ""
                saveSettings()
            }
        } message: {
            Text("This removes your custom words from this Mac.")
        }
        .onAppear { loadSettings() }
        // Words can also arrive from Services › Add to Sotto Vocabulary while this is open.
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            if settings.customVocabulary != customVocabulary {
                customVocabulary = settings.customVocabulary
            }
        }
    }

    @ViewBuilder
    private var wordsSection: some View {
        VStack(alignment: .leading, spacing: SottoDesign.spacing / 2) {
            Text("Words").font(.subheadline.weight(.semibold))
            Text(section.description).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: SottoDesign.spacing / 2) {
                TextField("Add a word or phrase…", text: $newWord)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, SottoDesign.spacing / 2)
                    .frame(height: 32)
                    .background(SottoDesign.charcoal, in: RoundedRectangle(cornerRadius: 8))
                    .onSubmit(addWord)
                Button("Add", systemImage: "plus", action: addWord)
                    .sottoPrimaryAction()
                    .disabled(VocabularyInput.additions(from: newWord, existing: vocabularyList).isEmpty)
            }
            if !newWord.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               VocabularyInput.additions(from: newWord, existing: vocabularyList).isEmpty {
                Text("These words are already in your vocabulary.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .sottoSurface()

        if vocabularyList.isEmpty {
            SottoEmptyState(symbol: .vocabulary, title: "No custom words yet", detail: "Add names and terms to help Sotto spell them correctly.")
                .frame(height: 140)
                .sottoSurface()
        } else {
            FlowLayout(spacing: SottoDesign.spacing / 2) {
                ForEach(vocabularyList, id: \.self) { word in
                    HStack(spacing: SottoDesign.spacing / 4) {
                        Text(word).font(.caption)
                        Button {
                            removeWord(word)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Remove \(word)")
                        .accessibilityLabel("Remove \(word)")
                    }
                    .padding(.horizontal, SottoDesign.spacing / 2)
                    .padding(.vertical, SottoDesign.spacing / 3)
                    .background(SottoDesign.cream.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .sottoSurface()
        }

        HStack {
            Text("\(vocabularyList.count) word\(vocabularyList.count == 1 ? "" : "s")")
                .foregroundStyle(.secondary)

            Spacer()

            if !vocabularyList.isEmpty {
                Button("Clear All") { confirmsClearAll = true }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            Text("Stored locally").foregroundStyle(.secondary)
        }
        .font(.caption)
    }

    private func loadSettings() {
        customVocabulary = settings.customVocabulary
    }

    private func saveSettings() {
        settings.customVocabulary = customVocabulary
        onSave?()
    }

    private func addWord() {
        let additions = VocabularyInput.additions(from: newWord, existing: vocabularyList)
        guard !additions.isEmpty else { return }
        customVocabulary = (vocabularyList + additions).joined(separator: ", ")
        newWord = ""
        saveSettings()
    }

    private func removeWord(_ word: String) {
        var list = vocabularyList
        list.removeAll { $0 == word }
        customVocabulary = list.joined(separator: ", ")
        saveSettings()
    }
}
