import AppKit
import ApplicationServices
import CoreGraphics
import ScreenCaptureKit
import Vision

/// Captures the frontmost window and runs on-device OCR for LLM screen context.
///
/// Design goals for dictation reliability:
/// - Never crashes via double-resumed `CheckedContinuation` (Vision `perform` is sync; no continuation).
/// - Serialized: overlapping calls cancel the previous in-flight capture.
/// - Time-boxed and non-throwing: callers always get `nil` on failure/timeout and can continue paste.
/// - Screen Recording APIs are never touched unless the caller opts into OCR; permission is
///   requested at most once per process (never on every stop/close).
actor ScreenCaptureService {

    /// Default budget so stop→transcribe→paste cannot hang on OCR forever.
    static let defaultTimeoutSeconds: TimeInterval = 2.5

    /// In-flight capture; a newer call cancels the previous one.
    private var inFlight: Task<String?, Never>?

    /// Process-lifetime guard so we never spam `CGRequestScreenCaptureAccess`.
    private static let accessRequestLock = NSLock()
    private static var didRequestScreenRecordingAccess = false

    // MARK: - Screen Recording access (no capture yet)

    /// Non-prompting check. Safe to call anytime; does not show a system dialog.
    nonisolated static func hasScreenRecordingAccess() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Prompts the user at most once per process. Returns whether access is granted afterward.
    /// Call when the user enables Screen Context (OCR), or on first capture if still undecided.
    @discardableResult
    nonisolated static func requestScreenRecordingAccessIfNeeded() -> Bool {
        if CGPreflightScreenCaptureAccess() {
            return true
        }

        accessRequestLock.lock()
        let alreadyAsked = didRequestScreenRecordingAccess
        if !alreadyAsked {
            didRequestScreenRecordingAccess = true
        }
        accessRequestLock.unlock()

        if alreadyAsked {
            // User already saw the prompt (or Settings link) this session — do not spam.
            return false
        }

        // Shows the system Screen Recording prompt once. May still return false until the
        // user toggles Sotto on in System Settings (and sometimes until relaunch).
        return CGRequestScreenCaptureAccess()
    }

    // MARK: - Capture + OCR

    /// Best-effort screen OCR. Always returns (never throws); `nil` means skip context.
    /// Call only when Screen Context (OCR) is enabled — this is the sole entry that may
    /// touch ScreenCaptureKit / screenshot APIs.
    func captureScreenContext(timeoutSeconds: TimeInterval = ScreenCaptureService.defaultTimeoutSeconds) async -> String? {
        // Permission gate before any ScreenCaptureKit / SCScreenshotManager use.
        // First call may prompt once; later calls never re-prompt.
        guard Self.hasScreenRecordingAccess() || Self.requestScreenRecordingAccessIfNeeded() else {
            NSLog("[ScreenCapture] Screen Recording not granted; skipping OCR (no re-prompt)")
            return nil
        }

        inFlight?.cancel()

        let work = Task<String?, Never> {
            do {
                return try await self.performCapture()
            } catch is CancellationError {
                return nil
            } catch {
                NSLog("[ScreenCapture] capture/OCR failed: %@", error.localizedDescription)
                return nil
            }
        }
        inFlight = work

        let result = await withTaskGroup(of: String?.self) { group -> String? in
            group.addTask {
                await work.value
            }
            group.addTask {
                let nanos = UInt64(max(timeoutSeconds, 0.1) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanos)
                work.cancel()
                NSLog("[ScreenCapture] capture timed out after %.1fs; continuing without context", timeoutSeconds)
                return nil
            }

            // First finished child wins (success, failure→nil, or timeout→nil).
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? nil
        }

        if inFlight == work {
            inFlight = nil
        }
        return result
    }

    private func performCapture() async throws -> String? {
        try Task.checkCancellation()

        // Re-check without prompting — identity/TCC can change mid-session; never spam.
        guard Self.hasScreenRecordingAccess() else {
            NSLog("[ScreenCapture] Screen Recording lost or not yet active; skipping capture")
            return nil
        }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

        guard let frontApp = await MainActor.run(body: { NSWorkspace.shared.frontmostApplication }) else {
            return nil
        }

        let appPID = frontApp.processIdentifier

        guard let window = content.windows.first(where: { $0.owningApplication?.processID == appPID }) else {
            return nil
        }

        try Task.checkCancellation()

        guard let image = try await captureWindow(window) else {
            return nil
        }

        try Task.checkCancellation()

        // Vision's `perform` is synchronous — run off the cooperative pool and never use
        // CheckedContinuation (request handler + perform catch can both fire → SIGTRAP).
        return try await Task.detached(priority: .userInitiated) {
            try Self.recognizeText(in: image)
        }.value
    }

    private func captureWindow(_ window: SCWindow) async throws -> CGImage? {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        // Cap resolution so OCR stays inside the time budget on large displays.
        let maxDimension: CGFloat = 1600
        let scale = min(1, maxDimension / max(window.frame.width, window.frame.height, 1))
        configuration.width = max(1, Int(window.frame.width * scale))
        configuration.height = max(1, Int(window.frame.height * scale))
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = false

        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        return image
    }

    /// Synchronous Vision OCR. Completion runs during `perform`, so results are collected
    /// in local vars — no continuation, no double-resume hazard.
    nonisolated private static func recognizeText(in image: CGImage) throws -> String? {
        var recognized: String?
        var requestError: Error?

        let request = VNRecognizeTextRequest { request, error in
            if let error {
                requestError = error
                return
            }

            guard let observations = request.results as? [VNRecognizedTextObservation] else {
                recognized = nil
                return
            }

            let text = observations.compactMap { observation in
                observation.topCandidates(1).first?.string
            }.joined(separator: " ")

            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            recognized = trimmed.isEmpty ? nil : trimmed
        }

        // `.fast` keeps OCR inside the stop-recording time budget.
        request.recognitionLevel = .fast
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            throw requestError ?? error
        }

        if let requestError {
            throw requestError
        }

        return recognized
    }

    // MARK: - Metadata (no Screen Recording)

    /// Frontmost app display name via AppKit — does **not** require Screen Recording.
    nonisolated func getActiveAppName() -> String? {
        NSWorkspace.shared.frontmostApplication?.localizedName
    }

    /// Frontmost window title via Accessibility — does **not** use `CGWindowListCopyWindowInfo`
    /// / `kCGWindowName`, which would trigger a Screen Recording TCC prompt on modern macOS.
    /// Requires Accessibility (already needed for auto-paste); returns nil if unavailable.
    nonisolated func getActiveWindowTitle() -> String? {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            return nil
        }

        let appElement = AXUIElementCreateApplication(frontApp.processIdentifier)

        var focusedWindow: CFTypeRef?
        let windowStatus = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            &focusedWindow
        )
        guard windowStatus == .success, let focusedWindow else {
            return nil
        }

        let windowElement = focusedWindow as! AXUIElement
        var titleValue: CFTypeRef?
        let titleStatus = AXUIElementCopyAttributeValue(
            windowElement,
            kAXTitleAttribute as CFString,
            &titleValue
        )
        guard titleStatus == .success else {
            return nil
        }

        return titleValue as? String
    }
}
