# SnapFlow

A lightweight macOS menu-bar screenshot tool built with AppKit and
ScreenCaptureKit. Capture a region, annotate it in place, take scrolling
long-shots, and pin screenshots on top of everything.

## Features

- **Region capture** with an in-place editor — annotate right where you shot it.
- **Annotations** — pen, shapes, lines, colour & line-width palette; select,
  move, resize existing marks; hold Shift to constrain.
- **Long (scrolling) capture** — reuses the current region, auto-stitches
  frames, shows a live preview while you scroll.
- **Pin to desktop** — floating always-on-top windows with a soft shadow.
- **Colour picker** loupe with a pixel grid.
- **Configurable shortcuts** (default region capture: ⇧⌘X) and optional
  launch-at-login.

## Requirements

- macOS 14.0 or later
- Universal binary (Apple Silicon + Intel)

## Install

Download the latest `SnapFlow.dmg` (or `.zip`) from the
[Releases](https://github.com/LonglangMountain/SnapFlow/releases) page, drag
SnapFlow to Applications, and grant **Screen Recording** permission on first
launch (System Settings → Privacy & Security → Screen Recording).

## Build from source

```bash
./build.sh release        # universal release build → SnapFlow.app
```

Requires a recent Swift toolchain (see `Package.swift`).

## License

Not yet specified. Add a `LICENSE` file (e.g. MIT) before publishing if you
want others to reuse the code.
