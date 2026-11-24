import CoreGraphics
import Foundation

var failures = 0
var checks = 0

func check(_ condition: Bool, _ message: String, line: Int = #line) {
    checks += 1
    if !condition {
        failures += 1
        print("FAILED (line \(line)): \(message)")
    }
}

func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 1e-9 }

func moved(_ events: [GestureEvent]) -> CGVector? {
    for e in events { if case .moved(let d) = e { return d } }
    return nil
}

// MARK: Geometry

let laptop = CGRect(x: 0, y: 0, width: 1512, height: 982)
let external = CGRect(x: 1512, y: -200, width: 2560, height: 1440)
let both = [laptop, external]

check(Geometry.snapZone(at: CGPoint(x: 0, y: 500), displays: [laptop])?.zone == .left, "left edge")
check(Geometry.snapZone(at: CGPoint(x: 1511, y: 500), displays: [laptop])?.zone == .right, "right edge")
check(Geometry.snapZone(at: CGPoint(x: 700, y: 0), displays: [laptop])?.zone == .maximize, "top edge")
check(Geometry.snapZone(at: CGPoint(x: 700, y: 500), displays: [laptop]) == nil, "middle")
check(Geometry.snapZone(at: .zero, displays: [laptop])?.zone == .left, "side edge wins in a corner")

check(Geometry.snapZone(at: CGPoint(x: 1511, y: 500), displays: both) == nil, "edge between two displays does not snap")
check(Geometry.snapZone(at: CGPoint(x: 1512, y: 500), displays: both) == nil, "inner left edge of the external display does not snap")
check(Geometry.snapZone(at: CGPoint(x: 4071, y: 500), displays: both)?.zone == .right, "outer right edge of the external display")
check(Geometry.snapZone(at: CGPoint(x: 2000, y: -200), displays: both)?.zone == .maximize, "top of the external display")
check(Geometry.snapZone(at: CGPoint(x: 700, y: 0), displays: both)?.zone == .maximize, "top of the laptop is an outer edge")
check(Geometry.snapZone(at: CGPoint(x: 4071, y: 500), displays: both)?.display == external, "the zone is on the external display")

check(
    Geometry.clamp(CGPoint(x: -50, y: 500), previous: CGPoint(x: 10, y: 500), displays: [laptop])
        == CGPoint(x: 0, y: 500),
    "the pointer stops at the left edge when pushed past it"
)
check(
    Geometry.clamp(CGPoint(x: 1600, y: 500), previous: CGPoint(x: 1500, y: 500), displays: both)
        == CGPoint(x: 1600, y: 500),
    "crossing between displays is free"
)
check(
    Geometry.clamp(CGPoint(x: 1600, y: 1300), previous: CGPoint(x: 1600, y: 1200), displays: both)
        == CGPoint(x: 1600, y: 1239),
    "stops at the bottom of the external display"
)

let visible = CGRect(x: 0, y: 33, width: 1512, height: 949)
check(Geometry.snapFrame(.left, visible: visible) == CGRect(x: 0, y: 33, width: 756, height: 949), "left half")
check(Geometry.snapFrame(.right, visible: visible) == CGRect(x: 756, y: 33, width: 756, height: 949), "right half")
check(Geometry.snapFrame(.maximize, visible: visible) == visible, "whole screen")
let odd = CGRect(x: 10, y: 0, width: 1513, height: 900)
check(
    Geometry.snapFrame(.left, visible: odd).width + Geometry.snapFrame(.right, visible: odd).width == 1513,
    "halves leave no gap at an odd width"
)

let cocoaVisible = CGRect(x: 0, y: 0, width: 1512, height: 949)
check(Geometry.flip(cocoaVisible, primaryHeight: 982) == visible, "Cocoa → CG")
check(Geometry.flip(Geometry.flip(visible, primaryHeight: 982), primaryHeight: 982) == visible, "flipping twice is the identity")

let a: [Int32: CGPoint] = [1: CGPoint(x: 0.1, y: 0.1), 2: CGPoint(x: 0.2, y: 0.2)]
let b: [Int32: CGPoint] = [2: CGPoint(x: 0.3, y: 0.2), 3: CGPoint(x: 0.9, y: 0.9)]
let d = Geometry.averageDelta(from: a, to: b)
check(d != nil && near(d!.dx, 0.1) && near(d!.dy, 0), "only shared fingers count")
check(Geometry.averageDelta(from: [1: .zero], to: [2: .zero]) == nil, "nil without shared fingers")

// MARK: GestureTracker

func touches(_ ids: [Int32], dx: CGFloat = 0, dy: CGFloat = 0) -> [TouchPoint] {
    ids.enumerated().map { i, id in
        TouchPoint(id: id, position: CGPoint(x: 0.3 + 0.05 * CGFloat(i) + dx, y: 0.5 + dy))
    }
}

var clock = 0.0
func step(_ t: inout GestureTracker, _ frame: [TouchPoint]) -> [GestureEvent] {
    clock += 0.01
    return t.process(frame, at: clock)
}

/// The drag tests below predate flicks, pinches and taps, and expect the drag to start at the threshold.
func dragTracker() -> GestureTracker {
    var t = GestureTracker()
    t.recognizesSwipes = false
    t.recognizesPinch = false
    t.recognizesTap = false
    return t
}

/// Four fingers in a row around x 0.375, spread apart by `scale` (1 = as they landed).
func spreadTouches(_ scale: CGFloat, dx: CGFloat = 0, dy: CGFloat = 0) -> [TouchPoint] {
    [-0.075, -0.025, 0.025, 0.075].enumerated().map { i, offset in
        TouchPoint(id: Int32(i + 1), position: CGPoint(x: 0.375 + offset * scale + dx, y: 0.5 + dy))
    }
}

func began(_ events: [GestureEvent]) -> Bool { events.first == .began }

func resizeBegan(_ events: [GestureEvent]) -> Bool {
    if case .resizeBegan? = events.first { return true }
    return false
}

/// A thumb at the bottom and three fingers above it, the fingers raised by `lift` (the thumb stays):
/// how a hand usually opens.
func thumbHand(_ lift: CGFloat, dx: CGFloat = 0) -> [TouchPoint] {
    [
        TouchPoint(id: 1, position: CGPoint(x: 0.40 + dx, y: 0.30)),
        TouchPoint(id: 2, position: CGPoint(x: 0.34 + dx, y: 0.45 + lift)),
        TouchPoint(id: 3, position: CGPoint(x: 0.40 + dx, y: 0.47 + lift)),
        TouchPoint(id: 4, position: CGPoint(x: 0.46 + dx, y: 0.45 + lift)),
    ]
}

