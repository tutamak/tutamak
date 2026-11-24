import AppKit
import SwiftUI

/// A small bubble under Tutamak's own menu bar icon, pointing at it: where the app lives once the
/// setup is done. It drops in, nods once toward the icon and then holds still; clicking it, or the
/// setup closing, puts it away.
final class MenuBarHint {
    static let size = CGSize(width: 236, height: 70)
    /// It points the way once; it does not stay on every Space.
    static let lifetime: TimeInterval = 8
    private var panel: NSPanel?
    private var expiry: DispatchWorkItem?

    /// `item` is the status item's frame on screen (Cocoa coordinates).
    func show(below item: CGRect) {
        hide()
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(CGPoint(x: item.midX, y: item.midY)) }) else { return }
        var frame = CGRect(x: item.midX - Self.size.width / 2, y: item.minY - 4 - Self.size.height,
                           width: Self.size.width, height: Self.size.height)
        // On screen, with the arrow still under the icon.
        let visible = screen.frame.insetBy(dx: 8, dy: 0)
        frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
        let arrowX = item.midX - frame.minX

        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let host = NSHostingView(rootView: HintBubble(arrowX: arrowX) { [weak self] in self?.hide() })
        host.sizingOptions = []
        panel.contentView = host
        panel.orderFrontRegardless()
        self.panel = panel
        let expiry = DispatchWorkItem { [weak self] in self?.hide() }
        self.expiry = expiry
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.lifetime, execute: expiry)
    }

    func hide() {
        expiry?.cancel()
        expiry = nil
        panel?.orderOut(nil)
        panel = nil
    }
}

private struct HintBubble: View {
    let arrowX: CGFloat
    let dismiss: () -> Void
    @State private var shown = false
    @State private var nod = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shape = Bubble(arrowX: arrowX, arrow: 8)
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text("Tutamak lives here")
                    .font(.system(size: 13, weight: .semibold))
                Text("Its menu has every setting")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 8 + 9)
        .padding(.bottom, 9)
        .padding(.horizontal, 12)
        .frame(width: MenuBarHint.size.width, height: MenuBarHint.size.height)
        .modifier(GlassShape(shape: shape))
        .contentShape(shape)
        .onTapGesture(perform: dismiss)
        .offset(y: shown ? (nod ? -3 : 0) : -6)
        .opacity(shown ? 1 : 0)
        .onAppear {
            guard !reduceMotion else {
                shown = true
                return
            }
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { shown = true }
            // One nod toward the icon, then still.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                withAnimation(.easeOut(duration: 0.18)) { nod = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) { nod = false }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Liquid Glass in the bubble's shape on macOS 26, a popover-like material before it.
private struct GlassShape<S: Shape>: ViewModifier {
    let shape: S

    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content.background(.regularMaterial, in: shape)
        }
    }
}

/// A rounded rectangle with a small arrow on top, at `arrowX`.
private struct Bubble: Shape {
    let arrowX: CGFloat
    let arrow: CGFloat

    func path(in rect: CGRect) -> Path {
        let body = CGRect(x: rect.minX, y: rect.minY + arrow, width: rect.width, height: rect.height - arrow)
        var p = Path(roundedRect: body, cornerRadius: 14, style: .continuous)
        let x = min(max(arrowX, body.minX + 20), body.maxX - 20)
        var tip = Path()
        tip.move(to: CGPoint(x: x - arrow - 2, y: body.minY + 0.5))
        tip.addQuadCurve(to: CGPoint(x: x, y: rect.minY), control: CGPoint(x: x - 3, y: body.minY))
        tip.addQuadCurve(to: CGPoint(x: x + arrow + 2, y: body.minY + 0.5), control: CGPoint(x: x + 3, y: body.minY))
        tip.closeSubpath()
        p.addPath(tip)
        return p
    }
}
