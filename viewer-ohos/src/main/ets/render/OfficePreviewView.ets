import { image } from '@kit.ImageKit';
import * as model from '../core/OfficeModel';
import { NativeCore } from '../core/NativeCore';
import { RenderUtils } from './RenderUtils';
import { CanvasElementDrawer } from './CanvasElementDrawer';
import { ImageStore } from './ImageStore';
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
            .width('100%')
            .height('100%')
        } else if (this.document.kind === 'PPTX') {
          PptxSlidesView({ document: this.document, filePath: this.filePath })
            .width('100%')
            .height('100%')
        } else if (this.document.kind === 'XLSX') {
          SpreadsheetView({ document: this.document })
            .width('100%')
            .height('100%')
        }
      }

    }
    .width('100%')
    .height('100%')
    .backgroundColor('#f8f9fa')
    .clip(true)
  }
}

@Component
struct DocxFlowView {
  // 使用普通属性替代 @Prop，避免对整棵文档 AST 进行深拷贝
  document: model.OfficeDocument | null = null;
  filePath: string = '';
  private imageStore: ImageStore = new ImageStore('');

  @State zoom: number = 1.0;
  @State offsetX: number = 0;
  @State offsetY: number = 0;

  aboutToAppear(): void {
    this.imageStore = new ImageStore(this.filePath);
  }

  aboutToDisappear(): void {
    this.imageStore.release();
  }

  private pinchStartZoom: number = 1.0;
  private panStartX: number = 0;
  private panStartY: number = 0;
  private viewportWidth: number = 0;
  private viewportHeight: number = 0;

  private clampOffsets(): void {
    if (this.zoom <= 1.05) {
      this.offsetX = 0;
      this.offsetY = 0;
      return;
    }
    const maxOx = Math.max(0, (this.viewportWidth * (this.zoom - 1)) / 2);
    const maxOy = Math.max(0, (this.viewportHeight * (this.zoom - 1)) / 2);
    this.offsetX = Math.min(maxOx, Math.max(-maxOx, this.offsetX));
    this.offsetY = Math.min(maxOy, Math.max(-maxOy, this.offsetY));
  }

  private setZoom(value: number, focusX: number, focusY: number): void {
    if (isNaN(value) || !isFinite(value)) return;
    const oldZoom = this.zoom;
    const newZoom = Math.max(1.0, Math.min(3.0, value));

    const cX = this.viewportWidth / 2;
    const cY = this.viewportHeight / 2;
    const dx = focusX - cX;
    const dy = focusY - cY;

    if (newZoom <= 1.05) {
      this.zoom = 1.0;
      this.offsetX = 0;
      this.offsetY = 0;
    } else {
      const worldX = (dx - this.offsetX) / oldZoom;
      const worldY = (dy - this.offsetY) / oldZoom;
      this.offsetX = dx - worldX * newZoom;
      this.offsetY = dy - worldY * newZoom;
      this.zoom = newZoom;
      this.clampOffsets();
    }
  }

