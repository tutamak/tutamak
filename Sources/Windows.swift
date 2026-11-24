import AppKit
import ApplicationServices

/// A movable window under the pointer.
struct TargetWindow {
    let element: AXUIElement
    let pid: pid_t
    /// In CG/AX coordinates.
    let frame: CGRect
    let appName: String
}

/// Finding and moving windows through the Accessibility (AX) API.
enum AX {
    static func window(at location: CGPoint) -> TargetWindow? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.3)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(location.x), Float(location.y), &hit) == .success,
              let hit, let window = containingWindow(of: hit)
        else { return nil }
        AXUIElementSetMessagingTimeout(window, 0.3)

        var pid: pid_t = 0
        AXUIElementGetPid(window, &pid)
        if pid == getpid() { return nil }
        if bool(window, "AXFullScreen") == true { return nil }

        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(window, kAXPositionAttribute as CFString, &settable) == .success,
              settable.boolValue,
              let origin = point(window, kAXPositionAttribute),
              let size = size(window, kAXSizeAttribute)
        else { return nil }

        let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "pid \(pid)"
        return TargetWindow(element: window, pid: pid, frame: CGRect(origin: origin, size: size), appName: name)
    }

    /// The window server's ID for a window element (private API), to order our own windows next to it.
    static func windowID(_ element: AXUIElement) -> CGWindowID? {
        var id: CGWindowID = 0
        return _AXUIElementGetWindow(element, &id) == .success && id != 0 ? id : nil
    }

    static func isSizeSettable(_ element: AXUIElement) -> Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(element, kAXSizeAttribute as CFString, &settable) == .success
            && settable.boolValue
    }

    static func frame(_ element: AXUIElement) -> CGRect? {
        guard let origin = point(element, kAXPositionAttribute), let size = size(element, kAXSizeAttribute) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    /// Applies a size, then places the window from the size the app actually accepted, so a window
    /// that refuses a size (a minimum, a fixed size, size steps) stays anchored instead of sliding.
    /// `anchor` is the point that stays put: 0 = min edge, 1 = max edge, 0.5 = center.
    static func setFrame(_ element: AXUIElement, _ frame: CGRect, anchor: CGPoint) {
        // When growing, move first: apps keep windows on screen by trimming a size that would push
        // past the screen edge from where the window still is. A window hugging the right edge
        // would otherwise be held at its width, and the anchoring below would take that as the
        // app's choice.
        if let current = size(element, kAXSizeAttribute),
           frame.width > current.width || frame.height > current.height {
            setOrigin(element, frame.origin)
        }
        setSize(element, frame.size)
        let actual = size(element, kAXSizeAttribute) ?? frame.size
        setOrigin(element, CGPoint(
            x: frame.minX + (frame.width - actual.width) * anchor.x,
            y: frame.minY + (frame.height - actual.height) * anchor.y
        ))
    }

    /// Brings the window to the front and activates its app, as if it were grabbed by its title bar.
    static func raise(_ window: TargetWindow) {
        AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(window.element, kAXMainAttribute as CFString, kCFBooleanTrue)
        let app = AXUIElementCreateApplication(window.pid)
        AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    }

    private static func containingWindow(of element: AXUIElement) -> AXUIElement? {
        if string(element, kAXRoleAttribute) == kAXWindowRole { return element }
        if let window = child(element, kAXWindowAttribute) { return window }
        var current = element
        for _ in 0..<32 {
            guard let parent = child(current, kAXParentAttribute) else { return nil }
            if string(parent, kAXRoleAttribute) == kAXWindowRole { return parent }
            current = parent
        }
        return nil
    }

    // MARK: Attributes

    private static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    private static func child(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let v = value(element, attribute), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        value(element, attribute) as? String
    }

    static func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        value(element, attribute) as? Bool
    }

    static func point(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
        guard let v = value(element, attribute), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero
        return AXValueGetValue(v as! AXValue, .cgPoint, &p) ? p : nil
    }

    static func size(_ element: AXUIElement, _ attribute: String) -> CGSize? {
        guard let v = value(element, attribute), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var s = CGSize.zero
        return AXValueGetValue(v as! AXValue, .cgSize, &s) ? s : nil
    }

    static func setOrigin(_ element: AXUIElement, _ origin: CGPoint) {
        var p = origin
        guard let v = AXValueCreate(.cgPoint, &p) else { return }
        AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, v)
    }

    static func setSize(_ element: AXUIElement, _ size: CGSize) {
        var s = size
        guard let v = AXValueCreate(.cgSize, &s) else { return }
        AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, v)
    }
}

