import CoreGraphics
import Foundation

/// Where a window lands when it is released.
enum SnapZone: Equatable, CustomStringConvertible {
    case left
    case right
    case maximize

    var description: String {
        switch self {
        case .left: "left half"
        case .right: "right half"
        case .maximize: "full screen"
        }
    }
}

/// Which edges of a window a pinch moves, chosen by where the cursor is in the window when the
/// resize starts, so the hand can always make its easy sideways spread: near the left or right edge
/// the width changes, near the top or bottom edge the height, right in a corner both, and in the
/// middle the whole window scales.
struct ResizeGrip: Equatable, CustomStringConvertible {
    /// Where the cursor is along one axis: near the min edge, in the middle, or near the max edge.
    enum Side { case low, middle, high }

    var x: Side
    var y: Side

    init(x: Side, y: Side) {
        self.x = x
        self.y = y
    }

    /// `spot` is the cursor's place in the window, 0..1 from its top-left corner (CG coordinates);
    /// `size` is the window's size, to tell which edge is physically nearer.
    ///
    /// The middle ninth of the window is the centre. A corner is the outer sixth on both axes, kept
    /// small so that "near the bottom" means the bottom edge along almost all of its length.
    /// Anywhere else the edge nearest the cursor is gripped.
    init(spot: CGPoint, size: CGSize) {
        // How far from the middle toward an edge, per axis: 0 in the middle, 1 at the edge.
        let ox = abs(spot.x * 2 - 1)
        let oy = abs(spot.y * 2 - 1)
        let sx: Side = spot.x < 0.5 ? .low : .high
        let sy: Side = spot.y < 0.5 ? .low : .high
        let middle: CGFloat = 1.0 / 3
        let corner: CGFloat = 2.0 / 3
        if ox < middle, oy < middle {
            self.init(x: .middle, y: .middle)
        } else if ox >= corner, oy >= corner {
            self.init(x: sx, y: sy)
        } else if oy < middle {
            self.init(x: sx, y: .middle)
        } else if ox < middle {
            self.init(x: .middle, y: sy)
        } else {
            let toSide = (1 - ox) / 2 * size.width
            let toEnd = (1 - oy) / 2 * size.height
            self.init(x: toEnd <= toSide ? .middle : sx, y: toEnd <= toSide ? sy : .middle)
        }
    }

    static let centre = ResizeGrip(x: .middle, y: .middle)

    var isCentre: Bool { self == .centre }

    var description: String {
        if isCentre { return "centre" }
        let vertical = y == .low ? "top" : y == .high ? "bottom" : nil
        let horizontal = x == .low ? "left" : x == .high ? "right" : nil
        switch (vertical, horizontal) {
        case let (v?, h?): return "\(v)-\(h) corner"
        case let (v?, nil): return "\(v) edge"
        case let (nil, h?): return "\(h) edge"
        default: return "centre"
        }
    }
}

/// A grid that divides a display's visible area into equal cells to drop windows into.
struct GridLayout: Equatable, CustomStringConvertible {
    let columns: Int
    let rows: Int

    var description: String { "\(columns)×\(rows)" }

    /// The layout a display gets on Auto: three columns where a third is still a comfortable
    /// window (a 2560 pt display), two otherwise (a laptop).
    static func auto(for visible: CGRect) -> GridLayout {
        visible.width >= 2200 ? GridLayout(columns: 3, rows: 2) : GridLayout(columns: 2, rows: 2)
    }
}

/// What the drop grid is set to in the menu.
enum GridChoice: Equatable {
    case off
    case auto
    case fixed(GridLayout)

    /// "off", "auto" or "3x2", as stored in the defaults.
    init(_ raw: String) {
        switch raw {
        case "auto": self = .auto
        default:
            let parts = raw.split(separator: "x").compactMap { Int($0) }
            if parts.count == 2, (1...6).contains(parts[0]), (1...6).contains(parts[1]) {
                self = .fixed(GridLayout(columns: parts[0], rows: parts[1]))
            } else {
                self = .off
            }
        }
    }

    var raw: String {
        switch self {
        case .off: "off"
        case .auto: "auto"
        case .fixed(let g): "\(g.columns)x\(g.rows)"
        }
    }

    /// The grid for a display, or nil when the grid is off.
    func layout(for visible: CGRect) -> GridLayout? {
        switch self {
        case .off: nil
        case .auto: GridLayout.auto(for: visible)
        case .fixed(let g): g
        }
    }
}

/// Pure geometry; it does not touch AppKit, so the tests compile it on its own.
/// Display rectangles are in CG/AX coordinates: origin at the top left of the main display, y grows downward.
enum Geometry {
    static func display(containing point: CGPoint, in displays: [CGRect]) -> CGRect? {
        displays.first { $0.contains(point) }
    }

