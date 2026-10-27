import SwiftUI

// MARK: - Modes Tab

struct ModesTab: View {
    var settings: AppSettings

    @State private var appModes: [AppMode] = []
    @State private var editingMode: AppMode?
    @State private var showingAddMode = false
    @State private var defaultInstructions: String = ""
    @State private var isEditingDefaults: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            // Default Instructions Section
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Default Instructions")
                            .font(.title2)
                            .fontWeight(.semibold)
                        Text("Applied to all transcripts. A matching app mode adds its instructions after these, or replaces them if it overrides defaults.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button(isEditingDefaults ? "Done" : "Edit") {
                        isEditingDefaults.toggle()
                    }
                }

                if isEditingDefaults {
                    TextEditor(text: $defaultInstructions)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 100, maxHeight: 150)
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .background(Color(nsColor: .textBackgroundColor))
                        .cornerRadius(8)
                        .onChange(of: defaultInstructions) {
                            settings.defaultInstructions = defaultInstructions
                        }

                    Button("Reset to Default") {
                        defaultInstructions = """
                        Clean up the dictated text:
                        - Fix grammar and punctuation
                        - Remove filler words (um, uh, like, you know, basically, so, well, etc.)
                        - Remove false starts and repeated words
                        - Keep the original meaning and tone
                        """
                        settings.defaultInstructions = defaultInstructions
                    }
                    .font(.caption)
                }
            }
            .sottoSurface()
            .padding(16)

            Divider()

            // App Modes Header
            VStack(alignment: .leading, spacing: 8) {
                Text("App Modes")
                    .font(.headline)

                Text("Modes identify which app you're in and add their instructions after the defaults. Enable 'Override Default Instructions' on a mode to use only its instructions for that app.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()

            Divider()

            // Mode list
            if appModes.isEmpty {
                SottoEmptyState(symbol: .appModes, title: "No app modes yet", detail: "Add a mode to customize dictation for an app or website.")
                .frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(appModes) { mode in
                        ModeRowView(mode: mode, onToggle: { toggleMode(mode) }, onEdit: { editingMode = mode })
                            .contextMenu {
                                Button("Edit…") { editingMode = mode }
                                Button("Export…") { ModeExport.run([mode]) { _ in NSSound.beep() } }
                            }
                    }
                    .onDelete(perform: deleteModes)
                }
                .listStyle(.inset)
            }

            Divider()

            HStack {
                Text("\(appModes.filter { $0.isEnabled }.count) of \(appModes.count) modes enabled")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Reset to Defaults") {
                    settings.resetModesToDefaults()
                    loadModes()
                }.font(.caption)
            }.padding(12)
        }
        .navigationTitle("App Modes")
        .toolbar {
            ToolbarItemGroup {
                ModeImportExportButtons(settings: settings) { loadModes() }
                Button("Add Mode", systemImage: "plus") { showingAddMode = true }.sottoPrimaryAction()
            }
        }
        .onAppear {
            loadModes()
            defaultInstructions = settings.defaultInstructions
        }
        .sheet(item: $editingMode) { mode in
            ModeEditorSheet(mode: mode, isNew: false) { updatedMode in
                updateMode(updatedMode)
            }
        }
        .sheet(isPresented: $showingAddMode) {
            ModeEditorSheet(mode: AppMode(displayName: ""), isNew: true) { newMode in
                addMode(newMode)
            }
        }
    }

    private func loadModes() {
        appModes = settings.appModes
    }

    private func saveModes() {
        settings.appModes = appModes
    }

    private func toggleMode(_ mode: AppMode) {
        if let index = appModes.firstIndex(where: { $0.id == mode.id }) {
            appModes[index].isEnabled.toggle()
            saveModes()
        }
    }

    private func updateMode(_ mode: AppMode) {
        if let index = appModes.firstIndex(where: { $0.id == mode.id }) {
            appModes[index] = mode
            saveModes()
        }
    }

    private func addMode(_ mode: AppMode) {
        appModes.append(mode)
        saveModes()
    }

    private func deleteModes(at offsets: IndexSet) {
        // Don't allow deleting built-in modes
        let indicesToDelete = offsets.filter { !appModes[$0].isBuiltIn }
        appModes.remove(atOffsets: IndexSet(indicesToDelete))
        saveModes()
    }
}

