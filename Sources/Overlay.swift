import AppKit

/// Display information in CG/AX coordinates.
struct ScreenInfo {
    let frame: CGRect
    let visible: CGRect

    /// Must be called on the main thread.
    static func current() -> [ScreenInfo] {
        let screens = NSScreen.screens
        guard let primary = screens.first else { return [] }
        let h = primary.frame.maxY
        return screens.map {
            ScreenInfo(
                frame: Geometry.flip($0.frame, primaryHeight: h),
                visible: Geometry.flip($0.visibleFrame, primaryHeight: h)
            )
        }
    }
}

/// Rebuilds an overlay's window whenever the displays change. A window made before the change can
/// end up on no Space at all: seen after switching from the laptop display to an external one, the
/// window took its frame, was ordered in at full alpha and still never appeared. Re-setting its
/// collection behavior did not help; a fresh window with the same settings showed at once.
private final class DisplayChangeWatcher {
    private var observer: NSObjectProtocol?

    init(_ handler: @escaping () -> Void) {
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { _ in handler() }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }
}

/// A translucent preview of where the window will land when released. Main thread only.
///
/// It grows into place when it appears, glides between zones, and fades out while the window
/// animates into the same spot.
final class SnapOverlay {
    private let inset: CGFloat = 6
    private var shownFrame: CGRect?
    /// Bumped on every change so a finishing fade-out does not hide a preview shown after it began.
    private var generation = 0
    private var built: NSWindow?
    private var displayWatcher: DisplayChangeWatcher?

    init() {
        displayWatcher = DisplayChangeWatcher { [weak self] in
            guard let self, self.built != nil else { return }
            self.discardWindow()
            logger.notice("snap preview rebuilt after a display change")
        }
    }

    /// The window, built on first use and again after the displays change.
    private var window: NSWindow {
        if let built { return built }
        let w = Self.makeWindow()
        built = w
        return w
    }

    private func discardWindow() {
        guard let old = built else { return }
        built = nil
        shownFrame = nil
        generation += 1
        old.orderOut(nil)
    }

    private static func makeWindow() -> NSWindow {
        let w = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: true)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.isReleasedWhenClosed = false
        // Above the grid backdrop.
        w.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

        let view = NSView()
        view.wantsLayer = true
        if let layer = view.layer {
            layer.cornerRadius = 12
            layer.cornerCurve = .continuous
            layer.borderWidth = 2
            layer.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor
            layer.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.7).cgColor
        }
        w.contentView = view
        return w
    }

    /// `frame` is in CG/AX coordinates.
    func show(_ frame: CGRect) {
        guard let primary = NSScreen.screens.first else { return }
        let cocoa = Geometry.flip(frame, primaryHeight: primary.frame.maxY).insetBy(dx: inset, dy: inset)
        generation += 1

        if shownFrame != nil {
            // Already visible: glide to the new zone.
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                window.animator().setFrame(cocoa, display: true)
                window.animator().alphaValue = 1
            }
        } else {
            // Appearing: grow from slightly smaller while fading in.
            let start = cocoa.insetBy(dx: min(24, cocoa.width / 8), dy: min(24, cocoa.height / 8))
            window.setFrame(start, display: false)
            window.alphaValue = 0
            window.orderFrontRegardless()
            if !window.isOnActiveSpace {
                // Stranded off every Space without a display-change notice: start over with a fresh window.
                discardWindow()
                generation += 1
                window.setFrame(start, display: false)
                window.alphaValue = 0
                window.orderFrontRegardless()
                logger.notice("snap preview was not on the current Space; rebuilt it")
            }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                window.animator().setFrame(cocoa, display: true)
                window.animator().alphaValue = 1
            }
        }
        shownFrame = cocoa
    }

    func hide() {
        guard shownFrame != nil, let window = built else { return }
        shownFrame = nil
        generation += 1
        let current = generation
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.generation == current else { return }
            window.orderOut(nil)
        })
    }
}

