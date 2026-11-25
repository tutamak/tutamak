# Changelog

Every change worth knowing about, newest first. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/).

Changes go under **Unreleased** as they are made. A release renames that section to its version
and date and opens a new, empty Unreleased above it. The version's section becomes the notes on
the GitHub release and in the update window, so it is written for people who use Tutamak, not
for the code.

## [Unreleased]

### Added

- A snapped or maximized window gets its earlier size back as you slide it away, the way macOS's own tiling does. Hold ⌥ as you start to keep the size it has.
- A light tick on the trackpad when a window you're dragging catches a screen edge or a line of the snap grid.
- Snapped windows keep the gaps of macOS's tiling when "Tiled windows have margins" is on in Desktop & Dock settings.

## [0.2.0] - 2026-11-25

### Added

- An About window, from the menu bar menu: the version, what the name means, and links to the website, the changelog and where to report a problem.

### Changed

- Tutamak now needs macOS 26 or later, the only version it has been tried on.

## [0.1.0] - 2026-11-25

The first release.

### Added

- Four fingers on the trackpad act on the window under the pointer: slide to move it, pinch or spread to resize it, tap to make it fill the screen and tap again to put it back.
- A quick sideways flick switches desktops. A flick up opens Mission Control and a flick down App Exposé, if you turn them on in Settings.
- Let go at a screen edge to snap a window to half or the whole screen, or to a cell of a snap grid (halves and quarters, thirds and sixths, or thirds). Hold ⌥ as you let go to skip snapping.
- Edge resistance: window edges stick to the screen's edges for a moment as you drag past them.
- A setup assistant that sits beside System Settings while you allow Accessibility, turns off macOS's own four-finger gestures (with a backup you can restore), and lets you try every gesture on a live trackpad.
- Settings, with a preview of each gesture as you point at it.
- Updates: Tutamak checks for new versions once a day and installs them when you agree.

[Unreleased]: https://github.com/tutamak/tutamak/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/tutamak/tutamak/releases/tag/v0.2.0
[0.1.0]: https://github.com/tutamak/tutamak/releases/tag/v0.1.0
