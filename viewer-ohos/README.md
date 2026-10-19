# @jzdy/office

Lightweight DOCX, PPTX and XLSX offline preview library for HarmonyOS NEXT (API 12+).

基于 Rust 核心解析引擎（复用自 JZOffice），通过 ArkTS N-API 与 Canvas 渲染技术，提供纯离线、低内存占用的文档渲染能力。

## 安装

```shell
ohpm install @jzdy/office
```

或者使用简写命令：

```shell
ohpm i @jzdy/office
```

在模块的 `oh-package.json5` 中配置依赖：

```json5
{
  "dependencies": {
    "@jzdy/office": "^0.6.0"
  }
}
```

## 快速上手

### 1. 引入预览组件与控制器

```typescript
import { OfficePreviewController, OfficePreviewInfo, OfficePreviewView } from '@jzdy/office';

@Entry
@Component
struct PreviewPage {
  @State filePath: string = '';
  private previewController: OfficePreviewController = new OfficePreviewController();

  aboutToAppear() {
    // 传入应用沙箱中的文档绝对路径（如 cacheDir 或 filesDir）
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

可通过 `OfficePreviewController` 在宿主页面中控制预览状态：

- `jumpToPage(pageNumber: number)`：跳转到指定页码或工作表（1-based）
- `selectSheet(sheetNumber: number)`：切换到指定工作表（1-based）
- `setZoom(value: number)` / `resetZoom()` / `getZoom()`：设置、重置或查询缩放比例
- `getCurrentPage()` / `getPageCount()` / `getSheetNames()`：查询当前页码、总页数与工作表名列表

### 2. 底层数据模型接口

如需自定义渲染或仅提取文档结构，可直接调用 `NativeCore` 异步解析接口：

```typescript
import { NativeCore, OfficeDocument } from '@jzdy/office';

// 异步解析（在后台工作线程中完成，不阻塞 UI）
const doc: OfficeDocument = await NativeCore.parseDocumentAsync(sandboxPath);
console.info(`Document kind: ${doc.kind}`);
```

## 支持格式与特性

- **DOCX**: 文本段落、格式排版、表格渲染、内嵌图片（含裁剪）与分页虚拟化按需渲染
- **XLSX**: 多工作表切换、单元格多行文本与自动字号适配、合并单元格空间索引、网格惯性滑动与缩放
- **PPTX**: 幻灯片矢量图形、图片裁剪与文字排版、线性渐变填充、折线图与按需虚拟化渲染
- **跨架构**: 支持 `arm64-v8a`、`x86_64`、`armeabi-v7a`

## 开源协议

[Apache-2.0](LICENSE)
