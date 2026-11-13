# JZOfficeViewer

[English](README.en.md) | **简体中文**

轻量级 Office 文档离线预览库，支持 **Android**、**HarmonyOS NEXT** 与 **macOS**，提供 DOCX、PPTX 和 XLSX 的本地只读预览。

底层共用 Rust 解析核心 `jz-office-core`，平台层使用原生组件与 Canvas 排版绘制，不依赖服务端转换、WebView、外部 Office 应用或内置字体。Android 端另提供可选的 `viewer-online` 模块，支持在线文档下载与缓存管理。

当前最新版本为 **0.13.1**，详细变更记录见 [CHANGELOG](CHANGELOG.md)，开发、测试与发布规范见 [AGENT.md](AGENT.md)。

- **GitHub Release**：[v0.13.1 Release](https://github.com/donglua/JZOfficeViewer/releases/tag/v0.13.1)
- **Maven Central (Android)**：[io.github.donglua.office:viewer](https://central.sonatype.com/artifact/io.github.donglua.office/viewer/0.13.1) / [viewer-online](https://central.sonatype.com/artifact/io.github.donglua.office/viewer-online/0.13.1)
- **OHPM (HarmonyOS NEXT)**：`@jzdy/office`（`0.13.1`）

## 产物体积

以下为 `0.13.1` Release 构建产物的实际大小（1 KiB = 1024 字节）：

| 平台 | 产物 | 文件大小 | 说明 |
| --- | --- | --- | --- |
| Android | `viewer-0.13.1.aar` | **约 922 KiB** | DOCX / PPTX / XLSX 核心预览，含 `arm64-v8a` 与 `armeabi-v7a` |
| Android | `viewer-online-0.13.1.aar` | **约 21.1 KiB** | 可选的在线下载与缓存模块，配合 `viewer` 使用，零额外网络库依赖 |
| HarmonyOS | `jzdy-office-0.13.1.har` | **约 1057 KiB** | 鸿蒙 NEXT 核心预览 HAR（`@jzdy/office`），含 `arm64-v8a` 与 `x86_64` |
| macOS | `CJZOffice-0.13.1.xcframework.zip` | **约 1.7 MiB** | macOS 原生核心 XCFramework，含 `arm64`（Apple Silicon）与 `x86_64`（Intel）双架构静态库 |

产物均不打包字体或演示样例。实际接入后的应用体积增量受 ABI 过滤、R8/混淆及打包配置影响。

## 预览效果

Demo 内置综合样例的真机预览效果（点击可查看大图）：

<table>
  <tr>
    <th>DOCX</th>
    <th>PPTX</th>
    <th>XLSX</th>
  </tr>
  <tr>
    <td><a href="docs/images/preview-docx.png"><img src="docs/images/preview-docx.png" width="260" alt="DOCX 预览：文字样式、图片与表格"></a></td>
    <td><a href="docs/images/preview-pptx.png"><img src="docs/images/preview-pptx.png" width="260" alt="PPTX 预览：组合图形与图表"></a></td>
    <td><a href="docs/images/preview-xlsx.png"><img src="docs/images/preview-xlsx.png" width="260" alt="XLSX 预览：单元格样式、数字格式与工作表标签"></a></td>
  </tr>
</table>

## 支持范围

本库定位于**轻量、离线、只读的基础预览**，不保证与桌面端 Microsoft Office 版式逐像素一致。

| 格式 | 已支持能力 | 简化或忽略项 |
| --- | --- | --- |
| **DOCX** | 段落与样式继承、显式字体名传递、字号/颜色/粗斜体/下划线、倍数/固定/最小行距、首行/悬挂/左右缩进、16 种常见自动编号、内嵌图片、矩形表格、页眉页脚（随内容滚动）、隐藏文本（`vanish`/`webHidden`）与注音过滤 | 连续滚动流式布局（`pageCount` 固定为 1）；忽略精确分页、浮动环绕和公式 |
| **PPTX** | 按演示顺序渲染幻灯片、文本框对齐与自动换行控制、行距与缩进、已保存的自动缩字（`normAutofit`）、内嵌图片与 `blipFill` 背景图、矩形/椭圆/圆角矩形/三角形/菱形及自定义数值路径、线性渐变填充与背景、嵌套组合变换（平移/缩放/旋转）、表格与单元格填充、带缓存数据的基础折线图与垂直柱状图、主题色与明暗度（`lumMod`/`lumOff`） | 忽略动画、非折线/柱状图（如饼图、面积图）、SmartArt、复杂预设几何与引导公式、WordArt；渐变文字以代表色近似；不重新求解字体自适应 |
| **XLSX** | 多工作表切换、行列标题、双向平滑滚动与缩放、合并单元格、行高列宽、字体/填充/边框/对齐/自动换行、自定义索引调色板与 `tint` 明暗色、多段数字格式（正/负/零/文本、百分比、日期、区域标签剥离）、公式缓存值显示 | 不执行公式计算或宏；忽略工作表浮动图片、图表、条件格式、数据透视表和冻结窗格；富文本合并为单元格普通文字 |

- **不支持旧版二进制格式**：`.doc`、`.ppt`、`.xls` 需先转换为 `.docx`、`.pptx`、`.xlsx`（仅修改文件扩展名无效）。
- **不支持加密文档、ZIP64/分卷压缩包及文档编辑**。
- **未支持内容提示**：解析过程中识别到的省略项通过 `Info.warnings` 返回。

## Android 接入

最低支持 **Android 6.0（API 23）**。确保 `settings.gradle.kts` 已启用 `mavenCentral()`：

```kotlin
dependencyResolutionManagement {
    repositories {
        google()
        mavenCentral()
    }
}
```

### 1. 添加依赖

仅需本地 `Uri` 预览时引入 `viewer`；需要在线 URL 下载预览时引入 `viewer-online`（它会通过 `api` 自动传递依赖同版本 `viewer`）：

```kotlin
dependencies {
    // 方式一：仅本地文档预览
    implementation("io.github.donglua.office:viewer:0.13.1")

    // 方式二：包含在线下载与缓存 + 本地预览
    implementation("io.github.donglua.office:viewer-online:0.13.1")
}
```

> 若直接拷贝 Release 附件中的 AAR 到本地 `libs/`，在线预览需同时引入 `viewer-0.13.1.aar` 和 `viewer-online-0.13.1.aar`。

### 2. 本地文档预览

主要接收 `content://` 或应用有权限读取的 `file://` URI。所有 UI 方法在主线程调用，解析与解码在后台线程执行：

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

- **手势与缩放**：支持滚动、双指捏合缩放、双击缩放以及代码调用 `setZoom()` / `resetZoom()`。捏合时内容始终 1:1 跟随手指，不使用跟随阻尼；缩放到达 1.0x / 4.0x 边界后继续捏合按抵抗曲线让步（上限外最多 0.4x、下限外最多 0.1x），松手以 220 ms 减速动画回弹到边界值。双击与读屏缩放动作同样以 220 ms 补间过渡，`setZoom()` / `resetZoom()` 保持即时生效，便于外部精确恢复到指定缩放。
- **页码与跳页**（页码从 1 开始）：
  ```kotlin
  preview.setOnPageChangeListener { pageNumber, pageCount ->
      pageLabel.text = "$pageNumber / $pageCount"
  }
  preview.jumpToPage(2)
  ```
- **XLSX 工作表切换与标准化标签栏组件**：
  可以直接调用 `preview.selectSheet(2)` 切换工作表（表序号从 1 开始），或直接接入标准组件 `OfficeSheetTabs`（自动与预览视图双向联动绑定，非 XLSX 时自动隐藏）：
  ```kotlin
  import cn.jingzhuan.lib.office.widget.OfficeSheetTabs

  val sheetTabs = OfficeSheetTabs(context)
  sheetTabs.attachTo(preview)
  container.addView(sheetTabs)
  ```
- **无头元数据读取（`OfficeMetadata`）**：
  无需初始化 View 即可在后台离线读取文档格式、页数、尺寸（点单位）及工作表名称列表：
  ```kotlin
  import cn.jingzhuan.lib.office.OfficeMetadata

  OfficeMetadata.readAsync(context, uri, object : OfficeMetadata.Callback {
      override fun onSuccess(meta: OfficeMetadata) {
          Log.i("Office", "Format: ${meta.format}, pages: ${meta.pageCount}, sheets: ${meta.sheetNames}")
      }
      override fun onError(error: Exception) { }
  })
  ```
- **离屏封面/缩略图生成（`OfficeThumbnail`）**：
  脱离 UI 视图直接在后台工作线程渲染文档首页（DOCX / PPTX / XLSX）为指定最大边界的 Bitmap（自动按原比例缩放）：
  ```kotlin
  import cn.jingzhuan.lib.office.OfficeThumbnail

  OfficeThumbnail.load(context, uri, 300, 300, object : OfficeThumbnail.Callback {
      override fun onSuccess(bitmap: Bitmap) {
          coverImageView.setImageBitmap(bitmap)
      }
      override fun onError(error: Exception) { }
  })
  ```
- **生命周期清理**：在 `Activity.onDestroy()` 或 `Fragment.onDestroyView()` 中调用 `preview.clear()`，及时释放图片缓存并清理私有暂存文件。

### 3. 在线链接预览与缓存管理

`viewer-online` 将文件直链或签名 URL 下载至应用私有缓存目录（`cacheDir/office-preview/`），下载完成后自动交由 `OfficePreviewView` 渲染：

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
        // totalBytes 为 -1 表示响应未声明 Content-Length
    }

    override fun onDownloaded(result: RemoteOfficeDownloader.Result) {}

    override fun onLoaded(info: OfficePreviewView.Info) {}

    override fun onError(error: Exception) {
        showError(error.message)
    }
})

