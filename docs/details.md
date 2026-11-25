# Tutamak in detail

The [README](../README.md) covers what Tutamak does and how to install it. This page is for the
curious: how each gesture behaves, the numbers behind it, how to work on the code, and what is
known not to work.

## The setup assistant

On first launch the **setup assistant** opens. It asks for the **Accessibility** permission the
way recent Mac apps do: System Settings opens to Privacy & Security > Accessibility, and a card
docks beside it with Tutamak's icon and a hint that shows the icon being dragged into the list.
Drop the icon there (or switch Tutamak on if it is already listed) and the assistant comes back.

It then offers to turn off the macOS four-finger gestures (only when you press the button; it
says which gestures stay on three fingers), lets you try each gesture on a live drawing of your
fingers (no window moves while you practice), offers the snap grid and Open at login, and points
out Tutamak's menu bar icon. To run it again, choose **Setup Assistant…** from the menu or in
Settings.

## The macOS four-finger gestures

Choosing three fingers for Mission Control and for switching desktops in System Settings does not
turn the four-finger gestures off, and while they are on they fire on every Tutamak drag as well.
To turn them off, use the setup assistant or **Settings > macOS > Four-finger swipes and pinch**,
or run:

```sh
make gestures-off       # backs up the current values, turns four-finger gestures off
make gestures-status    # current values
make gestures-restore   # restores the backup
```

Three-finger gestures are left alone. If the change does not take effect right away, log out and
back in. The backup is kept in `~/Library/Application Support/Tutamak/gestures-backup.tsv`.

Tutamak's flicks stand in for what is lost: a sideways flick switches desktops, and with **Flick
up for Mission Control** on (**Settings > Gestures**), a flick up opens Mission Control and a flick
down opens App Exposé.

## How the gestures behave

- **Drag:** put four fingers down with the pointer over a window and slide. The window comes to
  the front and follows your fingers; the pointer moves with it.
- **Snap:** push the pointer against the outer edge of a display and release. The left or right
  edge gives that half of the screen, the top edge the whole screen.
- **Pull out:** drag a window that Tutamak snapped or maximized (by an edge, the grid or a tap)
  and it takes back the size it had before the first snap, over 0.2 s as it follows the fingers
  (at once with **Animate snapping** off).
  The pointer keeps its place in the window, and the window stays on the display it is pulled
  from. Hold **⌥** as the drag starts to keep the snapped size. A window resized since it was
  snapped (a pinch, its own green button) keeps its new size.
- **Margins:** with **Tiled windows have margins** on in System Settings > Desktop & Dock, snapped
  and maximized windows leave the same gap as macOS's own tiling: 8 pt from the screen's edges and
  between neighbors, the grid's zones included. A pinch then fills the screen up to the margin.
  The setting is read as each gesture starts. With it off, or never changed, windows go edge to
  edge. (The 8 pt is the figure other window managers use; it was not measured here.)
- **Haptics:** a light tick on the trackpad under the fingers when a dragged window catches
  something: a screen edge's snap zone, a line of the snap grid (once per line: not again on the
  way off it into a cell), or a display edge that holds it (edge resistance, below). None while
  ⌥ is held. Ticks are at least 60 ms apart. It drives the trackpad's actuator through the
  private `MultitouchSupport` framework, waveform 3, the lightest built-in one.
- **Snap grid** (off by default; **Settings > Windows**): while you drag, a grid of zones is drawn
  over the display, just behind the window, and letting go drops the window into the zone under
  the pointer. On a line between two zones it takes both, so one grid gives several sizes:

  | Grid | Zones |
  | --- | --- |
  | Halves and quarters (2 × 2) | quarters; halves on the middle lines; the whole screen where they cross |
  | Thirds and sixths (3 × 2) | sixths; two-thirds on the column lines; full-height thirds on the middle line |
  | Thirds (3 × 1) | thirds; two-thirds on the column lines |

  **Auto** picks 3 × 2 for displays at least 2200 pt wide and 2 × 2 for the rest. The screen edges
  still win (the left or right half, the whole screen at the top). Hold **⌥** while letting go to
  leave the window exactly where it is. Lifting is also how a long drag carries on (the clutch,
  below), so a hand that lifts while still sliding does not drop the window at once: the drop
  waits up to 0.6 s for the fingers to come back and keep dragging. A hand that had come to rest
  drops the window right away. The log records the lift speed and how soon the fingers came back,
  which helps to tune this.
- **Clutch:** lift your fingers and put them back to keep dragging (the pointer travels with the
  window, so the same window is grabbed again).
