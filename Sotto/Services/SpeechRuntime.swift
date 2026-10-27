import Foundation

protocol SpeechRuntime: Actor {
    func load(from directory: URL) async throws
    func transcribe(_ url: URL) async throws -> String
    func unload() async
}