do {
    var t = dragTracker()
    check(step(&t, touches([1, 2, 3, 4])).isEmpty, "four fingers landing does not start at once")
    check(step(&t, touches([1, 2, 3, 4], dx: 0.005)).isEmpty, "sliding below the threshold does not start")
    let start = step(&t, touches([1, 2, 3, 4], dx: 0.02))
    check(start.first == .began, "starts once past the threshold")
    check(moved(start).map { near($0.dx, 0.02) && near($0.dy, 0) } == true, "accumulated travel comes with the first step")
    check(t.isDragging, "dragging")

    let next = step(&t, touches([1, 2, 3, 4], dx: 0.05, dy: 0.01))
    check(moved(next).map { near($0.dx, 0.03) && near($0.dy, 0.01) } == true, "frame difference")

    let shuffled = Array(touches([1, 2, 3, 4], dx: 0.05, dy: 0.01).reversed())
    check(step(&t, shuffled).isEmpty, "no jump when the array order changes")

    check(!step(&t, touches([1, 2, 3], dx: 0.05, dy: 0.01)).contains(.ended), "losing a finger for one frame does not end it")
    check(!step(&t, touches([1, 2, 3, 4], dx: 0.05, dy: 0.01)).contains(.ended), "continues when the finger comes back")
    check(t.isDragging, "still dragging")

    let lifting = step(&t, touches([1, 2, 3], dx: 0.06, dy: 0.01))
    check(moved(lifting) == nil, "the fingers left behind while lifting do not move it")
    var ended = false
    for _ in 0..<10 where !ended {
        ended = step(&t, touches([1, 2, 3], dx: 0.06, dy: 0.01)).contains(.ended)
    }
    check(ended, "ends shortly after dropping to three fingers")
    check(!t.isDragging && !t.isActive, "ended")
    check(step(&t, touches([1, 2, 3], dx: 0.2)).isEmpty, "three fingers do not restart the drag")
}

do {
    var t = dragTracker()
    _ = step(&t, touches([1, 2, 3, 4]))
    _ = step(&t, touches([1, 2, 3, 4], dx: 0.03))
    check(t.isDragging, "started")
    check(step(&t, []).last == .ended, "ends at once when every finger lifts")
}

// Reported on 2026-11-25: held against a display edge by the resistance, the window moved a
// few points away after the hand let go. A hand lifts one finger after another, and those left
// behind roll back as they leave; none of that may move the window.
do {
    var t = dragTracker()
    _ = step(&t, touches([1, 2, 3, 4]))
    _ = step(&t, touches([1, 2, 3, 4], dy: 0.03))
    check(t.isDragging, "dragging toward the edge")
    var lift: [GestureEvent] = []
    lift += step(&t, touches([1, 2, 3], dy: 0.026))
    lift += step(&t, touches([2, 3], dy: 0.02))
    lift += step(&t, touches([3], dy: 0.015))
    lift += step(&t, [])
    check(moved(lift) == nil, "a hand lifting finger by finger moves nothing")
    check(lift.last == .ended, "and the drag ends")
}

do {
    var t = dragTracker()
    _ = step(&t, touches([1, 2, 3, 4, 5]))
    _ = step(&t, touches([1, 2, 3, 4], dx: 0.05))
    _ = step(&t, touches([1, 2, 3, 4], dx: 0.1))
    check(!t.isDragging, "a gesture that starts with five fingers does not drag")
    _ = step(&t, touches([1, 2]))
    _ = step(&t, touches([6, 7, 8, 9]))
    _ = step(&t, touches([6, 7, 8, 9], dx: 0.05))
    check(t.isDragging, "works again once fingers drop and return to four")
}

do {
    var t = dragTracker()
    _ = step(&t, touches([1, 2, 3]))
    _ = step(&t, touches([1, 2, 3], dx: 0.1))
    check(!t.isActive, "three fingers never engage")
}

do {
    var t = dragTracker()
    _ = step(&t, touches([1, 2, 3, 4]))
    // A pinch: the fingers move symmetrically toward the center, so their average movement is ~0.
    let pinch = [
        TouchPoint(id: 1, position: CGPoint(x: 0.32, y: 0.5)),
        TouchPoint(id: 2, position: CGPoint(x: 0.36, y: 0.5)),
        TouchPoint(id: 3, position: CGPoint(x: 0.39, y: 0.5)),
        TouchPoint(id: 4, position: CGPoint(x: 0.43, y: 0.5)),
    ]
    check(step(&t, pinch).isEmpty && !t.isDragging, "a symmetric pinch does not drag")
}

do {
    var t = dragTracker()
    check(!t.isEngaged, "not engaged when idle")
    _ = step(&t, touches([1, 2, 3, 4]))
    check(t.isEngaged, "scroll is muted as soon as four fingers land (before sliding)")
    _ = step(&t, touches([1, 2, 3, 4], dx: 0.03))
    check(t.isEngaged, "engaged while dragging")
    _ = step(&t, [])
    check(!t.isEngaged, "lets go when the fingers lift")
    _ = step(&t, touches([1, 2, 3, 4, 5]))
    check(!t.isEngaged, "does not interfere with scrolling while blocked by five fingers")
}

// MARK: GestureTracker: flicks

do {
    var t = GestureTracker()
    _ = step(&t, touches([1, 2, 3, 4]))
    check(step(&t, touches([1, 2, 3, 4], dx: -0.03)).isEmpty, "a flick-like start waits")
    check(t.isEngaged && !t.isDragging, "waiting does not move the window but keeps scroll muted")
    check(step(&t, touches([1, 2, 3, 4], dx: -0.06)).isEmpty, "still waiting below the flick distance")
    check(step(&t, touches([1, 2, 3, 4], dx: -0.09)) == [.swiped(.left)], "a fast sideways flick fires")
    check(t.lastDecision?.kind == .swipe, "the decision is recorded")
    check(step(&t, touches([1, 2, 3, 4], dx: -0.3)).isEmpty, "the rest of the motion is ignored")
    check(t.isEngaged, "scroll stays muted after a flick")
    check(step(&t, touches([1, 2], dx: -0.3)).isEmpty, "lifting fingers emits nothing")
    _ = step(&t, [])
    check(!t.isActive, "idle once the hand is off")
}

do {
    var t = GestureTracker()
    _ = step(&t, touches([1, 2, 3, 4]))
    _ = step(&t, touches([1, 2, 3, 4], dx: 0.05))
    check(step(&t, touches([1, 2, 3, 4], dx: 0.1)) == [.swiped(.right)], "a flick to the right")
}

do {
    var t = GestureTracker()
    _ = step(&t, touches([1, 2, 3, 4]))
    for _ in 0..<15 { _ = step(&t, touches([1, 2, 3, 4])) }
    check(began(step(&t, touches([1, 2, 3, 4], dx: 0.05))), "resting first always drags, without waiting")
    check(t.lastDecision?.reason == "too slow", "the time spent resting counts against the flick window")
}

do {
    var t = GestureTracker()
    _ = step(&t, touches([1, 2, 3, 4]))
    check(began(step(&t, touches([1, 2, 3, 4], dy: -0.04))), "a vertical start drags at once")
    check(t.lastDecision?.reason == "not horizontal", "ruled out by direction")
}

do {
    var t = GestureTracker()
    _ = step(&t, touches([1, 2, 3, 4]))
    var frames = 0
    var decided: [GestureEvent] = []
    for i in 1...20 where decided.isEmpty {
        decided = step(&t, touches([1, 2, 3, 4], dx: 0.004 * CGFloat(i)))
        frames = i
    }
    check(began(decided), "a slow sideways start drags")
    check(Double(frames) * 0.01 <= t.swipeWindow + 0.011, "and waits at most the flick window (\(frames) frames)")
}

do {
    var t = GestureTracker()
    _ = step(&t, touches([1, 2, 3, 4]))
    _ = step(&t, touches([1, 2, 3, 4], dx: -0.02))
    _ = step(&t, touches([1, 2, 3, 4], dx: -0.04))
    check(step(&t, []) == [.swiped(.left)], "a short flick that lifts early still switches")
}

do {
    var t = GestureTracker()
    _ = step(&t, touches([1, 2, 3, 4]))
    _ = step(&t, touches([1, 2, 3, 4], dx: 0.015))
    check(step(&t, []).isEmpty && !t.isActive, "a tiny touch that lifts does nothing")
}

