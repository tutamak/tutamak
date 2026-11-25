import AppKit
import os
import SwiftUI

/// What the touch window shows: the fingers, in a `PracticeFeed` whose drawing it shares with the
/// setup's practice, and a caption naming the gesture they make. Unlike the practice it only
/// watches: `GestureController` hands it every frame and gesture and goes on to act on them.
///
/// Written on the gesture queue and read by the drawing on each display frame.
final class TouchFeed {
    struct Caption {
        var text: String
        /// ⌥ is held. A recording shows the fingers but not the keyboard, and ⌥ changes what a
        /// slide does, so the caption shows it as a key.
        var option: Bool
        /// When the gesture ended (system uptime), or nil while it goes on.
        var ended: Double?
    }

    /// How long a caption stays after its gesture ends, then how long it takes to fade.
    static let captionHold = 0.8
    static let captionFade = 0.3

    let fingers = PracticeFeed()
    /// Called on the main queue when the first finger touches and when the last one lifts.
    var onTouching: (Bool) -> Void = { _ in }

    private let lock = OSAllocatedUnfairLock<Caption?>(initialState: nil)
    // Used only on the gesture queue.
    private var touching = false

    var caption: Caption? { lock.withLock { $0 } }

    private var now: Double { ProcessInfo.processInfo.systemUptime }

    /// The fingers touching now, by id, in trackpad units with y down.
    func touches(_ points: [Int32: CGPoint]) {
        fingers.touches(points)
        let down = !points.isEmpty
        guard down != touching else { return }
        touching = down
        let onTouching = self.onTouching
        DispatchQueue.main.async { onTouching(down) }
    }

    func handle(_ event: GestureEvent) {
        let option = CGEventSource.flagsState(.combinedSessionState).contains(.maskAlternate)
        let now = self.now
        lock.withLock { caption in
            switch event {
            case .began:
                caption = Caption(text: "Slide", option: option)
            case .moved:
                caption?.option = option
            case .resizeBegan:
                caption = Caption(text: "Pinch", option: option)
            case .resized(let spread):
                if spread.radial != 0 { caption?.text = spread.radial < 0 ? "Pinch" : "Spread" }
                caption?.option = option
            case .ended, .resizeEnded:
                caption?.option = option
                caption?.ended = now
            case .tapped:
                caption = Caption(text: "Tap", option: option, ended: now)
            case .swiped(let direction):
                let arrow = switch direction {
                case .left: "←"
                case .right: "→"
                case .up: "↑"
                case .down: "↓"
                }
                caption = Caption(text: "Flick \(arrow)", option: option, ended: now)
            }
        }
    }

    /// The gesture was cut short and its frames may not come again: no finger is left on the
    /// drawing, and no caption waits for an end that will not arrive.
    func cancel() {
        touches([:])
        let now = self.now
        lock.withLock { caption in
            if caption != nil, caption?.ended == nil { caption?.ended = now }
        }
    }

    /// Nothing left to draw: no finger down and the caption gone. (A lifted finger fades in a
    /// quarter of a second, well within the caption's time.)
    func isSettled(at now: Double) -> Bool {
        guard fingers.state.fingers.isEmpty else { return false }
        guard let caption else { return true }
        guard let ended = caption.ended else { return false }
        return now - ended > Self.captionHold + Self.captionFade
    }
}

/// A small trackpad in a corner of the screen that shows where the fingers are and names the
/// gesture they make, for screen recordings. A development-build tool: Tutamak Dev's menu has it
/// under Show Touches. Main thread only.
///
/// It only shows. Clicks pass through it, it stays put while desktops switch and Mission Control
/// opens, and it sits above the snap preview and the grid.
final class TouchWindow {
    enum Corner: String, CaseIterable {
        case bottomRight, bottomLeft, topRight, topLeft

        var title: String {
            switch self {
            case .bottomRight: "Bottom Right"
            case .bottomLeft: "Bottom Left"
            case .topRight: "Top Right"
            case .topLeft: "Top Left"
            }
        }

        var isLeft: Bool { self == .bottomLeft || self == .topLeft }
        var isTop: Bool { self == .topRight || self == .topLeft }
    }

    /// How big it is: everything in it scales together, from the trackpad to the caption's type.
    enum Size: String, CaseIterable {
        case small, medium, large, extraLarge

        var title: String {
            switch self {
            case .small: "Small"
            case .medium: "Medium"
            case .large: "Large"
            case .extraLarge: "Extra Large"
            }
        }

        var scale: CGFloat {
            switch self {
            case .small: 0.75
            case .medium: 1
            case .large: 1.35
            case .extraLarge: 1.75
            }
        }

        /// The window at this size; at Medium the trackpad is 240 pt wide.
        var window: CGSize { CGSize(width: 272 * scale, height: 238 * scale) }
    }
    /// From the screen's edge (beside the Dock and below the menu bar) to the window, whose
    /// drawing keeps 16 pt of room for its shadow.
    private static let inset: CGFloat = 4

