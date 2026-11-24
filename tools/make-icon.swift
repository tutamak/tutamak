// Draws Tutamak's app icon ("Paper Onyx") into an .iconset: a white ceramic dish holding four
// polished onyx stones, the fingertips of a resting hand in its lopsided arc (the little finger
// lowest). The light is in the stones: a soft sheen above, a thin rim, a faint bounce from the
// dish below. A light face with dark marks, in the same family as the icon of Evlat, a
// sibling app.
//
// At 16 px (1x) the stones would blur into each other, so there they are one-pixel ticks with
// two-pixel gaps, on edges that fall on whole pixels.
//
// The icon is code, not a checked-in image: this file is its only source, and the Makefile turns
// the iconset into AppIcon.icns with `iconutil`. AppKit and CoreGraphics only.
//
//   swift tools/make-icon.swift <out.iconset>
//
// Geometry is on Apple's 1024 grid (body 824 with a 100 margin), y measured from the top. Shadow
// and blur radii ignore the context's transform, so every one goes through `Pen`, which scales it.
import AppKit

let args = CommandLine.arguments
guard args.count == 2 else {
    FileHandle.standardError.write("usage: make-icon.swift <out.iconset>\n".data(using: .utf8)!)
    exit(2)
}
let out = URL(fileURLWithPath: args[1])
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

// MARK: Color and paths

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

/// A gradient stop: color, alpha, location.
typealias Stop = (UInt32, CGFloat, CGFloat)

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

func ellipse(_ cx: CGFloat, _ cy: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGPath {
    CGPath(ellipseIn: CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h), transform: nil)
}

/// Apple's continuous-corner rounded rect (the well-known Bézier approximation of the shape).
func continuousRect(_ rect: CGRect, radius r: CGFloat) -> CGPath {
    let p = CGMutablePath()
    // Each corner: its point, a unit vector back along the edge the path arrives on, and one along
    // the edge it leaves on.
    func corner(_ o: CGPoint, _ a: CGVector, _ b: CGVector, first: Bool) {
        func q(_ u: CGFloat, _ v: CGFloat) -> CGPoint {
            CGPoint(x: o.x + (a.dx * u + b.dx * v) * r, y: o.y + (a.dy * u + b.dy * v) * r)
        }
        if first { p.move(to: q(1.52866483, 0)) } else { p.addLine(to: q(1.52866483, 0)) }
        p.addCurve(to: q(0.66993427, 0.06549600), control1: q(1.08849323, 0), control2: q(0.86840689, 0))
        p.addLine(to: q(0.63149399, 0.07491100))
        p.addCurve(to: q(0.07491100, 0.63149399), control1: q(0.37282392, 0.16905899), control2: q(0.16905899, 0.37282401))
        p.addCurve(to: q(0, 1.52866483), control1: q(0, 0.86840701), control2: q(0, 1.08849299))
    }
    corner(pt(rect.maxX, rect.minY), CGVector(dx: -1, dy: 0), CGVector(dx: 0, dy: 1), first: true)
    corner(pt(rect.maxX, rect.maxY), CGVector(dx: 0, dy: -1), CGVector(dx: -1, dy: 0), first: false)
    corner(pt(rect.minX, rect.maxY), CGVector(dx: 1, dy: 0), CGVector(dx: 0, dy: -1), first: false)
    corner(pt(rect.minX, rect.minY), CGVector(dx: 0, dy: 1), CGVector(dx: 1, dy: 0), first: false)
    p.closeSubpath()
    return p
}

/// The icon body, optionally inset (the corner radius shrinks with it).
func body(inset d: CGFloat = 0) -> CGPath {
    continuousRect(CGRect(x: 100 + d, y: 100 + d, width: 824 - 2 * d, height: 824 - 2 * d), radius: 185.4 - d)
}

/// A superellipse: fuller than an oval, softer than a capsule.
func superellipse(_ cx: CGFloat, _ cy: CGFloat, _ w: CGFloat, _ h: CGFloat, n: CGFloat = 2.35, degrees: CGFloat = 0) -> CGPath {
    let p = CGMutablePath()
    let steps = 240
    let rot = degrees * .pi / 180
    for i in 0..<steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let ct = cos(t), st = sin(t)
        let x = (w / 2) * (ct < 0 ? -1 : 1) * pow(abs(ct), 2 / n)
        let y = (h / 2) * (st < 0 ? -1 : 1) * pow(abs(st), 2 / n)
        let q = pt(cx + x * cos(rot) - y * sin(rot), cy + x * sin(rot) + y * cos(rot))
        if i == 0 { p.move(to: q) } else { p.addLine(to: q) }
    }
    p.closeSubpath()
    return p
}

// MARK: The hand

/// Fingertip centers and lean: index, middle, ring, little. The step is 160 so that at 32 px each
/// stone lands on the same sub-pixel phase.
struct Finger { let x, y, lean: CGFloat }
let hand = [Finger(x: 272, y: 512, lean: -3.5), Finger(x: 432, y: 446, lean: -1),
            Finger(x: 592, y: 478, lean: 1.5), Finger(x: 752, y: 576, lean: 4.5)]

/// The same hand at 16 px: the top-left corners of 64 × 192 ticks, every edge on a whole pixel.
let ticks: [(CGFloat, CGFloat)] = [(192, 448), (384, 384), (576, 384), (768, 512)]

// MARK: Pen

struct Pen {
    let c: CGContext
    /// Device pixels per grid unit.
    let s: CGFloat

    init(_ c: CGContext, pixels: Int) { self.c = c; s = CGFloat(pixels) / 1024 }