    /// Keeps the cursor on a display. A point outside every display is clamped
    /// to the bounds of the display the previous point was on.
    static func clamp(_ point: CGPoint, previous: CGPoint, displays: [CGRect]) -> CGPoint {
        if display(containing: point, in: displays) != nil { return point }
        guard let d = display(containing: previous, in: displays) ?? displays.first else { return point }
        return CGPoint(
            x: min(max(point.x, d.minX), d.maxX - 1),
            y: min(max(point.y, d.minY), d.maxY - 1)
        )
    }

    /// The snap zone for a cursor pushed against the outer edge of a display.
    /// Inner edges where two displays meet do not count; the cursor crosses there to the other display.
    /// In a corner the side edge wins over the top edge.
    static func snapZone(at p: CGPoint, displays: [CGRect], edge: CGFloat = 3)
        -> (zone: SnapZone, display: CGRect)?
    {
        guard let d = display(containing: p, in: displays) else { return nil }
        func outer(_ beyond: CGPoint) -> Bool { display(containing: beyond, in: displays) == nil }

        if p.x <= d.minX + edge, outer(CGPoint(x: d.minX - 1, y: p.y)) { return (.left, d) }
        if p.x >= d.maxX - 1 - edge, outer(CGPoint(x: d.maxX + 1, y: p.y)) { return (.right, d) }
        if p.y <= d.minY + edge, outer(CGPoint(x: p.x, y: d.minY - 1)) { return (.maximize, d) }
        return nil
    }

    /// The zone's frame within the display's visible area (without the menu bar and the Dock).
    static func snapFrame(_ zone: SnapZone, visible v: CGRect) -> CGRect {
        let half = (v.width / 2).rounded(.down)
        switch zone {
        case .left: return CGRect(x: v.minX, y: v.minY, width: half, height: v.height)
        case .right: return CGRect(x: v.minX + half, y: v.minY, width: v.width - half, height: v.height)
        case .maximize: return v
        }
    }

    /// The cells of `layout` within `visible`, row by row from the top left. Neighbouring cells
    /// share their edges exactly.
    static func gridCells(_ layout: GridLayout, in visible: CGRect) -> [CGRect] {
        var cells: [CGRect] = []
        for row in 0..<layout.rows {
            for column in 0..<layout.columns {
                cells.append(gridFrame(layout, in: visible, columns: column...column, rows: row...row))
            }
        }
        return cells
    }

    /// The zone to drop a window into for the cursor at `p`: the cell under it, or, within `seam`
    /// (a fraction of a cell) of a line between two cells, both of them. So a 2×2 grid gives
    /// quarters, halves on its middle lines and the whole area where they cross; a 3×2 grid gives
    /// sixths, two-thirds on its column lines and full-height thirds on its middle line.
    static func gridZone(at p: CGPoint, in visible: CGRect, layout: GridLayout, seam: CGFloat = 0.1) -> CGRect {
        func span(_ position: CGFloat, _ lo: CGFloat, _ length: CGFloat, _ count: Int) -> ClosedRange<Int> {
            let u = min(max((position - lo) / length, 0), 0.999_999) * CGFloat(count)
            let i = Int(u)
            let f = u - CGFloat(i)
            if f < seam, i > 0 { return (i - 1)...i }
            if f > 1 - seam, i < count - 1 { return i...(i + 1) }
            return i...i
        }
        return gridFrame(
            layout, in: visible,
            columns: span(p.x, visible.minX, visible.width, layout.columns),
            rows: span(p.y, visible.minY, visible.height, layout.rows)
        )
    }