  build() {
    if (this.document) {
      Stack() {
        Stack() {
          List({ space: 8 }) {
            ForEach(
              this.document.blocks,
              (element: model.Element) => {
                ListItem() {
                  if (element.type === 'TABLE' && element.rows && element.rows.length > 0) {
                    DocxTableView({ element: element })
                  } else if (element.type === 'IMAGE') {
                    DocxImageView({ element: element, imageStore: this.imageStore })
                  } else if (element.paragraphs && element.paragraphs.length > 0) {
                    Column({ space: 4 }) {
                      ForEach(
                        element.paragraphs,
                        (para: model.Paragraph) => {
                          DocxParagraphView({ para: para })
                        },
                        (_para: model.Paragraph, pIdx: number) => `p-${pIdx}`
                      )
                    }
                    .width('100%')
                    .alignItems(HorizontalAlign.Start)
                  }
                }
              },
              (_element: model.Element, index: number) => `block-${index}`
            )
          }
          .width('100%')
          .height('100%')
          .padding({ left: 16, right: 16, top: 16, bottom: 24 })
          .backgroundColor('#ffffff')
          .enabled(this.zoom <= 1.05)
        }
        .width('100%')
        .height('100%')
        .scale({ x: this.zoom, y: this.zoom })
        .translate({ x: this.offsetX, y: this.offsetY })
        .animation({ duration: 150, curve: Curve.EaseOut })
      }
      .width('100%')
      .height('100%')
      .clip(true)
      .onAreaChange((_oldArea: Area, newArea: Area) => {
        const w = Number(newArea.width);
        const h = Number(newArea.height);
        if (w > 0) this.viewportWidth = w;
        if (h > 0) this.viewportHeight = h;
      })
      .gesture(
        GestureGroup(
          GestureMode.Parallel,
          TapGesture({ count: 2 })
            .onAction((event: GestureEvent) => {
              const focusX = event.fingerList && event.fingerList.length > 0
                ? event.fingerList[0].localX
                : (this.viewportWidth / 2);
              const focusY = event.fingerList && event.fingerList.length > 0
                ? event.fingerList[0].localY
                : (this.viewportHeight / 2);
              this.setZoom(this.zoom > 1.1 ? 1.0 : 1.8, focusX, focusY);
            }),
          PinchGesture({ fingers: 2 })
            .onActionStart((event: GestureEvent) => {
              this.pinchStartZoom = this.zoom;
            })
            .onActionUpdate((event: GestureEvent) => {
              const focusX = event.pinchCenterX > 0 ? event.pinchCenterX : (this.viewportWidth / 2);
              const focusY = event.pinchCenterY > 0 ? event.pinchCenterY : (this.viewportHeight / 2);
              this.setZoom(this.pinchStartZoom * event.scale, focusX, focusY);
            })
            .onActionEnd(() => {
              if (this.zoom <= 1.05) {
                this.zoom = 1.0;
                this.offsetX = 0;
                this.offsetY = 0;
              }
            }),
          PanGesture()
            .onActionStart(() => {
              this.panStartX = this.offsetX;
              this.panStartY = this.offsetY;
            })
            .onActionUpdate((event: GestureEvent) => {
              if (this.zoom > 1.05) {
                this.offsetX = this.panStartX + event.offsetX;
                this.offsetY = this.panStartY + event.offsetY;
                this.clampOffsets();
              }
            })
        )
      )
    }
  }
}

/**
 * DOCX 内嵌图片异步解码与展示组件
 */
@Component
struct DocxImageView {
  element: model.Element | null = null;
  imageStore: ImageStore = new ImageStore('');

  @State pixelMap: image.PixelMap | null = null;
  @State isLoading: boolean = true;
  @State loadFailed: boolean = false;

  aboutToAppear(): void {
    this.loadImage();
  }

  private async loadImage(): Promise<void> {
    const part = this.element?.image;
    if (!part) {
      this.isLoading = false;
      this.loadFailed = true;
      return;
    }
    const cached = this.imageStore.cache.get(part);
    if (cached) {
      this.pixelMap = cached;
      this.isLoading = false;
      return;
    }
    this.isLoading = true;
    this.loadFailed = false;
    try {
      await this.imageStore.load(part);
      const loaded = this.imageStore.cache.get(part);
      if (loaded) {
        this.pixelMap = loaded;
      } else {
        this.loadFailed = true;
      }
    } catch (_e) {
      this.loadFailed = true;
    } finally {
      this.isLoading = false;
    }
  }

