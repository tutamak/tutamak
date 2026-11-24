import AppKit
import Observation
import SwiftUI

/// System Settings' main window, found by the app's pid, because the owner name of its windows
/// follows the system language. Reading window bounds needs no permission.
enum SettingsWindow {
    static let bundleID = "com.apple.systempreferences"
    /// Lands on Privacy & Security > Accessibility (checked on macOS 26.4).
    static let accessibilityURL = URL(
        string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility"
    )!

    static func openAccessibility() { NSWorkspace.shared.open(accessibilityURL) }

    /// The largest normal window of System Settings on screen, in Cocoa coordinates; nil when it
    /// is closed or minimized.
    static func frame() -> CGRect? {
        let pids = Set(NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).map(\.processIdentifier))
        guard !pids.isEmpty, let primary = NSScreen.screens.first?.frame.height else { return nil }
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        var best: CGRect?
        for info in list {
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, pids.contains(pid),
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let b = info[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            let r = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
            guard r.width > 300, r.height > 300 else { continue }
            if best.map({ $0.width * $0.height < r.width * r.height }) ?? true { best = r }
        }
        return best.map { Geometry.flip($0, primaryHeight: primary) }
    }
}

/// The guide card's state, shown by `GuideCard`.
@Observable
final class GuideCardModel {
    var side = GuidePlacement.Side.right
    var granted = false
    /// The user is dragging the icon; the hint steps aside.
    var dragging = false
    /// The icon's frame in the card (y down), where the hint starts from.
    @ObservationIgnored var iconFrame: CGRect?
}

/// Guides the Accessibility grant the way recent Mac apps do: opens the right pane of System
/// Settings, flies a card from the button that was pressed to a spot beside the Settings window,
/// and gives the user Tutamak's icon to drag into the list. The card follows the window and goes
/// away on every way out: granted, Settings closed or minimized, `cancel()`.
final class PermissionGuide {
    enum End { case granted, gone }

    static let cardSize = CGSize(width: 312, height: 150)

    private let isGranted: () -> Bool
    private let onEnd: (End) -> Void
    /// A finished drop counts as the grant (`--setup-demo`, where the Mac already granted it).
    private let demo: Bool
    private let card = GuideCardModel()
    private var panel: NSPanel?
    private var hint: NSPanel?
    private var timer: Timer?
    private var lastSettings: CGRect?
    private var ended = false

    init(demo: Bool, isGranted: @escaping () -> Bool, onEnd: @escaping (End) -> Void) {
        self.demo = demo
        self.isGranted = isGranted
        self.onEnd = onEnd
    }

