# Changelog

All notable changes to SnapFlow are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.2.0] - 2026-10-08

### Added
- 本地 OCR 文字识别（Apple Vision，离线、无需 API Key），分两套入口：
  - 提取屏幕文字（独立）：全局快捷键 ⇧⌘O / 菜单栏入口，框选 → 识别 → 复制全部，
    结果浮层提示「已复制 N 段文字」，不打开编辑器。
  - 识别文字（编辑器）：工具栏「识别文字」按钮，识别当前图片后在截图右侧弹出结果
    列表（多选 → 复制所选 / 复制全部），不重新框选。

### Changed
- 画笔支持按住 Shift 画直线；矩形 / 圆形工具提示补充 Shift 说明。
- 工具栏图标与间距微调：文字工具图标改为 `t.square`，保存 / 长截图图标尺寸微调，
  圆角与分隔间距收紧。
- 官网首页同步新增 OCR 文字识别介绍。

### Removed
- 移除工具栏中的独立「直线」工具（可用画笔 + Shift 替代）。

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

[Unreleased]: https://github.com/LonglangMountain/SnapFlow/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/LonglangMountain/SnapFlow/releases/tag/v0.2.0
[0.1.0]: https://github.com/LonglangMountain/SnapFlow/releases/tag/v0.1.0