    private static func gridFrame(
        _ layout: GridLayout, in v: CGRect, columns: ClosedRange<Int>, rows: ClosedRange<Int>
    ) -> CGRect {
        func line(_ i: Int, _ lo: CGFloat, _ length: CGFloat, _ count: Int) -> CGFloat {
            (lo + length * CGFloat(i) / CGFloat(count)).rounded()
        }
        let x0 = line(columns.lowerBound, v.minX, v.width, layout.columns)
        let x1 = line(columns.upperBound + 1, v.minX, v.width, layout.columns)
        let y0 = line(rows.lowerBound, v.minY, v.height, layout.rows)
        let y1 = line(rows.upperBound + 1, v.minY, v.height, layout.rows)
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// Which point of a window stays put while it resizes, per axis: 0 keeps the min edge, 1 the max
    /// edge, 0.5 the centre. An edge resting on the edge of `bounds` stays there (a snapped window
    /// keeps hugging the screen). Otherwise the edge away from the grip stays, so the edge near the
    /// cursor is the one that moves; with the grip in the middle the window resizes around its centre.
    static func resizeAnchor(
        _ frame: CGRect, in bounds: CGRect, grip: ResizeGrip = .centre, tolerance: CGFloat = 8
    ) -> CGPoint {
        func axis(_ lo: CGFloat, _ hi: CGFloat, _ boundsLo: CGFloat, _ boundsHi: CGFloat, _ side: ResizeGrip.Side) -> CGFloat {
            let loFlush = abs(lo - boundsLo) <= tolerance
            let hiFlush = abs(hi - boundsHi) <= tolerance
            if loFlush, !hiFlush { return 0 }
            if hiFlush, !loFlush { return 1 }
            switch side {
            case .low: return 1
            case .high: return 0
            case .middle: return 0.5
            }
        }
        return CGPoint(
            x: axis(frame.minX, frame.maxX, bounds.minX, bounds.maxX, grip.x),
            y: axis(frame.minY, frame.maxY, bounds.minY, bounds.maxY, grip.y)
        )
    }

    /// Whether a window spans `bounds` along each axis (both of its edges rest on the edges of `bounds`).
    static func spans(_ frame: CGRect, _ bounds: CGRect, tolerance: CGFloat = 8) -> (width: Bool, height: Bool) {
        (
            abs(frame.minX - bounds.minX) <= tolerance && abs(frame.maxX - bounds.maxX) <= tolerance,
            abs(frame.minY - bounds.minY) <= tolerance && abs(frame.maxY - bounds.maxY) <= tolerance
        )
    }

    /// Which axes a resize changes: the gripped edge's axis; both from a corner or the middle.
    /// No exceptions, so the cursor alone says what changes. An axis already as long as the screen
    /// (a snapped half's height) can still shrink; spreading just leaves it at full length.
    static func resizedAxes(_ grip: ResizeGrip) -> (width: Bool, height: Bool) {
        grip.isCentre ? (true, true) : (grip.x != .middle, grip.y != .middle)
    }

    /// How much to scale a window for a hand whose spread (mean distance of the fingers from their
    /// centre) went from `start` by `change`: like a zoom, by the ratio of the spreads to `exponent`,
    /// along the axes `resizedAxes` picks. Only the overall spread counts, never its direction, so
    /// the easy sideways spread works for the height too.
    static func resizeScale(grip: ResizeGrip, start: CGFloat, change: CGFloat, exponent: CGFloat) -> CGSize {
        // A floor on the starting spread keeps a bunched-up hand from turning a tiny change into a huge ratio.
        let base = max(start, 0.02)
        let r = pow(max(0.2, (base + change) / base), exponent)
        let axes = resizedAxes(grip)
        return CGSize(width: axes.width ? r : 1, height: axes.height ? r : 1)
    }

    static func resizedFrame(_ start: CGRect, scale: CGFloat, anchor: CGPoint, within bounds: CGRect, minimum: CGSize) -> CGRect {
        resizedFrame(start, scale: CGSize(width: scale, height: scale), anchor: anchor, within: bounds, minimum: minimum)
    }

    /// `start` scaled by `scale` (per axis) around `anchor`. Each axis stays between `minimum` (or the
    /// start size, if smaller) and the `bounds` size (or the start size, if larger), so spreading far
    /// enough fills the screen. The result is shifted to stay within `bounds` and wherever `start` already was.
    static func resizedFrame(_ start: CGRect, scale: CGSize, anchor: CGPoint, within bounds: CGRect, minimum: CGSize) -> CGRect {
        let w = min(max(start.width * scale.width, min(minimum.width, start.width)), max(bounds.width, start.width))
        let h = min(max(start.height * scale.height, min(minimum.height, start.height)), max(bounds.height, start.height))
        let allowed = bounds.union(start)
        var x = start.minX + (start.width - w) * anchor.x
        var y = start.minY + (start.height - h) * anchor.y
        x = min(max(x, allowed.minX), allowed.maxX - w)
        y = min(max(y, allowed.minY), allowed.maxY - h)
        return CGRect(x: x.rounded(), y: y.rounded(), width: w.rounded(), height: h.rounded())
    }

    /// Whether two frames match within `tolerance` on every edge.
    static func isClose(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 4) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
            && abs(a.maxX - b.maxX) <= tolerance && abs(a.maxY - b.maxY) <= tolerance
    }

    /// Converts between Cocoa (origin bottom left) and CG/AX (origin top left); the same formula works both ways.
    static func flip(_ r: CGRect, primaryHeight h: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height)
    }

    /// The average displacement of the fingers present in both frames.
    /// Only shared fingers count, so the centroid does not jump when a finger lifts or lands.
    static func averageDelta(from a: [Int32: CGPoint], to b: [Int32: CGPoint]) -> CGVector? {
        var sx: CGFloat = 0
        var sy: CGFloat = 0
        var n = 0
        for (id, p) in b {
            guard let q = a[id] else { continue }
            sx += p.x - q.x
            sy += p.y - q.y
            n += 1
        }
        guard n > 0 else { return nil }
        return CGVector(dx: sx / CGFloat(n), dy: sy / CGFloat(n))
    }
}
