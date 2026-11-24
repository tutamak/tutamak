import CoreGraphics
import Foundation

/// The Mission Control keyboard shortcuts that flicks post (System Settings > Keyboard >
/// Keyboard Shortcuts > Mission Control). macOS has no public API for switching desktops or
/// opening Mission Control. The raw values are the symbolic hotkey ids in com.apple.symbolichotkeys.
enum SystemShortcut: String, CaseIterable {
    case moveLeftSpace = "79"
    case moveRightSpace = "81"
    case missionControl = "32"
    case appWindows = "33"

    struct Keys: Equatable {
        let keyCode: CGKeyCode
        let flags: CGEventFlags
        let enabled: Bool
    }

    static let desktopSwitching: [SystemShortcut] = [.moveLeftSpace, .moveRightSpace]
    static let missionControlAndAppWindows: [SystemShortcut] = [.missionControl, .appWindows]

    /// What a flick posts, as the system gestures do: fingers moving left bring in the desktop on
    /// the right, up opens Mission Control, down shows the front app's windows (App Exposé).
    init(flick direction: SwipeDirection) {
        switch direction {
        case .left: self = .moveRightSpace
        case .right: self = .moveLeftSpace
        case .up: self = .missionControl
        case .down: self = .appWindows
        }
    }

    /// The name in Keyboard Shortcuts.
    var title: String {
        switch self {
        case .moveLeftSpace: "Move left a space"
        case .moveRightSpace: "Move right a space"
        case .missionControl: "Mission Control"
        case .appWindows: "Application windows"
        }
    }

    /// Arrow keys: left, right, up, down.
    private var defaultKey: CGKeyCode {
        switch self {
        case .moveLeftSpace: 123
        case .moveRightSpace: 124
        case .missionControl: 126
        case .appWindows: 125
        }
    }

    /// Control + Fn (arrow keys carry the Fn flag): the default modifiers of all four shortcuts.
    private static let defaultModifiers: UInt64 = 0x840000

    var isEnabled: Bool { keys.enabled }

    /// Posts the shortcut. Returns false if the user turned it off; it is never turned on from here.
    @discardableResult
    func post() -> Bool {
        let keys = self.keys
        guard keys.enabled else { return false }
        let source = CGEventSource(stateID: .hidSystemState)
        // Only the arrow key events carry the modifiers; separate modifier key events risk a stuck key.
        for keyDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: keys.keyCode, keyDown: keyDown)
            else { continue }
            event.flags = keys.flags
            event.post(tap: .cghidEventTap)
        }
        return true
    }

    /// The keys as set in Keyboard Shortcuts, read fresh each time so changes apply at once.
    var keys: Keys {
        let fallback = Keys(keyCode: defaultKey, flags: CGEventFlags(rawValue: Self.defaultModifiers), enabled: true)
        let all = CFPreferencesCopyAppValue(
            "AppleSymbolicHotKeys" as CFString, "com.apple.symbolichotkeys" as CFString
        ) as? [String: Any]
        // No entry means the shortcut was never changed: it has its default and is on.
        guard let entry = all?[rawValue] as? [String: Any] else { return fallback }
        let enabled = (entry["enabled"] as? NSNumber)?.boolValue ?? true
        guard let value = entry["value"] as? [String: Any],
              let parameters = (value["parameters"] as? [NSNumber])?.map(\.intValue),
              parameters.count == 3, parameters[1] != 65535
        else {
            return Keys(keyCode: fallback.keyCode, flags: fallback.flags, enabled: enabled)
        }
        return Keys(
            keyCode: CGKeyCode(parameters[1]),
            flags: CGEventFlags(rawValue: UInt64(parameters[2])),
            enabled: enabled
        )
    }
}
