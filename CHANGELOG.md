# Changelog

All notable changes to SnapFlow are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2026-10-08

First public release. A lightweight macOS menu-bar screenshot tool built with
AppKit + ScreenCaptureKit.

### Added
- Region capture with an in-place editor (annotate exactly where the shot was taken).
- Annotation tools: pen, shapes, lines and colour/line-width palette, with
  select / move / resize of existing annotations and Shift to constrain.
- Long (scrolling) capture that reuses the current region, stitches frames
  pixel-accurately and shows a smooth live preview while you scroll.
- Pin-to-desktop floating windows with a soft shadow and quick close button;
  pins stay pixel-sharp and land exactly where the shot was taken.
- Colour picker loupe with a pixel grid.
- Configurable global shortcuts (default region capture: ⇧⌘X) and optional
  launch-at-login.
- Full Retina-resolution captures.
- Universal binary (Apple Silicon + Intel); packaged as `.zip` and `.dmg`.

[Unreleased]: https://github.com/LonglangMountain/SnapFlow/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/LonglangMountain/SnapFlow/releases/tag/v0.1.0