do {
    var t = GestureTracker()
    _ = step(&t, touches([1, 2, 3, 4]))
    for _ in 0..<15 { _ = step(&t, touches([1, 2, 3, 4])) }
    _ = step(&t, touches([1, 2, 3, 4], dx: 0.05))
    check(t.isDragging, "dragging")
    _ = step(&t, [])
    _ = step(&t, touches([5, 6, 7, 8]))
    _ = step(&t, touches([5, 6, 7, 8], dx: 0.05))
    let clutch = step(&t, touches([5, 6, 7, 8], dx: 0.1))
    check(!clutch.contains(.swiped(.right)) && t.isDragging, "re-landing right after a drag keeps dragging (clutch)")
    check(t.lastDecision?.reason == "clutch", "decided as clutch")
}

do {
    var t = GestureTracker()
    t.recognizesSwipes = false
    _ = step(&t, touches([1, 2, 3, 4]))
    _ = step(&t, touches([1, 2, 3, 4], dx: -0.05))
    check(t.isDragging, "with sideways flicks off, a flick drags")
}

// MARK: GestureTracker: vertical flicks (Mission Control / App Exposé)

/// Every gesture on, plus flicks up and down.
func verticalFlickTracker() -> GestureTracker {
    var t = GestureTracker()
    t.recognizesVerticalSwipes = true
    return t
}

check(!GestureTracker().recognizesVerticalSwipes, "vertical flicks are off by default")

do {
    var t = verticalFlickTracker()
    _ = step(&t, touches([1, 2, 3, 4]))
    check(step(&t, touches([1, 2, 3, 4], dy: 0.04)).isEmpty, "a fast upward start waits")
    check(t.isEngaged && !t.isDragging, "waiting does not move the window")
    check(step(&t, touches([1, 2, 3, 4], dy: 0.08)).isEmpty, "still waiting below the flick distance (physical)")
    check(step(&t, touches([1, 2, 3, 4], dy: 0.13)) == [.swiped(.up)], "a fast upward flick")
    check(t.lastDecision?.kind == .swipe, "the decision is recorded")
    check(step(&t, touches([1, 2, 3, 4], dy: 0.3)).isEmpty, "the rest of the motion is ignored")
    _ = step(&t, [])
}

do {
    var t = verticalFlickTracker()
    _ = step(&t, touches([1, 2, 3, 4]))
    _ = step(&t, touches([1, 2, 3, 4], dy: -0.05))
    _ = step(&t, touches([1, 2, 3, 4], dy: -0.1))
    check(step(&t, touches([1, 2, 3, 4], dy: -0.13)) == [.swiped(.down)], "a fast downward flick")
    _ = step(&t, [])
}

do {
    var t = verticalFlickTracker()
    _ = step(&t, touches([1, 2, 3, 4]))
    _ = step(&t, touches([1, 2, 3, 4], dy: 0.03))
    _ = step(&t, touches([1, 2, 3, 4], dy: 0.06))
    check(step(&t, []) == [.swiped(.up)], "a short upward flick that lifts early still counts")
    check(t.lastDecision?.reason == "flick lifted early", "decided on the lift")
}

do {
    var t = verticalFlickTracker()
    _ = step(&t, touches([1, 2, 3, 4]))
    _ = step(&t, touches([1, 2, 3, 4], dy: 0.03))
    check(step(&t, []).isEmpty, "an upward touch shorter than the lift distance (physically) does nothing")
}

do {
    var t = verticalFlickTracker()
    _ = step(&t, touches([1, 2, 3, 4]))
    for _ in 0..<15 { _ = step(&t, touches([1, 2, 3, 4])) }
    check(began(step(&t, touches([1, 2, 3, 4], dy: 0.08))), "resting first drags up, without waiting")
    check(t.lastDecision?.reason == "too slow", "the time spent resting counts against the flick window")
}

do {
    var t = verticalFlickTracker()
    _ = step(&t, touches([1, 2, 3, 4]))
    var frames = 0
    var decided: [GestureEvent] = []
    for i in 1...20 where decided.isEmpty {
        decided = step(&t, touches([1, 2, 3, 4], dy: 0.004 * CGFloat(i)))
        frames = i
    }
    check(began(decided), "a slow upward start drags")
    check(Double(frames) * 0.01 <= t.swipeWindow + 0.011, "and waits at most the flick window (\(frames) frames)")
}

do {
    var t = verticalFlickTracker()
    _ = step(&t, touches([1, 2, 3, 4]))
    check(began(step(&t, touches([1, 2, 3, 4], dx: 0.03, dy: 0.03))), "a diagonal start drags at once")
    check(t.lastDecision?.reason == "diagonal", "ruled out by direction")
}

do {
    var t = verticalFlickTracker()
    _ = step(&t, touches([1, 2, 3, 4]))
    _ = step(&t, touches([1, 2, 3, 4], dx: -0.03))
    _ = step(&t, touches([1, 2, 3, 4], dx: -0.06))
    check(step(&t, touches([1, 2, 3, 4], dx: -0.09)) == [.swiped(.left)], "sideways flicks still switch desktops")
}

do {
    var t = verticalFlickTracker()
    t.recognizesSwipes = false
    _ = step(&t, touches([1, 2, 3, 4]))
    check(began(step(&t, touches([1, 2, 3, 4], dx: -0.05))), "with only vertical flicks, a sideways start drags at once")
    check(t.lastDecision?.reason == "not vertical", "ruled out by direction")
    _ = step(&t, [])
    clock += 1
    _ = step(&t, touches([1, 2, 3, 4]))
    _ = step(&t, touches([1, 2, 3, 4], dy: 0.05))
    _ = step(&t, touches([1, 2, 3, 4], dy: 0.1))
    check(step(&t, touches([1, 2, 3, 4], dy: 0.13)) == [.swiped(.up)], "and an upward flick still opens Mission Control")
}

do {
    var t = verticalFlickTracker()
    _ = step(&t, touches([1, 2, 3, 4]))
    for _ in 0..<15 { _ = step(&t, touches([1, 2, 3, 4])) }
    _ = step(&t, touches([1, 2, 3, 4], dy: 0.05))
    check(t.isDragging, "dragging")
    _ = step(&t, [])
    _ = step(&t, touches([5, 6, 7, 8]))
    _ = step(&t, touches([5, 6, 7, 8], dy: 0.06))
    let clutch = step(&t, touches([5, 6, 7, 8], dy: 0.13))
    check(!clutch.contains(.swiped(.up)) && t.isDragging, "re-landing right after a drag keeps dragging up (clutch)")
    check(t.lastDecision?.reason == "clutch", "decided as clutch")
}

// Vertical drags logged on 2026-11-23 reached dy ≈ −0.030 in ~64 ms; at that pace a drag
// waits out the flick window and then drags, rather than opening App Exposé.
do {
    var t = verticalFlickTracker()
    _ = step(&t, touches([1, 2, 3, 4]))
    var events: [GestureEvent] = []
    for i in 1...20 where events.isEmpty {
        events = step(&t, touches([1, 2, 3, 4], dx: -0.0006 * CGFloat(i), dy: -0.0047 * CGFloat(i)))
    }
    check(began(events) && t.lastDecision?.kind == .drag, "logged vertical drag (dy −0.030 in 64 ms) still drags")
}

