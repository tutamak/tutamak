import SwiftUI

/// The gestures the setup assistant draws.
enum GestureDemo: Int, CaseIterable, Identifiable {
    case slide, pinch, tap, flick, flickUp

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .slide: "Slide to move"
        case .pinch: "Pinch to resize"
        case .tap: "Tap to maximize"
        case .flick: "Flick to switch desktops"
        case .flickUp: "Flick up for Mission Control"
        }
    }

    var shortTitle: String {
        switch self {
        case .slide: "Move"
        case .pinch: "Resize"
        case .tap: "Maximize"
        case .flick: "Switch desktops"
        case .flickUp: "Mission Control"
        }
    }

    var symbol: String {
        switch self {
        case .slide: "arrow.up.and.down.and.arrow.left.and.right"
        case .pinch: "arrow.up.left.and.arrow.down.right"
        case .tap: "hand.tap"
        case .flick: "rectangle.on.rectangle.angled"
        case .flickUp: "rectangle.3.group"
        }
    }

    /// Seconds per loop: the gesture one way, then back, so every loop ends where it began.
    var period: Double { self == .tap ? 3.2 : 4 }

    /// A moment that shows the gesture well, for Reduce Motion and still captures.
    var stillTime: Double {
        switch self {
        case .slide: 0.8
        case .pinch: 0.9
        case .tap: 0.2
        case .flick: 0.22
        case .flickUp: 0.3
        }
    }
}

/// One moment of a scene. Finger positions are in trackpad units (0...1, y down); the window is in
/// units of the display below its menu bar.
struct SceneFrame: Equatable {
    static let restingWindow = CGRect(x: 0.12, y: 0.17, width: 0.46, height: 0.56)
    /// Where four fingers rest: index to little finger, in a gentle arc like a real hand.
    static let restingFingers = [
        CGPoint(x: 0.30, y: 0.54), CGPoint(x: 0.43, y: 0.45), CGPoint(x: 0.56, y: 0.46), CGPoint(x: 0.68, y: 0.57),
    ]

    var fingers: [CGPoint] = Self.restingFingers
    /// Where each finger's trail starts, or nil for none.
    var trailStarts: [CGPoint]? = Self.restingFingers
    var fingerOpacity: Double = 0
    /// Each finger's own presence (landing, lifting), or nil for `fingerOpacity` for all.
    var fingerOpacities: [Double]?
    /// Each finger's own size, with `fingerOpacities`: a little larger as it lands, a little
    /// smaller as it lifts.
    var fingerScales: [Double]?
    var fingerScale: Double = 1
    /// A tap's ripple, 0...1, or nil.
    var ripple: Double?
    var window = Self.restingWindow
    /// Where the pointer sits, in window units (0...1), or nil to hide it.
    var pointer: CGPoint? = CGPoint(x: 0.34, y: 0.1)
    /// 0 shows the first desktop, 1 the one to its right.
    var desktop: Double = 0
    /// Mission Control, 0...1.
    var overview: Double = 0