    /// Opens Settings and, once its window has stopped moving, flies the card from `source`
    /// (a screen rect, usually the button) to beside it.
    func start(from source: CGRect?) {
        SettingsWindow.openAccessibility()
        var previous: CGRect?
        var waited = 0.0
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] timer in
            guard let self else { return timer.invalidate() }
            waited += 0.1
            let frame = SettingsWindow.frame()
            // Two equal readings in a row: the window has opened (or come back from the Dock).
            if let frame, frame.integral == previous?.integral {
                timer.invalidate()
                self.dock(beside: frame, from: source)
            } else if waited > 6 {
                timer.invalidate()
                self.finish(.gone)
            }
            previous = frame
        }
    }

    /// The setup closed or went back: the card goes, and nothing is reported.
    func cancel() {
        ended = true
        timer?.invalidate()
        hideHint()
        panel?.orderOut(nil)
        panel = nil
    }

    // MARK: Card

    private func dock(beside settings: CGRect, from source: CGRect?) {
        let screen = NSScreen.screens.first { $0.frame.contains(CGPoint(x: settings.midX, y: settings.midY)) }
            ?? NSScreen.main ?? NSScreen.screens[0]
        let (target, side) = GuidePlacement.dock(card: Self.cardSize, beside: settings, in: screen.visibleFrame)
        card.side = side
        let panel = makePanel(frame: target)
        self.panel = panel
        lastSettings = settings

        if let source, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            // Out of the button and over to Settings, settling with a slight overshoot.
            panel.setFrame(CGRect(origin: CGPoint(x: source.midX - target.width / 2, y: source.midY - target.height / 2),
                                  size: target.size), display: false)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.6
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.3, 1.25, 0.55, 1)
                panel.animator().setFrame(target, display: true)
                panel.animator().alphaValue = 1
            }, completionHandler: { [weak self] in self?.showHint(settings: settings) })
        } else {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            panel.animator().alphaValue = 1
            showHint(settings: settings)
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in self?.watch() }
    }

    /// Follows the Settings window and watches for the grant.
    private func watch() {
        guard !ended else { return }
        if isGranted() { return grant() }
        guard let settings = SettingsWindow.frame() else { return finish(.gone) }
        guard settings.integral != lastSettings?.integral, let panel else { return }
        lastSettings = settings
        let screen = NSScreen.screens.first { $0.frame.contains(CGPoint(x: settings.midX, y: settings.midY)) }
            ?? NSScreen.screens[0]
        let (target, side) = GuidePlacement.dock(card: Self.cardSize, beside: settings, in: screen.visibleFrame)
        card.side = side
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            panel.animator().setFrame(target, display: true)
        }, completionHandler: { [weak self] in self?.showHint(settings: settings) })
    }

    // MARK: Hint

    /// A ghost of the icon, held by a closed hand, travels from the card into the list and
    /// drops there, over and over until the user drags the real one. It is drawn in a panel of
    /// its own that mouse events pass through, spanning the card and the list.
    private func showHint(settings: CGRect) {
        guard !ended, let panel, let icon = card.iconFrame,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let from = CGPoint(x: panel.frame.minX + icon.midX, y: panel.frame.maxY - icon.midY)
        // Into the list: the pane's right part, a little under its header.
        let to = CGPoint(x: settings.minX + settings.width * 0.62, y: settings.maxY - min(250, settings.height * 0.42))
        let frame = CGRect(x: min(from.x, to.x), y: min(from.y, to.y), width: abs(from.x - to.x), height: abs(from.y - to.y))
            .insetBy(dx: -90, dy: -110)
        let local = { (p: CGPoint) in CGPoint(x: p.x - frame.minX, y: frame.maxY - p.y) }
        let view = DragHint(model: card, from: local(from), to: local(to))
        let hint = self.hint ?? {
            let hint = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            hint.isFloatingPanel = true
            hint.level = .floating
            hint.isOpaque = false
            hint.backgroundColor = .clear
            hint.hasShadow = false
            hint.ignoresMouseEvents = true
            hint.hidesOnDeactivate = false
            hint.isReleasedWhenClosed = false
            hint.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            return hint
        }()
        let host = NSHostingView(rootView: view)
        host.sizingOptions = []
        hint.contentView = host
        hint.setFrame(frame, display: true)
        if self.hint == nil {
            self.hint = hint
            // Under the card, so the ghost seems to leave it.
            hint.order(.below, relativeTo: panel.windowNumber)
        }
    }

    private func hideHint() {
        hint?.orderOut(nil)
        hint = nil
    }

    private func dropEnded(dropped: Bool) {
        if demo, dropped { grant() }
    }

    private func grant() {
        guard !ended else { return }
        ended = true
        timer?.invalidate()
        hideHint()
        card.granted = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            guard let self, let panel = self.panel else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.25
                panel.animator().alphaValue = 0
            }, completionHandler: {
                panel.orderOut(nil)
                self.panel = nil
                self.onEnd(.granted)
            })
        }
    }

    private func finish(_ end: End) {
        guard !ended else { return }
        ended = true
        timer?.invalidate()
        hideHint()
        panel?.orderOut(nil)
        panel = nil
        onEnd(end)
    }

    private func makePanel(frame: CGRect) -> NSPanel {
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        // Stays with Settings under Stage Manager and over a full-screen Settings.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let host = NSHostingView(rootView: GuideCard(model: card) { [weak self] dropped in
            self?.card.dragging = false
            self?.dropEnded(dropped: dropped)
        })
        host.sizingOptions = []
        panel.contentView = GlassBackground.wrap(host, cornerRadius: 22)
        return panel
    }
}

/// Liquid Glass on macOS 26; a popover material on older systems (a fallback not yet tried on one).
enum GlassBackground {
    static func wrap(_ content: NSView, cornerRadius: CGFloat) -> NSView {
        if #available(macOS 26, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = cornerRadius
            glass.contentView = content
            return glass
        }
        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = cornerRadius
        effect.layer?.masksToBounds = true
        content.frame = effect.bounds
        content.autoresizingMask = [.width, .height]
        effect.addSubview(content)
        return effect
    }
}

/// The card beside Settings: where to drag, and the icon to drag.
private struct GuideCard: View {
    let model: GuideCardModel
    let onDragEnd: (Bool) -> Void

    private var arrow: String {
        switch model.side {
        case .right: "arrow.left"
        case .left: "arrow.right"
        case .below: "arrow.up"
        case .inside: "arrow.up.left"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: model.granted ? "checkmark.circle.fill" : arrow)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(model.granted ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 18)
                Text(model.granted ? "Tutamak is allowed" : "Drag Tutamak into the list")
                    .font(.system(size: 14, weight: .semibold))
                    .contentTransition(.opacity)
            }
            Text(model.granted ? "You can go back to the setup." : "Already listed? Switch it on instead.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.leading, 26)
                .padding(.top, 2)
                .contentTransition(.opacity)
            AppPill(model: model, onDragEnd: onDragEnd)
                .padding(.top, 14)
                .opacity(model.granted ? 0.4 : 1)
                .allowsHitTesting(!model.granted)
        }
        .padding(16)
        .frame(width: PermissionGuide.cardSize.width, height: PermissionGuide.cardSize.height, alignment: .topLeading)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: model.granted)
    }
}