    let feed = TouchFeed()
    private(set) var corner: Corner?
    private(set) var size = Size.medium
    private let model = TouchModel()
    private var panel: NSPanel?
    private var displayWatcher: DisplayChangeWatcher?
    private var sleep: DispatchWorkItem?

    init() {
        feed.onTouching = { [weak self] down in self?.touching(down) }
        // A window made before a display change can end up on no Space (see `SnapOverlay`).
        displayWatcher = DisplayChangeWatcher { [weak self] in
            guard let self, let corner = self.corner else { return }
            self.panel?.orderOut(nil)
            self.panel = nil
            self.show(in: corner, size: self.size)
        }
    }

    /// Shows it in `corner` of the screen with the pointer, at `size`.
    func show(in corner: Corner, size: Size) {
        self.corner = corner
        if size != self.size {
            // Built again at the new size; the fingers' easing starts over, which nothing shows.
            panel?.orderOut(nil)
            panel = nil
            self.size = size
        }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else { return }
        let v = screen.visibleFrame
        let size = size.window
        panel.setFrameOrigin(NSPoint(
            x: corner.isLeft ? v.minX + Self.inset : v.maxX - size.width - Self.inset,
            y: corner.isTop ? v.maxY - size.height - Self.inset : v.minY + Self.inset
        ))
        panel.orderFrontRegardless()
    }

    func close() {
        corner = nil
        sleep?.cancel()
        panel?.orderOut(nil)
        panel = nil
    }

    /// The drawing runs at the display's pace only while there is something to move: from the
    /// first touch until the last finger and the caption have faded.
    private func touching(_ down: Bool) {
        sleep?.cancel()
        if down {
            model.awake = true
        } else {
            scheduleSleep()
        }
    }

    private func scheduleSleep() {
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.feed.isSettled(at: ProcessInfo.processInfo.systemUptime) {
                self.model.awake = false
            } else {
                self.scheduleSleep()
            }
        }
        sleep = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size.window), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        // The drawing casts its own.
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        // Above the grid and the snap preview, which sit at the floating level and just above it.
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        let host = NSHostingView(rootView: TouchView(feed: feed, model: model, scale: size.scale))
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: size.window)
        p.contentView = host
        return p
    }
}

@Observable
private final class TouchModel {
    /// Something on the trackpad is moving; while false the drawing holds its last frame.
    var awake = false
}

private struct TouchView: View {
    let feed: TouchFeed
    let model: TouchModel
    /// 1 at Medium. Every length below is drawn at this scale rather than scaled as a picture,
    /// so it stays sharp at every size.
    let scale: CGFloat
    /// Eases the fingers between display frames, as in the setup's practice; kept across redraws.
    @State private var smoother = LiveSmoother()

    var body: some View {
        let s = scale
        TimelineView(.animation(minimumInterval: nil, paused: !model.awake)) { _ in
            let now = ProcessInfo.processInfo.systemUptime
            VStack(spacing: 10 * s) {
                TrackpadView(frame: smoother.frame(for: feed.fingers.state, now: now))
                    .frame(width: 240 * s, height: 169 * s)
                    .shadow(color: .black.opacity(0.25), radius: 12 * s, y: 4 * s)
                CaptionView(caption: feed.caption, now: now, scale: s)
            }
            .padding(16 * s)
            .frame(width: 272 * s, height: 238 * s, alignment: .top)
        }
    }
}

/// The gesture's name in a pill under the trackpad, with ⌥ beside it while it is held.
private struct CaptionView: View {
    let caption: TouchFeed.Caption?
    let now: Double
    let scale: CGFloat
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        // The trackpad's own colors, so the two read as one piece.
        let fill = dark ? Color(red: 0x2C / 255, green: 0x2E / 255, blue: 0x33 / 255)
                        : Color(red: 0xEC / 255, green: 0xED / 255, blue: 0xF0 / 255)
        let edge = dark ? Color(red: 0x3B / 255, green: 0x3E / 255, blue: 0x44 / 255)
                        : Color(red: 0xD6 / 255, green: 0xD8 / 255, blue: 0xDD / 255)
        let s = scale
        HStack(spacing: 7 * s) {
            if caption?.option == true {
                Text("⌥")
                    .font(.system(size: 12 * s, weight: .semibold))
                    .frame(width: 20 * s, height: 18 * s)
                    .background(RoundedRectangle(cornerRadius: 4.5 * s, style: .continuous)
                        .strokeBorder(.secondary, lineWidth: max(1, s)))
            }
            Text(caption?.text ?? "")
                .font(.system(size: 13 * s, weight: .semibold))
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 12 * s)
        .frame(height: 28 * s)
        .background(Capsule().fill(fill))
        .overlay(Capsule().strokeBorder(edge, lineWidth: max(1, s)))
        .shadow(color: .black.opacity(0.2), radius: 8 * s, y: 3 * s)
        .opacity(opacity)
    }

    private var opacity: Double {
        guard let caption else { return 0 }
        guard let ended = caption.ended else { return 1 }
        let t = now - ended - TouchFeed.captionHold
        return 1 - SceneFrame.ease(min(max(t / TouchFeed.captionFade, 0), 1))
    }
}