    /// The demo's frame `t` seconds into its loop.
    static func demo(_ demo: GestureDemo, at time: Double) -> SceneFrame {
        let t = time.truncatingRemainder(dividingBy: demo.period)
        let half = demo.period / 2
        let back = t >= half
        let s = back ? t - half : t
        var f = SceneFrame()

        switch demo {
        case .slide:
            touch(&f, s, land: 0, lift: 1.2)
            let p = ease(seg(s, 0.22, 1.08))
            let travel = CGVector(dx: 0.2, dy: 0.07)
            let d = back ? -1.0 : 1.0
            f.fingers = moved(Self.restingFingers, by: travel, times: p * d)
            let w = back ? 1 - p : p
            f.window.origin.x += 0.34 * w
            f.window.origin.y += 0.1 * w

        case .pinch:
            touch(&f, s, land: 0, lift: 1.2)
            let p = ease(seg(s, 0.22, 1.08))
            // Out: the hand opens. Back: it lands open and closes.
            let open = back ? 1 - p : p
            f.fingers = spread(Self.restingFingers, by: back ? 1.55 - 0.55 * p : 1 + 0.55 * p)
            let grow = 1 + 0.5 * open
            let centre = CGPoint(x: Self.restingWindow.midX + 0.06 * open, y: Self.restingWindow.midY)
            f.window = CGRect(
                x: centre.x - Self.restingWindow.width * grow / 2, y: centre.y - Self.restingWindow.height * grow / 2,
                width: Self.restingWindow.width * grow, height: Self.restingWindow.height * grow
            )
            f.pointer = CGPoint(x: 0.5, y: 0.55)

        case .tap:
            touch(&f, s, land: 0, lift: 0.26, fade: 0.1)
            f.ripple = s >= 0.12 && s <= 0.72 ? seg(s, 0.12, 0.72) : nil
            let p = overshoot(seg(s, 0.24, 0.7))
            let full = CGRect(x: 0, y: 0, width: 1, height: 1)
            f.window = back ? mix(full, Self.restingWindow, p) : mix(Self.restingWindow, full, p)
            f.pointer = CGPoint(x: 0.5, y: 0.5)

        case .flick:
            touch(&f, s, land: 0, lift: 0.34, fade: 0.12)
            let swipe = easeIn(seg(s, 0.1, 0.32))
            f.fingers = moved(Self.restingFingers, by: CGVector(dx: back ? 0.26 : -0.26, dy: 0.01), times: swipe)
            let p = overshoot(seg(s, 0.2, 0.75), amount: 0.6)
            f.desktop = back ? 1 - p : p
            f.pointer = nil

        case .flickUp:
            touch(&f, s, land: 0, lift: 0.34, fade: 0.12)
            let swipe = easeIn(seg(s, 0.1, 0.32))
            f.fingers = moved(Self.restingFingers, by: CGVector(dx: 0, dy: back ? 0.3 : -0.3), times: swipe)
            let p = ease(seg(s, 0.2, 0.72))
            f.overview = back ? 1 - p : p
            f.pointer = nil
        }
        return f
    }

    // MARK: Motion

    /// Fingers fade in as they land and out as they lift.
    private static func touch(_ f: inout SceneFrame, _ s: Double, land: Double, lift: Double, fade: Double = 0.18) {
        let down = ease(seg(s, land, land + fade))
        let up = ease(seg(s, lift, lift + fade))
        f.fingerOpacity = down * (1 - up)
        f.fingerScale = 1 + 0.25 * (1 - down) + 0.12 * up
    }

    static func seg(_ t: Double, _ a: Double, _ b: Double) -> Double { min(max((t - a) / (b - a), 0), 1) }

    static func ease(_ x: Double) -> Double { x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2 }

    static func easeIn(_ x: Double) -> Double { x * x * x }

    /// Ease out with a slight settle past the end, like a spring.
    static func overshoot(_ x: Double, amount: Double = 1.1) -> Double {
        let c3 = amount + 1
        return 1 + c3 * pow(x - 1, 3) + amount * pow(x - 1, 2)
    }

    private static func moved(_ points: [CGPoint], by v: CGVector, times k: Double) -> [CGPoint] {
        points.map { CGPoint(x: $0.x + v.dx * k, y: $0.y + v.dy * k) }
    }

    private static func spread(_ points: [CGPoint], by k: Double) -> [CGPoint] {
        let cx = points.map(\.x).reduce(0, +) / CGFloat(points.count)
        let cy = points.map(\.y).reduce(0, +) / CGFloat(points.count)
        return points.map { CGPoint(x: cx + ($0.x - cx) * k, y: cy + ($0.y - cy) * k) }
    }

    static func mix(_ a: CGRect, _ b: CGRect, _ p: Double) -> CGRect {
        CGRect(
            x: a.minX + (b.minX - a.minX) * p, y: a.minY + (b.minY - a.minY) * p,
            width: a.width + (b.width - a.width) * p, height: a.height + (b.height - a.height) * p
        )
    }
}

