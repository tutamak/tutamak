import AppKit
import SwiftUI

/// Where the About window's links lead. The website says the same things in more words.
enum Links {
    static let website = URL(string: "https://tutamak.kalaomer.com")!
    static let changelog = URL(string: "https://tutamak.kalaomer.com/changelog")!
    static let source = URL(string: "https://github.com/tutamak/tutamak")!
    static let issues = URL(string: "https://github.com/tutamak/tutamak/issues")!
}

/// The About window, from the menu: what Tutamak is, its version, where its name comes from and
/// where to go next. One instance, brought forward when opened again.
final class AboutWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    var onClose: () -> Void = {}

    func show() {
        if window == nil {
            AppWindows.opened()
            window = makeWindow()
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let window = AboutPanel(contentRect: .zero, styleMask: [.titled, .closable, .fullSizeContentView],
                                backing: .buffered, defer: false)
        window.title = "About \(Flavor.name)"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        let host = NSHostingView(rootView: AboutView(
            name: Flavor.name, version: Flavor.version, development: !Flavor.isRelease,
            icon: NSApp.applicationIconImage
        ))
        // The window takes the view's size: the text sets the height, the view a fixed width.
        window.contentView = host
        window.setContentSize(host.fittingSize)
        window.center()
        return window
    }

    func windowWillClose(_ notification: Notification) {
        window?.contentView = nil
        window = nil
        AppWindows.closed()
        onClose()
    }
}

/// Closes on Escape and ⌘W. The app has no main menu to send ⌘W, so the window answers it itself.
private final class AboutPanel: NSWindow {
    override func cancelOperation(_ sender: Any?) {
        close()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "w" {
            close()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// Everything it shows comes in as values, so a capture outside the app bundle draws the real thing.
struct AboutView: View {
    let name: String
    let version: String
    let development: Bool
    let icon: NSImage

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)

            Text(name)
                .font(.system(size: 22, weight: .semibold))
                .padding(.top, 8)
            Text(development ? "Version \(version) · Development build" : "Version \(version)")
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .padding(.top, 2)

            // Broken by hand: at this width it would leave "your trackpad." alone on the second line.
            Text("Move and resize windows\nwith four fingers on your trackpad.")
                .padding(.top, 18)

            VStack(spacing: 8) {
                Text("Tutamak is Turkish for “handle”: the part of something you hold on to. It gives every window one.")
                Text("Written by Claude, Anthropic's AI model, which also picked the name.")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.top, 10)

            HStack(spacing: 18) {
                Link("Website", destination: Links.website)
                Link("What's New", destination: Links.changelog)
                Link("Report a Problem", destination: Links.issues)
            }
            .font(.callout)
            .padding(.top, 20)

            Link(destination: Links.source) {
                Text("Free and open source, Apache License 2.0")
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
            .padding(.top, 14)
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: 300)
        // Below the title bar, which the window's safe area already keeps clear.
        .padding(.top, 8)
        .padding(.horizontal, 28)
        .padding(.bottom, 24)
    }
}