// What each flick posts; a new direction must not fall through to switching desktops.
check(SystemShortcut(flick: .left) == .moveRightSpace, "fingers moving left bring in the desktop on the right")
check(SystemShortcut(flick: .right) == .moveLeftSpace, "fingers moving right bring in the desktop on the left")
check(SystemShortcut(flick: .up) == .missionControl && SystemShortcut.missionControl.rawValue == "32", "up: Mission Control")
check(SystemShortcut(flick: .down) == .appWindows && SystemShortcut.appWindows.rawValue == "33", "down: App Exposé")

// MARK: GestureTracker: logged gestures, with every gesture on

// Values logged in real use on 2026-11-23, in a session where the gestures felt right.
do {
    var t = GestureTracker()
    _ = step(&t, touches([1, 2, 3, 4]))
    var events: [GestureEvent] = []
    for i in 1...12 where events.isEmpty {
        events = step(&t, touches([1, 2, 3, 4], dx: -0.0074 * CGFloat(i)))
    }
    check(events == [.swiped(.left)], "logged flick (dx −0.089 in 120 ms) switches desktops")
}

do {
    var t = GestureTracker()
    _ = step(&t, touches([1, 2, 3, 4]))
    for i in 1...9 { _ = step(&t, touches([1, 2, 3, 4], dx: 0.0057 * CGFloat(i))) }
    check(step(&t, []) == [.swiped(.right)], "logged early lift (dx +0.051 in 90 ms) switches desktops")
}

do {
    var t = GestureTracker()
    _ = step(&t, touches([1, 2, 3, 4]))
    var events: [GestureEvent] = []
    for i in 1...16 where events.isEmpty {
        events = step(&t, touches([1, 2, 3, 4], dx: -0.0036 * CGFloat(i)))
    }
    check(began(events) && t.lastDecision?.kind == .drag, "logged slow slide (dx −0.054 in 150 ms) drags")
}

// MARK: GestureTracker: pinch

do {
    var t = GestureTracker()
    _ = step(&t, spreadTouches(1))
    check(step(&t, spreadTouches(1.1)).isEmpty, "a small spread does not start resizing")
    let start = step(&t, spreadTouches(1.4))
    check(resizeBegan(start), "spreading past the threshold starts resizing")
    if case .resized(let s)? = start.last { check(s.radial > 0.015 && s.x > 0, "the spread grows") } else { check(false, "resized follows resizeBegan") }
    check(t.isResizing && t.lastDecision?.kind == .resize, "resizing")
    let more = step(&t, spreadTouches(1.8, dx: 0.1))
    if case .resized(let s)? = more.first { check(s.radial > 0.03, "keeps following the spread") } else { check(false, "resized") }
    check(!more.contains(.began), "sliding while resizing does not drag")
    check(step(&t, []).contains(.resizeEnded), "lifting ends the resize")
    check(!t.isActive, "idle")
}

do {
    var t = GestureTracker()
    _ = step(&t, spreadTouches(1))
    let start = step(&t, spreadTouches(0.6))
    if case .resized(let s)? = start.last { check(resizeBegan(start) && s.radial < 0, "pinching in shrinks") } else { check(false, "pinch in resizes") }
}

do {
    var t = GestureTracker()
    _ = step(&t, spreadTouches(1))
    let events = step(&t, spreadTouches(1.05, dy: -0.04))
    check(began(events) && !t.isResizing, "sliding with a little spread change drags, not resizes")
}

// A bug found in use: opening the hand around a still thumb slides the fingers' center too,
// and was taken for a drag; only symmetric pinches resized.
do {
    var t = GestureTracker()
    _ = step(&t, thumbHand(0))
    var events: [GestureEvent] = []
    var sawDrag = false
    for i in 1...15 where !resizeBegan(events) {
        events = step(&t, thumbHand(0.006 * CGFloat(i)))
        if began(events) { sawDrag = true }
    }
    check(resizeBegan(events) && !sawDrag, "opening the hand around a still thumb resizes, not drags")
    if case .resized(let s)? = events.last { check(s.radial > 0, "and grows") } else { check(false, "resized") }
}

do {
    var t = GestureTracker()
    _ = step(&t, thumbHand(0.05))
    var events: [GestureEvent] = []
    for i in 1...15 where !resizeBegan(events) {
        events = step(&t, thumbHand(0.05 - 0.006 * CGFloat(i)))
    }
    if case .resized(let s)? = events.last { check(resizeBegan(events) && s.radial < 0, "closing the hand onto a still thumb shrinks") } else { check(false, "closing resizes") }
}

do {
    var t = GestureTracker()
    _ = step(&t, thumbHand(0))
    var events: [GestureEvent] = []
    for i in 1...20 where events.isEmpty {
        events = step(&t, thumbHand(0, dx: 0.004 * CGFloat(i)))
    }
    check(began(events), "a hand sliding without opening drags")
    check(!t.isResizing, "not resizing")
}

do {
    var t = GestureTracker()
    _ = step(&t, spreadTouches(1))
    var events: [GestureEvent] = []
    for i in 1...20 where events.isEmpty {
        events = step(&t, spreadTouches(1 + 0.008 * CGFloat(i), dy: -0.004 * CGFloat(i)))
    }
    check(!resizeBegan(events) || began(events), "a slide that also opens a little settles one way")
    check(t.isDragging || t.isResizing, "and does not hang undecided")
}

do {
    var t = GestureTracker()
    t.recognizesPinch = false
    _ = step(&t, spreadTouches(1))
    check(step(&t, spreadTouches(1.6)).isEmpty && !t.isResizing, "with pinch off, spreading does nothing")
}

// MARK: GestureTracker: tap

do {
    var t = GestureTracker()
    _ = step(&t, touches([1, 2, 3, 4]))
    for _ in 0..<5 { _ = step(&t, touches([1, 2, 3, 4], dx: 0.001)) }
    check(step(&t, touches([1, 2, 3])) == [.tapped], "a quick still four-finger tap fires on lift")
    check(t.lastDecision?.kind == .tap, "recorded as a tap")
    check(step(&t, touches([1])).isEmpty, "fires once")
    _ = step(&t, [])
    check(!t.isActive, "idle")
}

do {
    var t = GestureTracker()
    _ = step(&t, touches([1, 2, 3, 4]))
    for _ in 0..<30 { _ = step(&t, touches([1, 2, 3, 4])) }
    check(step(&t, []).isEmpty, "holding before lifting is not a tap")
}

do {
    var t = GestureTracker()
    for _ in 0..<20 { _ = step(&t, touches([1, 2, 3])) }
    _ = step(&t, touches([1, 2, 3, 4]))
    check(step(&t, []).isEmpty, "a late fourth finger is not a tap")
}

do {
    var t = GestureTracker()
    _ = step(&t, touches([1, 2, 3, 4]))
    for _ in 0..<15 { _ = step(&t, touches([1, 2, 3, 4])) }
    _ = step(&t, touches([1, 2, 3, 4], dx: 0.05))
    _ = step(&t, [])
    _ = step(&t, touches([5, 6, 7, 8]))
    check(step(&t, []).isEmpty, "landing and lifting right after a drag is not a tap")
}

do {
    var t = GestureTracker()
    t.recognizesTap = false
    _ = step(&t, touches([1, 2, 3, 4]))
    check(step(&t, []).isEmpty, "with tap off, nothing happens")
}

// MARK: Spread and resizing geometry