  build() {
    Row() {
      if (this.pixelMap) {
        if (this.element?.width && this.element?.height && this.element.width > 0 && this.element.height > 0) {
          Image(this.pixelMap)
            .objectFit(ImageFit.Fill)
            .width(this.element.width)
            .height(this.element.height)
            .aspectRatio(this.element.width / this.element.height)
            .constraintSize({ maxWidth: '100%' })
        } else if (this.element?.width && this.element.width > 0) {
          Image(this.pixelMap)
            .objectFit(ImageFit.Fill)
            .width(this.element.width)
            .constraintSize({ maxWidth: '100%' })
        } else {
          Image(this.pixelMap)
            .objectFit(ImageFit.Fill)
            .width('100%')
            .height(this.element?.height && this.element.height > 0 ? this.element.height : 180)
        }
      } else if (this.isLoading) {
        Row() {
          LoadingProgress().width(24).height(24).color('#0a59f7')
        }
        .width(Math.min(240, this.element?.width || 120))
        .height(Math.min(120, this.element?.height || 60))
        .backgroundColor('#f8f9fa')
        .justifyContent(FlexAlign.Center)
      } else {
        Row() {
          Text('[图片]').fontSize(12).fontColor('#80868b')
        }
        .width(Math.min(240, this.element?.width || 120))
        .height(Math.min(120, this.element?.height || 60))
        .backgroundColor('#e8eaed')
        .justifyContent(FlexAlign.Center)
      }
    }
    .width('100%')
    .justifyContent(FlexAlign.Center)
    .margin({ top: 4, bottom: 6 })
  }
}

@Component
struct DocxParagraphView {
  para: model.Paragraph | null = null;

  build() {
    if (this.para) {
      Text() {
        if (this.para.bullet) {
          Span(`${this.para.bullet}`).fontSize(13).fontColor('#5f6368')
        }
        ForEach(
          this.para.runs,
          (run: model.Run) => {
            Span(run.text)
              .fontSize(run.size || 14)
              .fontColor(RenderUtils.argbToCss(run.color) ?? '#202124')
              .fontWeight(run.bold ? FontWeight.Bold : FontWeight.Normal)
              .fontStyle(run.italic ? FontStyle.Italic : FontStyle.Normal)
              .decoration({
                type: run.underline ? TextDecorationType.Underline : TextDecorationType.None,
                color: RenderUtils.argbToCss(run.color) ?? '#202124'
              })
          },
          (_run: model.Run, rIdx: number) => `r-${rIdx}`
        )
      }
      .width('100%')
      .textAlign(this.mapAlignment(this.para.alignment))
      .margin({
        top: this.para.before || 2,
        bottom: this.para.after || 4,
        left: (this.para.indent || 0) + (this.para.firstLineIndent || 0),
        right: this.para.rightIndent || 0
      })
    }
  }

  private mapAlignment(align: number): TextAlign {
    switch (align) {
      case 1: return TextAlign.Center;
      case 2: return TextAlign.End;
      default: return TextAlign.Start;
    }
  }
}

@Component
struct DocxTableView {
  element: model.Element | null = null;

  build() {
    if (this.element) {
      Column() {
        ForEach(
          this.element.rows,
          (row: model.Paragraph[][], rIdx: number) => {
            Row() {
              ForEach(
                row,
                (cellParas: model.Paragraph[], cIdx: number) => {
                  Column({ space: 2 }) {
                    ForEach(
                      cellParas,
                      (para: model.Paragraph) => {
                        DocxParagraphView({ para: para })
                      },
                      (_p: model.Paragraph, pIdx: number) => `cp-${pIdx}`
                    )
                  }
                  .layoutWeight(this.element?.columnWidths?.[cIdx] ?? 1)
                  .padding(6)
                  .border({ width: 0.5, color: '#b7bec7' })
                  .backgroundColor(RenderUtils.argbToCss(this.element?.cellFills?.[rIdx]?.[cIdx] ?? 0) ?? '#ffffff')
                },
                (_cell: model.Paragraph[], cIdx: number) => `c-${rIdx}-${cIdx}`
              )
            }
            .width('100%')
          },
          (_row: model.Paragraph[][], rIdx: number) => `r-${rIdx}`
        )
      }
      .width('100%')
      .margin({ top: 8, bottom: 8 })
    }
  }
}

