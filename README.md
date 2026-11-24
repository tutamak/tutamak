# Tutamak

Four-finger trackpad gestures for windows, acting on the window under the cursor:

| With four fingers | Does |
| --- | --- |
| Slide | Moves the window, as if grabbed by its title bar. Release at a screen edge to snap it, or over the snap grid (if on) to drop it into a zone. |
| Pinch / spread | Resizes the window live: where the cursor is in the window picks the edges. |
| Tap | Maximizes the window; tap again to restore it. |
| Quick sideways flick | Switches to the desktop on that side (the old macOS habit). |
| Quick flick up / down (off by default) | Opens Mission Control / App Exposé; another flick closes it. |

It is a small macOS menu bar app (Swift; its only UI is the menu).

## Install

```sh
make install          # builds, installs as ~/Applications/Tutamak.app and opens it
```

On first launch the **setup assistant** opens. It asks for the **Accessibility** permission the
way recent Mac apps do: System Settings opens on Privacy & Security > Accessibility, a card docks
beside it with Tutamak's icon, and a hint shows the icon being dragged into the list; drop it there
(or switch Tutamak on if it is listed) and the setup comes back. It then offers to turn off macOS's
four-finger gestures (only on your press; what stays on three fingers is said), lets you try each
gesture on a live drawing of your fingers (no window moves while you practice), picks the snap grid
and Open at Login, and points at Tutamak's menu bar icon. Run it again from the menu: **Setup
Assistant…**. The app is signed with a persistent Apple Development identity, so the permission
survives rebuilds.

### macOS four-finger gestures

Even with "three fingers" chosen for Mission Control and Spaces in System Settings, macOS keeps its
four-finger gestures on, and while they are on they fire on every drag as well. To turn them off,
use **Turn off macOS four-finger gestures…** in the menu, or:

```sh
make gestures-off       # backs up the current values, turns four-finger gestures off
make gestures-status    # current values
make gestures-restore   # restores the backup
```

Three-finger gestures are left alone. If the change does not take effect right away, log out and
back in. Backup: `~/Library/Application Support/Tutamak/gestures-backup.tsv`.

Tutamak's flicks stand in for what is lost: sideways switches desktops, and with **Flick Up/Down
for Mission Control** on (under **Gestures**), up opens Mission Control and down App Exposé.

## Usage

- **Drag:** put four fingers down with the cursor over a window and slide. The window comes to the
  front and follows your fingers; the cursor moves with it.
- **Snap:** push the cursor against the outer edge of a display (left/right → half the screen,
  top → full screen) and release.
- **Snap grid** (off by default; menu **Snap Grid**): while dragging, the display is drawn as a
  grid of zones just below the window, and letting go drops the window into the zone under the
  cursor. On a line between two zones it takes both, so one grid gives several sizes:

  | Grid | Zones |
  | --- | --- |
  | Halves & Quarters (2 × 2) | quarters; halves on the middle lines; the whole screen where they cross |
  | Thirds & Sixths (3 × 2) | sixths; two-thirds on the column lines; full-height thirds on the middle line |
  | Thirds (3 × 1) | thirds; two-thirds on the column lines |

  **Auto** picks 3 × 2 for displays at least 2200 pt wide and 2 × 2 for others. The screen edges
  still win (left/right half, top full screen). Hold **⌥** while letting go to place the window
  exactly where it is. Lifting is also how a long drag carries on (the clutch), so a hand that
  lifts while still sliding does not drop the window at once: it waits up to 0.6 s for the fingers
  to come back and keep dragging. A hand that had settled drops it right away. The log notes the
  lift speed and how soon the fingers came back, to tune that.
- **Clutch:** lift your fingers and put them back to keep dragging (the cursor travels with the
  window, so the same window is grabbed again).
- **Resize:** spread the fingers apart to grow the window, pinch them together to shrink it, like
  a zoom: the window scales with how far the hand opens. Which edges move depends on where the
  cursor is in the window, not on which way the hand opens, so the easy sideways spread works for
  every direction:

  | Cursor in the window | Changes |
  | --- | --- |
  | nearer the left or right edge | the width (that edge moves) |
  | nearer the top or bottom edge | the height (that edge moves) |
  | right in a corner (outer sixth both ways) | both (that corner moves) |
  | middle (the central ninth) | both, around the centre |

  The cursor alone decides, whatever the window's shape: on a full-height window (a snapped half,
  a maximized window) the top or bottom still changes the height. It can only shrink there, so a
  spread does nothing until the window is shorter than the screen. An edge resting on a screen
  edge stays put, so a snapped half keeps hugging its side.
  Spreading far enough fills the screen. The cursor stays on the same spot of the window, so you
  can pinch again to carry on. If an app refuses a size (a minimum, a fixed size), the window stays
  anchored instead of sliding.
