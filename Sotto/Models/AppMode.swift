import AppKit

/// Every name the frontmost app can be matched by. `localizedName` alone is fragile:
/// e.g. VS Code reports "Code" while the App Picker stores its file name "Visual Studio Code".
struct SourceAppIdentity: Equatable {
    /// Localized name first, then bundle display/short names and the .app file name (deduplicated).
    let names: [String]
    let bundleIdentifier: String?

    init(names: [String?], bundleIdentifier: String? = nil) {
        var seen = Set<String>()
        self.names = names
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
        self.bundleIdentifier = bundleIdentifier
    }

    init(app: NSRunningApplication) {
        let info = app.bundleURL.flatMap { Bundle(url: $0)?.infoDictionary }
        self.init(
            names: [
                app.localizedName,
                info?["CFBundleDisplayName"] as? String,
                info?["CFBundleName"] as? String,
                app.bundleURL?.deletingPathExtension().lastPathComponent
            ],
            bundleIdentifier: app.bundleIdentifier
        )
    }

    var displayName: String { names.first ?? bundleIdentifier ?? "unknown" }

    /// Exact: the entry equals one of the app's names (case/diacritic-insensitive) or its bundle ID.
    /// Loose: an app name contains the entry (e.g. "iTerm" matches "iTerm2"); bundle IDs stay exact-only.
    func matches(_ entry: String, exact: Bool) -> Bool {
        let pattern = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pattern.isEmpty else { return false }
        if let bundleIdentifier, bundleIdentifier.caseInsensitiveCompare(pattern) == .orderedSame {
            return true
        }
        return names.contains { name in
            name.compare(pattern, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
                || (!exact && name.localizedCaseInsensitiveContains(pattern))
        }
    }
}

struct AppMode: Codable, Identifiable, Equatable {
    let id: UUID
    var displayName: String
    var matchedApps: [String]      // App names to match (e.g., ["Xcode", "Visual Studio Code"])
    var matchedWebsites: [String]  // Website domains to match (e.g., ["github.com", "stackoverflow.com"])
    var prompt: String
    var isEnabled: Bool
    var overrideDefaults: Bool  // When true, prompt replaces default instructions; when false, it's appended after them
    let isBuiltIn: Bool  // true for default modes, false for user-created
    /// Press `sendKey` after a successful paste (one-shot chat messages). Off by default.
    var sendAfterPaste: Bool
    var sendKey: SendKey
    /// Raw: skip AI cleanup for this mode (Vocabulary, replacements, snippets, and voice
    /// commands still apply). Lowest latency.
    var skipsCleanup: Bool
    /// Only useful with Apple's on-device model (e.g. Prompt); skipped when it's unavailable.
    let requiresAppleIntelligence: Bool
    /// N5: example dictation → output pairs. The small on-device model follows examples better
    /// than instructions; at most `maxPromptExamples` are sent.
    var promptExamples: [PromptExample]
    /// N12: app categories (AppCatalog.Category raw values) this mode also matches when the
    /// user hasn't listed the app or site. Explicit matches always win.
    var catalogCategories: [String]
    /// L10: speak any language, paste English. Whisper translates; if its output isn't English,
    /// the on-device model translates the transcript (Apple Intelligence). Off by default.
    var translateToEnglish: Bool

    static let maxPromptExamples = 3

    struct PromptExample: Codable, Hashable, Identifiable {
        var id = UUID()
        var input: String
        var output: String
    }

    enum SendKey: String, Codable, CaseIterable {
        case returnKey = "return"
        case commandReturn = "commandReturn"

        var displayName: String {
            switch self {
            case .returnKey: return "Return ⏎"
            case .commandReturn: return "⌘ Return"
            }
        }
    }

    // Legacy support - for reading old format
    private var appIdentifier: String?

    /// See `SourceAppIdentity.matches(_:exact:)` for exact vs loose matching.
    func matchesApp(_ app: SourceAppIdentity, exact: Bool) -> Bool {
        matchedApps.contains { app.matches($0, exact: exact) }
    }

    /// Matches the page URL's host against each entry: the entry's domain or any subdomain
    /// (slack.com matches app.slack.com). An entry with a path also needs that path prefix
    /// (icloud.com/mail). Scheme and "www." are ignored on both sides.
    func matchesWebsite(url: URL?) -> Bool {
        guard let url, let rawHost = url.host?.lowercased(), !rawHost.isEmpty else { return false }
        let host = rawHost.hasPrefix("www.") ? String(rawHost.dropFirst(4)) : rawHost
        let path = url.path.lowercased()
        return matchedWebsites.contains { entry in
            guard let site = Self.parseWebsite(entry) else { return false }
            guard host == site.host || host.hasSuffix("." + site.host) else { return false }
            return site.path.isEmpty || path == site.path || path.hasPrefix(site.path + "/")
        }
    }

