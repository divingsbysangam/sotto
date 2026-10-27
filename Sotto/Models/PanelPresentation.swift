import Foundation

enum RecordingIndicatorPlacement {
    static func dotOrigin(at point: CGPoint, visibleFrame: CGRect, size: CGSize) -> CGPoint {
        CGPoint(x: min(max(point.x + 2, visibleFrame.minX + 4), visibleFrame.maxX - size.width - 4),
                y: min(max(point.y - 28, visibleFrame.minY + 4), visibleFrame.maxY - size.height - 4))
    }
    static func bottomOrigin(in visibleFrame: CGRect, size: CGSize) -> CGPoint {
        CGPoint(x: visibleFrame.midX - size.width / 2, y: visibleFrame.minY + 20)
    }
}

/// A hide completion is valid only for the presentation that scheduled it.
final class PanelPresentation {
    private(set) var generation = UUID()
    @discardableResult func renew() -> UUID { generation = UUID(); return generation }
    func contains(_ generation: UUID) -> Bool { self.generation == generation }
}

enum RecordingOverlayStatus {
    static func make(isProcessing: Bool, message: String) -> SottoStatusPresentation {
        guard isProcessing else {
            return .init(title: "Listening", detail: "", symbol: "mic.fill", tone: .recording)
        }
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("⚠︎") {
            return .init(title: String(text.dropFirst()).trimmingCharacters(in: .whitespaces), detail: "", symbol: "exclamationmark.triangle.fill", tone: .attention)
        }
        if text.hasPrefix("✓") {
            return .init(title: String(text.dropFirst()).trimmingCharacters(in: .whitespaces), detail: "", symbol: "checkmark.circle.fill", tone: .ready)
        }
        if text.hasPrefix("💡") {
            return .init(title: String(text.dropFirst()).trimmingCharacters(in: .whitespaces), detail: "", symbol: "lightbulb", tone: .neutral)
        }
        return .init(title: text.isEmpty ? "Preparing your transcript…" : text, detail: "", symbol: "waveform.circle.fill")
    }
}