@Component
struct PptxSlidesView {
  document: model.OfficeDocument | null = null;
  filePath: string = '';
  private imageStore: ImageStore = new ImageStore('');

  @State zoom: number = 1.0;
  @State offsetX: number = 0;
  @State offsetY: number = 0;

  private pinchStartZoom: number = 1.0;
  private panStartX: number = 0;
  private panStartY: number = 0;
  private viewportWidth: number = 0;
  private viewportHeight: number = 0;

  aboutToAppear(): void {
    this.imageStore = new ImageStore(this.filePath);
  }

  aboutToDisappear(): void {
    this.imageStore.release();
  }

  private clampOffsets(): void {
    if (this.zoom <= 1.05) {
      this.offsetX = 0;
      this.offsetY = 0;
      return;
    }
    const maxOx = Math.max(0, (this.viewportWidth * (this.zoom - 1)) / 2);
    const maxOy = Math.max(0, (this.viewportHeight * (this.zoom - 1)) / 2);
    this.offsetX = Math.min(maxOx, Math.max(-maxOx, this.offsetX));
    this.offsetY = Math.min(maxOy, Math.max(-maxOy, this.offsetY));
  }

  private setZoom(value: number, focusX: number, focusY: number): void {
    if (isNaN(value) || !isFinite(value)) return;
    const oldZoom = this.zoom;
    const newZoom = Math.max(1.0, Math.min(4.0, value));

    const cX = this.viewportWidth / 2;
    const cY = this.viewportHeight / 2;
    const dx = focusX - cX;
    const dy = focusY - cY;

    if (newZoom <= 1.05) {
      this.zoom = 1.0;
      this.offsetX = 0;
      this.offsetY = 0;
    } else {
      const worldX = (dx - this.offsetX) / oldZoom;
      const worldY = (dy - this.offsetY) / oldZoom;
      this.offsetX = dx - worldX * newZoom;
      this.offsetY = dy - worldY * newZoom;
      this.zoom = newZoom;
      this.clampOffsets();
    }
  }

  build() {
    if (this.document) {
      Stack() {
        Stack() {
          List({ space: 16 }) {
            ForEach(
              this.document.pages,
              (page: model.Page, index: number) => {
                ListItem() {
                  Column({ space: 6 }) {
                    PptxSlideCanvas({ page: page, imageStore: this.imageStore })
                    Text(`${index + 1} / ${this.document?.pages.length ?? 0}`)
                      .fontSize(12)
                      .fontColor('#80868b')
                  }
                  .width('100%')
                  .alignItems(HorizontalAlign.Center)
                }
              },
              (_page: model.Page, index: number) => `slide-${index}`
            )
          }
          .cachedCount(2)
          .width('100%')
          .height('100%')
          .padding({ left: 16, right: 16, top: 16, bottom: 24 })
          .enabled(this.zoom <= 1.05)
        }
        .width('100%')
        .height('100%')
        .scale({ x: this.zoom, y: this.zoom })
        .translate({ x: this.offsetX, y: this.offsetY })
        .animation({ duration: 150, curve: Curve.EaseOut })
      }
      .width('100%')
      .height('100%')
      .clip(true)
      .onAreaChange((_oldArea: Area, newArea: Area) => {
        const w = Number(newArea.width);
        const h = Number(newArea.height);
        if (w > 0) this.viewportWidth = w;
        if (h > 0) this.viewportHeight = h;
      })
      .gesture(
        GestureGroup(
          GestureMode.Parallel,
          TapGesture({ count: 2 })
            .onAction((event: GestureEvent) => {
              const focusX = event.fingerList && event.fingerList.length > 0
                ? event.fingerList[0].localX
                : (this.viewportWidth / 2);
              const focusY = event.fingerList && event.fingerList.length > 0
                ? event.fingerList[0].localY
                : (this.viewportHeight / 2);
              this.setZoom(this.zoom > 1.1 ? 1.0 : 2.0, focusX, focusY);
            }),
          PinchGesture({ fingers: 2 })
            .onActionStart((event: GestureEvent) => {
              this.pinchStartZoom = this.zoom;
            })
            .onActionUpdate((event: GestureEvent) => {
              const focusX = event.pinchCenterX > 0 ? event.pinchCenterX : (this.viewportWidth / 2);
              const focusY = event.pinchCenterY > 0 ? event.pinchCenterY : (this.viewportHeight / 2);
              this.setZoom(this.pinchStartZoom * event.scale, focusX, focusY);
            })
            .onActionEnd(() => {
              if (this.zoom <= 1.05) {
                this.zoom = 1.0;
                this.offsetX = 0;
                this.offsetY = 0;
              }
            }),
          PanGesture()
            .onActionStart(() => {
              this.panStartX = this.offsetX;
              this.panStartY = this.offsetY;
            })
            .onActionUpdate((event: GestureEvent) => {
              if (this.zoom > 1.05) {
                this.offsetX = this.panStartX + event.offsetX;
                this.offsetY = this.panStartY + event.offsetY;
                this.clampOffsets();
              }
            })
        )
      )
    }
  }
}

