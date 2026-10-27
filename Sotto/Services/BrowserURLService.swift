import AppKit
import os

/// Reads the page URL of the frontmost browser tab via Accessibility, so website App Modes can
/// match the real host instead of guessing from the window title. Any app that exposes an
/// http(s) web area counts — no browser list needed. Requires Accessibility (already granted
/// for auto-paste); returns nil when unavailable.
enum BrowserURLService {
    private static let logger = Logger(subsystem: "com.divingsbysangam.sotto", category: "BrowserURL")

    /// Keep AX calls from stalling dictation if the target app is busy: per call, and overall.
    private static let messagingTimeout: Float = 0.1
    private static let lookupBudget: TimeInterval = 0.3
    private static let maxAncestorHops = 60
    private static let maxSearchedElements = 600

    static func currentURL(for app: NSRunningApplication?) -> URL? {
        guard let app, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, messagingTimeout)

        // Chromium browsers and Electron apps build their AX tree only on request.
        AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)

        let appLabel = app.localizedName ?? app.bundleIdentifier ?? "unknown"
        let deadline = Date().addingTimeInterval(lookupBudget)

        // 1. Walk up from the focused element (usually the field being dictated into).
        if let focused = element(appElement, kAXFocusedUIElementAttribute),
           let url = webAreaURL(fromDescendant: focused, deadline: deadline) {
            log(url, via: "focused", app: appLabel)
            return url
        }

        guard let window = element(appElement, kAXFocusedWindowAttribute) else {
            logger.debug("no url app=\(appLabel, privacy: .public) reason=no focused window")
            return nil
        }

        // 2. Some browsers (Safari) publish the page URL as the window's document.
        if let document = string(window, kAXDocumentAttribute), let url = webURL(document) {
            log(url, via: "document", app: appLabel)
            return url
        }

        // 3. Focus is outside the page (e.g. the address bar): search the window for a web area.
        if let url = webAreaURL(searchingFrom: window, deadline: deadline) {
            log(url, via: "search", app: appLabel)
            return url
        }

        logger.debug("no url app=\(appLabel, privacy: .public)")
        return nil
    }

    /// `https://host` only — paths and queries can hold private data and are never stored.
    static func origin(of url: URL?) -> String? {
        guard let url, let scheme = url.scheme, let host = url.host else { return nil }
        return "\(scheme)://\(host)"
    }

    // MARK: - Tree walking

    private static func webAreaURL(fromDescendant start: AXUIElement, deadline: Date) -> URL? {
        var current: AXUIElement? = start
        for _ in 0..<maxAncestorHops {
            guard let element = current, Date() < deadline else { return nil }
            if role(element) == "AXWebArea" {
                return url(element, kAXURLAttribute)
            }
            current = self.element(element, kAXParentAttribute)
        }
        return nil
    }

    /// Breadth-first, bounded: the top-level web area is found before any nested iframes.
    private static func webAreaURL(searchingFrom root: AXUIElement, deadline: Date) -> URL? {
        var queue = [root]
        var index = 0
        while index < queue.count, index < maxSearchedElements, Date() < deadline {
            let element = queue[index]
            index += 1
            if role(element) == "AXWebArea" {
                if let url = url(element, kAXURLAttribute) { return url }
                continue  // Don't descend into a page's own content.
            }
            queue.append(contentsOf: children(element))
        }
        return nil
    }

    // MARK: - AX helpers

    private static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    private static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let value = value(element, attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return bounded(value as! AXUIElement)
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        ((value(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []).map(bounded)
    }

    private static func bounded(_ element: AXUIElement) -> AXUIElement {
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        return element
    }

    private static func role(_ element: AXUIElement) -> String? {
        string(element, kAXRoleAttribute)
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        value(element, attribute) as? String
    }

    private static func url(_ element: AXUIElement, _ attribute: String) -> URL? {
        guard let raw = value(element, attribute) else { return nil }
        if let url = raw as? URL { return webURL(url.absoluteString) }
        if let string = raw as? String { return webURL(string) }
        return nil
    }

    /// Only real web pages: skips file://, about:blank, vscode-file://, chrome://, etc.
    private static func webURL(_ string: String) -> URL? {
        guard let url = URL(string: string),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host?.isEmpty == false else { return nil }
        return url
    }

    private static func log(_ url: URL, via strategy: String, app: String) {
        logger.notice("url via=\(strategy, privacy: .public) app=\(app, privacy: .public) host=\(url.host ?? "", privacy: .public)")
    }
}