/// A gesture shown side by side: a trackpad with four fingers on the left, the screen it acts on
/// on the right. Flat and in the system's colors, light or dark; the fingers are the accent
/// color, with a trail where they slide and a ring where they tap.
struct GestureStage: View {
    let frame: SceneFrame
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Canvas { ctx, size in
            StageRenderer(frame: frame, dark: scheme == .dark).draw(in: &ctx, size: size)
        }
        .accessibilityHidden(true)
    }
}

/// A demo playing in a loop; a fixed `time` or Reduce Motion holds it still.
struct GestureDemoView: View {
    let demo: GestureDemo
    var time: Double?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let time {
            GestureStage(frame: .demo(demo, at: time))
        } else if reduceMotion {
            GestureStage(frame: .demo(demo, at: demo.stillTime))
        } else {
            TimelineView(.animation) { context in
                GestureStage(frame: .demo(demo, at: context.date.timeIntervalSinceReferenceDate))
            }
        }
    }
}

private struct StageRenderer {
    let frame: SceneFrame
    let dark: Bool

    static let design = CGSize(width: 392, height: 150)
    static let pad = CGRect(x: 6, y: 26, width: 140, height: 98)
    static let display = CGRect(x: 168, y: 4, width: 218, height: 142)
    static let bezel: CGFloat = 5
    static let menuBar: CGFloat = 8

    private func hex(_ light: UInt32, _ dark: UInt32, _ alpha: Double = 1) -> Color {
        let v = self.dark ? dark : light
        return Color(.sRGB, red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255,
                     blue: Double(v & 0xFF) / 255, opacity: alpha)
    }

    func draw(in ctx: inout GraphicsContext, size: CGSize) {
        let d = Self.design
        let scale = min(size.width / d.width, size.height / d.height)
        ctx.translateBy(x: (size.width - d.width * scale) / 2, y: (size.height - d.height * scale) / 2)
        ctx.scaleBy(x: scale, y: scale)
        drawPad(&ctx)
        drawDisplay(&ctx)
    }

    // MARK: Trackpad

