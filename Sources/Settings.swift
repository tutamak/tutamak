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

/// While macOS's own four-finger gestures (Mission Control, Spaces, Launchpad) are on,
/// they fire on every drag too. Reads them, and turns them off/back on with the bundled script.
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