- **Resize:** spread the fingers apart to grow the window, pinch them together to shrink it, like
  a zoom: the window scales with how far the hand opens. Which edges move depends on where the
  pointer is in the window, not on which way the hand opens, so the easy sideways spread works for
  every direction:

  | Pointer in the window | What changes |
  | --- | --- |
  | nearer the left or right edge | the width (that edge moves) |
  | nearer the top or bottom edge | the height (that edge moves) |
  | in a corner (the outer sixth on both axes) | both (that corner moves) |
  | in the middle (the central ninth) | both, around the center |

  The pointer alone decides, whatever the window's shape: on a full-height window (a snapped half,
  a maximized window) the top or bottom still changes the height. Such a window can only get
  shorter, so a spread does nothing until it is shorter than the screen. An edge resting on a
  screen edge stays put, so a snapped half keeps hugging its side. Spreading far enough fills the
  screen. The pointer stays on the same spot of the window, so you can pinch again to carry on. If
  an app refuses a size (a minimum, a fixed size), the window stays anchored instead of sliding.
- **Maximize / restore:** tap with four fingers (land together, lift quickly, without sliding).
  Tapping a window that Tutamak maximized, or snapped to the whole screen, restores its earlier
  frame. A snapped half (or grid zone) maximized this way goes back to that half, and a drag out of
  it still gives back the size from before the half.
- **Switch desktops:** a quick sideways four-finger flick switches desktops instead of dragging,
  as the macOS swipe did: flicking left brings in the desktop on the right. It works by posting
  the "Move left a space" or "Move right a space" keyboard shortcut. A flick is told apart from a
  drag by how it starts: the fingers land and sweep sideways fast. Resting the fingers for a
  moment before sliding always drags, and so does landing again right after a drag. A drag that
  starts like a flick waits up to ~0.14 s before the window moves.
- **Mission Control / App Exposé** (off by default; **Settings > Gestures > Flick up for Mission
  Control**): a quick four-finger flick up opens Mission Control, and a flick down shows the front
  app's windows (App Exposé), by posting the "Mission Control" and "Application windows" keyboard
  shortcuts. Another flick, either way, closes what is open. These flicks are told apart from a
  drag the same way as a sideways flick, over the same finger distance. While they are on, a
  vertical drag that starts fast also waits up to ~0.14 s; that is why they are off by default.
- **One touch, one gesture:** each touch is decided at the start (slide, flick, pinch or tap) and
  stays that way until the fingers lift. Every decision is logged, which helps to tune the
  thresholds.
- Pinch, tap and sideways flicks can each be turned off, and up/down flicks turned on, under
  **Settings > Gestures**; pointing at a gesture there plays a preview of it.
- **Smooth motion:** the window moves once per display refresh, following the fingers with a short
  catch-up, instead of once per trackpad frame (which does not line up with the display). Snapping
  animates the window into place; turn that off with **Settings > Windows > Animate snapping** if
  an app resizes jerkily.
- **Edge resistance:** when a window edge reaches a display edge (including below the menu bar,
  above the Dock, and where two displays meet), it sticks there. Push ~4 mm further to break
  through, or pull back to let go at once. Lifting the hand leaves the window at the edge: the
  fingers left behind roll back as a hand lifts, and only a whole hand of four moves a window.
  Edge resistance can be turned off in **Settings > Windows**.
- Movement is smoothed (One Euro filter) so the window does not jitter while your fingers rest:
  heavily when slow, lightly when fast. The window does not move until it would move at least one
  point.
- A four-finger touch that rests before lifting does nothing; a slide starts only once the fingers
  move a little. (A quick, still tap maximizes; see above.)
- With the macOS four-finger gestures off, a four-finger slide also reaches the app underneath as
  a scroll. Tutamak mutes that scroll (and the momentum after you lift) while four fingers are
  engaged, and logs which zoom, rotate and swipe gesture events arrive in that time (those are not
  muted yet). A scroll that restarts within 0.3 s of the fingers letting go comes from the same
  hand: macOS restarts the scroll as a fast hand lifts, and the Dock sends it again when a flick
  opens Mission Control. It stays muted along with its momentum, which would otherwise scroll the
  window by up to thousands of points.
- Menu bar icon: the app icon in miniature, a dish with four fingertips. It is dimmed while
  Tutamak is paused, and shows a small dot while something needs attention (a permission, the
  macOS gestures).
- Menu: a single "Ready" line when all is well (otherwise one line per problem, each leading to
  its fix), Enabled, Settings… (⌘,), Setup Assistant…, About Tutamak, Check for Updates…
  (release builds), Quit. The line for a missing permission opens the setup assistant.
- About: the icon, name and version, what the name means, and links to the website, the
  changelog, the issues and the source. It closes with Escape or ⌘W.
- Settings: General (on/off, Open at login, speed), Gestures (each one, with a preview of the one
  pointed at), Windows (snap grid, edge resistance, animate snapping), macOS (Accessibility, the
  macOS four-finger gestures with Turn Off and Restore, the shortcuts the flicks need) and About
  (trackpads and Rescan, version, Setup Assistant).