// 取消当前任务：task.cancel()
// 页面销毁时关闭：loader.close()
```

- **安全策略**：跨源重定向自动剥离自定义请求头，禁止从 HTTPS 降级重定向至 HTTP。
- **自定义下载器**：默认使用系统 `HttpURLConnection`；如需接入 OkHttp 或自定义鉴权/代理，可实现 `RemoteOfficeDownloader` 接口传入 `RemoteOfficeLoader` 构造函数。
- **清理闲置缓存**（正在下载或预览中的文件会被安全跳过）：
  ```kotlin
  RemoteOfficeLoader.clearCache(context) { result ->
      val releasedBytes = result.deletedBytes
  }
  ```

## HarmonyOS NEXT 接入

鸿蒙端组件包名为 `@jzdy/office`（API 12+，Stage 模型），与 Android 端共用同一个 Rust 解析核心，支持：
- **DOCX / PPTX**：流式排版与 Canvas 幻灯片渲染、内嵌图片异步提取与缓存、双指缩放（1.0x~4.0x，越界按抵抗曲线让步并回弹）、双击缩放（1.0x/2.0x，带补间）、缩放态下原生滚动与平移。
- **XLSX**：多工作表切换、行列固定表头、合并单元格、自动换行、双指/双击缩放（边界回弹与补间）与 Fling 物理惯性滚动。

### 1. 安装依赖

```shell
ohpm install @jzdy/office
```

或在模块的 `oh-package.json5` 中添加：

```json5
{
  "dependencies": {
    "@jzdy/office": "^0.13.1"
  }
}
```

### 2. 使用预览组件与控制器

向 `OfficePreviewView` 传入应用沙箱内的文档绝对路径（如 `cacheDir` 或 `filesDir` 下的路径），并可通过 `OfficePreviewController` 控制跳页、切换工作表与缩放：

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

如需直接获取解析后的结构化文档模型（`OfficeDocument`），可调用异步接口 `NativeCore.parseDocumentAsync(filePath)`。

如需在鸿蒙端无头速读文档元数据、离屏生成文档封面缩略图，或接入多工作表切换栏，可直接使用标准开箱即用接口：

```typescript
import {
  readOfficeMetadata,
  renderOfficeThumbnail,
  OfficeSheetTabs,
  OfficeMetadataInfo
} from '@jzdy/office';

