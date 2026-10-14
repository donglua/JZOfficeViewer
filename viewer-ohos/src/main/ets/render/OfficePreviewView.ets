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
          DocxFlowView({ document: this.document })
        } else if (this.document.kind === 'PPTX') {
          PptxSlidesView({ document: this.document })
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

@Component
struct DocxFlowView {
  // 使用普通属性替代 @Prop，避免对整棵文档 AST 进行深拷贝
  document: model.OfficeDocument | null = null;

  build() {
    if (this.document) {
      List({ space: 8 }) {
        ForEach(
          this.document.blocks,
          (element: model.Element) => {
            ListItem() {
              if (element.type === 'TABLE' && element.rows && element.rows.length > 0) {
                DocxTableView({ element: element })
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
              } else if (element.type === 'IMAGE') {
                Row() {
                  Text('[图片]').fontSize(12).fontColor('#80868b')
                }
                .width('100%')
                .height(Math.min(240, element.height || 120))
                .backgroundColor('#e8eaed')
                .justifyContent(FlexAlign.Center)
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
    }
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

  build() {
    if (this.document) {
      List({ space: 16 }) {
        ForEach(
          this.document.pages,
          (page: model.Page, index: number) => {
            ListItem() {
              Column({ space: 6 }) {
                PptxSlideCanvas({ page: page })
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
    }
  }
}

@Component
struct PptxSlideCanvas {
  page: model.Page | null = null;

  private settings: RenderingContextSettings = new RenderingContextSettings(true);
  private ctx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings);
  private isReady: boolean = false;
  private lastDrawnWidth: number = 0;
  private lastDrawnHeight: number = 0;

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
        CanvasElementDrawer.drawElement(ctx, element);
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