@Component
struct PptxSlideCanvas {
  page: model.Page | null = null;
  imageStore: ImageStore = new ImageStore('');

  private settings: RenderingContextSettings = new RenderingContextSettings(true);
  private ctx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings);
  private isReady: boolean = false;
  private lastDrawnWidth: number = 0;
  private lastDrawnHeight: number = 0;

  aboutToAppear(): void {
    this.loadImages();
  }

  /** 收集本页引用的全部图片，异步加载完成后强制重绘 */
  private async loadImages(): Promise<void> {
    if (!this.page || !this.page.elements) return;
    const parts: string[] = [];
    for (const element of this.page.elements) {
      if (element.type === 'IMAGE' && element.image && parts.indexOf(element.image) < 0) {
        parts.push(element.image);
      }
    }
    if (parts.length === 0) return;
    await Promise.all(parts.map((part: string) => this.imageStore.load(part)));
    this.drawSlide(true);
  }

  private drawSlide(force: boolean = false): void {
    if (!this.isReady || !this.page) return;
    const w = this.ctx.width;
    const h = this.ctx.height;
    if (w <= 0 || h <= 0) return;
    if (!force && Math.abs(w - this.lastDrawnWidth) < 0.5 && Math.abs(h - this.lastDrawnHeight) < 0.5) {
      return;
    }
    this.lastDrawnWidth = w;
    this.lastDrawnHeight = h;

    const ctx = this.ctx;
    ctx.clearRect(0, 0, w, h);

    const pW = this.page.width || 720;
    const pH = this.page.height || 405;
    const scale = Math.min(w / pW, h / pH);

    ctx.save();
    const offsetX = (w - pW * scale) / 2;
    const offsetY = (h - pH * scale) / 2;
    ctx.translate(offsetX, offsetY);
    ctx.scale(scale, scale);

    ctx.beginPath();
    ctx.rect(0, 0, pW, pH);
    ctx.clip();

    const bgCss = RenderUtils.argbToCss(this.page.background) ?? '#ffffff';
    ctx.fillStyle = bgCss;
    ctx.fillRect(0, 0, pW, pH);

    if (this.page.elements) {
      for (const element of this.page.elements) {
        CanvasElementDrawer.drawElement(ctx, element, this.imageStore.cache);
      }
    }

    ctx.restore();
  }

  build() {
    Canvas(this.ctx)
      .width('100%')
      .aspectRatio(((this.page?.width ?? 720) / (this.page?.height ?? 405)))
      .shadow({ radius: 8, color: '#20000000', offsetY: 2 })
      .borderRadius(4)
      .backgroundColor('#ffffff')
      .onReady(() => {
        this.isReady = true;
        this.drawSlide(true);
      })
      .onAreaChange(() => {
        this.drawSlide(false);
      })
  }
}
