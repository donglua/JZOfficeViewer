import { image } from '@kit.ImageKit';
import * as model from '../core/OfficeModel';
import { NativeCore } from '../core/NativeCore';
import { RenderUtils } from './RenderUtils';
import { CanvasElementDrawer } from './CanvasElementDrawer';
import { SpreadsheetView } from './SpreadsheetView';

/**
 * JZOffice 鸿蒙端核心统一预览组件
 * 自动根据文档格式分发至 DOCX (流式排版)、PPTX (幻灯片画布) 与 XLSX (电子表格) 渲染引擎
 */
@Component
export struct OfficePreviewView {
  @Watch('onFilePathChanged') @Prop filePath: string = '';
  @Prop preloadedDoc: model.OfficeDocument | null = null;

  @State document: model.OfficeDocument | null = null;
  @State isLoading: boolean = true;
  @State errorMessage: string = '';

  aboutToAppear(): void {
    if (this.preloadedDoc) {
      this.document = this.preloadedDoc;
      this.isLoading = false;
      return;
    }
    if (this.filePath) {
      this.loadDocument(this.filePath);
    }
  }

  onFilePathChanged(): void {
    if (this.filePath) {
      this.loadDocument(this.filePath);
    }
  }

  private async loadDocument(path: string): Promise<void> {
    this.isLoading = true;
    this.errorMessage = '';
    try {
      this.document = await NativeCore.parseDocumentAsync(path);
    } catch (e) {
      this.errorMessage = `文档加载失败: ${e}`;
    } finally {
      this.isLoading = false;
    }
  }

