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
                return "Add words and phrases to help the transcription engine spell them correctly. Useful for names, technical terms, and brand names."
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

    private var vocabularyList: [String] {
        VocabularyInput.additions(from: customVocabulary, existing: [])
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Vocabulary")
                        .font(.title2)
                        .fontWeight(.semibold)
                    Spacer()
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

                Text(section.description)
                    .font(.callout)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()

            Divider()

            switch section {
            case .words:
                wordsSection
            case .replacements:
                ReplacementsEditor(settings: settings)
            case .snippets:
                SnippetsEditor(settings: settings)
            }
        }
        .navigationTitle("Vocabulary")
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
        // Add new word
        VStack(alignment: .leading, spacing: 8) {
        HStack {
            TextField("Add a word or phrase...", text: $newWord)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    addWord()
                }

            Button("Add") {
                addWord()
            }
            .sottoPrimaryAction()
            .disabled(VocabularyInput.additions(from: newWord, existing: vocabularyList).isEmpty)
        }
        if !newWord.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           VocabularyInput.additions(from: newWord, existing: vocabularyList).isEmpty {
            Text("These words are already in your vocabulary.").font(.caption).foregroundStyle(.secondary)
        }
        }
        .padding()

        Divider()

        // Word list
        if vocabularyList.isEmpty {
            SottoEmptyState(symbol: .vocabulary, title: "No custom words yet", detail: "Add names and terms to help Sotto spell them correctly.")
            .frame(maxHeight: .infinity)
        } else {
            List {
                ForEach(vocabularyList, id: \.self) { word in
                    HStack {
                        Text(word)
                        Spacer()
                        Button {
                            removeWord(word)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Remove \(word)")
                        .accessibilityLabel("Remove \(word)")
                    }
                }
            }
            .listStyle(.inset)
        }

        Divider()

        // Footer
        HStack {
            Text("\(vocabularyList.count) word\(vocabularyList.count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundColor(.secondary)

            Spacer()

            if !vocabularyList.isEmpty {
                Button("Clear All") {
                    customVocabulary = ""
                    saveSettings()
                }
                .font(.caption)
                .foregroundColor(.red)
            }
        }
        .padding()
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