- There are no keyboard shortcuts: window managers such as Magnet and Rectangle already own the
  usual ones (⌃⌥ arrows and letters), and macOS has its own tiling shortcuts.

## Development

Tutamak is built in two flavors, told apart by name and identity, so a development copy and the
released app can live on the same Mac:

| | Development (`make`) | Release (`make release`) |
| --- | --- | --- |
| Name | Tutamak Dev | Tutamak |
| Bundle identifier | `local.tutamak` | `dev.tutamak.tutamak` |
| Built into | `build/dev/TutamakDev.app` | `build/release/Tutamak.app` |
| Installed into | `~/Applications` (`make install`) | `/Applications`, from the disk image |
| Signed with | Apple Development, if installed | Developer ID, hardened runtime, notarized |
| Updates | none: it has no feed | Sparkle, from the latest GitHub release |

Settings, the Accessibility permission and "Open at login" belong to an identity, so the two
flavors keep their own. Both act on every four-finger gesture, so don't run them at once; each
one's menu offers to quit the other.

The development build signs the app with an Apple Development identity if one is installed, so
the Accessibility permission survives rebuilds. Without one the app is ad-hoc signed, and the
permission has to be granted again after every build.

```sh
make test       # geometry and gesture tests (no trackpad needed)
make touches    # prints raw finger frames; warns ANOMALOUS VALUE if the struct layout is off
make check      # starts without asking for permission, prints trackpad/permission/gesture status and quits
make debug      # opens the app and follows its log (drag, zone, snap)
make run        # opens it from build/dev/
build/dev/TutamakDev.app/Contents/MacOS/TutamakDev --setup-demo
                # runs only the setup assistant, with Accessibility reported as not allowed and
                # every setting kept in memory, so the card beside System Settings can be tried on
                # a Mac that is already set up. It reads no trackpad; to try the practice step, use
                # Setup Assistant in the installed app
```

The log can also be followed at any time with (for the released app, the subsystem is
`dev.tutamak.tutamak`):

```sh
log stream --level info --predicate 'subsystem == "local.tutamak"'
```

Gesture lines (what each touch became, the resize grip, drops, refused sizes) are logged at notice
level, so the system keeps them and the most recent gestures can be read back afterward:

```sh
log show --last 10m --style compact --predicate 'subsystem == "local.tutamak"'
```

### Releasing a version

Releases are made on a Mac that has a "Developer ID Application" identity, a notarytool profile
(`NOTARY_PROFILE`, made once with `xcrun notarytool store-credentials`) and Sparkle's signing key
in the login keychain (made once with Sparkle's `generate_keys`; its public half is `SPARKLE_KEY`
in the Makefile). Keep a backup of that key (`generate_keys -x <file>`): without it, installed
copies can never be updated again.

1. Write the changes under **Unreleased** in `CHANGELOG.md` as they are made.
2. To release, rename that section to `## [x.y.z] - <date>`, open a new empty Unreleased above it,
   put `x.y.z` in `VERSION`, and commit.
3. `make release` checks the version, a clean tree, an unused tag, the tests and the changelog
   section, then builds the release flavor, has Apple notarize it and staples the ticket. It writes
   `build/release/v<x.y.z>/`: `Tutamak-<x.y.z>.zip` (for updates), `Tutamak.dmg` (for first
   installs), `appcast.xml`, `notes.md` and the commit it was built from. Both archives are checked
   the way they arrive: the zip unpacked, the disk image mounted, each app verified, assessed by
   Gatekeeper and its ticket validated. Nothing is public yet; try the disk image first.
4. `make publish` tags that commit `v<x.y.z>`, pushes the tag and creates the GitHub release with
   the notes, the disk image, the zip and the appcast, marked latest.

`make ship` runs the two in a row on main. Installed copies read
`releases/latest/download/appcast.xml`, so publishing the release is publishing the update. A
broken release is fixed by a newer one; Sparkle never goes back.

To try an update before publishing, start an older release build with `TUTAMAK_FEED` pointing at a
local copy of the appcast (`python3 -m http.server` serving it and the zip, with the enclosure URL
changed to match).

### A tour of the code

- `Sources/Multitouch.swift`: raw finger frames from Apple's private `MultitouchSupport` framework
  (declarations from Karabiner-Elements). Because the framework is private, the app cannot go on
  the App Store; if a macOS update changes the struct, `make touches` shows it.
- `Sources/GestureTracker.swift`: decides what each touch is (slide, flick, pinch, tap). Pure and
  tested.
- `Sources/GestureController.swift`: turns gestures into window actions: moves and snaps windows,
  resizes them on a pinch, maximizes or restores them on a tap, posts a shortcut on a flick.
