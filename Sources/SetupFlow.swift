/// The setup's steps and what each asks for, from the live state of the Mac. Pure and tested.
///
/// The order follows the dependencies: without Accessibility permission no window moves, and with
/// macOS's four-finger gestures on, every practice swipe would also open Mission Control or switch
/// desktops. There is no welcome step: the first step is the first thing to do. Every step can be
/// left with "Not now"; the menu's warnings stay as the safety net.
enum SetupStep: Int, CaseIterable, Comparable {
    case permission
    case systemGestures
    case practice
    case grid
    case done

    static func < (a: SetupStep, b: SetupStep) -> Bool { a.rawValue < b.rawValue }

    var next: SetupStep? { SetupStep(rawValue: rawValue + 1) }
    var previous: SetupStep? { SetupStep(rawValue: rawValue - 1) }
}

/// What the footer's one primary button does on a step.
enum SetupPrimary: Equatable {
    /// Opens Privacy & Security > Accessibility, with the guide card beside it.
    case allowAccess
    /// Turns macOS's four-finger gestures off, and only when this button is pressed.
    case turnOffGestures
    case next
    case finish

    var title: String {
        switch self {
        case .allowAccess: "Open Settings"
        case .turnOffGestures: "Turn Off"
        case .next: "Continue"
        case .finish: "Done"
        }
    }
}

/// The three-finger trackpad gestures, which turning the four-finger ones off leaves alone.
struct ThreeFingerGestures: Equatable {
    /// Swipe between full-screen apps and desktops.
    var swipesBetweenDesktops = false
    /// Swipe up for Mission Control, down for App Exposé.
    var missionControl = false
    /// Three-finger drag (Accessibility > Pointer Control).
    var drag = false
}

/// What the setup reads from the Mac each time it looks. Injected, so every state can be drawn
/// and tested without changing the Mac it runs on.
struct SetupStatus: Equatable {
    var accessibilityGranted = false
    var fourFingerGesturesOn = false
    var trackpads = 0
    var desktopShortcutsOn = true
    var missionControlShortcutsOn = true
    var threeFinger = ThreeFingerGestures()
    /// A backup of macOS's four-finger gesture settings exists, so they can be restored.
    var gesturesBackupExists = false

    func primary(on step: SetupStep) -> SetupPrimary {
        switch step {
        case .permission: accessibilityGranted ? .next : .allowAccess
        case .systemGestures: fourFingerGesturesOn ? .turnOffGestures : .next
        case .practice, .grid: .next
        case .done: .finish
        }
    }

    /// "Not now" shows only where the primary button would change something.
    func showsSkip(on step: SetupStep) -> Bool {
        [.allowAccess, .turnOffGestures].contains(primary(on: step))
    }

    /// Without the four-finger gestures, Mission Control and App Exposé are left only on three
    /// fingers. Someone without them there would lose both, so Tutamak's up/down flick is offered.
    var missionControlNeedsFlicks: Bool { !threeFinger.missionControl }
}
