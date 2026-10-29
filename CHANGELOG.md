# Changelog

All notable changes to SnapFlow are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.3.2] - 2026-10-28

### Fixed
- 区域截图 / 提取屏幕文字可以截到 Chrome DevTools「审查元素」的高亮框：
  按下快捷键时先同步定格屏幕，再显示遮罩，且显示遮罩时不抢焦点，
  高亮不再消失或闪烁。

### Changed
- 启动时及屏幕排布变化时预热截屏内容过滤器，减少截图前的等待。

## [0.3.1] - 2026-10-16

### Added
- 长截图自动匀速滚动：操作栏新增 ▶/❚❚，鼠标移入截图区域开始匀速滚动、移出即
  暂停，滚到底自动停止；不移动用户鼠标。

### Changed
- 长截图操作栏位置与普通截图操作栏保持一致，并为出现/消失加入淡入淡出动画。
- 编辑器「保存」默认文件名改为 `SnapFlow-时间戳.png`（与自动保存一致）。
- 工具选中背景上下边距各收窄 2pt。

### Fixed
- 长截图在重复表格行场景下的内容重复 / 错位：粗匹配保留多个候选并全分辨率精修，
  且支持上下双向匹配，回弹或往回滚不再被当作新内容拼接。

## [0.3.0] - 2026-10-15

### Added
- 区域截图 / 提取屏幕文字在按下快捷键的瞬间定格屏幕，框选过程中消失的内容
  （如 2 秒 toast）也能截到；框选背景即定格画面，所见即所得。
- 设置 → 通用：显示当前版本，新增「检查更新」（对比 GitHub 最新 Release）
  与「GitHub」项目主页入口。

### Changed
- 截图时选区外遮罩加深。

### Fixed
- 框选区域较大时长截图内容重复堆叠。
- 长截图实时预览与「已截 xxx px」高度显示延迟严重。

### Removed
- 移除编辑器操作栏的「复制」按钮（⌘⇧C）；「完成 ✓」即复制并关闭。

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

[Unreleased]: https://github.com/LonglangMountain/SnapFlow/compare/v0.3.2...HEAD
[0.3.2]: https://github.com/LonglangMountain/SnapFlow/releases/tag/v0.3.2
[0.3.1]: https://github.com/LonglangMountain/SnapFlow/releases/tag/v0.3.1
[0.3.0]: https://github.com/LonglangMountain/SnapFlow/releases/tag/v0.3.0
[0.2.0]: https://github.com/LonglangMountain/SnapFlow/releases/tag/v0.2.0
[0.1.0]: https://github.com/LonglangMountain/SnapFlow/releases/tag/v0.1.0