// 1. 无头元数据速读（只读取格式与页数所需的部件，不构建正文与样式模型）
const info: OfficeMetadataInfo = await readOfficeMetadata(filePath);

// 2. 离屏封面/缩略图生成（走首屏解析，使用完毕后调用 pixelMap.release()）
const pixelMap = await renderOfficeThumbnail(filePath, 240, 320);

// 3. 多工作表切换标签栏（仅需传入 controller 即可自动订阅联动，非 XLSX 文档自动隐藏）
OfficeSheetTabs({
  controller: this.previewController
})
```

完整用法可参考 `demo-ohos` 模块。

## macOS 原生接入（Swift Package）

macOS 端模块位于 `viewer-macos`（最低支持 **macOS 14.0 Sonoma**），通过 C-ABI（`jz-office-macos`）直接调用 Rust 解析核心 `jz-office-core`，渲染层基于 Apple 原生 `CoreGraphics` + `CoreText` + `ImageIO` + `SwiftUI` / `AppKit` 实现，与 Android、HarmonyOS NEXT 保持对称的标准化组件接口。

### 1. 构建 XCFramework 与运行测试

```shell
./scripts/build-macos.sh
```

脚本会自动编译 `libjz_office_macos.a`（默认或传入 `--universal` 时包含 `arm64` + `x86_64` 通用二进制），打包出 `viewer-macos/libs/CJZOffice.xcframework` 与归档包 `viewer-macos/build/CJZOffice.xcframework.zip`，并执行 `viewer-macos` 的 Swift Package 构建与单元/离屏渲染测试。也可直接运行内置 macOS 演示应用：

```shell
cd viewer-macos && swift run JZOfficeMacDemo
```

### 2. 使用预览组件与标准化接口

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
            // 多工作表标签栏（自动订阅 controller，非 XLSX 文档自动隐藏）
            OfficeSheetTabs(controller: controller)
        }
    }
}

// 无头元数据速读（支持同步 read 与异步 readAsync）
let meta = try await OfficeMetadata.readAsync(from: fileURL)

// 离屏封面/缩略图生成（支持 DOCX / PPTX / XLSX，返回 NSImage 或 CGImage）
let thumbnail: NSImage = try await OfficeThumbnail.renderAsync(
    from: fileURL,
    maxSize: CGSize(width: 240, height: 320)
)
```

