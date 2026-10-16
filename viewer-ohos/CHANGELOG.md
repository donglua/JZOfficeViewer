# Changelog

All notable changes to `@jzdy/office` will be documented in this file.

## [0.5.0] - 2026-10-16

### Added
- Native `package_cache` thread-safe LRU caching in Rust core to reuse ZIP handles and avoid repeated directory scans.
- Cumulative 256 MiB decompression budget (`MAX_EXPANDED`) and dynamic streaming read for image extraction protection.
- Native `parse_path_to_json` binding, replacing duplicated NAPI serialization glue code.
- Viewport interaction enhancement: native vertical scrolling and horizontal panning while zoomed in for DOCX and PPTX.
- DOCX typography features: `textIndent`, `fontFamily`, `lineHeight` spacing, and `DocxShapeView` vector shapes.
- XLSX auto line-wrapping (`style.wrap`), complex multi-section number formatting, and UTF-16 surrogate pair truncation safety.
- Filtering of hidden text (`vanish`, `webHidden`) and ruby text (`rt`, `rp`) in DOCX.

### Optimized
- Eliminated redundant native source/cache archiving and filtered 32-bit binaries, significantly reducing HAR package size.
- Optimized `ImageStore` and native handle lifecycle management to prevent memory peaks and leaks.
- Single-pass text layout measurements in `CanvasElementDrawer` to eliminate repeated Canvas measuring overhead.

## [0.4.0] - 2026-10-15

### Added
- Viewport gesture navigation: pinch-to-zoom (1.0x-4.0x) and double-tap zoom (1.0x/2.0x) with focus anchoring for PPTX and DOCX.
- Viewport boundary damping and panning in magnified state, with container hardware clipping (`.clip(true)`).
- DOCX asynchronous inline image extraction and PixelMap decoding via `ImageStore` and `DocxImageView`.
- DOCX `ImageFit.Fill` rendering for stretched vector/solid shapes and responsive `maxWidth: 100%` viewport constraints.
- Fling inertial scrolling physics simulation for XLSX spreadsheet navigation.

### Optimized
- Highly optimized XLSX viewport cell rendering using binary search prefix-sum axis lookups instead of O(N) full-sheet scans.
- Replaced string-based merge tracking with `Uint8Array` dense byte flags to eliminate per-frame GC pressure.
- Removed ArkUI state dirty-tracking on high-frequency gesture coordinates to prevent redundant re-renders.
- Hardened OHPM automated release pipeline (`publish-ohpm.py`) to disable PTY echo and enforce timeout limits.

## [0.3.1] - 2026-10-15

### Fixed
- Fixed PPTX picture background parsing (`blipFill`) in slide, layout, and master parts.
- Fixed PPTX inline and background image loading and rendering via `ImageStore`.

## [0.3.0] - 2026-10-15

### Added
- Renamed HarmonyOS package to `@jzdy/office`.
- Added support for Rust MSRV 1.88.0 and HarmonyOS NEXT API 12+.
- Optimized document rendering pipeline and text measuring across DOCX, XLSX, and PPTX models.
- Added comprehensive CI workflow for automated OHPM package publishing.

## [0.2.0] - 2026-09-20

### Added
- Added multi-architecture support: `arm64-v8a`, `x86_64`, `armeabi-v7a`.
- Added canvas element drawer for spreadsheet grid rendering.

## [0.1.0] - 2026-09-18

### Added
- Initial release of JZOffice for HarmonyOS NEXT.
- Basic DOCX, XLSX, PPTX parser and ArkTS native component binding via `ohrs`.