private struct ModeBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2)
            .foregroundColor(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.2))
            .cornerRadius(4)
    }
}

struct ModeRowView: View {
    let mode: AppMode
    let onToggle: () -> Void
    let onEdit: () -> Void

    private var matchSummary: String {
        var parts: [String] = []
        if !mode.matchedApps.isEmpty {
            parts.append(mode.matchedApps.joined(separator: ", "))
        }
        if !mode.matchedWebsites.isEmpty {
            parts.append(mode.matchedWebsites.joined(separator: ", "))
        }
        let categories = mode.catalogCategories.compactMap { AppCatalog.Category(rawValue: $0)?.displayName }
        if !categories.isEmpty {
            parts.append("+ " + categories.joined(separator: ", ") + " apps")
        }
        return parts.isEmpty ? "No matches configured" : parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 12) {
            // Enable toggle
            Toggle("", isOn: Binding(
                get: { mode.isEnabled },
                set: { _ in onToggle() }
            ))
            .labelsHidden()
            .toggleStyle(.switch)

            // Mode info
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(mode.displayName)
                        .font(.headline)
                    if mode.isBuiltIn {
                        Text("Built-in")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.2))
                            .cornerRadius(4)
                    }
                    if mode.overrideDefaults {
                        Text("Overrides")
                            .font(.caption2)
                            .foregroundColor(.orange)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.2))
                            .cornerRadius(4)
                    }
                    if mode.skipsCleanup {
                        ModeBadge(text: "Raw", color: .blue)
                    }
                    if mode.translateToEnglish {
                        ModeBadge(text: "→ English", color: .teal)
                    }
                    if mode.sendAfterPaste {
                        ModeBadge(text: "Sends \(mode.sendKey == .commandReturn ? "⌘⏎" : "⏎")", color: .purple)
                    }
                    if mode.requiresAppleIntelligence && !LLMService.foundationModelsAvailable {
                        ModeBadge(text: "Needs Apple Intelligence", color: .secondary)
                            .help("This mode is skipped until Apple Intelligence is available on this Mac.")
                    }
                }

                Text(matchSummary)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)

                if !mode.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(mode.prompt)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .italic()
                }
            }

            Spacer()

            // Edit button
            Button("Edit") {
                onEdit()
            }
            .buttonStyle(.bordered)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Installed Apps Manager

@Observable
class InstalledAppsManager {
    static let shared = InstalledAppsManager()

    struct InstalledApp: Identifiable, Hashable {
        let id = UUID()
        let name: String
        let path: String
        let icon: NSImage?
    }

    var installedApps: [InstalledApp] = []

    private init() {
        loadInstalledApps()
    }

    func loadInstalledApps() {
        var apps: [InstalledApp] = []
        let fileManager = FileManager.default

        // Scan /Applications
        let applicationsPaths = [
            "/Applications",
            "/System/Applications",
            NSHomeDirectory() + "/Applications"
        ]

        for basePath in applicationsPaths {
            guard let contents = try? fileManager.contentsOfDirectory(atPath: basePath) else { continue }

            for item in contents where item.hasSuffix(".app") {
                let appPath = "\(basePath)/\(item)"
                let appName = item.replacingOccurrences(of: ".app", with: "")

                // Get app icon
                let icon = NSWorkspace.shared.icon(forFile: appPath)
                icon.size = NSSize(width: 20, height: 20)

                apps.append(InstalledApp(name: appName, path: appPath, icon: icon))
            }
        }

        // Sort alphabetically
        installedApps = apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

// MARK: - App Picker Sheet

struct AppPickerSheet: View {
    @Environment(\.dismiss) private var dismiss

    @Binding var selectedApps: [String]
    @State private var searchText = ""

    private let appsManager = InstalledAppsManager.shared

    private var filteredApps: [InstalledAppsManager.InstalledApp] {
        if searchText.isEmpty {
            return appsManager.installedApps
        }
        return appsManager.installedApps.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Text("Select Applications")
                    .font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .sottoPrimaryAction()
            }
            .padding()

            Divider()

            // Search
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Search apps...", text: $searchText)
                    .textFieldStyle(.plain)
            }
            .padding(10)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            // App list
            List {
                ForEach(filteredApps) { app in
                    HStack {
                        if let icon = app.icon {
                            Image(nsImage: icon)
                        }
                        Text(app.name)
                        Spacer()
                        if selectedApps.contains(app.name) {
                            Image(systemName: "checkmark")
                                .foregroundColor(.accentColor)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if selectedApps.contains(app.name) {
                            selectedApps.removeAll { $0 == app.name }
                        } else {
                            selectedApps.append(app.name)
                        }
                    }
                }
            }
            .listStyle(.plain)
        }
        .frame(width: 350, height: 450)
    }
}