    /// "https://www.iCloud.com/mail/" → (host: "icloud.com", path: "/mail").
    static func parseWebsite(_ entry: String) -> (host: String, path: String)? {
        var text = entry.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let scheme = text.range(of: "://") { text = String(text[scheme.upperBound...]) }
        var path = ""
        if let slash = text.firstIndex(of: "/") {
            path = String(text[slash...])
            text = String(text[..<slash])
            while path.hasSuffix("/") { path.removeLast() }
        }
        if text.hasPrefix("www.") { text = String(text.dropFirst(4)) }
        guard !text.isEmpty else { return nil }
        return (text, path)
    }

    init(
        id: UUID = UUID(),
        displayName: String,
        matchedApps: [String] = [],
        matchedWebsites: [String] = [],
        prompt: String = "",
        isEnabled: Bool = true,
        overrideDefaults: Bool = false,
        isBuiltIn: Bool = false,
        sendAfterPaste: Bool = false,
        sendKey: SendKey = .returnKey,
        skipsCleanup: Bool = false,
        requiresAppleIntelligence: Bool = false,
        promptExamples: [PromptExample] = [],
        catalogCategories: [String] = [],
        translateToEnglish: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.matchedApps = matchedApps
        self.matchedWebsites = matchedWebsites
        self.prompt = prompt
        self.isEnabled = isEnabled
        self.overrideDefaults = overrideDefaults
        self.isBuiltIn = isBuiltIn
        self.sendAfterPaste = sendAfterPaste
        self.sendKey = sendKey
        self.skipsCleanup = skipsCleanup
        self.requiresAppleIntelligence = requiresAppleIntelligence
        self.promptExamples = promptExamples
        self.catalogCategories = catalogCategories
        self.translateToEnglish = translateToEnglish
    }

