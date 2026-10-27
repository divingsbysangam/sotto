import Foundation
import os

/// Bundled catalog (Resources/app-catalog.json) mapping apps and sites to categories, so
/// built-in App Modes work for apps the user never listed (N12). Explicit matches always win.
struct AppCatalog {
    static let shared = AppCatalog.load()

    /// Category names used by App Modes (`AppMode.catalogCategories`).
    enum Category: String, CaseIterable {
        case email, chat, messaging, code, terminal, notes, docs
        case aiChat = "ai-chat"

        var displayName: String {
            switch self {
            case .email: return "Email"
            case .chat: return "Work chat"
            case .messaging: return "Messaging"
            case .code: return "Code"
            case .terminal: return "Terminal"
            case .notes: return "Notes"
            case .docs: return "Documents"
            case .aiChat: return "AI chat"
            }
        }
    }

    private struct File: Decodable {
        struct Entry: Decodable {
            let id: String
            let name: String
        }
        struct Group: Decodable {
            let apps: [Entry]
            let domains: [String]
        }
        let categories: [String: Group]
    }

    private static let logger = Logger(subsystem: "com.divingsbysangam.sotto", category: "AppCatalog")

    private let categoryByBundleID: [String: Category]
    private let categoryByAppName: [String: Category]
    private let domains: [(site: (host: String, path: String), category: Category)]

    private init(categoryByBundleID: [String: Category], categoryByAppName: [String: Category], domains: [(site: (host: String, path: String), category: Category)]) {
        self.categoryByBundleID = categoryByBundleID
        self.categoryByAppName = categoryByAppName
        self.domains = domains
    }

    static func load(from url: URL? = Bundle.main.url(forResource: "app-catalog", withExtension: "json")) -> AppCatalog {
        guard let url, let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data) else {
            logger.error("app catalog missing or unreadable; category matching off")
            return AppCatalog(categoryByBundleID: [:], categoryByAppName: [:], domains: [])
        }
        var byID: [String: Category] = [:]
        var byName: [String: Category] = [:]
        var domains: [(site: (host: String, path: String), category: Category)] = []
        for (key, group) in file.categories {
            guard let category = Category(rawValue: key) else { continue }
            for app in group.apps {
                byID[app.id.lowercased()] = category
                byName[app.name.lowercased()] = category
            }
            for domain in group.domains {
                if let site = AppMode.parseWebsite(domain) { domains.append((site, category)) }
            }
        }
        return AppCatalog(categoryByBundleID: byID, categoryByAppName: byName, domains: domains)
    }

    /// The page URL's category (host or subdomain, optional path prefix), else the app's.
    func category(for app: SourceAppIdentity?, url: URL?) -> Category? {
        if let url, let rawHost = url.host?.lowercased() {
            let host = rawHost.hasPrefix("www.") ? String(rawHost.dropFirst(4)) : rawHost
            let path = url.path.lowercased()
            if let match = domains.first(where: { entry in
                (host == entry.site.host || host.hasSuffix("." + entry.site.host))
                    && (entry.site.path.isEmpty || path == entry.site.path || path.hasPrefix(entry.site.path + "/"))
            }) {
                return match.category
            }
        }
        if let id = app?.bundleIdentifier?.lowercased(), let category = categoryByBundleID[id] {
            return category
        }
        return nil
    }

    /// Most common category among app names (for giving renamed built-in modes categories).
    func likelyCategory(forAppNames names: [String]) -> Category? {
        let counts = Dictionary(grouping: names.compactMap { categoryByAppName[$0.lowercased()] }, by: { $0 }).mapValues(\.count)
        return counts.max { $0.value < $1.value }?.key
    }
}
