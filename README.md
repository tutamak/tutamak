# Tutamak

Move and resize Mac windows with four fingers on your trackpad.

Put four fingers down and the window under the pointer is yours: slide to move it, pinch to
resize it, tap to make it fill the screen. No title bar to aim for, no shortcut to remember.

## What it does

| With four fingers | What happens |
| --- | --- |
| Slide | Moves the window. Let go at a screen edge to snap it to half or the whole screen. |
| Pinch or spread | Resizes it. Where the pointer sits in the window decides which edge moves. |
| Tap | Fills the screen. Tap again to put it back. |
| Quick flick sideways | Switches desktops. |
| Quick flick up or down | Opens Mission Control or App Exposé (off by default). |

A few extras live in Settings: a snap grid for halves, thirds and quarters, window edges that
stick to the screen's edges for a moment, and a preview of every gesture.

## Getting started

You need macOS 14 or later on an Apple silicon Mac, a trackpad, and Xcode's command line tools.

```sh
git clone https://github.com/tutamak/tutamak.git
cd tutamak
make install
```

That builds the app, puts it in `~/Applications` and opens it. A short setup walks you through
the rest: letting Tutamak move windows (macOS asks for Accessibility access), turning off macOS's
own four-finger swipes so the two don't fight, and trying each gesture.

After that, Tutamak lives in the menu bar. Its menu has Settings (⌘,) and the setup, if you
ever want to run it again.

## Good to know

- macOS keeps its own four-finger gestures on even after you move Mission Control to three
  fingers. The setup can turn them off for you and keeps a backup, which Settings can restore.
- Hold ⌥ as you let go to leave a window exactly where it is, without snapping.
- Full-screen apps and windows that can't be moved, like the Dock, are left alone.
- Tutamak reads the trackpad through a private Apple framework. That keeps it out of the App
  Store, and a future macOS update could break it.

## Why "Tutamak"?

*Tutamak* is Turkish for "handle": the part of something you hold on to. Tutamak gives every
window one. The name was picked by Claude, Anthropic's AI model, which wrote the app in Claude
Code.

## For developers

```sh
make test       # the tests; no trackpad needed
make debug      # runs the app and follows its log
make touches    # prints raw finger data from the trackpad
```

How the gestures are told apart, the numbers behind them and a tour of the code are in
[docs/details.md](docs/details.md).

## Uninstall

```sh
make gestures-restore   # only if you let Tutamak turn off the macOS gestures
make uninstall
```

## License

Apache License 2.0. See [LICENSE](LICENSE).
