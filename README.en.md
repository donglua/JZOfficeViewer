# JZOfficeViewer

**English** | [简体中文](README.md)

A lightweight offline Office document preview library for **Android**, **HarmonyOS NEXT** and **macOS**, providing local read-only preview of DOCX, PPTX and XLSX files.

Both platforms share the Rust parsing core `jz-office-core`; the platform layers use native components and Canvas for layout and drawing. There is no server-side conversion, no WebView, no external Office app and no bundled fonts. Android also offers an optional `viewer-online` module for online document download and cache management.

The latest version is **0.11.0**. See the [CHANGELOG](CHANGELOG.md) (Chinese) for release notes and [AGENT.md](AGENT.md) (Chinese) for development, testing and release guidelines.

- **GitHub Release**: [v0.11.0 Release](https://github.com/donglua/JZOfficeViewer/releases/tag/v0.11.0)
- **Maven Central (Android)**: [io.github.donglua.office:viewer](https://central.sonatype.com/artifact/io.github.donglua.office/viewer/0.11.0) / [viewer-online](https://central.sonatype.com/artifact/io.github.donglua.office/viewer-online/0.11.0)
- **OHPM (HarmonyOS NEXT)**: `@jzdy/office` (`0.11.0`)

## Artifact Size

Actual sizes of the `0.11.0` release artifacts (1 KiB = 1024 bytes):

| Platform | Artifact | Size | Description |
| --- | --- | --- | --- |
| Android | `viewer-0.11.0.aar` | **~899 KiB** | Core DOCX / PPTX / XLSX preview, includes `arm64-v8a` and `armeabi-v7a` |
| Android | `viewer-online-0.11.0.aar` | **~21.1 KiB** | Optional online download and cache module used with `viewer`, no extra networking dependency |
| HarmonyOS | `jzdy-office-0.11.0.har` | **~1057 KiB** | Core preview HAR for HarmonyOS NEXT (`@jzdy/office`), includes `arm64-v8a` and `x86_64` |
| macOS | `CJZOffice-0.11.0.xcframework.zip` | **~1.7 MiB** | macOS native core XCFramework, includes universal `arm64` (Apple Silicon) and `x86_64` (Intel) static library |

No artifact bundles fonts or demo samples. The actual size increase in your app depends on ABI filters, R8/obfuscation and packaging settings.

## Preview

Real-device previews of the built-in demo samples (click to enlarge):

<table>
  <tr>
    <th>DOCX</th>
    <th>PPTX</th>
    <th>XLSX</th>
  </tr>
  <tr>
    <td><a href="docs/images/preview-docx.png"><img src="docs/images/preview-docx.png" width="260" alt="DOCX preview: text styles, images and tables"></a></td>
    <td><a href="docs/images/preview-pptx.png"><img src="docs/images/preview-pptx.png" width="260" alt="PPTX preview: grouped shapes and charts"></a></td>
    <td><a href="docs/images/preview-xlsx.png"><img src="docs/images/preview-xlsx.png" width="260" alt="XLSX preview: cell styles, number formats and sheet tabs"></a></td>
  </tr>
</table>

## Supported Features

This library targets **lightweight, offline, read-only basic preview**. It does not guarantee pixel-perfect fidelity with desktop Microsoft Office.

| Format | Supported | Simplified or ignored |
| --- | --- | --- |
| **DOCX** | Paragraphs and style inheritance, explicit font names, font size / color / bold / italic / underline, multiple / fixed / minimum line spacing, first-line / hanging / left / right indents, 16 common auto-numbering formats, embedded images, rectangular tables, headers and footers (scroll with content), hidden text (`vanish` / `webHidden`) and phonetic guide filtering | Continuous scrolling flow layout (`pageCount` is fixed to 1); exact pagination, floating wrapping and equations are ignored |
| **PPTX** | Slides rendered in presentation order, text box alignment and wrap control, line spacing and indents, saved autofit (`normAutofit`), embedded images and `blipFill` backgrounds, rectangle / ellipse / rounded rectangle / triangle / diamond and custom numeric paths, linear gradient fills and backgrounds, nested group transforms (translate / scale / rotate), tables and cell fills, basic line charts and vertical bar charts with cached data, theme colors and luminance (`lumMod` / `lumOff`) | Animations, chart types other than line / bar (e.g. pie, area), SmartArt, complex preset geometry and guide formulas, and WordArt are ignored; gradient text is approximated with a representative color; font fitting is not re-solved |
| **XLSX** | Multi-sheet switching, row / column headers, smooth two-way scrolling and zooming, merged cells, row heights and column widths, font / fill / border / alignment / wrap text, custom indexed palette and `tint` colors, multi-section number formats (positive / negative / zero / text, percent, date, locale tag stripping), cached formula values | Formulas and macros are not executed; floating images, charts, conditional formatting, pivot tables and frozen panes are ignored; rich text is merged into plain cell text |

- **Legacy binary formats are not supported**: `.doc`, `.ppt` and `.xls` must first be converted to `.docx`, `.pptx` and `.xlsx` (renaming the extension does not work).
- **Encrypted documents, ZIP64 / split archives and editing are not supported.**
- **Unsupported-content hints**: omitted items detected during parsing are returned via `Info.warnings`.

## Android Integration

Requires **Android 6.0 (API 23)** or higher. Make sure `mavenCentral()` is enabled in `settings.gradle.kts`:

```kotlin
dependencyResolutionManagement {
    repositories {
        google()
        mavenCentral()
    }
}
```

### 1. Add Dependencies

Use `viewer` if you only need to preview local `Uri`s. Use `viewer-online` to also preview online URLs (it transitively exposes the same-version `viewer` via `api`):

```kotlin
dependencies {
    // Option 1: local document preview only
    implementation("io.github.donglua.office:viewer:0.11.0")

    // Option 2: online download and cache + local preview
    implementation("io.github.donglua.office:viewer-online:0.11.0")
}
```

> If you copy the AARs from the release assets into a local `libs/` directory, online preview requires both `viewer-0.11.0.aar` and `viewer-online-0.11.0.aar`.

### 2. Local Document Preview

Accepts `content://` URIs or `file://` URIs your app is allowed to read. Call all UI methods on the main thread; parsing and decoding run on background threads:

```kotlin
import cn.jingzhuan.lib.office.OfficePreviewView

val preview = OfficePreviewView(context)
container.addView(preview)

preview.open(uri, object : OfficePreviewView.Listener {
    override fun onLoaded(info: OfficePreviewView.Info) {
        // info.format, info.pageCount, info.warnings, info.sheetNames
    }

    override fun onError(error: Exception) {
        showError(error.message)
    }
})
```

- **Gestures and zoom**: supports scrolling, pinch zoom, double-tap zoom, and `setZoom()` / `resetZoom()` from code. Content tracks your fingers 1:1 while pinching, with no follow damping. Pinching beyond the 1.0x / 4.0x bounds yields along a resistance curve (at most 0.4x above the upper bound and 0.1x below the lower bound), and on release the view bounces back to the bound with a 220 ms decelerating animation. Double-tap and screen-reader zoom actions use the same 220 ms tween, while `setZoom()` / `resetZoom()` take effect immediately so you can restore an exact zoom level.
- **Page number and page jump** (page numbers start at 1):
  ```kotlin
  preview.setOnPageChangeListener { pageNumber, pageCount ->
      pageLabel.text = "$pageNumber / $pageCount"
  }
  preview.jumpToPage(2)
  ```
- **XLSX sheet switching and the standard tab bar component**:
  Call `preview.selectSheet(2)` to switch sheets (sheet index starts at 1), or use the standard `OfficeSheetTabs` component, which binds to the preview view in both directions and hides itself for non-XLSX documents:
  ```kotlin
  import cn.jingzhuan.lib.office.widget.OfficeSheetTabs

  val sheetTabs = OfficeSheetTabs(context)
  sheetTabs.attachTo(preview)
  container.addView(sheetTabs)
  ```
- **Headless metadata reading (`OfficeMetadata`)**:
  Read the document format, page count, size (in points) and sheet names offline in the background, without creating a View:
  ```kotlin
  import cn.jingzhuan.lib.office.OfficeMetadata

  OfficeMetadata.readAsync(context, uri, object : OfficeMetadata.Callback {
      override fun onSuccess(meta: OfficeMetadata) {
          Log.i("Office", "Format: ${meta.format}, pages: ${meta.pageCount}, sheets: ${meta.sheetNames}")
      }
      override fun onError(error: Exception) { }
  })
  ```
- **Offscreen cover / thumbnail generation (`OfficeThumbnail`)**:
  Render the first page of a document (DOCX / PPTX / XLSX) into a Bitmap within the given maximum bounds (scaled proportionally) on a background worker thread, without any UI view:
  ```kotlin
  import cn.jingzhuan.lib.office.OfficeThumbnail

  OfficeThumbnail.load(context, uri, 300, 300, object : OfficeThumbnail.Callback {
      override fun onSuccess(bitmap: Bitmap) {
          coverImageView.setImageBitmap(bitmap)
      }
      override fun onError(error: Exception) { }
  })
  ```
- **Lifecycle cleanup**: call `preview.clear()` in `Activity.onDestroy()` or `Fragment.onDestroyView()` to release the image cache and remove private staging files promptly.

### 3. Online Link Preview and Cache Management

`viewer-online` downloads a direct file link or signed URL into the app's private cache directory (`cacheDir/office-preview/`) and hands the result to `OfficePreviewView` for rendering:

```kotlin
import cn.jingzhuan.lib.office.online.RemoteOfficeDownloader
import cn.jingzhuan.lib.office.online.RemoteOfficeLoader
import cn.jingzhuan.lib.office.online.RemoteOfficeRequest

val loader = RemoteOfficeLoader(context)
val request = RemoteOfficeRequest.builder("https://example.com/report.xlsx")
    .header("Authorization", "Bearer <token>")
    .displayName("report.xlsx")
    .build()

val task = loader.open(preview, request, object : RemoteOfficeLoader.Listener {
    override fun onProgress(bytesRead: Long, totalBytes: Long) {
        // totalBytes of -1 means the response did not declare Content-Length
    }

    override fun onDownloaded(result: RemoteOfficeDownloader.Result) {}

    override fun onLoaded(info: OfficePreviewView.Info) {}

    override fun onError(error: Exception) {
        showError(error.message)
    }
})

// Cancel the current task: task.cancel()
// Close when the page is destroyed: loader.close()
```

- **Security policy**: custom request headers are stripped on cross-origin redirects, and HTTPS-to-HTTP downgrade redirects are rejected.
- **Custom downloader**: uses the system `HttpURLConnection` by default. To use OkHttp or custom auth / proxy, implement the `RemoteOfficeDownloader` interface and pass it to the `RemoteOfficeLoader` constructor.
- **Clear idle cache** (files being downloaded or previewed are safely skipped):
  ```kotlin
  RemoteOfficeLoader.clearCache(context) { result ->
      val releasedBytes = result.deletedBytes
  }
  ```

## HarmonyOS NEXT Integration

The HarmonyOS package is `@jzdy/office` (API 12+, Stage model). It shares the same Rust parsing core as Android and supports:
- **DOCX / PPTX**: flow layout and Canvas slide rendering, asynchronous extraction and caching of embedded images, pinch zoom (1.0x–4.0x, yielding along a resistance curve beyond the bounds and bouncing back), double-tap zoom (1.0x / 2.0x, tweened), and native scrolling and panning while zoomed.
- **XLSX**: multi-sheet switching, frozen row / column headers, merged cells, wrap text, pinch / double-tap zoom (bounce-back and tween) and physics-based fling scrolling.

### 1. Install

```shell
ohpm install @jzdy/office
```

Or add it to the module's `oh-package.json5`:

```json5
{
  "dependencies": {
    "@jzdy/office": "^0.11.0"
  }
}
```

### 2. Use the Preview Component and Controller

Pass the absolute path of a document inside the app sandbox (e.g. under `cacheDir` or `filesDir`) to `OfficePreviewView`, and use `OfficePreviewController` to jump to pages, switch sheets and zoom:

```typescript
import { OfficePreviewController, OfficePreviewInfo, OfficePreviewView } from '@jzdy/office';

@Entry
@Component
struct PreviewPage {
  @State filePath: string = '';
  private previewController: OfficePreviewController = new OfficePreviewController();

  aboutToAppear() {
    const hostContext = this.getUIContext().getHostContext();
    if (hostContext) {
      this.filePath = `${hostContext.cacheDir}/sample.docx`;
    }
  }

  build() {
    Column() {
      OfficePreviewView({
        filePath: this.filePath,
        controller: this.previewController,
        onLoaded: (info: OfficePreviewInfo) => {
          console.info(`Loaded ${info.format}, pages: ${info.pageCount}`);
        },
        onError: (error: Error) => {
          console.error(`Preview error: ${error.message}`);
        },
        onPageChange: (page: number, pageCount: number) => {
          console.info(`Page: ${page}/${pageCount}`);
        }
      })
        .width('100%')
        .height('100%')
    }
    .width('100%')
    .height('100%')
  }
}
```

To get the parsed structured document model (`OfficeDocument`) directly, call the async API `NativeCore.parseDocumentAsync(filePath)`.

To read document metadata headlessly, generate offscreen cover thumbnails, or add a multi-sheet tab bar on HarmonyOS, use the ready-made standard APIs:

```typescript
import {
  readOfficeMetadata,
  renderOfficeThumbnail,
  OfficeSheetTabs,
  OfficeMetadataInfo
} from '@jzdy/office';

// 1. Headless metadata reading
const info: OfficeMetadataInfo = await readOfficeMetadata(filePath);

// 2. Offscreen cover / thumbnail generation (DOCX / PPTX / XLSX; call pixelMap.release() when done)
const pixelMap = await renderOfficeThumbnail(filePath, 240, 320);

// 3. Multi-sheet tab bar (just pass the controller to subscribe automatically; hidden for non-XLSX documents)
OfficeSheetTabs({
  controller: this.previewController
})
```

See the `demo-ohos` module for complete usage.

## macOS Native Integration (Swift Package)

The macOS module is located at `viewer-macos` (minimum supported version: **macOS 14.0 Sonoma**). It links directly to the Rust parsing core `jz-office-core` via a C-ABI bridge (`jz-office-macos`). The rendering pipeline is implemented natively on Apple's `CoreGraphics` + `CoreText` + `ImageIO` + `SwiftUI` / `AppKit`, providing symmetrical standardized component interfaces with Android and HarmonyOS NEXT.

### 1. Build XCFramework and Run Tests

```shell
./scripts/build-macos.sh
```

The script automatically compiles `libjz_office_macos.a` (universal `arm64` + `x86_64` binary when both targets are installed or `--universal` is passed), packages `viewer-macos/libs/CJZOffice.xcframework` and `viewer-macos/build/CJZOffice.xcframework.zip`, and runs Swift Package builds along with unit and offscreen rendering tests. You can also run the built-in macOS demo application directly:

```shell
cd viewer-macos && swift run JZOfficeMacDemo
```

### 2. Standardized Preview Component and APIs

```swift
import SwiftUI
import JZOffice

struct DocumentPreviewScreen: View {
    let fileURL: URL
    @StateObject private var controller = OfficePreviewController()

    var body: some View {
        VStack(spacing: 0) {
            OfficePreviewView(
                fileURL: fileURL,
                controller: controller,
                onLoaded: { info in
                    print("Loaded \(info.format), pages: \(info.pageCount)")
                },
                onError: { error in
                    print("Preview error: \(error.localizedDescription)")
                }
            )
            // Multi-sheet tab bar (automatically linked to controller; hidden for non-XLSX documents)
            OfficeSheetTabs(controller: controller)
        }
    }
}

// Headless metadata reading (supports sync read and async readAsync)
let meta = try await OfficeMetadata.readAsync(from: fileURL)

// Offscreen cover / thumbnail generation (DOCX / PPTX / XLSX; returns NSImage or CGImage)
let thumbnail: NSImage = try await OfficeThumbnail.renderAsync(
    from: fileURL,
    maxSize: CGSize(width: 240, height: 320)
)
```

## Resource and Security Limits

To prevent maliciously crafted documents (such as zip bombs or extremely long text) from causing out-of-memory errors or main-thread stalls, the library enforces strict bounds:

| Dimension | Limit |
| --- | --- |
| Input file / total expansion budget | Single file up to **128 MiB**; cumulative ZIP expansion budget up to **256 MiB**, at most **4096** entries |
| XML parsing | A single XML up to **4 MiB**, at most **60,000** nodes, nesting depth up to **64**; DTDs and path traversal are rejected |
| DOCX content | Cumulative text up to **8 MiB**, at most **5,000** table cells |
| PPTX content | At most **100** slides, at most **5,000** elements / nodes / cells in total; a single chart (line / bar) has at most **8** series and **4,096** data points |
| XLSX content | At most **32** sheets, up to **10,000 rows × 256 columns** per sheet, at most **50,000** stored cells and **8 MiB** of text in total; cell preview is capped at **4,096** UTF-16 code units (excess is truncated with a warning) |
| Image decoding and caching | A single image part up to **16 MiB** compressed, longest edge up to **4,096 px**; the in-memory cache uses LRU eviction (Android pixel budget ≈ 8 million pixels / 30.5 MiB) |

## Repository Layout and Local Build

| Directory | Description |
| --- | --- |
| `core/` | `jz-office-core`: Rust core parsing library (ZIP/OOXML validation, style computation and platform-independent document model) |
| `viewer/` | Android core preview library (AAR) and JNI bridge (`viewer/native/`) |
| `viewer-online/` | Android online document download and cache module (AAR) |
| `demo/` | Android demo app (built-in samples, file picker and online preview) |
| `viewer-ohos/` | HarmonyOS NEXT preview library (`@jzdy/office` HAR) and N-API bridge (`viewer-ohos/native/`) |
| `demo-ohos/` | HarmonyOS NEXT demo app |
| `viewer-macos/` | macOS native preview library (Swift Package `JZOffice`), C-ABI bridge (`viewer-macos/native/`) and macOS demo app (`JZOfficeMacDemo`) |
| `scripts/` | Cross-platform native build scripts and JVM test cases |

### Build Commands

- **Rust core checks and tests** (Rust 1.88+):
  ```sh
  cargo test --workspace
  ```
- **Android build** (JDK 21, Android SDK 35, NDK `28.2.13676358`):
  ```sh
  ./gradlew :viewer:assembleRelease :viewer-online:assembleRelease :demo:assembleDebug
  ```
- **HarmonyOS NEXT build** (DevEco Studio and `ohrs`):
  ```sh
  ./scripts/build-ohos.sh
  ```
- **macOS native build and tests** (Xcode / Command Line Tools and Rust):
  ```sh
  ./scripts/build-macos.sh
  ```

For architecture constraints, dedicated test suites, sample generators and the Maven Central / OHPM release process, see [AGENT.md](AGENT.md) (Chinese).

## License

This project is licensed under the [Apache License 2.0](LICENSE).