    private func drawPad(_ ctx: inout GraphicsContext) {
        let pad = Self.pad
        let shape = Path(roundedRect: pad, cornerRadius: 12, style: .continuous)
        ctx.fill(shape, with: .color(hex(0xECEDF0, 0x2C2E33)))
        ctx.stroke(shape, with: .color(hex(0xD6D8DD, 0x3B3E44)), lineWidth: 1)

        let accent = Color.accentColor
        let points = frame.fingers.map { CGPoint(x: pad.minX + $0.x * pad.width, y: pad.minY + $0.y * pad.height) }
        let starts = (frame.trailStarts ?? []).map { CGPoint(x: pad.minX + $0.x * pad.width, y: pad.minY + $0.y * pad.height) }

        let presence = { (i: Int) -> Double in frame.fingerOpacities?[i] ?? frame.fingerOpacity }
        // Where the fingers slid from, while they are down.
        for (i, (a, b)) in zip(starts, points).enumerated() where presence(i) > 0.05 && hypot(b.x - a.x, b.y - a.y) > 4 {
            var trail = Path()
            trail.move(to: a)
            trail.addLine(to: b)
            ctx.stroke(trail, with: .linearGradient(Gradient(colors: [accent.opacity(0), accent.opacity(0.35 * presence(i))]),
                                                    startPoint: a, endPoint: b),
                       style: StrokeStyle(lineWidth: 4, lineCap: .round))
        }
        for (i, c) in points.enumerated() {
            let opacity = presence(i)
            let scale = frame.fingerScales?[i] ?? frame.fingerScale
            if let ripple = frame.ripple {
                let r = 8 + 16 * ripple
                ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
                           with: .color(accent.opacity(0.6 * (1 - ripple))), lineWidth: 1.5)
            }
            guard opacity > 0.01 else { continue }
            let size = 14 * scale
            let dot = Path(ellipseIn: CGRect(x: c.x - size / 2, y: c.y - size / 2, width: size, height: size))
            ctx.drawLayer { l in
                l.opacity = opacity
                let halo = 12 * scale
                l.fill(Path(ellipseIn: CGRect(x: c.x - halo, y: c.y - halo, width: halo * 2, height: halo * 2)),
                       with: .color(accent.opacity(0.14)))
                l.addFilter(.shadow(color: .black.opacity(0.2), radius: 1.5, x: 0, y: 1))
                l.fill(dot, with: .color(accent))
            }
            ctx.drawLayer { l in
                l.opacity = opacity
                l.stroke(dot, with: .color(.white.opacity(dark ? 0.35 : 0.9)), lineWidth: 1.5)
            }
        }
    }

    // MARK: Display

    private var screen: CGRect { Self.display.insetBy(dx: Self.bezel, dy: Self.bezel) }
    private var content: CGRect {
        CGRect(x: screen.minX, y: screen.minY + Self.menuBar, width: screen.width, height: screen.height - Self.menuBar)
    }

    private func drawDisplay(_ ctx: inout GraphicsContext) {
        let outer = Path(roundedRect: Self.display, cornerRadius: 10, style: .continuous)
        ctx.fill(outer, with: .color(hex(0x1D1E21, 0x0E0F11)))
        ctx.stroke(outer, with: .color(hex(0x000000, 0x4A4D53, dark ? 1 : 0.15)), lineWidth: 0.75)
        let screenPath = Path(roundedRect: screen, cornerRadius: 5, style: .continuous)
        ctx.drawLayer { layer in
            layer.clip(to: screenPath)
            let shift = screen.width * frame.desktop
            layer.drawLayer { d in
                d.translateBy(x: -shift, y: 0)
                drawDesktop(&d, first: true)
            }
            layer.drawLayer { d in
                d.translateBy(x: screen.width - shift, y: 0)
                drawDesktop(&d, first: false)
            }
            let bar = CGRect(x: screen.minX, y: screen.minY, width: screen.width, height: Self.menuBar)
            layer.fill(Path(bar), with: .color(hex(0xFFFFFF, 0x000000, dark ? 0.35 : 0.55)))
            layer.fill(Path(ellipseIn: CGRect(x: bar.minX + 6, y: bar.midY - 1.5, width: 3, height: 3)),
                       with: .color(hex(0x1D1E21, 0xE8EAED, 0.7)))
            for i in 0..<3 {
                layer.fill(Path(roundedRect: CGRect(x: bar.minX + 13 + CGFloat(i) * 10, y: bar.midY - 1, width: 7, height: 2),
                                cornerRadius: 1), with: .color(hex(0x1D1E21, 0xE8EAED, 0.45)))
            }
        }
    }

    private func drawDesktop(_ ctx: inout GraphicsContext, first: Bool) {
        let colors = first ? [hex(0xDCE6F2, 0x2A3A50), hex(0xBFD0E6, 0x1B2534)]
                           : [hex(0xEFE5D8, 0x473A2C), hex(0xDDC9B2, 0x2E251C)]
        ctx.fill(Path(screen), with: .linearGradient(Gradient(colors: colors), startPoint: CGPoint(x: screen.minX, y: screen.minY),
                                                     endPoint: CGPoint(x: screen.maxX, y: screen.maxY)))
        let m = first ? frame.overview : 0
        if m > 0 {
            ctx.fill(Path(screen), with: .color(.black.opacity((dark ? 0.35 : 0.2) * m)))
            drawSpaces(&ctx, m)
        }
        if first {
            if m > 0 {
                let other = CGRect(x: 0.58, y: 0.3, width: 0.34, height: 0.42)
                drawWindow(&ctx, unit(SceneFrame.mix(other.offsetBy(dx: 0.1, dy: 0.04), other, m)), opacity: m, pointer: nil)
            }
            let overview = CGRect(x: 0.1, y: 0.3, width: 0.42, height: 0.5)
            drawWindow(&ctx, unit(SceneFrame.mix(frame.window, overview, m)), opacity: 1, pointer: m < 0.05 ? frame.pointer : nil)
        } else {
            drawWindow(&ctx, unit(CGRect(x: 0.4, y: 0.18, width: 0.5, height: 0.6)), opacity: 1, pointer: nil)
        }
    }

    private func drawSpaces(_ ctx: inout GraphicsContext, _ m: Double) {
        let y = content.minY + 5 - 8 * (1 - m)
        for i in 0..<2 {
            let r = CGRect(x: content.midX - 40 + CGFloat(i) * 44, y: y, width: 36, height: 22)
            ctx.drawLayer { l in
                l.opacity = m
                l.fill(Path(roundedRect: r, cornerRadius: 3, style: .continuous),
                       with: .color(i == 0 ? hex(0xDCE6F2, 0x2A3A50) : hex(0xEFE5D8, 0x473A2C)))
                if i == 0 {
                    l.stroke(Path(roundedRect: r.insetBy(dx: -1.5, dy: -1.5), cornerRadius: 4.5, style: .continuous),
                             with: .color(.white.opacity(0.9)), lineWidth: 1.2)
                }
            }
        }
    }

    private func unit(_ r: CGRect) -> CGRect {
        CGRect(x: content.minX + r.minX * content.width, y: content.minY + r.minY * content.height,
               width: r.width * content.width, height: r.height * content.height)
    }

    private func drawWindow(_ ctx: inout GraphicsContext, _ r: CGRect, opacity: Double, pointer: CGPoint?) {
        let shape = Path(roundedRect: r, cornerRadius: min(4, r.height / 6), style: .continuous)
        ctx.drawLayer { l in
            l.opacity = opacity
            l.addFilter(.shadow(color: .black.opacity(dark ? 0.45 : 0.16), radius: 5, x: 0, y: 2))
            l.fill(shape, with: .color(hex(0xFFFFFF, 0x3A3C41)))
        }
        ctx.drawLayer { l in
            l.opacity = opacity
            l.clip(to: shape)
            let title = min(9, r.height * 0.2)
            l.fill(Path(CGRect(x: r.minX, y: r.minY, width: r.width, height: title)), with: .color(hex(0xF1F2F4, 0x44464C)))
            let dot = min(3.4, title * 0.4)
            for (i, c) in [Color(red: 1, green: 0.37, blue: 0.34), Color(red: 1, green: 0.74, blue: 0.18),
                           Color(red: 0.16, green: 0.78, blue: 0.25)].enumerated() {
                l.fill(Path(ellipseIn: CGRect(x: r.minX + 4.5 + CGFloat(i) * (dot + 2.2), y: r.minY + title / 2 - dot / 2,
                                              width: dot, height: dot)), with: .color(c))
            }
            var y = r.minY + title + 6
            for w in [0.62, 0.8, 0.5, 0.72] as [CGFloat] where y + 3 < r.maxY - 4 {
                l.fill(Path(roundedRect: CGRect(x: r.minX + 7, y: y, width: (r.width - 14) * w, height: 2.5), cornerRadius: 1.25),
                       with: .color(hex(0xE3E5E9, 0x55585F)))
                y += 7
            }
        }
        if let pointer, opacity > 0.5 {
            drawPointer(&ctx, at: CGPoint(x: r.minX + r.width * pointer.x, y: r.minY + r.height * pointer.y))
        }
    }

    /// The macOS pointer: a black arrow with a white outline.
    private func drawPointer(_ ctx: inout GraphicsContext, at p: CGPoint) {
        var arrow = Path()
        let outline: [(CGFloat, CGFloat)] = [(0, 0), (0, 13.5), (3.4, 10.4), (5.8, 15.6), (8, 14.6), (5.7, 9.6), (10, 9.6)]
        arrow.addLines(outline.map { CGPoint(x: p.x + $0.0 * 0.75, y: p.y + $0.1 * 0.75) })
        arrow.closeSubpath()
        ctx.drawLayer { l in
            l.addFilter(.shadow(color: .black.opacity(0.3), radius: 1, x: 0, y: 0.5))
            l.fill(arrow, with: .color(.black))
        }
        ctx.stroke(arrow, with: .color(.white), style: StrokeStyle(lineWidth: 1, lineJoin: .round))
    }
}