- **Maximize / restore:** tap with four fingers (land together, lift quickly, without sliding).
  Tapping a window Tutamak maximized, or snapped to full screen, restores its earlier frame.
- **Switch desktops:** a quick sideways four-finger flick (the old macOS habit) switches to the
  desktop on that side instead of dragging, by posting the "Move left/right a space" shortcut.
  A flick is told apart by how it starts: the fingers land and sweep sideways fast. Resting the
  fingers for a moment before sliding always drags, and so does re-landing right after a drag.
  A drag that starts like a flick waits up to ~0.14 s before the window moves.
- **Mission Control / App Exposé** (off by default; **Gestures > Flick Up/Down for Mission
  Control**): a quick four-finger flick up opens Mission Control, down shows the front app's
  windows (App Exposé), by posting the "Mission Control" and "Application windows" shortcuts.
  Another flick, either way, closes what is open. Told apart from a drag the same way as the
  sideways flick, over the same finger distance. While it is on, a vertical drag that starts fast
  also waits up to ~0.14 s; that is why it is off by default.
- **One touch, one gesture:** each touch is decided at the start (slide, flick, pinch or tap) and
  stays that until the fingers lift. Every decision is logged, to tune the thresholds.
- Pinch, tap and sideways flicks can each be turned off, and up/down flicks turned on, under
  **Gestures** in the menu.
- **Smooth motion:** the window moves once per display refresh, following the fingers with a short
  catch-up, instead of once per trackpad frame (which does not line up with the display). Snapping
  animates the window into place; turn it off with **Animate Snapping** if an app resizes jerkily.
- **Edge resistance:** when a window edge reaches a display edge (including below the menu bar,
  above the Dock, and where two displays meet), it sticks there; push ~4 mm further to break
  through, pull back to let go at once. Can be turned off from the menu (**Edge Resistance**).
  Letting go leaves it there: as a hand lifts, the fingers left behind roll back, and only a
  whole hand of four moves a window.
- Movement is smoothed so the window does not jitter while your fingers rest (One Euro filter):
  hard when slow, light when fast. The window does not move until it would move at least one point.
- A four-finger touch that rests before lifting does nothing; a slide starts only once the fingers
  move a little. (A quick still tap maximizes, see above.)
- With the macOS four-finger gestures off, a four-finger slide also reaches the app underneath as a
  scroll. Tutamak mutes that scroll (and the momentum after you lift) while four fingers are engaged,
  and logs which zoom/rotate/swipe gesture events arrive in that time (they are not muted yet).
  A scroll that restarts within 0.3 s of the fingers letting go is the same hand: macOS restarts the
  scroll as a fast hand lifts, and the Dock sends it again when a flick opens Mission Control. It
  stays muted with its momentum, which would otherwise scroll the window by up to thousands of points.
- Menu: a single "Ready" line when all is well (otherwise each problem, leading to its fix),
  Enabled, Gestures (Pinch to Resize, Tap to Maximize, Flick to Switch Desktops, Flick Up/Down
  for Mission Control), Speed, Snap Grid, Edge Resistance, Animate Snapping, Launch at Login,
  Rescan Trackpads, Setup Assistant. A missing permission's line opens the setup at its step.
- There are no keyboard shortcuts: window managers such as Magnet and Rectangle already own the
  usual ones (⌃⌥ arrows and letters), and macOS has its own tiling shortcuts.

## Development

```sh
make test       # geometry and gesture tests (no trackpad needed)
make touches    # prints raw finger frames; warns ANOMALOUS VALUE if the struct layout is off
make check      # starts without asking for permission, prints trackpad/permission/gesture status and quits
make debug      # opens the app and follows its log (drag, zone, snap)
make run        # opens it from build/
build/Tutamak.app/Contents/MacOS/Tutamak --setup-demo
                # only the setup, with Accessibility reading as not allowed and every setting in
                # memory: the card beside Settings can be tried on a Mac already set up. It reads no
                # trackpad, so the practice is tried from the installed app's Setup Assistant
```

