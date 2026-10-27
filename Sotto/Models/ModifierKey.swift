import AppKit
import Carbon.HIToolbox

/// A modifier used on its own as a key (N3: dictation key; N4: mode-cycle key). Right-hand keys
/// are told apart from left-hand ones, so left Option/Command keep working normally.
enum ModifierKey: String, CaseIterable, Codable {
    case fn
    case rightOption
    case rightCommand
    case rightShift
    case rightControl

    /// Keys offered as the dictation key.
    static let dictationChoices: [ModifierKey] = [.fn, .rightOption, .rightCommand]
    /// Keys offered for cycling modes while recording.
    static let modeCycleChoices: [ModifierKey] = [.rightShift, .rightOption, .rightCommand, .rightControl]

    var displayName: String {
        switch self {
        case .fn: return "Fn 🌐"
        case .rightOption: return "Right ⌥"
        case .rightCommand: return "Right ⌘"
        case .rightShift: return "Right ⇧"
        case .rightControl: return "Right ⌃"
        }
    }

    /// Virtual key code of the physical key (as in a flagsChanged event).
    var keyCode: Int {
        switch self {
        case .fn: return kVK_Function
        case .rightOption: return kVK_RightOption
        case .rightCommand: return kVK_RightCommand
        case .rightShift: return kVK_RightShift
        case .rightControl: return kVK_RightControl
        }
    }

    init?(keyCode: Int) {
        guard let key = Self.allCases.first(where: { $0.keyCode == keyCode }) else { return nil }
        self = key
    }

    /// Device-dependent flag bit (IOKit NX_DEVICE…KEYMASK) that is set while this exact key is down.
    var deviceFlag: UInt64 {
        switch self {
        case .fn: return CGEventFlags.maskSecondaryFn.rawValue
        case .rightOption: return 0x40      // NX_DEVICERALTKEYMASK
        case .rightCommand: return 0x10     // NX_DEVICERCMDKEYMASK
        case .rightShift: return 0x04       // NX_DEVICERSHIFTKEYMASK
        case .rightControl: return 0x2000   // NX_DEVICERCTLKEYMASK
        }
    }

    /// The side-independent modifier flag this key sets.
    var genericFlag: CGEventFlags {
        switch self {
        case .fn: return .maskSecondaryFn
        case .rightOption: return .maskAlternate
        case .rightCommand: return .maskCommand
        case .rightShift: return .maskShift
        case .rightControl: return .maskControl
        }
    }

    /// What pressing the Fn/🌐 key does in System Settings › Keyboard ("Press 🌐 key to").
    /// Anything but "Do Nothing" fires alongside Sotto. Nil when it's already "Do Nothing".
    static var fnKeySystemAction: String? {
        let usage = UserDefaults(suiteName: "com.apple.HIToolbox")?.object(forKey: "AppleFnUsageType") as? Int ?? 0
        switch usage {
        case 1: return "Change Input Source"
        case 2: return "Show Emoji & Symbols"
        case 3: return "Start Dictation"
        default: return nil
        }
    }
}