do {
    let row = Spread([CGPoint(x: 0.3, y: 0.5), CGPoint(x: 0.35, y: 0.5), CGPoint(x: 0.4, y: 0.5), CGPoint(x: 0.45, y: 0.5)], aspect: 0.66)
    check(near(row.x, 0.05) && near(row.y, 0) && near(row.radial, 0.05), "spread of four fingers in a row")
    let wider = Spread([CGPoint(x: 0.2, y: 0.5), CGPoint(x: 0.6, y: 0.5)], aspect: 0.66) - Spread([CGPoint(x: 0.3, y: 0.5), CGPoint(x: 0.5, y: 0.5)], aspect: 0.66)
    check(near(wider.x, 0.1) && near(wider.radial, 0.1), "spread difference")

    let screen = CGRect(x: 0, y: 33, width: 1512, height: 949)
    let floating = CGRect(x: 400, y: 200, width: 600, height: 400)
    check(Geometry.resizeAnchor(floating, in: screen) == CGPoint(x: 0.5, y: 0.5), "a floating window resizes around its center")
    let leftHalf = CGRect(x: 0, y: 33, width: 756, height: 949)
    check(Geometry.resizeAnchor(leftHalf, in: screen) == CGPoint(x: 0, y: 0.5), "a left-snapped window keeps hugging the left edge")
    check(Geometry.resizeAnchor(screen, in: screen) == CGPoint(x: 0.5, y: 0.5), "a window that fills the screen shrinks toward its center")

    let minimum = CGSize(width: 240, height: 160)
    let bigger = Geometry.resizedFrame(floating, scale: 1.5, anchor: CGPoint(x: 0.5, y: 0.5), within: screen, minimum: minimum)
    check(bigger == CGRect(x: 250, y: 100, width: 900, height: 600), "grows around its center")
    let huge = Geometry.resizedFrame(floating, scale: 10, anchor: CGPoint(x: 0.5, y: 0.5), within: screen, minimum: minimum)
    check(huge == screen, "spreading far enough fills the screen")
    let tiny = Geometry.resizedFrame(floating, scale: 0.01, anchor: CGPoint(x: 0.5, y: 0.5), within: screen, minimum: minimum)
    check(tiny.size == minimum, "stops at the minimum size")
    let hugging = Geometry.resizedFrame(leftHalf, scale: 0.8, anchor: CGPoint(x: 0, y: 0.5), within: screen, minimum: minimum)
    check(hugging.minX == 0 && hugging.width < leftHalf.width, "a left-snapped window shrinks toward the left edge")
    let offscreen = CGRect(x: -200, y: 200, width: 600, height: 400)
    let nudged = Geometry.resizedFrame(offscreen, scale: 1.0, anchor: CGPoint(x: 0.5, y: 0.5), within: screen, minimum: minimum)
    check(nudged == offscreen, "a partly offscreen window does not jump when the resize starts")

    check(Geometry.isClose(screen, screen.insetBy(dx: 2, dy: 2)), "frames within tolerance are close")
    check(!Geometry.isClose(screen, leftHalf), "different frames are not close")
}

// MARK: Resize grip (the pointer's place in the window picks the edges)

do {
    let size = CGSize(width: 1512, height: 865) // a maximized window, as logged on a laptop
    func grip(_ x: CGFloat, _ y: CGFloat) -> ResizeGrip { ResizeGrip(spot: CGPoint(x: x, y: y), size: size) }
    check(grip(0.5, 0.5).isCentre, "the middle of the window scales it")
    check(grip(0.6, 0.4).isCentre, "the whole middle ninth is the center")
    check(grip(0.9, 0.5) == ResizeGrip(x: .high, y: .middle), "near the right edge grips the right edge")
    check(grip(0.5, 0.1).description == "top edge", "near the top grips the top edge")
    check(grip(0.05, 0.95).description == "bottom-left corner", "right in a corner grips both")
    // With thirds, two thirds of the bottom band were corners that changed the width too.
    check(grip(0.25, 0.85).description == "bottom edge", "low in the window but off-center is still the bottom edge")
    check(grip(0.75, 0.2).description == "top edge", "high and off-center is the top edge")
    check(grip(0.2, 0.6).description == "left edge", "beside the middle is the side edge")
    check(grip(0.1, 0.75).description == "left edge", "between two edges, the physically nearer one (151 pt from the left, 216 from the bottom)")
    check(grip(0.15, 0.8).description == "bottom edge", "the other way around (227 pt from the left, 173 from the bottom)")

    let screen = CGRect(x: 0, y: 30, width: 2560, height: 1326)
    let floating = CGRect(x: 1000, y: 300, width: 800, height: 600)
    let right = ResizeGrip(x: .high, y: .middle)
    let bottom = ResizeGrip(x: .middle, y: .high)
    let top = ResizeGrip(x: .middle, y: .low)
    let topLeft = ResizeGrip(x: .low, y: .low)
    check(Geometry.resizeAnchor(floating, in: screen, grip: right).x == 0, "gripping the right edge keeps the left edge")
    check(Geometry.resizeAnchor(floating, in: screen, grip: top).y == 1, "gripping the top edge keeps the bottom edge")
    check(Geometry.resizeAnchor(floating, in: screen, grip: topLeft) == CGPoint(x: 1, y: 1), "a corner keeps the opposite corner")

    // The motion that was hard: making a window taller. Any spread now does it with the pointer low in the window.
    let sideways: CGFloat = 0.03 // a logged sideways spread (radial)
    let taller = Geometry.resizeScale(grip: bottom, start: 0.1, change: sideways, exponent: 1.5)
    check(taller.width == 1 && abs(taller.height - pow(1.3, 1.5)) < 1e-9, "a sideways spread makes the window taller with the bottom edge gripped")
    let wider = Geometry.resizeScale(grip: right, start: 0.1, change: -0.03, exponent: 1.5)
    check(wider.height == 1 && wider.width < 1, "a pinch narrows it with the right edge gripped")
    let flat = Geometry.resizeScale(grip: bottom, start: 0.001, change: 0.004, exponent: 1.5)
    check(flat.height < 1.4, "a bunched-up hand does not blow up the size (\(flat.height))")
    let anchor = Geometry.resizeAnchor(floating, in: screen, grip: bottom)
    let grown = Geometry.resizedFrame(floating, scale: taller, anchor: anchor, within: screen, minimum: CGSize(width: 240, height: 160))
    check(grown.minY == floating.minY && grown.height > floating.height && grown.width == floating.width, "the bottom edge moves down, the rest stays")

    // The grip alone decides: no axis is swapped for another, whatever the window spans.
    check(Geometry.resizedAxes(top) == (false, true), "top edge: height only")
    check(Geometry.resizedAxes(right) == (true, false), "right edge: width only")
    check(Geometry.resizedAxes(topLeft) == (true, true), "corner: both")
    check(Geometry.resizedAxes(.centre) == (true, true), "center: both")

    // Frames logged on a 2560×1440 display (visible area below a 30 pt menu bar).
    let rightHalf = CGRect(x: 1192, y: 31, width: 1368, height: 1324)
    let s = Geometry.spans(rightHalf, screen)
    check(s.height && !s.width, "a right-snapped window spans the height")
    check(Geometry.resizeAnchor(rightHalf, in: screen) == CGPoint(x: 1, y: 0.5), "and keeps hugging the right edge")
    check(Geometry.resizeAnchor(rightHalf, in: screen, grip: right).x == 1, "even gripped at its right edge: the flush edge stays, the left edge moves")
    let slightlyLow = CGRect(x: 1202, y: 33, width: 1358, height: 1323)
    check(Geometry.resizeAnchor(slightlyLow, in: screen) == CGPoint(x: 1, y: 0.5), "a window 3 pt below the menu bar still counts as full height")

    // The reported bug: on a full-height window the bottom edge changed the width instead.
    let minimum = CGSize(width: 240, height: 160)
    let pinched = Geometry.resizeScale(grip: bottom, start: 0.1, change: -0.02, exponent: 1.5)
    let bottomAnchor = Geometry.resizeAnchor(rightHalf, in: screen, grip: bottom)
    let shorter = Geometry.resizedFrame(rightHalf, scale: pinched, anchor: bottomAnchor, within: screen, minimum: minimum)
    check(shorter.width == rightHalf.width && shorter.height < rightHalf.height, "pinching at the bottom of a full-height half shortens it, width kept")
    check(shorter.minY == rightHalf.minY, "its top stays, the bottom edge rises")
    let topAnchor = Geometry.resizeAnchor(rightHalf, in: screen, grip: top)
    let fromTitleBar = Geometry.resizedFrame(rightHalf, scale: pinched, anchor: topAnchor, within: screen, minimum: minimum)
    check(fromTitleBar.maxY == rightHalf.maxY && fromTitleBar.height < rightHalf.height && fromTitleBar.width == rightHalf.width, "pinching at the title bar lowers the top edge")
    let spread = Geometry.resizeScale(grip: bottom, start: 0.1, change: 0.03, exponent: 1.5)
    let full = Geometry.resizedFrame(rightHalf, scale: spread, anchor: bottomAnchor, within: screen, minimum: minimum)
    check(full.width == rightHalf.width && full.minY == screen.minY && full.height == screen.height, "spreading at the bottom of a full-height window only fills the 2 pt it lacked (it cannot get taller)")
    let centre = Geometry.resizeScale(grip: .centre, start: 0.1, change: 0.02, exponent: 1.5)
    let fromCentre = Geometry.resizedFrame(rightHalf, scale: centre, anchor: Geometry.resizeAnchor(rightHalf, in: screen), within: screen, minimum: minimum)
    check(fromCentre.width > rightHalf.width && fromCentre.height == screen.height && fromCentre.maxX == rightHalf.maxX, "spreading from the center widens a right half; its height stops at the screen by itself")
    let maximized = CGRect(x: 0, y: 33, width: 1512, height: 865)
    let laptop = CGRect(x: 0, y: 33, width: 1512, height: 865)
    let lowered = Geometry.resizedFrame(maximized, scale: pinched, anchor: Geometry.resizeAnchor(maximized, in: laptop, grip: bottom), within: laptop, minimum: minimum)
    check(lowered.minY == 33 && lowered.width == 1512 && lowered.height < 865, "a maximized window pinched at the bottom gets shorter from below")
    let widened = Geometry.resizedFrame(rightHalf, scale: CGSize(width: 1.5, height: 1), anchor: CGPoint(x: 1, y: 0.5), within: screen, minimum: minimum)
    check(widened.maxX == rightHalf.maxX && widened.height == rightHalf.height && widened.width == 2052, "widening a right half grows it to the left, full height kept")
}

