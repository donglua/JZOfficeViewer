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
    "@jzdy/office": "^0.4.0"
  }
}
```

## 快速上手

### 1. 引入组件

```typescript
import { OfficePreviewView } from '@jzdy/office';

@Entry
@Component
struct PreviewPage {
  @State filePath: string = '';

  aboutToAppear() {
    // 传入应用沙箱中的文档绝对路径（如 cacheDir 或 filesDir）
    this.filePath = `${getContext(this).cacheDir}/sample.docx`;
  }

  build() {
    Column() {
      OfficePreviewView({ filePath: this.filePath })
        .width('100%')
        .height('100%')
    }
    .width('100%')
    .height('100%')
  }
}
```

### 2. 底层数据模型接口

如需自定义渲染或仅提取文档结构，可直接调用 `NativeCore` 异步解析接口：

```typescript
import { NativeCore, OfficeModel } from '@jzdy/office';

// 异步解析（在后台工作线程中完成，不阻塞 UI）
const model: OfficeModel = await NativeCore.parseDocumentAsync(sandboxPath);
console.info(`Document type: ${model.documentType}`);
```

## 支持格式与特性

- **DOCX**: 文本段落、格式排版、表格渲染、内嵌图片
- **XLSX**: 多工作表切换、单元格多行文本、合并单元格计算、网格拖动与缩放
- **PPTX**: 幻灯片矢量图形、图片与文字排版、线性渐变填充
- **跨架构**: 支持 `arm64-v8a`、`x86_64`、`armeabi-v7a`

## 开源协议

[Apache-2.0](LICENSE)
