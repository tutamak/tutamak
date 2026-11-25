import CoreGraphics

/// What Tutamak remembers about the windows it snapped or maximized: a tap puts a maximized window
/// back, and a drag gives a snapped window its size from before the snap. Pure and tested; `Key`
/// stands for a window (an Accessibility element in the app).
///
/// An entry counts only while the window is still where Tutamak put it. Once it is moved or resized
/// some other way (a pinch, its own green button, another app), the entry is ignored.
struct Placements<Key: Hashable> {
    struct Entry: Equatable {
        /// The window's frame before Tutamak first snapped it. Dragging it out gives this size back,
        /// however many snaps and maximizes came in between.
        let free: CGRect
        /// Where a tap puts it back while it fills the screen: the free frame, or the snapped one
        /// it was maximized from.
        let tapBack: CGRect
        /// Where Tutamak put it, as the window took it; nil until that is reported.
        var placed: CGRect?
        /// Whether that frame fills the screen, so that a tap restores instead of maximizing.
        let fills: Bool
        /// Which placement this is, so a late report for an earlier one is not taken for it.
        let token: Int
    }

    private var entries: [Key: Entry] = [:]
    private var nextToken = 0
    /// Entries are dropped wholesale past this many; windows come and go.
    private let limit = 64

    /// The entry in effect for a window now at `frame`: Tutamak put it there and it has not left.
    func current(_ key: Key, frame: CGRect) -> Entry? {
        guard let entry = entries[key], let placed = entry.placed, Geometry.isClose(frame, placed) else { return nil }
        return entry
    }

    /// Tutamak is about to put the window, now at `frame`, into a snapped or maximized frame.
    /// Returns the token to report the frame it took with (`placed`).
    mutating func placing(_ key: Key, from frame: CGRect, fills: Bool) -> Int {
        let free = current(key, frame: frame)?.free ?? frame
        return record(key, Entry(free: free, tapBack: frame, placed: nil, fills: fills, token: 0))
    }

    /// The frame the window actually took (it may refuse an exact size).
    mutating func placed(_ key: Key, token: Int, at frame: CGRect) {
        guard entries[key]?.token == token else { return }
        entries[key]?.placed = frame
    }

    /// A tap on the window at `frame`. If Tutamak made it fill the screen, returns where it goes
    /// back to (with the token to report that frame with, if it is a snap again); nil means maximize.
    mutating func tapBack(_ key: Key, frame: CGRect) -> (frame: CGRect, token: Int?)? {
        guard let entry = current(key, frame: frame), entry.fills else { return nil }
        if Geometry.isClose(entry.tapBack, entry.free) {
            entries[key] = nil
            return (entry.tapBack, nil)
        }
        // Back to the snapped frame it was maximized from: still a snap, with the same free size.
        let token = record(key, Entry(free: entry.free, tapBack: entry.free, placed: nil, fills: false, token: 0))
        return (entry.tapBack, token)
    }

    /// The fingers grab the window at `frame` to drag it. If Tutamak snapped or maximized it there,
    /// returns the size it had before (nil if that is the size it has now); the window is no longer
    /// snapped after this either way.
    mutating func pullOut(_ key: Key, frame: CGRect) -> CGSize? {
        guard let entry = current(key, frame: frame) else { return nil }
        entries[key] = nil
        let size = entry.free.size
        guard abs(size.width - frame.width) > 4 || abs(size.height - frame.height) > 4 else { return nil }
        return size
    }

    mutating func forget(_ key: Key) {
        entries[key] = nil
    }

    private mutating func record(_ key: Key, _ entry: Entry) -> Int {
        if entries.count >= limit, entries[key] == nil { entries.removeAll() }
        nextToken += 1
        entries[key] = Entry(free: entry.free, tapBack: entry.tapBack, placed: nil, fills: entry.fills, token: nextToken)
        return nextToken
    }
}