/// The drop grid drawn faintly over a display while a window is dragged, in the same style as the
/// snap preview (which glides over it to the zone under the cursor). It sits just below the dragged
/// window, so the window stays clear while every other window is covered. Main thread only.
final class GridBackdrop {
    /// The same inset as the snap preview, so a preview of one cell sits exactly on it.
    private let inset: CGFloat = 6
    private var shownArea: CGRect?
    private var below: CGWindowID?
    private var generation = 0
    private let cellsLayer = CAShapeLayer()
    /// A faint light line inside the accent one, so the cells read on dark windows too.
    private let innerLayer = CAShapeLayer()
    private var built: NSWindow?
    private var displayWatcher: DisplayChangeWatcher?

    init() {
        displayWatcher = DisplayChangeWatcher { [weak self] in
            guard let self, self.built != nil else { return }
            self.discardWindow()
            logger.notice("snap grid rebuilt after a display change")
        }
    }

    /// The window, built on first use and again after the displays change (see `DisplayChangeWatcher`).
    private var window: NSWindow {
        if let built { return built }
        let w = makeWindow()
        built = w
        return w
    }

    private func discardWindow() {
        guard let old = built else { return }
        built = nil
        shownArea = nil
        generation += 1
        old.orderOut(nil)
    }

    private func makeWindow() -> NSWindow {
        let w = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: true)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.isReleasedWhenClosed = false
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

        let accent = NSColor.controlAccentColor
        cellsLayer.fillColor = accent.withAlphaComponent(0.07).cgColor
        cellsLayer.strokeColor = accent.withAlphaComponent(0.6).cgColor
        cellsLayer.lineWidth = 1.5
        innerLayer.fillColor = nil
        innerLayer.strokeColor = NSColor.white.withAlphaComponent(0.22).cgColor
        innerLayer.lineWidth = 1
        let view = NSView()
        view.wantsLayer = true
        view.layer?.addSublayer(cellsLayer)
        view.layer?.addSublayer(innerLayer)
        w.contentView = view
        return w
    }

    /// `visible` (a display's visible area) and `cells` are in CG/AX coordinates. `window` is the
    /// dragged window; without it the grid floats above everything.
    func show(_ cells: [CGRect], in visible: CGRect, below window: CGWindowID?) {
        show(cells, in: visible, below: window, rebuilt: false)
    }

    private func show(_ cells: [CGRect], in visible: CGRect, below window: CGWindowID?, rebuilt: Bool) {
        guard let primary = NSScreen.screens.first, shownArea != visible else { return }
        let h = primary.frame.maxY
        let area = Geometry.flip(visible, primaryHeight: h)
        generation += 1
        self.window.setFrame(area, display: false)

        let outer = CGMutablePath()
        let inner = CGMutablePath()
        for cell in cells {
            let c = Geometry.flip(cell, primaryHeight: h).insetBy(dx: inset, dy: inset)
            let local = c.offsetBy(dx: -area.minX, dy: -area.minY)
            outer.addRoundedRect(in: local, cornerWidth: 12, cornerHeight: 12)
            inner.addRoundedRect(in: local.insetBy(dx: 1.5, dy: 1.5), cornerWidth: 10.5, cornerHeight: 10.5)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in [cellsLayer, innerLayer] { layer.frame = CGRect(origin: .zero, size: area.size) }
        cellsLayer.path = outer
        innerLayer.path = inner
        CATransaction.commit()

        let appearing = shownArea == nil
        shownArea = visible
        below = window
        if appearing { self.window.alphaValue = 0 }
        restack()
        if appearing, !rebuilt, !self.window.isOnActiveSpace {
            // Stranded off every Space without a display-change notice: start over, once, with a fresh window.
            discardWindow()
            logger.notice("snap grid was not on the current Space; rebuilding it")
            show(cells, in: visible, below: window, rebuilt: true)
            return
        }
        if appearing {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                self.window.animator().alphaValue = 1
            }
            // The dragged window's app may still be coming to the front; settle below it again.
            let current = generation
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self, self.generation == current else { return }
                self.restack()
            }
        }
    }

    func hide() {
        guard shownArea != nil, let window = built else { return }
        shownArea = nil
        generation += 1
        let current = generation
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.generation == current else { return }
            window.orderOut(nil)
        })
    }

    private func restack() {
        if let below {
            window.level = .normal
            window.order(.below, relativeTo: Int(below))
        } else {
            window.level = .floating
            window.orderFrontRegardless()
        }
    }
}