## 资源与安全限制

为防止恶意构造文档（如 Zip 炸弹或超长文本）引发内存溢出或主线程卡顿，库内实施了严格的边界控制：

| 维度 | 上限阈值 |
| --- | --- |
| 输入文件 / 整包解压预算 | 单文件最大 **128 MiB**；ZIP 累计解压预算最大 **256 MiB**，最多 **4096** 个条目 |
| XML 解析限制 | 单个 XML 最大 **4 MiB**、最多 **60,000** 个节点、最大嵌套深度 **64** 层；拒绝 DTD 与路径穿越 |
| DOCX 内容限制 | 累计文本最大 **8 MiB**，表格最多 **5,000** 个单元格 |
| PPTX 内容限制 | 最多 **100** 页，累计最多 **5,000** 个元素/节点/单元格；单图表（折线图/柱状图）最多 **8** 系列、**4,096** 数据点 |
| XLSX 内容限制 | 最多 **32** 张工作表，单表最大 **10,000 行 × 256 列**，全表最多 **50,000** 个存储单元格、**8 MiB** 文本；单元格预览上限 **4,096** 个 UTF-16 码元（超出自动截断并提示） |
| 图片解码与缓存 | 单个图片部件压缩数据最大 **16 MiB**，最长边上限 **4,096 px**；内存缓存采用 LRU 淘汰（Android 端像素预算约 800 万像素 / 30.5 MiB） |

## 仓库结构与本地构建

| 目录 | 说明 |
| --- | --- |
| `core/` | `jz-office-core`：Rust 核心解析库（ZIP/OOXML 校验、样式计算与平台无关文档模型） |
| `viewer/` | Android 核心预览库（AAR）与 JNI 桥接（`viewer/native/`） |
| `viewer-online/` | Android 在线文档下载与缓存模块（AAR） |
| `demo/` | Android 演示应用（内置综合样例、文件选择与在线预览） |
| `viewer-ohos/` | HarmonyOS NEXT 预览库（`@jzdy/office` HAR）与 N-API 桥接（`viewer-ohos/native/`） |
| `demo-ohos/` | HarmonyOS NEXT 演示应用 |
| `viewer-macos/` | macOS 原生预览库（Swift Package `JZOffice`）、C-ABI 桥接（`viewer-macos/native/`）与 macOS 演示应用（`JZOfficeMacDemo`） |
| `scripts/` | 跨平台原生构建脚本与 JVM 测试用例 |

### 构建命令

- **Rust 核心检查与测试**（需 Rust 1.88+）：
  ```sh
  cargo test --workspace
  ```
- **Android 构建**（需 JDK 21、Android SDK 35、NDK `28.2.13676358`）：
  ```sh
  ./gradlew :viewer:assembleRelease :viewer-online:assembleRelease :demo:assembleDebug
  ```
- **HarmonyOS NEXT 构建**（需 DevEco Studio 与 `ohrs`）：
  ```sh
  ./scripts/build-ohos.sh
  ```
- **macOS 原生构建与测试**（需 Xcode / Command Line Tools 与 Rust）：
  ```sh
  ./scripts/build-macos.sh
  ```

更多关于架构约束、专项测试套件、样例生成器和 Maven Central / OHPM 发布流程的说明，请参阅 [AGENT.md](AGENT.md)。

## 许可证

本项目采用 [Apache License 2.0](LICENSE)。
