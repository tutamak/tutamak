import AppKit

/// A release copy opened from the disk image or from Downloads offers, once per launch, to move
/// itself into /Applications and open again from there. A copy left on the disk image stops when
/// the image is ejected and cannot update itself; one opened from Downloads runs from a random
/// read-only path (App Translocation), which Sparkle cannot replace either.
enum AppMover {
    /// Returns true when the app is moving and about to quit; the caller then starts nothing.
    static func offerMoveIfNeeded() -> Bool {
        guard Flavor.isRelease else { return false }
        let running = Bundle.main.bundleURL
        let original = originalURL(of: running) ?? running
        let readOnly = (try? original.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly ?? false
        let place = AppLocation.place(of: original.path, home: NSHomeDirectory(), readOnlyVolume: readOnly)
        guard place == .diskImage || place == .downloads else { return false }

        let alert = NSAlert()
        alert.messageText = "Move Tutamak to Applications?"
        alert.informativeText = place == .diskImage
            ? "Tutamak is running from the disk image. In Applications it keeps running after the disk image is ejected, and it can update itself."
            : "Tutamak is running from your Downloads folder. In Applications it can update itself."
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Not Now")
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return false }

        let destination = URL(fileURLWithPath: "/Applications").appendingPathComponent(original.lastPathComponent)
        do {
            try install(original, at: destination, copy: place == .diskImage)
        } catch {
            let failure = NSAlert()
            failure.messageText = "Tutamak could not be moved"
            failure.informativeText = "\(error.localizedDescription)\n\nDrag Tutamak into the Applications folder yourself, then open it from there."
            failure.runModal()
            return false
        }
        relaunch(destination, eject: place == .diskImage ? volume(of: original) : nil)
        return true
    }

    /// Puts the app at `destination`, sending a copy already there to the Trash. A disk image is
    /// read-only, so its app is copied; one in Downloads is moved.
    private static func install(_ source: URL, at destination: URL, copy: Bool) throws {
        let files = FileManager.default
        if files.fileExists(atPath: destination.path) {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: Flavor.bundleID)
            where app.bundleURL?.standardizedFileURL == destination.standardizedFileURL {
                app.terminate()
            }
            try files.trashItem(at: destination, resultingItemURL: nil)
        }
        if copy {
            try files.copyItem(at: source, to: destination)
        } else {
            try files.moveItem(at: source, to: destination)
        }
    }

    /// Opens the moved app once this process has exited, then ejects the disk image it came from.
    /// The paths go to the shell as arguments, never inside the script.
    private static func relaunch(_ app: URL, eject volume: URL?) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        while kill -0 \(pid) 2>/dev/null; do sleep 0.1; done
        /usr/bin/open "$1"
        if [ -n "$2" ]; then /usr/bin/hdiutil detach -quiet "$2"; fi
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "sh", app.path, volume?.path ?? ""]
        do {
            try process.run()
        } catch {
            NSWorkspace.shared.open(app)
        }
        NSApp.terminate(nil)
    }

    private static func volume(of url: URL) -> URL? {
        (try? url.resourceValues(forKeys: [.volumeURLKey]))?.volume
    }

    /// The path a translocated app was opened from, through Security's
    /// `SecTranslocateCreateOriginalPathForURL` (exported, but not in the SDK headers).
    private static func originalURL(of url: URL) -> URL? {
        guard url.path.contains("/AppTranslocation/"),
              let security = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY),
              let symbol = dlsym(security, "SecTranslocateCreateOriginalPathForURL") else { return nil }
        typealias Original = @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?
        let original = unsafeBitCast(symbol, to: Original.self)
        return original(url as CFURL, nil)?.takeRetainedValue() as URL?
    }
}