/// AX calls are synchronous IPC to the target app and can pile up when that app is slow.
/// This class applies only the latest requested position; the ones in between are skipped.
final class WindowMover {
    private enum Job {
        case origin(AXUIElement, CGPoint)
        case frame(AXUIElement, CGRect, anchor: CGPoint)
    }

    private let queue = DispatchQueue(label: "tutamak.ax", qos: .userInteractive)
    private let lock = NSLock()
    private var pending: Job?
    private var draining = false
    private var slowest: Double = 0

    func move(_ window: AXUIElement, to origin: CGPoint) {
        submit(.origin(window, origin))
    }

    /// One step of a live resize or an animation. The final frame goes through `setFrame`.
    func resize(_ window: AXUIElement, to frame: CGRect, anchor: CGPoint = .zero) {
        submit(.frame(window, frame, anchor: anchor))
    }

    /// The slowest AX call (s) since `resetStats`: if the app is the bottleneck, pacing cannot help.
    func slowestCall() -> Double {
        lock.withLock { slowest }
    }

    func resetStats() {
        lock.withLock { slowest = 0 }
    }

    private func submit(_ job: Job) {
        lock.lock()
        pending = job
        let startDrain = !draining
        draining = true
        lock.unlock()
        guard startDrain else { return }

        queue.async { [self] in
            while true {
                lock.lock()
                guard let job = pending else {
                    draining = false
                    lock.unlock()
                    return
                }
                pending = nil
                lock.unlock()
                timed {
                    switch job {
                    case .origin(let window, let origin):
                        AX.setOrigin(window, origin)
                    case .frame(let window, let frame, let anchor):
                        AX.setFrame(window, frame, anchor: anchor)
                    }
                }
            }
        }
    }

    private func timed(_ work: () -> Void) {
        let start = DispatchTime.now().uptimeNanoseconds
        work()
        let seconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
        lock.withLock { slowest = max(slowest, seconds) }
    }

    /// The final frame of a snap, resize or animation. Runs after any pending steps (same serial queue),
    /// then reports the frame the window actually took.
    func setFrame(
        _ window: TargetWindow, _ frame: CGRect, anchor: CGPoint = .zero, completion: ((CGRect) -> Void)? = nil
    ) {
        queue.async { [self] in
            timed {
                // Some apps animate size changes while AXEnhancedUserInterface is on and stop halfway;
                // like Rectangle, turn it off for the duration.
                let app = AXUIElementCreateApplication(window.pid)
                let enhanced = AX.bool(app, "AXEnhancedUserInterface") == true
                if enhanced { AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse) }
                AX.setFrame(window.element, frame, anchor: anchor)
                // A second pass settles apps whose size limits changed after the window moved screens.
                AX.setFrame(window.element, frame, anchor: anchor)
                if enhanced { AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue) }
            }
            let actual = AX.frame(window.element) ?? frame
            if !Geometry.isClose(actual, frame, tolerance: 2) {
                let asked = "\(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))×\(Int(frame.height))"
                let took = "\(Int(actual.minX)),\(Int(actual.minY)) \(Int(actual.width))×\(Int(actual.height))"
                logger.notice("\(window.appName, privacy: .public) took (\(took, privacy: .public)) instead of (\(asked, privacy: .public))")
            }
            completion?(actual)
        }
    }
}
