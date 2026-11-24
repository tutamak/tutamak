import AppKit

/// Tutamak is built in two flavors that can live on one Mac (see the Makefile): the release,
/// "Tutamak", which people download and which updates itself, and the development build,
/// "Tutamak Dev", which `make install` puts in ~/Applications and which never updates. Both act
/// on every four-finger gesture, so each one notices when the other is running too.
enum Flavor {
    static let releaseID = "dev.tutamak.tutamak"
    static let developmentID = "local.tutamak"

    static var bundleID: String { Bundle.main.bundleIdentifier ?? developmentID }
    static var isRelease: Bool { bundleID == releaseID }

    /// The other flavor's copies that are running now.
    static func othersRunning() -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: isRelease ? developmentID : releaseID)
    }

    /// "Tutamak", or "Tutamak Dev" for a development build.
    static var name: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Tutamak"
    }

    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "–"
    }

    /// The update feed this copy checks, or nil for no updater at all. Only a release build carries
    /// one (`SUFeedURL`); a development build without it never offers to replace itself with the
    /// release. `TUTAMAK_FEED` points a copy at another feed, to try an update against a local
    /// appcast before a release goes out.
    static func feed(info: [String: Any], environment: [String: String]) -> String? {
        if let forced = environment["TUTAMAK_FEED"], !forced.isEmpty { return forced }
        guard let feed = info["SUFeedURL"] as? String, !feed.isEmpty else { return nil }
        return feed
    }
}

/// Where the app runs from, and whether it should offer to move itself into Applications.
enum AppLocation {
    enum Place: Equatable {
        /// In /Applications or ~/Applications: where it belongs.
        case applications
        /// Opened straight from the disk image.
        case diskImage
        /// Opened where the browser put it (or on the desktop).
        case downloads
        /// Anywhere else, such as a build folder: left alone.
        case elsewhere
    }

    /// `path` is where the app really is (for a translocated copy, its original path).
    static func place(of path: String, home: String, readOnlyVolume: Bool) -> Place {
        let path = (path as NSString).standardizingPath
        if path.hasPrefix("/Applications/") || path.hasPrefix(home + "/Applications/") { return .applications }
        if readOnlyVolume { return .diskImage }
        if path.hasPrefix(home + "/Downloads/") || path.hasPrefix(home + "/Desktop/") { return .downloads }
        return .elsewhere
    }
}
