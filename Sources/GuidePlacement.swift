import CoreGraphics

/// Where the permission guide's card docks beside the System Settings window. Pure and tested.
/// All rectangles are in Cocoa screen coordinates (origin at the bottom left, y up).
enum GuidePlacement {
    enum Side: Equatable { case right, left, below, inside }

    /// Beside the window, its top a little under the window's toolbar so the card sits level with
    /// the list: on the right if it fits on the window's display, else on the left, else below,
    /// else over the window's lower corner. Always inside `visible`, the display's visible frame.
    static func dock(card: CGSize, beside window: CGRect, in visible: CGRect,
                     gap: CGFloat = 14, topInset: CGFloat = 64) -> (frame: CGRect, side: Side) {
        let top = window.maxY - topInset
        let right = CGRect(x: window.maxX + gap, y: top - card.height, width: card.width, height: card.height)
        if visible.minX <= right.minX, right.maxX <= visible.maxX {
            return (clampVertically(right, in: visible), .right)
        }
        let left = CGRect(x: window.minX - gap - card.width, y: top - card.height, width: card.width, height: card.height)
        if visible.minX <= left.minX, left.maxX <= visible.maxX {
            return (clampVertically(left, in: visible), .left)
        }
        let below = CGRect(x: window.midX - card.width / 2, y: window.minY - gap - card.height,
                           width: card.width, height: card.height)
        if visible.minY <= below.minY {
            return (clamp(below, in: visible), .below)
        }
        let inside = CGRect(x: window.maxX - card.width - 16, y: window.minY + 16, width: card.width, height: card.height)
        return (clamp(inside, in: visible), .inside)
    }

    private static func clampVertically(_ r: CGRect, in visible: CGRect) -> CGRect {
        var r = r
        r.origin.y = min(max(r.minY, visible.minY), visible.maxY - r.height)
        return r
    }

    private static func clamp(_ r: CGRect, in visible: CGRect) -> CGRect {
        var r = clampVertically(r, in: visible)
        r.origin.x = min(max(r.minX, visible.minX), visible.maxX - r.width)
        return r
    }
}
