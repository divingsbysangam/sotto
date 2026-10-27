import AppKit

final class CursorPositionService {

    struct CursorPosition {
        let point: NSPoint  // Screen coordinates (bottom-left origin for NSWindow)
        let screen: NSScreen
    }

    /// Get the current text caret position using the Accessibility API.
    /// Falls back to the mouse location if the caret cannot be determined.
    func getCursorPosition() -> CursorPosition? {
        if let axPosition = getAccessibilityCursorPosition() {
            return axPosition
        }
        return getMousePosition()
    }

    // MARK: - Accessibility API

    private func getAccessibilityCursorPosition() -> CursorPosition? {
        let systemWide = AXUIElementCreateSystemWide()

        // Get the focused application
        var focusedAppValue: AnyObject?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedApplicationAttribute as CFString, &focusedAppValue) == .success,
              let focusedApp = focusedAppValue else {
            return nil
        }
        let appElement = focusedApp as! AXUIElement

        // Get the focused UI element
        var focusedElementValue: AnyObject?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedElementValue) == .success,
              let focusedElement = focusedElementValue else {
            return nil
        }
        let element = focusedElement as! AXUIElement

        // Get the selected text range
        var rangeValue: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
              let range = rangeValue else {
            return nil
        }

        // Get bounds for the selected text range
        var boundsValue: AnyObject?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString, range, &boundsValue) == .success,
              let bounds = boundsValue else {
            return nil
        }

        // Extract the CGRect from the AXValue
        var rect = CGRect.zero
        guard AXValueGetValue(bounds as! AXValue, .cgRect, &rect) else {
            return nil
        }

        // AX returns top-left origin screen coords; convert to NSWindow bottom-left origin
        let screenPoint = convertAXPointToScreen(axRect: rect)

        guard let screen = screenForPoint(screenPoint) else {
            return nil
        }

        return CursorPosition(point: screenPoint, screen: screen)
    }

    /// Convert AX top-left origin rect to NSScreen bottom-left origin point.
    private func convertAXPointToScreen(axRect: CGRect) -> NSPoint {
        // AX uses top-left origin (like CGDisplay). NSWindow uses bottom-left origin.
        // The primary screen's frame gives us the full height for conversion.
        guard let primaryScreen = NSScreen.screens.first else {
            return NSPoint(x: axRect.origin.x, y: axRect.origin.y)
        }
        let screenHeight = primaryScreen.frame.height
        // Convert: NSWindow y = screenHeight - AX y - rect height
        let flippedY = screenHeight - axRect.origin.y - axRect.height
        return NSPoint(x: axRect.origin.x, y: flippedY)
    }

    // MARK: - Text Around the Caret

    struct FocusedText {
        /// Up to `limit` characters just before the caret or selection ("" at the start).
        let before: String?
        let selected: String?
        /// Up to `limit` characters just after the caret or selection.
        let after: String?
    }

    /// The focused text field's text around the caret, via Accessibility. Nil when there is no
    /// readable text element, Accessibility isn't granted, or it's a password field (never read).
    static func focusedText(limit: Int = 200) -> FocusedText? {
        guard AXIsProcessTrusted() else { return nil }
        let systemWide = AXUIElementCreateSystemWide()
        // A hung app must not stall recording start or paste.
        AXUIElementSetMessagingTimeout(systemWide, 0.25)

        var focusedValue: AnyObject?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedValue) == .success,
              let focused = focusedValue,
              CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.25)

        // Password fields: normally subrole AXSecureTextField; some apps report it as the role.
        let secure = kAXSecureTextFieldSubrole as String
        if stringAttribute(element, kAXSubroleAttribute) == secure || stringAttribute(element, kAXRoleAttribute) == secure {
            return nil
        }

        var rangeValue: AnyObject?
        var range = CFRange()
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
              let rangeValue, CFGetTypeID(rangeValue) == AXValueGetTypeID(),
              AXValueGetValue(rangeValue as! AXValue, .cfRange, &range) else { return nil }

        var total = -1
        var countValue: AnyObject?
        if AXUIElementCopyAttributeValue(element, kAXNumberOfCharactersAttribute as CFString, &countValue) == .success,
           let count = countValue as? Int {
            total = count
        }

        let beforeStart = max(0, range.location - limit)
        let before = (range.location == 0 || limit == 0)
            ? ""
            : string(in: element, range: CFRange(location: beforeStart, length: range.location - beforeStart))
        let afterStart = range.location + range.length
        let afterLength = total >= 0 ? max(0, min(limit, total - afterStart)) : limit
        let after = (afterLength == 0 || limit == 0) ? "" : string(in: element, range: CFRange(location: afterStart, length: afterLength))
        let selected = range.length > 0 ? stringAttribute(element, kAXSelectedTextAttribute) : nil

        return FocusedText(before: before, selected: selected, after: after)
    }

    static func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    /// AXStringForRange, falling back to slicing AXValue (UTF-16 offsets, like AX ranges).
    static func string(in element: AXUIElement, range: CFRange) -> String? {
        var cfRange = range
        if let rangeValue = AXValueCreate(.cfRange, &cfRange) {
            var value: AnyObject?
            if AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString, rangeValue, &value) == .success,
               let string = value as? String {
                return string
            }
        }
        guard let whole = stringAttribute(element, kAXValueAttribute) else { return nil }
        let ns = whole as NSString
        let start = min(range.location, ns.length)
        return ns.substring(with: NSRange(location: start, length: min(range.length, ns.length - start)))
    }

    /// L2: the focused text element with its caret (selection) range and character count, for
    /// watching a field over time. Nil for password fields or when Accessibility can't read it.
    static func focusedTextElement() -> (element: AXUIElement, caret: CFRange, count: Int)? {
        guard AXIsProcessTrusted() else { return nil }
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, 0.25)
        var focusedValue: AnyObject?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedValue) == .success,
              let focused = focusedValue, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.25)
        let secure = kAXSecureTextFieldSubrole as String
        if stringAttribute(element, kAXSubroleAttribute) == secure || stringAttribute(element, kAXRoleAttribute) == secure {
            return nil
        }
        guard let caret = selectedRange(element), let count = characterCount(element) else { return nil }
        return (element, caret, count)
    }

    static func selectedRange(_ element: AXUIElement) -> CFRange? {
        var rangeValue: AnyObject?
        var range = CFRange()
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
              let rangeValue, CFGetTypeID(rangeValue) == AXValueGetTypeID(),
              AXValueGetValue(rangeValue as! AXValue, .cfRange, &range) else { return nil }
        return range
    }

    static func characterCount(_ element: AXUIElement) -> Int? {
        var countValue: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXNumberOfCharactersAttribute as CFString, &countValue) == .success else { return nil }
        return countValue as? Int
    }

    // MARK: - Mouse Fallback

    private func getMousePosition() -> CursorPosition? {
        let mouseLocation = NSEvent.mouseLocation
        guard let screen = screenForPoint(mouseLocation) else {
            return nil
        }
        return CursorPosition(point: mouseLocation, screen: screen)
    }

    // MARK: - Helpers

    private func screenForPoint(_ point: NSPoint) -> NSScreen? {
        for screen in NSScreen.screens {
            if screen.frame.contains(point) {
                return screen
            }
        }
        return NSScreen.main
    }
}