    // Custom decoding to handle migration from old format
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decode(UUID.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        prompt = try container.decodeIfPresent(String.self, forKey: .prompt) ?? ""
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        overrideDefaults = try container.decodeIfPresent(Bool.self, forKey: .overrideDefaults) ?? false
        isBuiltIn = try container.decodeIfPresent(Bool.self, forKey: .isBuiltIn) ?? false
        // Added later: modes saved before decode with these off.
        sendAfterPaste = try container.decodeIfPresent(Bool.self, forKey: .sendAfterPaste) ?? false
        sendKey = (try? container.decodeIfPresent(SendKey.self, forKey: .sendKey)) ?? .returnKey
        skipsCleanup = try container.decodeIfPresent(Bool.self, forKey: .skipsCleanup) ?? false
        requiresAppleIntelligence = try container.decodeIfPresent(Bool.self, forKey: .requiresAppleIntelligence) ?? false
        promptExamples = (try? container.decodeIfPresent([PromptExample].self, forKey: .promptExamples)) ?? []
        catalogCategories = try container.decodeIfPresent([String].self, forKey: .catalogCategories) ?? []
        translateToEnglish = try container.decodeIfPresent(Bool.self, forKey: .translateToEnglish) ?? false

        // Try new format first
        if let apps = try? container.decode([String].self, forKey: .matchedApps) {
            matchedApps = apps
        } else if let oldIdentifier = try? container.decode(String.self, forKey: .appIdentifier) {
            // Migrate from old comma-separated format
            matchedApps = oldIdentifier
                .components(separatedBy: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        } else {
            matchedApps = []
        }

        matchedWebsites = try container.decodeIfPresent([String].self, forKey: .matchedWebsites) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case id, displayName, matchedApps, matchedWebsites, prompt, isEnabled, overrideDefaults, isBuiltIn, appIdentifier
        case sendAfterPaste, sendKey, skipsCleanup, requiresAppleIntelligence
        case promptExamples, catalogCategories, translateToEnglish
    }

    /// Restructures a spoken ramble into a prompt for AI chat apps. First in the list so it wins
    /// Cursor over Code (exact app matches go to the first mode that lists the app).
    static let promptMode = AppMode(
        displayName: "Prompt",
        matchedApps: ["ChatGPT", "Claude", "Cursor"],
        matchedWebsites: ["chatgpt.com", "chat.openai.com", "claude.ai"],
        prompt: """
            Rewrite the dictation as a prompt for an AI assistant, using only what was said.
            Start with "Goal:" and one sentence saying what is wanted.
            Then add these headings only for things that were actually said, each followed by "- " bullets:
            Context: background that was given.
            Constraints: rules or limits that were given.
            Output format: how the answer should look.
            Leave out a heading when nothing was said for it. Add no requirements, rules, or examples of your own. Do not answer the prompt.
            """,
        overrideDefaults: true,
        isBuiltIn: true,
        requiresAppleIntelligence: true,
        promptExamples: [
            PromptExample(
                input: "so I need a python script that um reads all the csv files in a folder and merges them into one, they all have the same columns, skip any empty files, and write the result to merged dot csv",
                output: "Goal: Write a Python script that merges all the CSV files in a folder into one.\n\nContext:\n- All the files have the same columns\n\nConstraints:\n- Skip empty files\n\nOutput format:\n- Write the result to merged.csv"
            )
        ],
        catalogCategories: ["ai-chat"]
    )

    static let defaults: [AppMode] = [
        promptMode,
        AppMode(
            displayName: "Email",
            matchedApps: ["Mail"],
            matchedWebsites: [
                "mail.google.com", "gmail.com", "outlook.live.com", "outlook.office.com", "outlook.office365.com",
                "outlook.com", "mail.yahoo.com", "mail.proton.me", "icloud.com/mail", "fastmail.com", "app.hey.com",
                "mail.superhuman.com", "mail.zoho.com"
            ],
            prompt: "Format as a professional email. Use proper greeting and sign-off if appropriate. Keep tone professional and polished.",
            isBuiltIn: true,
            promptExamples: [
                PromptExample(
                    input: "hey sam just checking if you got the contract i sent tuesday let me know if you have questions thanks",
                    output: "Hi Sam,\n\nJust checking whether you received the contract I sent on Tuesday. Let me know if you have any questions.\n\nThanks"
                )
            ],
            catalogCategories: ["email"]
        ),
        AppMode(
            displayName: "Code",
            matchedApps: ["Xcode", "Visual Studio Code", "Sublime Text", "Nova", "BBEdit"],
            matchedWebsites: [
                "github.com", "gitlab.com", "bitbucket.org", "stackoverflow.com", "stackexchange.com",
                "codepen.io", "codesandbox.io", "stackblitz.com", "replit.com"
            ],
            prompt: "Preserve technical terms, code syntax, variable names, and function names exactly as spoken. Format code comments properly. Use camelCase for variable names.",
            isBuiltIn: true,
            promptExamples: [
                PromptExample(
                    input: "um rename the user count variable to active user count and return early if the list is empty",
                    output: "Rename the userCount variable to activeUserCount and return early if the list is empty."
                )
            ],
            catalogCategories: ["code"]
        ),
        AppMode(
            displayName: "Slack",
            matchedApps: ["Slack"],
            matchedWebsites: ["slack.com"],
            prompt: "Keep casual and conversational. Contractions are fine. Keep messages concise and friendly.",
            isBuiltIn: true,
            promptExamples: [
                PromptExample(
                    input: "um can you take a look at the pr when you get a chance no rush though",
                    output: "Can you take a look at the PR when you get a chance? No rush though."
                )
            ],
            catalogCategories: ["chat"]
        ),
        AppMode(
            displayName: "Notes",
            matchedApps: ["Notes", "Notion", "Obsidian", "Bear"],
            matchedWebsites: [
                "notion.so", "notion.site", "evernote.com", "docs.google.com", "keep.google.com",
                "onenote.com", "coda.io", "craft.do"
            ],
            prompt: "Format as clean notes. Use bullet points for lists. Keep structure clear and organized.",
            isBuiltIn: true,
            promptExamples: [
                PromptExample(
                    input: "to do for the launch finish the landing page uh write the announcement and email the beta list",
                    output: "To do for the launch:\n- Finish the landing page\n- Write the announcement\n- Email the beta list"
                )
            ],
            catalogCategories: ["notes"]
        ),
        AppMode(
            displayName: "Terminal",
            matchedApps: ["Terminal", "iTerm", "Warp"],
            matchedWebsites: [],
            prompt: "Preserve command syntax exactly. Do not modify technical terms, flags, or paths. Keep commands on single lines.",
            isBuiltIn: true,
            promptExamples: [
                PromptExample(input: "git checkout dash b fix slash login bug", output: "git checkout -b fix/login-bug")
            ],
            catalogCategories: ["terminal"]
        ),
        AppMode(
            displayName: "Messages",
            matchedApps: ["Messages", "WhatsApp", "Telegram"],
            matchedWebsites: [
                "web.whatsapp.com", "telegram.org", "messenger.com", "discord.com", "messages.google.com",
                "instagram.com/direct"
            ],
            prompt: "Keep very casual and brief. Use contractions. This is for text messaging so keep it short.",
            isBuiltIn: true,
            promptExamples: [
                PromptExample(input: "on my way um should be there in like ten minutes", output: "On my way, should be there in 10 minutes")
            ],
            catalogCategories: ["messaging"]
        )
    ]
}
