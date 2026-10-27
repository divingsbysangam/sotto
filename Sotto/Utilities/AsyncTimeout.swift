import Foundation

enum AsyncTimeoutError: LocalizedError {
    case timedOut(operation: String, seconds: TimeInterval)

    var errorDescription: String? {
        switch self {
        case .timedOut(let operation, let seconds):
            return "\(operation) timed out after \(Int(seconds))s"
        }
    }
}

/// Runs `operation` and fails if it does not finish within `seconds`.
/// Safe for non-Sendable return types (WhisperKit, etc.).
func withTimeout<T>(
    seconds: TimeInterval,
    operation name: String,
    operation: @escaping () async throws -> T
) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        let lock = NSLock()
        var resumed = false

        func resume(_ body: (CheckedContinuation<T, Error>) -> Void) {
            lock.lock()
            defer { lock.unlock() }
            guard !resumed else { return }
            resumed = true
            body(continuation)
        }

        Task {
            do {
                let result = try await operation()
                resume { $0.resume(returning: result) }
            } catch {
                resume { $0.resume(throwing: error) }
            }
        }

        Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            resume {
                $0.resume(throwing: AsyncTimeoutError.timedOut(operation: name, seconds: seconds))
            }
        }
    }
}