  build() {
    Stack() {
      if (this.isLoading) {
        Column({ space: 12 }) {
          LoadingProgress().width(48).height(48).color('#0a59f7')
          Text('正在解析文档...').fontSize(14).fontColor('#5f6368')
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
      } else if (this.errorMessage) {
        Column({ space: 12 }) {
          Text('⚠️').fontSize(36)
          Text(this.errorMessage).fontSize(14).fontColor('#d93025').padding({ left: 24, right: 24 })
          Button('重试')
            .fontSize(14)
            .height(36)
            .onClick(() => {
              if (this.filePath) this.loadDocument(this.filePath);
            })
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
      } else if (this.document) {
        if (this.document.kind === 'DOCX') {
          DocxFlowView({ document: this.document, filePath: this.filePath })
        } else if (this.document.kind === 'PPTX') {
          PptxSlidesView({ document: this.document, filePath: this.filePath })
        } else if (this.document.kind === 'XLSX') {
          SpreadsheetView({ document: this.document })
        }
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#f8f9fa')
  }
}

/**
 * DOCX 流式文档视图：利用 List 虚拟列表渲染段落、富文本 Span、表格与图片
 */
@Component
struct DocxFlowView {
  @Prop document: model.OfficeDocument;
  @Prop filePath: string = '';

  build() {
    List({ space: 8 }) {
      ForEach(this.document.blocks, (element: model.Element, index: number) => {
        ListItem() {
          if (element.type === 'TABLE' && element.rows && element.rows.length > 0) {
            DocxTableView({ element: element })
          } else if (element.paragraphs && element.paragraphs.length > 0) {
            Column({ space: 4 }) {
              ForEach(element.paragraphs, (para: model.Paragraph) => {
                DocxParagraphView({ para: para })
              })
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
          } else if (element.type === 'IMAGE') {
            DocxImageView({ filePath: this.filePath, element: element })
          }
        }
      })
    }
    .width('100%')
    .height('100%')
    .padding({ left: 16, right: 16, top: 16, bottom: 24 })
    .backgroundColor('#ffffff')
  }
}

/**
 * DOCX 内嵌图片异步解码与展示组件
 */
@Component
struct DocxImageView {
  @Prop filePath: string = '';
  @Prop element: model.Element;
  @State pixelMap: image.PixelMap | null = null;
  @State isLoading: boolean = true;

  aboutToAppear(): void {
    if (this.element.image && this.filePath) {
      this.loadImage();
    } else {
      this.isLoading = false;
    }
  }

  private async loadImage(): Promise<void> {
    try {
      const buffer = await NativeCore.readPartAsync(this.filePath, this.element.image!);
      this.pixelMap = await RenderUtils.decodeImageBuffer(buffer);
    } catch (_e) {
      // 容错处理
    } finally {
      this.isLoading = false;
    }
  }

  build() {
    Row() {
      if (this.pixelMap) {
        Image(this.pixelMap)
          .objectFit(ImageFit.Contain)
          .width(this.element.width > 0 ? this.element.width : '100%')
          .height(this.element.height > 0 ? this.element.height : 180)
      } else if (this.isLoading) {
        LoadingProgress().width(24).height(24).color('#0a59f7')
      } else {
        Text('[图片]').fontSize(12).fontColor('#80868b')
      }
    }
    .width('100%')
    .justifyContent(FlexAlign.Center)
    .margin({ top: 4, bottom: 4 })
  }
}

/**
 * DOCX 单段落富文本渲染
 */
@Component
struct DocxParagraphView {
  @Prop para: model.Paragraph;

  build() {
    Text() {
      if (this.para.bullet) {
        Span(`${this.para.bullet} `).fontSize(13).fontColor('#5f6368')
      }
      ForEach(this.para.runs, (run: model.Run) => {
        Span(run.text)
          .fontSize(run.size || 14)
          .fontColor(RenderUtils.argbToCss(run.color) ?? '#202124')
          .fontWeight(run.bold ? FontWeight.Bold : FontWeight.Normal)
          .fontStyle(run.italic ? FontStyle.Italic : FontStyle.Normal)
          .decoration({
            type: run.underline ? TextDecorationType.Underline : TextDecorationType.None,
            color: RenderUtils.argbToCss(run.color) ?? '#202124'
          })
      })
    }
    .width('100%')
    .textAlign(this.mapAlignment(this.para.alignment))
    .margin({
      top: this.para.before || 2,
      bottom: this.para.after || 4,
      left: this.para.firstLineIndent || this.para.indent || 0,
      right: this.para.rightIndent || 0
    })
  }

  private mapAlignment(align: number): TextAlign {
    switch (align) {
      case 1: return TextAlign.Center;
      case 2: return TextAlign.End;
      default: return TextAlign.Start;
    }
  }
}

/**
 * DOCX 表格渲染
 */
@Component
struct DocxTableView {
  @Prop element: model.Element;

  build() {
    Column() {
      ForEach(this.element.rows, (row: model.Paragraph[][], rIdx: number) => {
        Row() {
          ForEach(row, (cellParas: model.Paragraph[], cIdx: number) => {
            Column({ space: 2 }) {
              ForEach(cellParas, (para: model.Paragraph) => {
                DocxParagraphView({ para: para })
              })
            }
            .layoutWeight(this.element.columnWidths?.[cIdx] ?? 1)
            .padding(6)
            .border({ width: 0.5, color: '#b7bec7' })
            .backgroundColor(RenderUtils.argbToCss(this.element.cellFills?.[rIdx]?.[cIdx] ?? 0) ?? '#ffffff')
          })
        }
        .width('100%')
      })
    }
    .width('100%')
    .margin({ top: 8, bottom: 8 })
  }
}

/**
 * PPTX 幻灯片画布视图：垂直虚拟列表展示每一页幻灯片，每页用独立 Canvas 自绘矢量图元
 */
@Component
struct PptxSlidesView {
  @Prop document: model.OfficeDocument;
  @Prop filePath: string = '';

  build() {
    List({ space: 16 }) {
      ForEach(this.document.pages, (page: model.Page, index: number) => {
        ListItem() {
          Column({ space: 6 }) {
            PptxSlideCanvas({ page: page, filePath: this.filePath })
            Text(`${index + 1} / ${this.document.pages.length}`)
              .fontSize(12)
              .fontColor('#80868b')
          }
          .width('100%')
          .alignItems(HorizontalAlign.Center)
        }
      })
    }
    .width('100%')
    .height('100%')
    .padding({ left: 16, right: 16, top: 16, bottom: 24 })
  }
}

/**
 * 单页 PPTX Canvas 渲染组件
 */
@Component
struct PptxSlideCanvas {
  @Prop page: model.Page;
  @Prop filePath: string = '';

  private settings: RenderingContextSettings = new RenderingContextSettings(true);
  private ctx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings);
  private canvasWidth: number = 0;
  private canvasHeight: number = 0;
  private imageCache: Map<string, image.PixelMap> = new Map();

  aboutToAppear(): void {
    this.preloadImages();
  }

  private async preloadImages(): Promise<void> {
    if (!this.filePath || !this.page?.elements) return;
    const promises: Promise<void>[] = [];
    for (const elem of this.page.elements) {
      if (elem.type === 'IMAGE' && elem.image && !this.imageCache.has(elem.image)) {
        const imgPath = elem.image;
        promises.push(
          (async () => {
            try {
              const buf = await NativeCore.readPartAsync(this.filePath, imgPath);
              const pm = await RenderUtils.decodeImageBuffer(buf);
              if (pm) {
                this.imageCache.set(imgPath, pm);
              }
            } catch (_e) {
              // 容错处理
            }
          })()
        );
      }
    }
    if (promises.length > 0) {
      await Promise.all(promises);
      this.drawSlide();
    }
  }

  private drawSlide(): void {
    if (this.canvasWidth <= 0 || this.canvasHeight <= 0 || !this.page) return;

    const ctx = this.ctx;
    ctx.clearRect(0, 0, this.canvasWidth, this.canvasHeight);

    // 计算页面宽高比与缩放比
    const pW = this.page.width || 720;
    const pH = this.page.height || 405;
    const scale = Math.min(this.canvasWidth / pW, this.canvasHeight / pH);

    ctx.save();
    // 居中绘制
    const offsetX = (this.canvasWidth - pW * scale) / 2;
    const offsetY = (this.canvasHeight - pH * scale) / 2;
    ctx.translate(offsetX, offsetY);
    ctx.scale(scale, scale);

    // 绘制幻灯片背景
    const bgCss = RenderUtils.argbToCss(this.page.background) ?? '#ffffff';
    ctx.fillStyle = bgCss;
    ctx.fillRect(0, 0, pW, pH);

    // 绘制所有图元
    if (this.page.elements) {
      for (const element of this.page.elements) {
        CanvasElementDrawer.drawElement(ctx, element, this.imageCache);
      }
    }

    ctx.restore();
  }

  build() {
    Canvas(this.ctx)
      .width('100%')
      .aspectRatio((this.page.width || 720) / (this.page.height || 405))
      .shadow({ radius: 8, color: '#20000000', offsetY: 2 })
      .borderRadius(4)
      .backgroundColor('#ffffff')
      .onReady(() => {
        this.drawSlide();
      })
      .onAreaChange((_oldArea, newArea) => {
        this.canvasWidth = Number(newArea.width);
        this.canvasHeight = Number(newArea.height);
        this.drawSlide();
      })
  }
}