/// Tutamak's icon and name, a real drag source carrying the app's bundle URL: dropped on the
/// Accessibility list, it adds Tutamak there.
private struct AppPill: View {
    let model: GuideCardModel
    let onDragEnd: (Bool) -> Void
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath))
                .resizable()
                .frame(width: 34, height: 34)
                .background(GeometryReader { proxy in
                    Color.clear.onAppear { model.iconFrame = proxy.frame(in: .global) }
                })
            Text("Tutamak")
                .font(.system(size: 13, weight: .semibold))
            Spacer(minLength: 0)
            Image(systemName: "hand.draw")
                .font(.system(size: 13))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 7)
        .padding(.leading, 8)
        .padding(.trailing, 12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.primary.opacity(hovered ? 0.09 : 0.05)))
        .overlay(DragSource(onBegin: { model.dragging = true }, onEnd: onDragEnd))
        .onHover { hovered = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Tutamak app icon. Drag it into the Accessibility list.")
    }
}

private struct DragSource: NSViewRepresentable {
    let onBegin: () -> Void
    let onEnd: (Bool) -> Void

    func makeNSView(context: Context) -> AppDragView {
        let view = AppDragView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: AppDragView, context: Context) {
        view.onBegin = onBegin
        view.onEnd = onEnd
    }
}

final class AppDragView: NSView, NSDraggingSource {
    var onBegin: () -> Void = {}
    var onEnd: (Bool) -> Void = { _ in }
    private var down: NSEvent?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        down = event
    }

    override func mouseDragged(with event: NSEvent) {
        guard let down else { return }
        self.down = nil
        let item = NSDraggingItem(pasteboardWriter: Bundle.main.bundleURL as NSURL)
        let icon = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
        let point = convert(down.locationInWindow, from: nil)
        item.setDraggingFrame(NSRect(x: point.x - 24, y: point.y - 24, width: 48, height: 48), contents: icon)
        onBegin()
        beginDraggingSession(with: [item], event: down, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? .copy : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        onEnd(operation != [])
    }
}

/// Shows the drag: a ghost of the icon is picked up by the hand, carried along a gentle arc into
/// the list and dropped there with a ring; then a pause, and it plays again. It steps aside while
/// the user drags the real icon and is gone once Tutamak is allowed.
private struct DragHint: View {
    let model: GuideCardModel
    /// In the hint panel (y down): the card's icon and the spot in the list.
    let from: CGPoint
    let to: CGPoint

    static let period = 3.4

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: Self.period)
            frame(at: t)
        }
        .opacity(model.dragging || model.granted ? 0 : 1)
        .animation(.easeOut(duration: 0.2), value: model.dragging)
        .allowsHitTesting(false)
    }

    @ViewBuilder private func frame(at t: Double) -> some View {
        let appear = SceneFrame.ease(SceneFrame.seg(t, 0, 0.35))
        let grab = SceneFrame.ease(SceneFrame.seg(t, 0.35, 0.5))
        let travel = SceneFrame.ease(SceneFrame.seg(t, 0.5, 1.7))
        let drop = SceneFrame.ease(SceneFrame.seg(t, 1.7, 2.1))
        let ring = SceneFrame.seg(t, 1.75, 2.35)
        let p = point(at: travel)
        let held = t >= 0.35 && t < 2.1
        let scale: CGFloat = (0.8 + 0.2 * appear) * (1 + 0.06 * grab) * (1 - 0.15 * drop)
        let opacity: Double = 0.92 * appear * (1 - drop)
        let ringSize: CGFloat = 18 + 52 * ring
        let hand: NSImage = (held ? NSCursor.closedHand : NSCursor.openHand).image

        ZStack(alignment: .topLeading) {
            if ring > 0, ring < 1 {
                Circle()
                    .stroke(Color.accentColor.opacity(0.55 * (1 - ring)), lineWidth: 2)
                    .frame(width: ringSize, height: ringSize)
                    .position(to)
            }
            ZStack {
                Image(nsImage: NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath))
                    .resizable()
                    .frame(width: 34, height: 34)
                    .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
                    .scaleEffect(scale)
                Image(nsImage: hand)
                    .offset(x: 8, y: 10)
            }
            .opacity(opacity)
            .position(p)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// A point along a quadratic curve that rises above the straight line, like a hand carrying the icon.
    private func point(at k: Double) -> CGPoint {
        let control = CGPoint(x: (from.x + to.x) / 2, y: min(from.y, to.y) - 70)
        let a = 1 - k
        return CGPoint(x: a * a * from.x + 2 * a * k * control.x + k * k * to.x,
                       y: a * a * from.y + 2 * a * k * control.y + k * k * to.y)
    }
}