// MARK: Snap grid

do {
    let wide = CGRect(x: 0, y: 30, width: 2560, height: 1326) // an external display, as logged
    let laptop = CGRect(x: 0, y: 33, width: 1512, height: 949)
    check(GridLayout.auto(for: wide) == GridLayout(columns: 3, rows: 2), "a wide display gets three columns")
    check(GridLayout.auto(for: laptop) == GridLayout(columns: 2, rows: 2), "a laptop gets two")
    check(GridChoice("3x2") == .fixed(GridLayout(columns: 3, rows: 2)) && GridChoice("3x2").raw == "3x2", "grid setting round trip")
    check(GridChoice("auto") == .auto && GridChoice("nonsense") == .off, "unknown grid setting means off")
    check(GridChoice.off.layout(for: wide) == nil, "no grid when off")

    let six = GridLayout(columns: 3, rows: 2)
    let cells = Geometry.gridCells(six, in: wide)
    check(cells.count == 6 && cells[0] == CGRect(x: 0, y: 30, width: 853, height: 663), "3×2 cells")
    check(cells[1].minX == cells[0].maxX && cells[3].minY == cells[0].maxY && cells[5].maxX == wide.maxX && cells[5].maxY == wide.maxY, "cells share edges and fill the area")

    func zone(_ x: CGFloat, _ y: CGFloat, _ layout: GridLayout = six, _ v: CGRect = wide) -> CGRect {
        Geometry.gridZone(at: CGPoint(x: x, y: y), in: v, layout: layout)
    }
    check(zone(400, 300) == cells[0], "inside a cell: that sixth")
    check(zone(860, 300) == cells[0].union(cells[1]), "on a column line: two-thirds wide")
    check(zone(400, 700) == cells[0].union(cells[3]), "on the middle line: a full-height third")
    check(zone(1710, 690) == cells[1].union(cells[5]), "where lines cross: two-thirds wide, full height")
    check(zone(2559, 1355) == cells[5], "the far corner is the last cell")
    check(zone(400, 10) == cells[0], "above the visible area (the menu bar) counts as the top row")

    let four = GridLayout(columns: 2, rows: 2)
    check(zone(300, 200, four, laptop) == CGRect(x: 0, y: 33, width: 756, height: 475), "2×2: a quarter")
    check(zone(756, 200, four, laptop) == CGRect(x: 0, y: 33, width: 1512, height: 475), "2×2: the top half on the middle line")
    check(zone(756, 508, four, laptop) == laptop, "2×2: the whole area where the lines cross")
}

// MARK: DropHold (when a window released over the grid drops)

do {
    var h = DropHold()
    check(h.released(speed: 0.05) == .drop && !h.isPending, "a settled hand drops at once")
    check(h.released(speed: 0.8) == .wait(h.clutchWait) && h.isPending, "a hand still sliding waits for the clutch")
    check(h.frame(engaged: false, dragBegan: false, otherGesture: false) == nil, "nothing happens while the hand is away")
    check(h.expired() == .drop && !h.isPending, "no fingers came back: the window drops")

    _ = h.released(speed: 0.8)
    check(h.frame(engaged: true, dragBegan: false, otherGesture: false) == nil && h.isHeld, "fingers back: the drop is held")
    check(h.expired() == nil && h.isHeld, "the wait running out does not drop a held window")
    check(h.frame(engaged: true, dragBegan: true, otherGesture: false) == .cancel(keepPreview: true) && !h.isPending, "dragging again cancels the drop")

    _ = h.released(speed: 0.8)
    _ = h.frame(engaged: true, dragBegan: false, otherGesture: false)
    check(h.frame(engaged: false, dragBegan: false, otherGesture: false) == .drop, "fingers lifting again without dragging drop the window")

    _ = h.released(speed: 0.8)
    check(h.frame(engaged: true, dragBegan: false, otherGesture: true) == .cancel(keepPreview: false), "a pinch instead cancels it and hides the preview")
    check(h.frame(engaged: true, dragBegan: true, otherGesture: false) == nil, "nothing pending: frames do nothing")
}

// MARK: ScrollMuter