// MARK: - Chip View

struct ChipView: View {
    let text: String
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(text)
                .font(.caption)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.accentColor.opacity(0.2))
        .foregroundColor(.accentColor)
        .cornerRadius(12)
    }
}

// MARK: - Mode Editor Sheet

struct ModeEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var displayName: String
    @State private var matchedApps: [String]
    @State private var matchedWebsites: [String]
    @State private var prompt: String
    @State private var isEnabled: Bool
    @State private var overrideDefaults: Bool
    @State private var sendAfterPaste: Bool
    @State private var sendKey: AppMode.SendKey
    @State private var skipsCleanup: Bool
    @State private var translateToEnglish: Bool
    @State private var promptExamples: [AppMode.PromptExample]
    @State private var catalogCategories: [String]

    @State private var showingAppPicker = false
    @State private var newWebsite = ""

    let mode: AppMode
    let isNew: Bool
    let onSave: (AppMode) -> Void

    init(mode: AppMode, isNew: Bool, onSave: @escaping (AppMode) -> Void) {
        self.mode = mode
        self.isNew = isNew
        self.onSave = onSave
        _displayName = State(initialValue: mode.displayName)
        _matchedApps = State(initialValue: mode.matchedApps)
        _matchedWebsites = State(initialValue: mode.matchedWebsites)
        _prompt = State(initialValue: mode.prompt)
        _isEnabled = State(initialValue: mode.isEnabled)
        _overrideDefaults = State(initialValue: mode.overrideDefaults)
        _sendAfterPaste = State(initialValue: mode.sendAfterPaste)
        _sendKey = State(initialValue: mode.sendKey)
        _skipsCleanup = State(initialValue: mode.skipsCleanup)
        _translateToEnglish = State(initialValue: mode.translateToEnglish)
        _promptExamples = State(initialValue: mode.promptExamples)
        _catalogCategories = State(initialValue: mode.catalogCategories)
    }

    /// Return in these sends an email or runs a command.
    private var sendIsRisky: Bool {
        let risky = ["mail", "outlook", "terminal", "iterm", "warp", "ghostty", "kitty", "alacritty", "gmail", "email"]
        return ([displayName] + matchedApps + matchedWebsites).contains { entry in
            risky.contains { entry.lowercased().contains($0) }
        }
    }

    private var canSave: Bool {
        !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (!matchedApps.isEmpty || !matchedWebsites.isEmpty || !catalogCategories.isEmpty)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Text(isNew ? "Add Mode" : "Edit Mode")
                    .font(.headline)
                Spacer()
                Button("Save") {
                    let updatedMode = AppMode(
                        id: mode.id,
                        displayName: displayName,
                        matchedApps: matchedApps,
                        matchedWebsites: matchedWebsites,
                        prompt: prompt,
                        isEnabled: isEnabled,
                        overrideDefaults: overrideDefaults,
                        isBuiltIn: mode.isBuiltIn,
                        sendAfterPaste: sendAfterPaste,
                        sendKey: sendKey,
                        skipsCleanup: skipsCleanup,
                        requiresAppleIntelligence: mode.requiresAppleIntelligence,
                        promptExamples: promptExamples.filter {
                            !$0.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                || !$0.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        },
                        catalogCategories: catalogCategories,
                        translateToEnglish: translateToEnglish
                    )
                    onSave(updatedMode)
                    dismiss()
                }
                .disabled(!canSave)
                .sottoPrimaryAction()
            }
            .padding()

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Display Name
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Mode Name")
                            .font(.headline)
                        TextField("e.g., Code, Email, Chat", text: $displayName)
                            .textFieldStyle(.roundedBorder)
                    }

                    Divider()

                    // Matched Apps
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Matched Apps")
                                .font(.headline)
                            Spacer()
                            Button {
                                showingAppPicker = true
                            } label: {
                                Label("Add", systemImage: "plus")
                                    .font(.caption)
                            }
                            .buttonStyle(.bordered)
                        }

                        if matchedApps.isEmpty {
                            Text("No apps selected")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .italic()
                        } else {
                            FlowLayout(spacing: 6) {
                                ForEach(matchedApps, id: \.self) { app in
                                    ChipView(text: app) {
                                        matchedApps.removeAll { $0 == app }
                                    }
                                }
                            }
                        }

                        Text("Select applications from your system")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Divider()

                    // Matched Websites
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Matched Websites")
                            .font(.headline)

                        if !matchedWebsites.isEmpty {
                            FlowLayout(spacing: 6) {
                                ForEach(matchedWebsites, id: \.self) { website in
                                    ChipView(text: website) {
                                        matchedWebsites.removeAll { $0 == website }
                                    }
                                }
                            }
                        }

                        HStack {
                            TextField("Enter domain (e.g., github.com)", text: $newWebsite)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit { addWebsite() }

                            Button("Add") { addWebsite() }
                                .disabled(newWebsite.trimmingCharacters(in: .whitespaces).isEmpty)
                        }

                        Text("Matched against the page URL in any browser, including subdomains (slack.com matches app.slack.com). Add a path to narrow it, e.g. icloud.com/mail.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Divider()

                    // Catalog categories (N12)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Also Match Categories")
                            .font(.headline)
                        FlowLayout(spacing: 6) {
                            ForEach(AppCatalog.Category.allCases, id: \.self) { category in
                                Toggle(category.displayName, isOn: Binding(
                                    get: { catalogCategories.contains(category.rawValue) },
                                    set: { on in
                                        catalogCategories.removeAll { $0 == category.rawValue }
                                        if on { catalogCategories.append(category.rawValue) }
                                    }
                                ))
                                .toggleStyle(.button)
                                .controlSize(.small)
                            }
                        }
                        Text("Apps and sites Sotto knows (from its built-in catalog) match this mode by category when no mode lists them by name.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Divider()

                    // Mode Instructions
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Mode Instructions")
                            .font(.headline)

                        TextEditor(text: $prompt)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 80)
                            .scrollContentBackground(.hidden)
                            .padding(8)
                            .background(Color(nsColor: .textBackgroundColor))
                            .cornerRadius(8)

                        Text("Describe the output you want, briefly. Put names and terms in Vocabulary instead.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Divider()

                    // Examples (N5)
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Examples")
                                .font(.headline)
                            Spacer()
                            Button {
                                promptExamples.append(AppMode.PromptExample(input: "", output: ""))
                            } label: {
                                Label("Add", systemImage: "plus")
                                    .font(.caption)
                            }
                            .buttonStyle(.bordered)
                            .disabled(promptExamples.count >= AppMode.maxPromptExamples)
                        }

                        ForEach($promptExamples) { $example in
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 4) {
                                    TextField("What you might say…", text: $example.input, axis: .vertical)
                                        .textFieldStyle(.roundedBorder)
                                        .lineLimit(1...4)
                                    TextField("…and what it should become", text: $example.output, axis: .vertical)
                                        .textFieldStyle(.roundedBorder)
                                        .lineLimit(1...6)
                                }
                                Button {
                                    promptExamples.removeAll { $0.id == example.id }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundColor(.secondary)
                                }
                                .buttonStyle(.plain)
                                .help("Remove example")
                            }
                        }

                        Text("Up to \(AppMode.maxPromptExamples) short before → after pairs. Apple Intelligence follows examples better than instructions; they only set the style and are never copied.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Divider()

                    // Override Defaults
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Override Default Instructions", isOn: $overrideDefaults)
                            .font(.headline)

                        Text(overrideDefaults
                             ? "Only this mode's instructions are used; default instructions are ignored."
                             : "This mode's instructions are added after the default instructions.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Divider()

                    // After paste
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Send after paste", isOn: $sendAfterPaste)
                            .font(.headline)

                        if sendAfterPaste {
                            Picker("Send with", selection: $sendKey) {
                                ForEach(AppMode.SendKey.allCases, id: \.self) { key in
                                    Text(key.displayName).tag(key)
                                }
                            }
                            .pickerStyle(.segmented)
                            .frame(maxWidth: 260)
                        }

                        Text("Presses the key right after a successful paste, for one-shot chat messages. Never after a copy-only paste or if you've switched apps.")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        if sendAfterPaste || sendIsRisky {
                            Text("⚠︎ In email and terminal apps this sends the message or runs the command immediately.")
                                .font(.caption)
                                .foregroundColor(sendAfterPaste && sendIsRisky ? .orange : .secondary)
                        }
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Raw (skip cleanup)", isOn: $skipsCleanup)
                            .font(.headline)

                        Text("Pastes the transcript without AI cleanup, for the lowest latency. Vocabulary, replacements, snippets, and voice commands still apply; this mode's instructions are not used.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Translate to English", isOn: $translateToEnglish)
                            .font(.headline)

                        Text(LLMService.foundationModelsAvailable
                             ? "Speak any language; English is pasted. Sotto transcribes what you say, then Apple Intelligence translates it on this Mac."
                             : "Speak any language; English is pasted, using Whisper's built-in translation. It can drop or garble words; with Apple Intelligence, translation is much better.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    if mode.requiresAppleIntelligence {
                        Divider()
                        Text(LLMService.foundationModelsAvailable
                             ? "Uses Apple Intelligence (on-device) to restructure your dictation."
                             : "Needs Apple Intelligence, which isn't available on this Mac right now, so this mode is skipped.")
                            .font(.caption)
                            .foregroundColor(LLMService.foundationModelsAvailable ? .secondary : .orange)
                    }

                    Divider()

                    // Enabled
                    Toggle("Mode Enabled", isOn: $isEnabled)
                }
                .padding(20)
            }
        }
        .frame(minWidth: 450, idealWidth: 500, maxWidth: 600)
        .frame(minHeight: 500, idealHeight: 600, maxHeight: 700)
        .sheet(isPresented: $showingAppPicker) {
            AppPickerSheet(selectedApps: $matchedApps)
        }
    }

    private func addWebsite() {
        let website = newWebsite.trimmingCharacters(in: .whitespaces).lowercased()
        guard !website.isEmpty, !matchedWebsites.contains(website) else { return }
        matchedWebsites.append(website)
        newWebsite = ""
    }
}

// MARK: - Flow Layout for Chips

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = FlowResult(in: proposal.width ?? 0, subviews: subviews, spacing: spacing)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = FlowResult(in: bounds.width, subviews: subviews, spacing: spacing)
        for (index, subview) in subviews.enumerated() {
            subview.place(at: CGPoint(x: bounds.minX + result.positions[index].x,
                                       y: bounds.minY + result.positions[index].y),
                          proposal: .unspecified)
        }
    }

    struct FlowResult {
        var size: CGSize = .zero
        var positions: [CGPoint] = []

        init(in maxWidth: CGFloat, subviews: Subviews, spacing: CGFloat) {
            var x: CGFloat = 0
            var y: CGFloat = 0
            var rowHeight: CGFloat = 0

            for subview in subviews {
                let size = subview.sizeThatFits(.unspecified)

                if x + size.width > maxWidth, x > 0 {
                    x = 0
                    y += rowHeight + spacing
                    rowHeight = 0
                }

                positions.append(CGPoint(x: x, y: y))
                rowHeight = max(rowHeight, size.height)
                x += size.width + spacing
            }

            self.size = CGSize(width: maxWidth, height: y + rowHeight)
        }
    }
}
