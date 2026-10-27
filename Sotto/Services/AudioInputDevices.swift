import AppKit
import AVFoundation
import CoreAudio
import os

/// Microphones from CoreAudio (N9). The choice is stored by device UID, which stays the same
/// across reconnects, unlike the numeric device ID.
enum AudioInputDevices {
    struct Device: Identifiable, Hashable {
        let id: AudioDeviceID
        let uid: String
        let name: String
    }

    private static let logger = Logger(subsystem: "com.divingsbysangam.sotto", category: "Recording")

    static func all() -> [Device] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard hasInput(id), let uid = string(id, kAudioDevicePropertyDeviceUID), let name = string(id, kAudioObjectPropertyName) else { return nil }
            return Device(id: id, uid: uid, name: name)
        }
    }

    static func device(uid: String) -> Device? {
        all().first { $0.uid == uid }
    }

    /// Points the engine's input at the chosen microphone. Falls back to the system default
    /// (returns false) when it isn't connected.
    @discardableResult
    static func select(uid: String?, on engine: AVAudioEngine) -> Bool {
        guard let uid else { return false }
        guard let device = device(uid: uid) else {
            logger.notice("chosen microphone not connected; using the system default")
            return false
        }
        guard let unit = engine.inputNode.audioUnit else { return false }
        var id = device.id
        let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout<AudioDeviceID>.size))
        if status != noErr {
            logger.error("could not select microphone (\(status, privacy: .public)); using the system default")
            return false
        }
        logger.notice("recording from chosen microphone")
        return true
    }

    private static func hasInput(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return false }
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, buffer) == noErr else { return false }
        let list = UnsafeMutableAudioBufferListPointer(buffer.assumingMemoryBound(to: AudioBufferList.self))
        return list.contains { $0.mNumberChannels > 0 }
    }

    private static func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}

/// "Pause Music/Spotify while dictating" (N9): AppleScript to apps that are already running
/// (never launches them), and only resumes what it paused. No private MediaRemote.
final class MediaPauser {
    private static let players = [("com.apple.Music", "Music"), ("com.spotify.client", "Spotify")]
    private static let logger = Logger(subsystem: "com.divingsbysangam.sotto", category: "Recording")
    private let queue = DispatchQueue(label: "com.divingsbysangam.sotto.media-pause")
    private var paused: [String] = []

    func pauseIfPlaying() {
        let running = Self.players.filter { !NSRunningApplication.runningApplications(withBundleIdentifier: $0.0).isEmpty }.map(\.1)
        guard !running.isEmpty else { return }
        queue.async {
            for app in running {
                let script = "tell application \"\(app)\" to if player state is playing then\npause\nreturn \"paused\"\nend if"
                if Self.run(script) == "paused" {
                    self.paused.append(app)
                }
            }
            if !self.paused.isEmpty { Self.logger.notice("paused \(self.paused.joined(separator: ","), privacy: .public)") }
        }
    }

    func resume() {
        queue.async {
            for app in self.paused {
                _ = Self.run("tell application \"\(app)\" to play")
            }
            self.paused.removeAll()
        }
    }

    private static func run(_ source: String) -> String? {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error { logger.error("media AppleScript failed: \(error, privacy: .public)") }
        return result?.stringValue
    }
}