- `Sources/Placements.swift`: what Tutamak remembers about the windows it snapped or maximized:
  where a tap puts them back and the size a drag gives back. Pure and tested.
- `Sources/Haptics.swift`: the tick on the trackpad, through `MultitouchSupport`'s actuator calls
  (signatures from Yoshimasa Niwa's HapticKey sample).
- `Sources/Animator.swift`: paces moves and live resizes to the display refresh; animates snapping,
  maximizing and restoring.
- `Sources/SetupFlow.swift`: the setup assistant's steps and what each asks for, given the Mac's
  state. Pure and tested. `SetupWindow.swift` holds its model and window, `SetupViews.swift` its
  views.
- `Sources/PermissionGuide.swift`: the card beside System Settings (found by its pid) with the
  draggable icon and the drag hint. `GuidePlacement.swift` decides where it docks (pure and
  tested).
- `Sources/GestureArt.swift`: the gesture drawings (a trackpad beside a screen); `Practice.swift`
  feeds them the real fingers while the setup assistant's practice is on.
- `Sources/TouchWindow.swift`: Show Touches, in Tutamak Dev's menu, for screen recordings: the
  practice's trackpad drawing in a corner of the screen (in one of four sizes, each drawn at its
  own scale so it stays sharp), with the real fingers on it, rings where a tap's fingers were,
  and the gesture's name (and ⌥, while it is held) under it. It only watches; windows move as usual.
  Clicks pass through it, and it stays put while desktops switch and Mission Control opens.
- `Sources/MenuBarHint.swift`: the bubble under the menu bar icon at the end of the setup.
- `Sources/MenuBarIcon.swift`: the menu bar icon. `SettingsWindow.swift`: the settings window.
  `AboutWindow.swift`: the About window, and the links it shares with nothing else.
- `Sources/Updater.swift`: updates, through Sparkle; the only file that imports it.
  `Flavor.swift` tells the two flavors apart and picks the update feed, and `AppMover.swift` offers
  to move a copy opened from the disk image or Downloads into Applications.
- `tools/make-icon.swift`: draws the app icon; no image is checked in.
- `Sources/SystemShortcut.swift`: reads the Mission Control keyboard shortcuts a flick stands for
  ("Move left a space", "Move right a space", "Mission Control", "Application windows") and posts
  them.
- `Sources/Windows.swift`: Accessibility (AX) calls. Only the latest position is applied, so move
  requests do not pile up in slow apps; a size that must land (the end of a pull-out) carries a
  later move along instead of being replaced by it.
- `Sources/Geometry.swift`: display edges, zones, the snap grid, margins, resize frames and
  coordinate math. Pure and tested. `TiledMargins` in `Settings.swift` reads macOS's margin setting.
- `Sources/Overlay.swift`: the snap preview and the grid drawn while dragging. The grid is ordered
  just behind the dragged window, whose window server ID comes from the private
  `_AXUIElementGetWindow` (as in Rectangle and yabai).
- `Sources/Smoothing.swift`: the jitter filter (One Euro) and a one-point dead band. Pure and
  tested.
- `Sources/EdgeResistance.swift`: window edges sticking to display edges. Pure and tested.
- `Sources/DropHold.swift`: decides when a window released over the grid drops (at once, or after
  waiting to see whether the fingers come back). Pure and tested.
- `Sources/ScrollBlocker.swift`: listens to scroll events and zeroes their deltas while four fingers
  are engaged (it does not drop them, so apps never see a half-finished scroll sequence). The
  decision is made by `ScrollMuter.swift` (pure and tested).

## Known limitations

- Full-screen windows and windows whose position cannot be set (the Dock, the desktop) are not moved.
- If three fingers land and slide before the fourth arrives, the macOS three-finger gesture may
  start first.
- Flinging a window sideways the moment the fingers land switches desktops instead (and, with
  up/down flicks on, flinging it up or down opens Mission Control or App Exposé); rest the fingers
  briefly first. The switch happens at once; it does not track the fingers as the system gesture
  does.
- Flicks need their keyboard shortcuts turned on in System Settings > Keyboard > Keyboard
  Shortcuts > Mission Control ("Move left a space" and "Move right a space", and for up/down
  "Mission Control" and "Application windows"; all are on by default). The menu warns when one is
  off. `TutamakDev --flick left|right|up|down` posts a flick's shortcut on its own.
- The trackpad aspect ratio is assumed constant (0.66), so vertical speed may feel slightly
  different on built-in and external trackpads.
- Trackpads are restarted automatically when one is added or removed (a Bluetooth trackpad that
  reconnects comes back as a new device), when the display configuration changes, and after sleep.
  If a trackpad still does not respond, use **Settings > About > Rescan**.