do {
    let began = ScrollMuter.phaseBegan, changed: Int64 = 2, ended: Int64 = 4
    var m = ScrollMuter()
    var now = 100.0
    /// When the four fingers last let go; long ago unless a test says otherwise.
    var letGo = -Double.infinity
    func mute(_ engaged: Bool, _ phase: Int64, _ momentum: Int64 = 0) -> Bool {
        now += 0.016
        return m.shouldMute(engaged: engaged, disengagedAt: letGo, phase: phase, momentum: momentum, at: now)
    }

    check(!mute(false, began) && !mute(false, changed), "ordinary scrolling passes")
    check(mute(true, changed), "muted when four fingers arrive mid-sequence")
    check(mute(false, changed), "the rest of the sequence stays muted even when the finger count drops")
    check(mute(false, ended), "the ended phase is muted too")
    check(mute(false, 0, 1) && mute(false, 0, 2) && mute(false, 0, 3), "momentum is muted")
    check(!mute(false, ScrollMuter.phaseMayBegin), "a new sequence passes")
    check(!mute(false, changed), "the rest of the new sequence passes")

    check(mute(true, began), "a sequence started with four fingers is muted")
    check(!mute(false, 0, 0), "a mouse wheel ends muting")

    _ = mute(true, changed)
    now += 5
    check(!mute(false, changed), "released after the timeout")

    // The gesture's tail: a sequence restarting right after the fingers let go is not a new scroll.
    _ = mute(true, changed)
    letGo = now
    check(mute(false, ScrollMuter.phaseMayBegin), "a mayBegin right after the fingers let go stays muted")
    check(mute(false, 0, 2), "and so does the momentum that follows it")
    check(mute(false, began) && mute(false, changed), "a began within the tail window stays muted too")
    now = letGo + m.tailWindow
    check(!mute(false, began), "a sequence starting after the tail window is a new scroll")
    check(!mute(false, changed), "and passes")
}

// A scroll logged after a flick up opened Mission Control (2026-11-24 20:49:07.840): the
// four-finger sequence ended, macOS restarted it ~50 ms later and sent 755 pt of momentum.
do {
    var m = ScrollMuter()
    let flick = 1000.0
    var leaked = 0
    func event(_ dt: Double, engaged: Bool, phase: Int64, momentum: Int64 = 0, points: Int = 0) {
        if !m.shouldMute(engaged: engaged, disengagedAt: flick + 0.01, phase: phase, momentum: momentum, at: flick + dt) {
            leaked += abs(points)
        }
    }
    event(-0.024, engaged: true, phase: 1)
    for i in 0..<3 { event(-0.007 + 0.006 * Double(i), engaged: true, phase: 2) }
    event(0.012, engaged: false, phase: 4)
    event(0.013, engaged: false, phase: 0, momentum: 1)
    event(0.061, engaged: false, phase: 0, momentum: 3, points: 22)
    event(0.061, engaged: false, phase: 1, points: 22)
    event(0.062, engaged: false, phase: 0, momentum: 2, points: 37)
    event(0.095, engaged: false, phase: 4)
    for i in 0..<56 { event(0.096 + 0.007 * Double(i), engaged: false, phase: 0, momentum: 2, points: 13) }
    event(0.496, engaged: false, phase: 0, momentum: 3)
    check(leaked == 0, "the logged tail after a flick up stays muted (\(leaked) pt leaked)")
    check(!m.shouldMute(engaged: false, disengagedAt: flick + 0.01, phase: 1, momentum: 0, at: flick + 1.5),
          "a scroll a second later passes")
}

// MARK: EdgeResistance

do {
    let screen = [CGRect(x: 0, y: 33, width: 1512, height: 949)]
    func frame(x: CGFloat, y: CGFloat = 200) -> CGRect { CGRect(x: x, y: y, width: 400, height: 300) }

    var r = EdgeResistance()
    r.strength = 50
    check(near(r.apply(CGVector(dx: -30, dy: 0), frame: frame(x: 50), visibleFrames: screen).dx, -30), "free away from edges")
    check(near(r.apply(CGVector(dx: -30, dy: 0), frame: frame(x: 20), visibleFrames: screen).dx, -20), "moves up to the edge and stops")
    check(r.isHolding, "held at the edge")
    check(near(r.apply(CGVector(dx: -30, dy: 0), frame: frame(x: 0), visibleFrames: screen).dx, 0), "the push is absorbed")
    check(near(r.apply(CGVector(dx: -30, dy: 0), frame: frame(x: 0), visibleFrames: screen).dx, -20), "the excess passes once strength is exceeded")
    check(!r.isHolding, "broke through")
    check(near(r.apply(CGVector(dx: -30, dy: 0), frame: frame(x: -20), visibleFrames: screen).dx, -30), "free after breaking through")
    check(near(r.apply(CGVector(dx: 25, dy: 0), frame: frame(x: -50), visibleFrames: screen).dx, 25), "free while still away from the line on the way back")
    check(near(r.apply(CGVector(dx: 30, dy: 0), frame: frame(x: -25), visibleFrames: screen).dx, 25), "sticks when coming from the other side too")
    check(r.isHolding, "resistance in both directions")

    var back = EdgeResistance()
    back.strength = 50
    _ = back.apply(CGVector(dx: -30, dy: 0), frame: frame(x: 20), visibleFrames: screen)
    check(near(back.apply(CGVector(dx: 25, dy: 0), frame: frame(x: 0), visibleFrames: screen).dx, 15), "lets go at once when pulled back")
    check(!back.isHolding, "not held after pulling back")

    var flush = EdgeResistance()
    flush.strength = 50
    check(near(flush.apply(CGVector(dx: 10, dy: 0), frame: frame(x: 0), visibleFrames: screen).dx, 10), "a window flush with an edge pulls inward freely")
    check(near(flush.apply(CGVector(dx: -10, dy: 0), frame: frame(x: 0), visibleFrames: screen).dx, -10), "a push that starts flush with the edge is not held")

    var fast = EdgeResistance()
    fast.strength = 50
    check(near(fast.apply(CGVector(dx: -200, dy: 0), frame: frame(x: 20), visibleFrames: screen).dx, -150), "a fast fling only loses the strength amount")

    var right = EdgeResistance()
    right.strength = 50
    check(near(right.apply(CGVector(dx: 30, dy: 0), frame: frame(x: 1100), visibleFrames: screen).dx, 12), "the right edge sticks too")

    var top = EdgeResistance()
    top.strength = 50
    let up = top.apply(CGVector(dx: 5, dy: -30), frame: frame(x: 500, y: 50), visibleFrames: screen)
    check(near(up.dy, -17) && near(up.dx, 5), "sticks below the menu bar, horizontal stays free")

    var apart = EdgeResistance()
    apart.strength = 50
    let above = [CGRect(x: 0, y: -2000, width: 1000, height: 1000)]
    check(
        near(apart.apply(CGVector(dx: -150, dy: 0), frame: frame(x: 100), visibleFrames: above).dx, -150),
        "edges of a display that does not overlap the window vertically do not count"
    )
}

// MARK: PointerSmoother

do {
    var s = PointerSmoother()
    var time = 0.0
    var worst: CGFloat = 0
    for i in 0..<300 {
        time += 0.01
        let noise: CGFloat = i % 2 == 0 ? 1 : -1
        let p = s.filter(CGPoint(x: 500 + noise, y: 300 - noise), at: time)
        if i > 100 { worst = max(worst, abs(p.x - 500), abs(p.y - 300)) }
    }
    check(worst < 0.3, "±1 pt jitter on a still finger drops below 0.3 pt (\(worst))")

    var m = PointerSmoother()
    time = 0
    var x: CGFloat = 0
    var out = CGPoint.zero
    for _ in 0..<50 {
        time += 0.01
        x += 15 // 1500 pt/s
        out = m.filter(CGPoint(x: x, y: 0), at: time)
    }
    check(x - out.x < 15, "little lag on a fast move (\(x - out.x) pt)")
    for _ in 0..<100 {
        time += 0.01
        out = m.filter(CGPoint(x: x, y: 0), at: time)
    }
    check(abs(x - out.x) < 0.5, "settles where the finger is after stopping (\(abs(x - out.x)) pt)")
}

