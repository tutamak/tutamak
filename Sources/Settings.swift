import AppKit

enum Speed: String, CaseIterable {
    case slow, normal, fast

    var title: String {
        switch self {
        case .slow: "Slow"
        case .normal: "Normal"
        case .fast: "Fast"
        }
    }

    var pointsPerUnit: CGFloat {
        switch self {
        case .slow: 1400
        case .normal: 2000
        case .fast: 2800
        }
    }
}

/// macOS's own four-finger gestures (Mission Control, switching desktops, Launchpad). While they
/// are on, they fire on every drag too. This reads their state and turns them off or back on with
/// the bundled script.
enum SystemGestures {
    private static let appKeys = [
        "TrackpadFourFingerHorizSwipeGesture",
        "TrackpadFourFingerVertSwipeGesture",
        "TrackpadFourFingerPinchGesture",
    ]
    private static let appDomains = [
        "com.apple.AppleMultitouchTrackpad",
        "com.apple.driver.AppleBluetoothMultitouch.trackpad",
    ]
    private static let hostKeys = [
        "com.apple.trackpad.fourFingerHorizSwipeGesture",
        "com.apple.trackpad.fourFingerVertSwipeGesture",
        "com.apple.trackpad.fourFingerPinchSwipeGesture",
    ]

    static let backupPath = NSHomeDirectory() + "/Library/Application Support/Tutamak/gestures-backup.tsv"

    static var fourFingerEnabled: Bool {
        for domain in appDomains {
            for key in appKeys {
                if let v = CFPreferencesCopyAppValue(key as CFString, domain as CFString) as? Int, v != 0 { return true }
            }
        }
        for key in hostKeys {
            let v = CFPreferencesCopyValue(
                key as CFString, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost
            ) as? Int
            if let v, v != 0 { return true }
        }
        return false
    }

    static var hasBackup: Bool { FileManager.default.fileExists(atPath: backupPath) }

    /// The three-finger gestures, which turning the four-finger ones off leaves alone.
    static var threeFinger: ThreeFingerGestures {
        func on(_ key: String) -> Bool {
            appDomains.contains { domain in
                (CFPreferencesCopyAppValue(key as CFString, domain as CFString) as? Int ?? 0) != 0
            }
        }
        return ThreeFingerGestures(
            swipesBetweenDesktops: on("TrackpadThreeFingerHorizSwipeGesture"),
            missionControl: on("TrackpadThreeFingerVertSwipeGesture"),
            drag: on("TrackpadThreeFingerDrag")
        )
    }

    /// `off` or `restore`.
    static func run(_ action: String) -> (ok: Bool, output: String) {
        guard let script = Bundle.main.path(forResource: "gestures", ofType: "sh") else {
            return (false, "gestures.sh was not found in the app bundle.")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script, action]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return (false, error.localizedDescription)
        }
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (process.terminationStatus == 0, output.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

extension GridChoice {
    /// The snap grid's choices as offered in the settings and the setup, by their stored value.
    static let titled: [(title: String, raw: String)] = [
        ("Off", "off"),
        ("Auto (by display width)", "auto"),
        ("Halves and quarters · 2 × 2", "2x2"),
        ("Thirds and sixths · 3 × 2", "3x2"),
        ("Thirds · 3 × 1", "3x1"),
    ]
}

/// An accessory app's window opened from the menu can land behind the front app on macOS 14 and
/// later (activation is only a request; measured in Evlat, a sibling app). So while any of
/// Tutamak's windows is open the app is a regular one, with a Dock icon, and it becomes an accessory
/// again once the last one closes.
enum AppWindows {
    private static var open = 0

    static func opened() {
        open += 1
        NSApp.setActivationPolicy(.regular)
    }

    static func closed() {
        open = max(0, open - 1)
        if open == 0 { NSApp.setActivationPolicy(.accessory) }
    }
}