    func gradient(_ stops: [Stop]) -> CGGradient {
        CGGradient(colorsSpace: sRGB, colors: stops.map { rgb($0.0, $0.1) } as CFArray, locations: stops.map { $0.2 })!
    }

    func clipped(_ p: CGPath, _ draw: () -> Void) {
        c.saveGState(); c.addPath(p); c.clip(); draw(); c.restoreGState()
    }

    /// A linear gradient from the top of the shape to its bottom.
    func linear(_ p: CGPath, _ stops: [Stop]) {
        let b = p.boundingBoxOfPath
        clipped(p) {
            c.drawLinearGradient(gradient(stops), start: pt(b.midX, b.minY), end: pt(b.midX, b.maxY),
                                 options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
    }

    /// A blurred fill: only the shadow of an off-canvas copy of the shape lands on the canvas.
    func soft(_ p: CGPath, _ hex: UInt32, _ alpha: CGFloat, blur: CGFloat, dx: CGFloat = 0, dy: CGFloat = 0) {
        let far: CGFloat = 4096
        c.saveGState()
        c.setShadow(offset: CGSize(width: (far + dx) * s, height: -dy * s), blur: blur * s, color: rgb(hex, alpha))
        c.translateBy(x: -far, y: 0)
        c.addPath(p); c.setFillColor(rgb(0x000000)); c.fillPath()
        c.restoreGState()
    }

    /// A shadow cast by the shape's edge onto its own inside. Positive `dy` shades the top edge.
    func innerShadow(_ p: CGPath, dy: CGFloat, blur: CGFloat, _ hex: UInt32, _ alpha: CGFloat) {
        c.saveGState()
        c.addPath(p); c.clip()
        c.setShadow(offset: CGSize(width: 0, height: -dy * s), blur: blur * s, color: rgb(hex, alpha))
        let outside = CGMutablePath()
        outside.addRect(p.boundingBoxOfPath.insetBy(dx: -600, dy: -600))
        outside.addPath(p)
        c.addPath(outside); c.setFillColor(rgb(0x000000)); c.fillPath(using: .evenOdd)
        c.restoreGState()
    }

    /// A stroke just inside the shape's edge, colored top to bottom by a gradient.
    func rim(_ p: CGPath, width: CGFloat, _ stops: [Stop]) {
        let b = p.boundingBoxOfPath
        c.saveGState()
        c.addPath(p); c.clip()
        c.addPath(p); c.setLineWidth(width * 2); c.replacePathWithStrokedPath(); c.clip()
        c.drawLinearGradient(gradient(stops), start: pt(b.midX, b.minY), end: pt(b.midX, b.maxY),
                             options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        c.restoreGState()
    }

    /// The shadow the whole icon casts on the desktop: a soft one below, a tight one all around.
    func ground(_ p: CGPath) {
        soft(p, 0x000000, 0.30, blur: 26, dy: 12)
        soft(p, 0x000000, 0.22, blur: 5, dy: 1)     // keeps the light body's top edge visible on a light desktop
    }
}

// MARK: Drawing

func draw(_ c: CGContext, pixels: Int) {
    let k = Pen(c, pixels: pixels)
    let outer = body(), face = body(inset: 40)
    k.ground(outer)
    // The dish: a white ceramic rim around a slightly sunken face.
    k.linear(outer, [(0xffffff, 1, 0), (0xf3f2ee, 1, 0.5), (0xdddbd4, 1, 1)])
    k.rim(outer, width: 4, [(0xffffff, 1, 0), (0xffffff, 0, 0.3), (0x5a5548, 0, 0.7), (0x5a5548, 0.30, 1)])
    k.clipped(outer) { k.soft(face, 0xffffff, 1, blur: 5, dy: 5) }
    k.linear(face, [(0xeceae5, 1, 0), (0xf1efea, 1, 0.5), (0xe6e3dc, 1, 1)])
    k.innerShadow(face, dy: 12, blur: 26, 0x3a3528, 0.30)
    k.innerShadow(face, dy: 2, blur: 3, 0x3a3528, 0.25)

    if pixels <= 16 {
        for (x, y) in ticks {
            c.addPath(CGPath(roundedRect: CGRect(x: x, y: y, width: 64, height: 192), cornerWidth: 32, cornerHeight: 32,
                             transform: nil))
            c.setFillColor(rgb(0x16171a))
            c.fillPath()
        }
        return
    }
    // The stones: a shadow on the dish, onyx with a sheen above, a thin rim of light.
    for f in hand {
        let p = superellipse(f.x, f.y, 112, 178, degrees: f.lean)
        k.soft(p, 0x2a2518, 0.42, blur: 46, dy: 32)
        k.soft(p, 0x14110a, 0.60, blur: 10, dy: 9)
        k.linear(p, [(0x565a63, 1, 0), (0x25272c, 1, 0.42), (0x08080a, 1, 1)])
        k.clipped(p) { k.soft(ellipse(f.x - 6, f.y - 46, 64, 60), 0xffffff, 0.50, blur: 20) }
        k.rim(p, width: 2.5, [(0xffffff, 0.75, 0), (0xffffff, 0, 0.35), (0xfff4dc, 0, 0.75), (0xfff4dc, 0.42, 1)])
    }
}

func png(pixels: Int) -> Data {
    let c = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.interpolationQuality = .high
    let s = CGFloat(pixels) / 1024
    // y down, on the 1024 grid.
    c.translateBy(x: 0, y: CGFloat(pixels))
    c.scaleBy(x: s, y: -s)
    draw(c, pixels: pixels)
    return NSBitmapImageRep(cgImage: c.makeImage()!).representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(size)x\(size).png" : "icon_\(size)x\(size)@2x.png"
        try png(pixels: size * scale).write(to: out.appendingPathComponent(name))
    }
}