// MARK: DeadBand

do {
    var band = DeadBand()
    check(band.update(CGPoint(x: 100.2, y: 50)) == CGPoint(x: 100, y: 50), "the first position is rounded and applied")
    check(band.update(CGPoint(x: 100.6, y: 50.4)) == nil, "moving less than a point is not applied")
    check(band.update(CGPoint(x: 99.5, y: 49.6)) == nil, "hovering between two pixels is not applied")
    check(band.update(CGPoint(x: 101.2, y: 50)) == CGPoint(x: 101, y: 50), "applied after moving a point")
    check(band.update(CGPoint(x: 101, y: 48.9)) == CGPoint(x: 101, y: 49), "vertically too")
}

// Measured on 2026-11-25 with a window at the top edge: the window followed up to y 32 and stayed
// there, then jumped to 31, the edge, only when the fingers let go.
do {
    var band = DeadBand()
    _ = band.update(CGPoint(x: 0, y: 32))
    var shown = CGPoint(x: 0, y: 32), applied: CGPoint?
    // About a quarter of a second at 120 Hz: the follow is a hair short of the edge all along.
    for _ in 0..<30 {
        shown.y += (31 - shown.y) * 0.6
        if let p = band.update(shown) { applied = p }
    }
    check(applied == nil, "an exponential follow ending a point away does not apply it on its own")
    check(band.settle(CGPoint(x: 0, y: 31)) == CGPoint(x: 0, y: 31), "settled, the window goes onto the edge")
    check(band.settle(CGPoint(x: 0, y: 31)) == nil, "once")
    check(band.settle(CGPoint(x: 0, y: 31.6)) == nil, "fingers resting on a half point do not flip it")
    check(band.settle(CGPoint(x: 0, y: 31.4)) == nil, "either way")
    check(band.settle(CGPoint(x: 0.8, y: 31)) == CGPoint(x: 1, y: 31), "three quarters of a point away is applied")
}

// MARK: Setup flow

do {
    var status = SetupStatus()
    check(status.primary(on: .permission) == .allowAccess, "without Accessibility the first button asks for it")
    check(status.showsSkip(on: .permission), "and it can be left for later")
    status.accessibilityGranted = true
    check(status.primary(on: .permission) == .next && !status.showsSkip(on: .permission), "allowed: just Continue")
    status.fourFingerGesturesOn = true
    check(status.primary(on: .systemGestures) == .turnOffGestures, "macOS's gestures on: the button turns them off")
    check(status.showsSkip(on: .systemGestures), "only on a press, and they can be kept")
    status.fourFingerGesturesOn = false
    check(status.primary(on: .systemGestures) == .next, "already off: Continue")
    check(status.primary(on: .done) == .finish, "the last step finishes")
    check(SetupStep.permission.previous == nil && SetupStep.done.next == nil, "the steps have ends")
    status.threeFinger.missionControl = true
    check(!status.missionControlNeedsFlicks, "Mission Control on three fingers needs no flick")
    status.threeFinger.missionControl = false
    check(status.missionControlNeedsFlicks, "with it on four fingers only, the up/down flick is offered")
}

// MARK: Guide placement (Cocoa coordinates)

do {
    let card = CGSize(width: 312, height: 150)
    let display = CGRect(x: 0, y: 0, width: 2560, height: 1415)
    let settings = CGRect(x: 600, y: 300, width: 723, height: 657)
    let right = GuidePlacement.dock(card: card, beside: settings, in: display)
    check(right.side == .right && right.frame.minX == settings.maxX + 14, "the card docks right of Settings")
    check(right.frame.maxY == settings.maxY - 64, "level with the list, under the toolbar")

    let atRightEdge = CGRect(x: 1900, y: 300, width: 640, height: 657)
    let left = GuidePlacement.dock(card: card, beside: atRightEdge, in: display)
    check(left.side == .left && left.frame.maxX == atRightEdge.minX - 14, "no room on the right: left")

    let wide = CGRect(x: 100, y: 400, width: 2360, height: 900)
    let below = GuidePlacement.dock(card: card, beside: wide, in: display)
    check(below.side == .below && below.frame.maxY == wide.minY - 14, "no room either side: below")

    let full = CGRect(x: 0, y: 0, width: 2560, height: 1415)
    let inside = GuidePlacement.dock(card: card, beside: full, in: display)
    check(inside.side == .inside && display.contains(inside.frame), "a full-screen Settings: over its corner, on screen")

    let high = CGRect(x: 600, y: 1300, width: 723, height: 100)
    let clamped = GuidePlacement.dock(card: card, beside: high, in: display)
    check(display.contains(clamped.frame), "never off the display")

    let external = CGRect(x: 2560, y: 0, width: 1920, height: 1080)
    let onExternal = CGRect(x: 2700, y: 200, width: 723, height: 657)
    check(external.contains(GuidePlacement.dock(card: card, beside: onExternal, in: external).frame),
          "on the display Settings is on")
}

// MARK: Flavor and app location

do {
    let release: [String: Any] = ["SUFeedURL": "https://github.com/tutamak/tutamak/releases/latest/download/appcast.xml"]
    check(Flavor.feed(info: release, environment: [:]) == release["SUFeedURL"] as? String, "a release checks its own feed")
    check(Flavor.feed(info: [:], environment: [:]) == nil, "a development build has no feed and so no updater")
    check(Flavor.feed(info: ["SUFeedURL": ""], environment: [:]) == nil, "an empty feed is no feed")
    check(Flavor.feed(info: release, environment: ["TUTAMAK_FEED": "http://127.0.0.1:8000/appcast.xml"])
          == "http://127.0.0.1:8000/appcast.xml", "TUTAMAK_FEED points a copy at a local feed")
    check(Flavor.feed(info: release, environment: ["TUTAMAK_FEED": ""]) == release["SUFeedURL"] as? String,
          "an empty TUTAMAK_FEED changes nothing")

    let home = "/Users/someone"
    func place(_ path: String, readOnly: Bool = false) -> AppLocation.Place {
        AppLocation.place(of: path, home: home, readOnlyVolume: readOnly)
    }
    check(place("/Applications/Tutamak.app") == .applications, "/Applications")
    check(place("/Users/someone/Applications/Tutamak.app") == .applications, "~/Applications")
    check(place("/Volumes/Tutamak/Tutamak.app", readOnly: true) == .diskImage, "the disk image")
    check(place("/Users/someone/Downloads/Tutamak.app") == .downloads, "Downloads")
    check(place("/Users/someone/Downloads/Tutamak 2/Tutamak.app") == .downloads, "a folder in Downloads")
    check(place("/Users/someone/Desktop/Tutamak.app") == .downloads, "the desktop")
    check(place("/Users/someone/Projects/tutamak/build/release/Tutamak.app") == .elsewhere, "a build folder is left alone")
    check(place("/Volumes/Work/Tutamak.app") == .elsewhere, "a writable external drive is left alone")
    check(place("/Applications/../Users/someone/Downloads/Tutamak.app") == .downloads, "the path is standardized first")
    check(place("/ApplicationsOld/Tutamak.app") == .elsewhere, "only the folder itself counts")
}

print("\(checks - failures)/\(checks) checks passed")
exit(failures == 0 ? 0 : 1)