The log can also be followed at any time with:

```sh
log stream --level info --predicate 'subsystem == "local.tutamak"'
```

Gesture lines (what each touch became, the resize grip, drops, refused sizes) are logged at notice
level, so the system keeps them and the last gestures can be read back afterwards:

```sh
log show --last 10m --style compact --predicate 'subsystem == "local.tutamak"'
```

### How it works

- `Sources/Multitouch.swift`: raw finger frames from Apple's private `MultitouchSupport` framework
  (declarations from Karabiner-Elements). Because it is a private framework the app cannot go on the
  App Store; if a macOS update changes the struct, `make touches` shows it.
- `Sources/GestureTracker.swift`: decides what each touch is (slide, flick, pinch, tap). Pure, tested.
- `Sources/GestureController.swift`: turns gestures into window actions: moves and snaps windows,
  resizes them on a pinch, maximizes/restores them on a tap, posts a shortcut on a flick.
- `Sources/Animator.swift`: paces moves and live resizes to the display refresh; animates snapping,
  maximizing and restoring.
- `Sources/SetupFlow.swift`: the setup's steps and what each asks for, from the Mac's state. Pure,
  tested. `SetupWindow.swift` holds its model and window, `SetupViews.swift` its views.
- `Sources/PermissionGuide.swift`: the card beside System Settings (found by its pid) with the
  draggable icon and the drag hint; `GuidePlacement.swift` decides where it docks. Pure, tested.
- `Sources/GestureArt.swift`: the gesture drawings (a trackpad beside a screen); `Practice.swift`
  feeds them the real fingers while the setup's practice is on.
- `Sources/MenuBarHint.swift`: the bubble under the menu bar icon at the end of the setup.
- `tools/make-icon.swift`: draws the app icon; no image is checked in.
- `Sources/SystemShortcut.swift`: reads the Mission Control keyboard shortcuts a flick stands for
  ("Move left/right a space", "Mission Control", "Application windows") and posts them.
- `Sources/Windows.swift`: Accessibility (AX) calls. Only the latest position is applied, so move
  requests do not pile up in slow apps.
- `Sources/Geometry.swift`: display edges, zones, the snap grid, resize frames and coordinate
  math. Pure, tested.
- `Sources/Overlay.swift`: the snap preview and the grid drawn while dragging. The grid is ordered
  just below the dragged window, whose window server ID comes from the private
  `_AXUIElementGetWindow` (as in Rectangle and yabai).
- `Sources/Smoothing.swift`: the jitter filter (One Euro) and a one-point dead band. Pure, tested.
- `Sources/EdgeResistance.swift`: window edges sticking to display edges. Pure, tested.
- `Sources/DropHold.swift`: when a window released over the grid drops (at once, or after waiting
  to see whether the fingers come back). Pure, tested.
- `Sources/ScrollBlocker.swift`: listens to scroll events and zeroes their deltas while four fingers
  are engaged (it does not drop them, so apps never see a half-finished scroll sequence). The
  decision is made by `ScrollMuter.swift`. Pure, tested.

## Known limitations

- Full-screen windows and windows whose position cannot be set (the Dock, the desktop) are not moved.
- If three fingers land and slide before the fourth arrives, macOS's three-finger gesture may start first.
- Flinging a window sideways the moment the fingers land switches desktops instead (and, with up/down
  flicks on, flinging it up or down opens Mission Control or App Exposé); rest the fingers briefly
  first. The switch happens at once, it does not track the fingers like the system gesture.
- Flicks need their shortcuts on under Keyboard Shortcuts > Mission Control ("Move left/right a
  space", and for up/down "Mission Control" and "Application windows"; all are on by default); the
  menu warns when one is off. `Tutamak --flick left|right|up|down` posts a flick's shortcut on its own.
- The trackpad aspect ratio is assumed constant (0.66); vertical speed may feel slightly different on
  the built-in and external trackpads.
- Trackpads are restarted automatically when one is added or removed (a Bluetooth trackpad that
  reconnects comes back as a new device), when the display configuration changes, and after sleep.
  If a trackpad still does not respond, use **Rescan Trackpads** in the menu.

## Uninstall

```sh
make gestures-restore   # if you turned four-finger gestures off
make uninstall
```
