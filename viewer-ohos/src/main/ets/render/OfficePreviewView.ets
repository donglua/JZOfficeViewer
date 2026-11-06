import { image } from '@kit.ImageKit';
import { displaySync } from '@kit.ArkGraphics2D';
import * as model from '../core/OfficeModel';
import { NativeCore } from '../core/NativeCore';
import { RenderUtils } from './RenderUtils';
import { CanvasElementDrawer } from './CanvasElementDrawer';
import { ImageStore } from './ImageStore';
import { SpreadsheetView } from './SpreadsheetView';

class ArrayDataSource<T> implements IDataSource {
  private readonly items: T[];
  private readonly listeners: Set<DataChangeListener> = new Set();

  constructor(items: T[]) {
    this.items = items;
  }

  totalCount(): number {
    return this.items.length;
  }

  getData(index: number): T {
    return this.items[index];
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    this.listeners.add(listener);
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    this.listeners.delete(listener);
  }
}

/**
 * 文档加载完成后的元信息快照（对齐 Android 端 OfficePreviewView.Info）
 */
export interface OfficePreviewInfo {
  readonly format: model.Kind;
  readonly pageCount: number;
  readonly warnings: string[];
  readonly sheetNames: string[];
}

export interface OfficePreviewActions {
  getPageCount: () => number;
  getCurrentPage: () => number;
  getSheetNames: () => string[];
  getZoom: () => number;
  setZoom: (value: number) => void;
  resetZoom: () => void;
  jumpToPage: (pageNumber: number) => void;
  selectSheet: (sheetNumber: number) => void;
}

/**
 * JZOffice 鸿蒙端预览控制器（对齐 Android 端 OfficePreviewView 控制方法）
 */
export class OfficePreviewController {
  private actions: OfficePreviewActions | null = null;

  bind(actions: OfficePreviewActions | null): void {
    this.actions = actions;
  }

  public getPageCount(): number {
    return this.actions ? this.actions.getPageCount() : 0;
  }

  public getCurrentPage(): number {
    return this.actions ? this.actions.getCurrentPage() : 0;
  }

  public getSheetNames(): string[] {
    return this.actions ? this.actions.getSheetNames() : [];
  }

  public getZoom(): number {
    return this.actions ? this.actions.getZoom() : 1.0;
  }

  public setZoom(value: number): void {
    this.actions?.setZoom(value);
  }

  public resetZoom(): void {
    this.actions?.resetZoom();
  }

  public jumpToPage(pageNumber: number): void {
    this.actions?.jumpToPage(pageNumber);
  }

  public selectSheet(sheetNumber: number): void {
    this.actions?.selectSheet(sheetNumber);
  }
}

/**
 * JZOffice 鸿蒙端核心统一预览组件
 * 自动根据文档格式分发至 DOCX (流式排版)、PPTX (幻灯片画布) 与 XLSX (电子表格) 渲染引擎
 */
@Component
export struct OfficePreviewView {
  @Watch('onFilePathChanged') @Prop filePath: string = '';
  // 使用普通属性替代 @Prop，避免对大型预加载文档 AST 触发递归深拷贝
  preloadedDoc: model.OfficeDocument | null = null;
  controller?: OfficePreviewController;
  onLoaded?: (info: OfficePreviewInfo) => void;
  onError?: (error: Error) => void;
  onPageChange?: (pageNumber: number, pageCount: number) => void;

  private rawDocument: model.OfficeDocument | null = null;
  @State private docRevision: number = 0;
  @State isLoading: boolean = true;
  @State errorMessage: string = '';
  private loadGeneration: number = 0;
  private currentPage: number = 0;
  private notifiedPage: number = -1;
  private notifiedCount: number = -1;
  private childGetZoom: (() => number) | null = null;
  private childSetZoom: ((value: number) => void) | null = null;
  private childJumpToPage: ((pageNumber: number) => void) | null = null;
  private childSelectSheet: ((sheetNumber: number) => void) | null = null;

  private bindController(): void {
    if (!this.controller) return;
    this.controller.bind({
      getPageCount: (): number => this.computePageCount(this.rawDocument),
      getCurrentPage: (): number => this.currentPage,
      getSheetNames: (): string[] => this.extractSheetNames(this.rawDocument),
      getZoom: (): number => (this.childGetZoom ? this.childGetZoom() : 1.0),
      setZoom: (value: number): void => {
        if (this.childSetZoom) this.childSetZoom(value);
      },
      resetZoom: (): void => {
        if (this.childSetZoom) this.childSetZoom(1.0);
      },
      jumpToPage: (pageNumber: number): void => {
        const count = this.computePageCount(this.rawDocument);
        if (pageNumber < 1 || pageNumber > count) return;
        if (this.rawDocument?.kind === 'XLSX') {
          if (this.childSelectSheet) this.childSelectSheet(pageNumber);
        } else {
          if (this.childJumpToPage) this.childJumpToPage(pageNumber);
        }
      },
      selectSheet: (sheetNumber: number): void => {
        if (this.rawDocument?.kind !== 'XLSX') return;
        const count = this.computePageCount(this.rawDocument);
        if (sheetNumber < 1 || sheetNumber > count) return;
        if (this.childSelectSheet) this.childSelectSheet(sheetNumber);
      }
    });
  }

  private computePageCount(doc: model.OfficeDocument | null): number {
    if (!doc) return 0;
    if (doc.kind === 'XLSX') return doc.sheets ? doc.sheets.length : 0;
    if (doc.kind === 'PPTX') return doc.pages ? doc.pages.length : 0;
    return 1;
  }

  private extractSheetNames(doc: model.OfficeDocument | null): string[] {
    if (!doc || !doc.sheets) return [];
    const names: string[] = [];
    for (const s of doc.sheets) {
      names.push(s.name);
    }
    return names;
  }

  private notifyPageChanged(pageNumber: number, pageCount: number): void {
    this.currentPage = pageNumber;
    if (this.notifiedPage === pageNumber && this.notifiedCount === pageCount) return;
    this.notifiedPage = pageNumber;
    this.notifiedCount = pageCount;
    if (this.onPageChange) {
      this.onPageChange(pageNumber, pageCount);
    }
  }

  private publishLoadedDocument(doc: model.OfficeDocument): void {
    this.rawDocument = doc;
    this.docRevision++;
    const count = this.computePageCount(this.rawDocument);
    this.currentPage = count > 0 ? 1 : 0;
    if (this.onLoaded) {
      this.onLoaded({
        format: doc.kind,
        pageCount: count,
        warnings: doc.warnings ? doc.warnings.slice() : [],
        sheetNames: this.extractSheetNames(this.rawDocument)
      });
    }
    this.notifyPageChanged(this.currentPage, count);
  }

  aboutToAppear(): void {
    this.bindController();
    if (this.preloadedDoc) {
      this.isLoading = false;
      this.publishLoadedDocument(this.preloadedDoc);
      return;
    }
    if (this.filePath) {
      this.loadDocument(this.filePath);
    }
  }

  aboutToDisappear(): void {
    this.loadGeneration++;
    this.rawDocument = null;
    this.docRevision++;
    this.childGetZoom = null;
    this.childSetZoom = null;
    this.childJumpToPage = null;
    this.childSelectSheet = null;
    this.controller?.bind(null);
  }

  onFilePathChanged(): void {
    if (this.filePath) {
      this.loadDocument(this.filePath);
    }
  }

  private async loadDocument(path: string): Promise<void> {
    const token = ++this.loadGeneration;
    this.isLoading = true;
    this.errorMessage = '';
    this.rawDocument = null;
    this.docRevision++;
    this.childGetZoom = null;
    this.childSetZoom = null;
    this.childJumpToPage = null;
    this.childSelectSheet = null;
    this.notifyPageChanged(0, 0);
    try {
      const parsed = await NativeCore.parseDocumentAsync(path);
      if (token !== this.loadGeneration) return;
      this.publishLoadedDocument(parsed);
    } catch (e) {
      if (token !== this.loadGeneration) return;
      const err: Error = e instanceof Error ? e : new Error(`${e}`);
      this.errorMessage = `文档加载失败: ${err.message}`;
      if (this.onError) {
        this.onError(err);
      }
    } finally {
      if (token === this.loadGeneration) {
        this.isLoading = false;
      }
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
      } else if (this.rawDocument) {
        if (this.rawDocument.kind === 'DOCX') {
          DocxFlowView({
            document: this.rawDocument,
            filePath: this.filePath,
            registerControls: (
              jumpToPage: (pageNumber: number) => void,
              getZoom: () => number,
              setZoom: (value: number) => void
            ): void => {
              this.childJumpToPage = jumpToPage;
              this.childGetZoom = getZoom;
              this.childSetZoom = setZoom;
            }
          })
            .id(`doc-${this.docRevision}-${this.rawDocument?.kind ?? ''}`)
            .width('100%')
            .height('100%')
        } else if (this.rawDocument.kind === 'PPTX') {
          PptxSlidesView({
            document: this.rawDocument,
            filePath: this.filePath,
            onSlideChange: (pageNumber: number, pageCount: number): void => {
              this.notifyPageChanged(pageNumber, pageCount);
            },
            registerControls: (
              jumpToPage: (pageNumber: number) => void,
              getZoom: () => number,
              setZoom: (value: number) => void
            ): void => {
              this.childJumpToPage = jumpToPage;
              this.childGetZoom = getZoom;
              this.childSetZoom = setZoom;
            }
          })
            .id(`doc-${this.docRevision}-${this.rawDocument?.kind ?? ''}`)
            .width('100%')
            .height('100%')
        } else if (this.rawDocument.kind === 'XLSX') {
          SpreadsheetView({
            document: this.rawDocument,
            onSheetChange: (sheetNumber: number, sheetCount: number): void => {
              this.notifyPageChanged(sheetNumber, sheetCount);
            },
            registerControls: (
              selectSheet: (sheetNumber: number) => void,
              getZoom: () => number,
              setZoom: (value: number) => void
            ): void => {
              this.childSelectSheet = selectSheet;
              this.childGetZoom = getZoom;
              this.childSetZoom = setZoom;
            }
          })
            .id(`doc-${this.docRevision}-${this.rawDocument?.kind ?? ''}`)
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
  registerControls?: (
    jumpToPage: (pageNumber: number) => void,
    getZoom: () => number,
    setZoom: (value: number) => void
  ) => void;
  private imageStore: ImageStore = new ImageStore('');
  private blockSource: ArrayDataSource<model.Element> = new ArrayDataSource([]);
  private scroller: ListScroller = new ListScroller();

  @State zoom: number = 1.0;
  @State offsetX: number = 0;
  @State offsetY: number = 0;
  @State isGesturing: boolean = false;
  @State settledZoomPad: number = 0;
  private headerCount: number = 0;
  private bodyCount: number = 0;
  /** 页眉与正文、正文与页脚之间的额外留白，对齐 Android OfficeRenderer 的 10pt 分隔 */
  private sectionGap: number = 10;

  aboutToAppear(): void {
    this.imageStore = new ImageStore(this.filePath);
    // 将页眉块插入到正文开头、页脚块追加到正文末尾，实现基础页眉页脚展示
    const headerBlocks = this.document?.headerBlocks ?? [];
    const bodyBlocks = this.document?.blocks ?? [];
    const footerBlocks = this.document?.footerBlocks ?? [];
    this.headerCount = headerBlocks.length;
    this.bodyCount = bodyBlocks.length;
    this.blockSource = new ArrayDataSource([...headerBlocks, ...bodyBlocks, ...footerBlocks]);
    if (this.registerControls) {
      this.registerControls(
        (_pageNumber: number): void => {
          this.scroller.scrollToIndex(0);
        },
        (): number => this.zoom,
        (value: number): void => {
          this.isGesturing = false;
          this.setZoom(value, this.viewportWidth / 2, this.viewportHeight / 2);
        }
      );
    }
  }

  aboutToDisappear(): void {
    this.imageStore.release();
  }

  private pinchStartZoom: number = 1.0;
  private pinchStartOffsetX: number = 0;
  private pinchFocusX: number = 0;
  private panStartX: number = 0;
  private viewportWidth: number = 0;
  private viewportHeight: number = 0;

  private verticalZoomPad(): number {
    if (this.zoom <= 1.0 || this.viewportHeight <= 0) return 0;
    return (this.viewportHeight * (this.zoom - 1)) / (2 * this.zoom);
  }

  private syncSettledZoomPad(): void {
    const pad = this.verticalZoomPad();
    if (Math.abs(this.settledZoomPad - pad) > 0.5) {
      this.settledZoomPad = pad;
    }
  }

  private clampOffsets(): void {
    if (this.zoom <= 1.05) {
      this.offsetX = 0;
      this.offsetY = 0;
      return;
    }
    const maxOx = Math.max(0, (this.viewportWidth * (this.zoom - 1)) / 2);
    this.offsetX = Math.min(maxOx, Math.max(-maxOx, this.offsetX));
    this.offsetY = 0;
  }

  private setZoom(value: number, focusX: number, focusY?: number): void {
    if (isNaN(value) || !isFinite(value)) return;
    const oldZoom = this.zoom;
    const newZoom = Math.max(1.0, Math.min(RenderUtils.ZOOM_MAX, value));

    const cX = this.viewportWidth / 2;
    const dx = focusX - cX;

    if (newZoom <= 1.05) {
      this.zoom = 1.0;
      this.offsetX = 0;
      this.offsetY = 0;
    } else {
      const worldX = (dx - this.offsetX) / oldZoom;
      this.offsetX = dx - worldX * newZoom;
      this.offsetY = 0;
      this.zoom = newZoom;
      this.clampOffsets();
    }
    if (focusY !== undefined && this.viewportHeight > 0 && Math.abs(newZoom - oldZoom) > 0.01) {
      const cY = this.viewportHeight / 2;
      const dy = (focusY - cY) * (1 / oldZoom - 1 / newZoom);
      if (Math.abs(dy) > 0.5) {
        this.scroller.scrollBy(0, dy);
      }
    }
    this.syncSettledZoomPad();
  }

  build() {
    if (this.document) {
      Stack() {
        Stack() {
          List({ space: 8, scroller: this.scroller }) {
            LazyForEach(
              this.blockSource,
              (element: model.Element, index: number) => {
                ListItem() {
                  if (element.type === 'TABLE' && element.rows && element.rows.length > 0) {
                    DocxTableView({ element: element })
                  } else if (element.type === 'IMAGE') {
                    DocxImageView({ element: element, imageStore: this.imageStore })
                  } else if (element.type === 'RECT' || element.type === 'ELLIPSE' || element.type === 'LINE' || element.type === 'PATH') {
                    DocxShapeView({ element: element, imageStore: this.imageStore })
                  } else if (element.paragraphs && element.paragraphs.length > 0) {
                    DocxTextBlockView({ element: element })
                  }
                }
                .reuseId(element.type)
                // 页眉最后一块之后、页脚第一块之前额外留白，让页眉页脚与正文视觉分开
                .margin({
                  top: this.headerCount + this.bodyCount === index ? this.sectionGap : 0,
                  bottom: this.headerCount > 0 && this.headerCount - 1 === index ? this.sectionGap : 0
                })
              },
              (_element: model.Element, index: number) => `block-${index}`
            )
          }
          .cachedCount(6)
          .width('100%')
          .height('100%')
          .padding({
            left: 16,
            right: 16,
            top: 16 + this.settledZoomPad,
            bottom: 24 + this.settledZoomPad
          })
          .backgroundColor('#ffffff')
        }
        .width('100%')
        .height('100%')
        .scale({ x: this.zoom, y: this.zoom })
        .translate({ x: this.offsetX, y: this.offsetY })
        .animation({ duration: this.isGesturing ? 0 : RenderUtils.ZOOM_ANIMATION_MS, curve: Curve.EaseOut })
      }
      .width('100%')
      .height('100%')
      .clip(true)
      .onAreaChange((_oldArea: Area, newArea: Area) => {
        const w = Number(newArea.width);
        const h = Number(newArea.height);
        if (w > 0) this.viewportWidth = w;
        if (h > 0) this.viewportHeight = h;
        this.clampOffsets();
        this.syncSettledZoomPad();
      })
      .gesture(
        GestureGroup(
          GestureMode.Parallel,
          TapGesture({ count: 2 })
            .onAction((event: GestureEvent) => {
              this.isGesturing = false;
              const focusX = event.fingerList && event.fingerList.length > 0
                ? event.fingerList[0].localX
                : (this.viewportWidth / 2);
              const focusY = event.fingerList && event.fingerList.length > 0
                ? event.fingerList[0].localY
                : (this.viewportHeight / 2);
              this.setZoom(this.zoom > 1.1 ? 1.0 : 2.0, focusX, focusY);
              this.syncSettledZoomPad();
            }),
          PinchGesture({ fingers: 2 })
            .onActionStart(() => {
              this.isGesturing = true;
              this.pinchStartZoom = Math.max(1.0, Math.min(RenderUtils.ZOOM_MAX, this.zoom));
              this.pinchStartOffsetX = this.offsetX;
            })
            .onActionUpdate((event: GestureEvent) => {
              const focusX = event.pinchCenterX > 0 ? event.pinchCenterX : (this.viewportWidth / 2);
              this.pinchFocusX = focusX;
              const raw = this.pinchStartZoom * event.scale;
              const settled = Math.max(1.0, Math.min(RenderUtils.ZOOM_MAX, raw));
              // 顶到边界后继续捏合按抵抗曲线让步，松手再收回，避免硬停带来的「手势丢了」错觉
              const excess = raw - settled;
              const display = settled + RenderUtils.rubberBandZoom(
                excess, excess > 0 ? RenderUtils.ZOOM_OVERFLOW_ABOVE : RenderUtils.ZOOM_OVERFLOW_BELOW);
              if (settled > 1.05) {
                const dx = focusX - this.viewportWidth / 2;
                const worldX = (dx - this.pinchStartOffsetX) / this.pinchStartZoom;
                this.offsetX = dx - worldX * display;
              } else {
                this.offsetX = 0;
              }
              this.offsetY = 0;
              this.zoom = display;
              this.clampOffsets();
            })
            .onActionEnd(() => {
              this.isGesturing = false;
              const settled = Math.max(1.0, Math.min(RenderUtils.ZOOM_MAX, this.zoom));
              if (settled > 1.05 && this.pinchStartZoom > 0) {
                const focusX = this.pinchFocusX > 0 ? this.pinchFocusX : (this.viewportWidth / 2);
                const dx = focusX - this.viewportWidth / 2;
                const worldX = (dx - this.pinchStartOffsetX) / this.pinchStartZoom;
                this.offsetX = dx - worldX * settled;
              } else {
                this.offsetX = 0;
              }
              // 回到已夹的缩放值；isGesturing 已置 false，外层 .animation 会把越界量平滑收回
              this.zoom = settled;
              this.clampOffsets();
              this.syncSettledZoomPad();
            })
            .onActionCancel(() => {
              this.isGesturing = false;
              const settled = Math.max(1.0, Math.min(RenderUtils.ZOOM_MAX, this.zoom));
              if (settled > 1.05 && this.pinchStartZoom > 0) {
                const focusX = this.pinchFocusX > 0 ? this.pinchFocusX : (this.viewportWidth / 2);
                const dx = focusX - this.viewportWidth / 2;
                const worldX = (dx - this.pinchStartOffsetX) / this.pinchStartZoom;
                this.offsetX = dx - worldX * settled;
              } else {
                this.offsetX = 0;
              }
              this.zoom = settled;
              this.clampOffsets();
              this.syncSettledZoomPad();
            }),
          PanGesture({ direction: PanDirection.Horizontal })
            .onActionStart(() => {
              this.isGesturing = true;
              this.panStartX = this.offsetX;
            })
            .onActionUpdate((event: GestureEvent) => {
              if (this.zoom > 1.05) {
                this.offsetX = this.panStartX + event.offsetX;
                this.clampOffsets();
              }
            })
            .onActionEnd(() => {
              this.isGesturing = false;
            })
            .onActionCancel(() => {
              this.isGesturing = false;
            })
        )
      )
    }
  }
}

/**
 * DOCX 内嵌图片异步解码与展示组件
 */
@Reusable
@Component
struct DocxImageView {
  element: model.Element | null = null;
  imageStore: ImageStore = new ImageStore('');

  @State pixelMap: image.PixelMap | null = null;
  @State isLoading: boolean = true;
  @State loadFailed: boolean = false;
  private isDisappeared: boolean = false;
  private acquiredPart: string = '';
  private loadGeneration: number = 0;
  private settings: RenderingContextSettings = new RenderingContextSettings(true);
  private cropCtx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings);
  private cropCanvasReady: boolean = false;

  aboutToAppear(): void {
    this.isDisappeared = false;
    this.loadImage();
  }

  aboutToDisappear(): void {
    this.loadGeneration++;
    this.isDisappeared = true;
    this.cropCanvasReady = false;
    this.pixelMap = null;
    if (this.acquiredPart) {
      this.imageStore.releasePart(this.acquiredPart);
      this.acquiredPart = '';
    }
  }

  aboutToRecycle(): void {
    this.loadGeneration++;
    if (this.acquiredPart) {
      this.imageStore.releasePart(this.acquiredPart);
      this.acquiredPart = '';
    }
    this.pixelMap = null;
    this.cropCanvasReady = false;
  }

  aboutToReuse(params: Record<string, Object>): void {
    this.isDisappeared = false;
    this.element = params['element'] as model.Element;
    if (params['imageStore']) {
      this.imageStore = params['imageStore'] as ImageStore;
    }
    this.loadImage();
  }

  private hasCustomBoundsOrFrame(): boolean {
    if (!this.element) return false;
    if (this.element.stroke !== 0 || this.element.fill !== 0 || this.element.fillGradient) {
      return true;
    }
    const ib = this.element.imageBounds;
    if (!ib || ib.length < 4) return false;
    const w = this.element.width ?? 0;
    const h = this.element.height ?? 0;
    return Math.abs(ib[0]) > 0.1 || Math.abs(ib[1]) > 0.1 || Math.abs(ib[2] - w) > 0.5 || Math.abs(ib[3] - h) > 0.5;
  }

  private drawCroppedImage(): void {
    if (!this.cropCanvasReady || !this.element || !this.pixelMap) return;
    const w = this.cropCtx.width;
    const h = this.cropCtx.height;
    if (w <= 0 || h <= 0) return;
    const elW = this.element.width > 0 ? this.element.width : w;
    const elH = this.element.height > 0 ? this.element.height : h;
    const ctx = this.cropCtx;
    ctx.clearRect(0, 0, w, h);
    ctx.save();
    const scale = Math.min(w / elW, h / elH);
    ctx.scale(scale, scale);
    CanvasElementDrawer.drawElement(ctx, this.element, this.imageStore.cache);
    ctx.restore();
  }

  private computePartBudget(): number {
    const w = this.element?.width && this.element.width > 0 ? this.element.width : 720;
    const h = this.element?.height && this.element.height > 0 ? this.element.height : 480;
    return Math.max(100_000, Math.min(4_000_000, Math.round(w * h * 2.25)));
  }

  private async loadImage(): Promise<void> {
    const part = this.element?.image;
    if (!part) {
      this.isLoading = false;
      this.loadFailed = true;
      return;
    }
    if (this.acquiredPart && this.acquiredPart !== part) {
      this.imageStore.releasePart(this.acquiredPart);
    }
    this.acquiredPart = part;
    this.imageStore.acquire(part);
    const cached = this.imageStore.cache.get(part);
    if (cached) {
      this.pixelMap = cached;
      this.isLoading = false;
      this.drawCroppedImage();
      return;
    }
    const currentGen = ++this.loadGeneration;
    this.isLoading = true;
    this.loadFailed = false;
    try {
      const budget = this.computePartBudget();
      await this.imageStore.load(part, budget);
      if (this.isDisappeared || this.loadGeneration !== currentGen || this.acquiredPart !== part) return;
      const loaded = this.imageStore.cache.get(part);
      if (loaded) {
        this.pixelMap = loaded;
        this.drawCroppedImage();
      } else {
        this.loadFailed = true;
      }
    } catch (_e) {
      if (!this.isDisappeared && this.loadGeneration === currentGen) {
        this.loadFailed = true;
      }
    } finally {
      if (!this.isDisappeared && this.loadGeneration === currentGen) {
        this.isLoading = false;
      }
    }
  }

  build() {
    Row() {
      if (this.pixelMap) {
        if (this.hasCustomBoundsOrFrame()) {
          Canvas(this.cropCtx)
            .width(this.element?.width && this.element.width > 0 ? this.element.width : '100%')
            .height(this.element?.height && this.element.height > 0 ? this.element.height : 180)
            .aspectRatio(
              this.element?.width && this.element?.height && this.element.width > 0 && this.element.height > 0
                ? (this.element.width / this.element.height)
                : undefined
            )
            .constraintSize({ maxWidth: '100%' })
            .onReady(() => {
              this.cropCanvasReady = true;
              this.drawCroppedImage();
            })
            .onAreaChange(() => {
              this.drawCroppedImage();
            })
        } else if (this.element?.width && this.element?.height && this.element.width > 0 && this.element.height > 0) {
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

/**
 * DOCX 矢量图形块 (RECT / ELLIPSE / LINE / PATH) 绘制组件
 */
@Reusable
@Component
struct DocxShapeView {
  element: model.Element | null = null;
  imageStore: ImageStore = new ImageStore('');
  @State private reuseVersion: number = 0;

  private settings: RenderingContextSettings = new RenderingContextSettings(true);
  private ctx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings);
  private isReady: boolean = false;

  aboutToReuse(params: Record<string, Object>): void {
    if (params['element']) {
      this.element = params['element'] as model.Element;
    }
    if (params['imageStore']) {
      this.imageStore = params['imageStore'] as ImageStore;
    }
    this.reuseVersion++;
    if (this.isReady) {
      this.drawShape();
    }
  }

  private drawShape(): void {
    if (!this.isReady || !this.element) return;
    const w = this.ctx.width;
    const h = this.ctx.height;
    if (w <= 0 || h <= 0) return;
    const elW = this.element.width > 0 ? this.element.width : w;
    const elH = this.element.height > 0 ? this.element.height : h;
    const ctx = this.ctx;
    ctx.clearRect(0, 0, w, h);
    ctx.save();
    const scale = Math.min(w / elW, h / elH);
    ctx.scale(scale, scale);
    CanvasElementDrawer.drawElement(ctx, this.element, this.imageStore.cache);
    ctx.restore();
  }

  build() {
    if (this.element) {
      Row() {
        Canvas(this.ctx)
          .width(this.element.width && this.element.width > 0 ? this.element.width : '100%')
          .height(this.element.height && this.element.height > 0 ? this.element.height : 100)
          .constraintSize({ maxWidth: '100%' })
          .onReady(() => {
            this.isReady = true;
            this.drawShape();
          })
          .onAreaChange(() => {
            this.drawShape();
          })
      }
      .id(`shape-${this.reuseVersion}`)
      .width('100%')
      .justifyContent(FlexAlign.Center)
      .margin({ top: 4, bottom: 6 })
    }
  }
}

@Component
struct DocxParagraphView {
  para: model.Paragraph | null = null;

  private calcLineHeight(): number | undefined {
    if (!this.para || !this.para.runs || this.para.runs.length === 0) return undefined;
    let maxFontSize = 14;
    for (const r of this.para.runs) {
      if (r.size && r.size > maxFontSize) maxFontSize = r.size;
    }
    if (this.para.lineSpacingRule === 'EXACT') {
      return Math.max(1, this.para.lineSpacing || (maxFontSize * 1.2));
    }
    if (this.para.lineSpacingRule === 'AT_LEAST') {
      return Math.max(maxFontSize * 1.2, this.para.lineSpacing || (maxFontSize * 1.2));
    }
    if (this.para.lineSpacing && this.para.lineSpacing > 0 && Math.abs(this.para.lineSpacing - 1.0) > 0.05) {
      return Math.max(1, maxFontSize * 1.2 * this.para.lineSpacing);
    }
    return undefined;
  }

  build() {
    if (this.para) {
      Text() {
        if (this.para.bullet) {
          Span(`${this.para.bullet}`)
            .fontSize(this.para.runs && this.para.runs.length > 0 ? (this.para.runs[0].size || 14) : 14)
            .fontColor(
              this.para.runs && this.para.runs.length > 0
                ? (RenderUtils.argbToCss(this.para.runs[0].color) ?? '#202124')
                : '#202124'
            )
            .fontWeight(
              this.para.runs && this.para.runs.length > 0 && RenderUtils.resolveFontBold(this.para.runs[0].fontFace, this.para.runs[0].bold)
                ? FontWeight.Bold
                : FontWeight.Normal
            )
            .fontStyle(
              this.para.runs && this.para.runs.length > 0 && this.para.runs[0].italic
                ? FontStyle.Italic
                : FontStyle.Normal
            )
        }
        ForEach(
          this.para.runs,
          (run: model.Run) => {
            Span(run.text)
              .fontSize(run.size || 14)
              .fontFamily(RenderUtils.resolveFontFamily(run.fontFace, false))
              .fontColor(RenderUtils.argbToCss(run.color) ?? '#202124')
              .fontWeight(RenderUtils.resolveFontBold(run.fontFace, run.bold) ? FontWeight.Bold : FontWeight.Normal)
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
      .textIndent(this.para.firstLineIndent && this.para.firstLineIndent > 0 ? this.para.firstLineIndent : 0)
      .lineHeight(this.calcLineHeight())
      .margin({
        top: this.para.before ?? 2,
        bottom: this.para.after ?? 4,
        left: Math.max(0, this.para.indent ?? 0),
        right: Math.max(0, this.para.rightIndent ?? 0)
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

@Reusable
@Component
struct DocxTextBlockView {
  element: model.Element | null = null;
  @State private reuseVersion: number = 0;

  aboutToReuse(params: Record<string, Object>): void {
    if (params['element']) {
      this.element = params['element'] as model.Element;
      this.reuseVersion++;
    }
  }

  build() {
    if (this.element && this.element.paragraphs) {
      Column({ space: 4 }) {
        ForEach(
          this.element.paragraphs,
          (para: model.Paragraph) => {
            DocxParagraphView({ para: para })
          },
          (_para: model.Paragraph, pIdx: number) => `p-${pIdx}-${this.reuseVersion}`
        )
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
  }
}

@Reusable
@Component
struct DocxTableView {
  element: model.Element | null = null;
  @State private reuseVersion: number = 0;

  aboutToReuse(params: Record<string, Object>): void {
    if (params['element']) {
      this.element = params['element'] as model.Element;
      this.reuseVersion++;
    }
  }

  build() {
    if (this.element) {
      Column() {
        ForEach(
          this.element.rows ?? [],
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
                      (_p: model.Paragraph, pIdx: number) => `cp-${pIdx}-${this.reuseVersion}`
                    )
                  }
                  .layoutWeight(Math.max(1, this.element?.columnWidths?.[cIdx] ?? 1))
                  .padding(6)
                  .border({ width: 0.5, color: '#b7bec7' })
                  .backgroundColor(RenderUtils.argbToCss(this.element?.cellFills?.[rIdx]?.[cIdx] ?? 0) ?? '#ffffff')
                },
                (_cell: model.Paragraph[], cIdx: number) => `c-${rIdx}-${cIdx}-${this.reuseVersion}`
              )
            }
            .width('100%')
          },
          (_row: model.Paragraph[][], rIdx: number) => `r-${rIdx}-${this.reuseVersion}`
        )
      }
      .width(this.element.width && this.element.width > 0 ? this.element.width : '100%')
      .constraintSize({ maxWidth: '100%' })
      .margin({ top: 8, bottom: 8 })
    }
  }
}

interface PptxPageLayout {
  readonly page: model.Page;
  readonly y: number;
  readonly width: number;
  readonly height: number;
}

/**
 * 为读屏软件生成幻灯片文本摘要：Canvas 自绘内容本身不可被朗读，需显式提供等效文本
 */
function buildSlideAccessibilityLabel(page: model.Page | null, slideNumber: number, slideCount: number): string {
  const lead = `幻灯片第 ${slideNumber} 页，共 ${slideCount} 页`;
  if (!page) return lead;
  const texts: string[] = [];
  let length = 0;
  const appendRuns = (runs: model.Run[] | undefined): void => {
    for (const run of runs ?? []) {
      if (!run.text || length >= 200) return;
      texts.push(run.text);
      length += run.text.length;
    }
  };
  for (const element of page.elements ?? []) {
    for (const para of element.paragraphs ?? []) appendRuns(para.runs);
    for (const row of element.rows ?? []) {
      for (const cell of row) {
        for (const para of cell) appendRuns(para.runs);
      }
    }
  }
  return texts.length === 0 ? `${lead}，无文本内容` : `${lead}：${texts.join('')}`;
}

@Component
struct PptxSlidesView {
  document: model.OfficeDocument | null = null;
  filePath: string = '';
  onSlideChange?: (pageNumber: number, pageCount: number) => void;
  registerControls?: (
    jumpToPage: (pageNumber: number) => void,
    getZoom: () => number,
    setZoom: (value: number) => void
  ) => void;

  private imageStore: ImageStore = new ImageStore('');
  private settings: RenderingContextSettings = new RenderingContextSettings(true);
  private ctx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings);
  private isReady: boolean = false;
  private isDisappeared: boolean = false;

  private pageLayouts: PptxPageLayout[] = [];
  private contentWidth: number = 720;
  private contentHeight: number = 405;

  private canvasWidth: number = 0;
  private canvasHeight: number = 0;

  // Viewport transforms (正向世界坐标与偏移，完全对齐 Android 端 OfficePreviewView)
  private zoom: number = 1.0;
  private rawZoom: number = 1.0;
  private offsetX: number = 0;
  private offsetY: number = 0;

  // Gestures
  private isPinching: boolean = false;
  private pinchStartZoom: number = 1.0;
  private pinchFocusX: number = 0;
  private pinchFocusY: number = 0;
  private panStartX: number = 0;
  private panStartY: number = 0;

  // Momentum Fling (via displaySync 120Hz)
  private vsync: displaySync.DisplaySync | null = null;
  private flingRunning: boolean = false;
  private flingVx: number = 0;
  private flingVy: number = 0;
  private lastVsyncTimestamp: number = 0;
  private lastFlingTime: number = 0;
  private flingTimer: number = -1;

  // Zoom Tween animation (双击平滑补间与越界回弹)
  private zoomTweenTimer: number = -1;
  private zoomTweenStart: number = 0;
  private zoomTweenFrom: number = 1.0;
  private zoomTweenTo: number = 1.0;
  private zoomTweenFocusX: number = 0;
  private zoomTweenFocusY: number = 0;
  private zoomTweenDuration: number = 0;

  // Page tracking & Accessibility
  @State private currentPage: number = 1;
  private totalPages: number = 0;
  private notifiedPage: number = 0;
  private pendingJumpPage: number = 0;
  private redrawTimer: number = -1;
  private readonly loadingParts: Set<string> = new Set();
  private loadGeneration: number = 0;

  aboutToAppear(): void {
    this.isDisappeared = false;
    this.imageStore = new ImageStore(this.filePath);
    this.initLayouts();
    if (this.registerControls) {
      this.registerControls(
        (pageNumber: number): void => {
          this.jumpToPage(pageNumber);
        },
        (): number => this.zoom,
        (value: number): void => {
          this.startZoomTween(value, this.canvasWidth / 2, this.canvasHeight / 2, RenderUtils.ZOOM_ANIMATION_MS);
        }
      );
    }
  }

  aboutToDisappear(): void {
    this.loadGeneration++;
    this.isDisappeared = true;
    this.isReady = false;
    this.stopFling();
    this.stopZoomTween();
    if (this.vsync) {
      try {
        this.vsync.off('frame');
      } catch (_e) {}
      this.vsync = null;
    }
    if (this.flingTimer !== -1) {
      clearTimeout(this.flingTimer);
      this.flingTimer = -1;
    }
    if (this.redrawTimer !== -1) {
      clearTimeout(this.redrawTimer);
      this.redrawTimer = -1;
    }
    this.imageStore.release();
  }

  private initLayouts(): void {
    this.pageLayouts = [];
    let totalH = 0;
    let maxW = 720;
    const pages = this.document?.pages ?? [];
    this.totalPages = pages.length;
    for (const page of pages) {
      const pW = page.width && page.width > 0 ? page.width : 720;
      const pH = page.height && page.height > 0 ? page.height : 405;
      this.pageLayouts.push({ page, y: totalH, width: pW, height: pH });
      totalH += pH + 16;
      if (pW > maxW) maxW = pW;
    }
    this.contentWidth = maxW;
    this.contentHeight = Math.max(0, totalH - 16);
    this.currentPage = this.totalPages > 0 ? 1 : 0;
    this.notifiedPage = this.currentPage;
  }

  private baseScale(): number {
    return this.contentWidth > 0 ? Math.max(0.1, (this.canvasWidth - 24) / this.contentWidth) : 1.0;
  }

  private getScale(): number {
    return this.baseScale() * this.zoom;
  }

  private getLeft(): number {
    const s = this.getScale();
    return Math.max(0, (this.canvasWidth - this.contentWidth * s) / 2);
  }

  private getTop(): number {
    return 12;
  }

  private maxX(): number {
    const s = this.getScale();
    return Math.max(0, Math.round(this.contentWidth * s - this.canvasWidth));
  }

  private maxY(): number {
    const s = this.getScale();
    return Math.max(0, Math.round(this.contentHeight * s + 2 * this.getTop() - this.canvasHeight));
  }

  private clampOffsets(): void {
    this.offsetX = Math.max(0, Math.min(this.maxX(), this.offsetX));
    this.offsetY = Math.max(0, Math.min(this.maxY(), this.offsetY));
  }

  private clampZoom(val: number): number {
    return Math.max(1.0, Math.min(RenderUtils.ZOOM_MAX, val));
  }

  private applyZoomAt(newZoom: number, focusX: number, focusY: number): void {
    const prevScale = this.getScale();
    let worldX = 0;
    let worldY = 0;
    if (prevScale > 0) {
      worldX = (focusX + this.offsetX - this.getLeft()) / prevScale;
      worldY = (focusY + this.offsetY - this.getTop()) / prevScale;
    }
    this.zoom = newZoom;
    const newScale = this.getScale();
    if (prevScale > 0 && newScale > 0) {
      this.offsetX = worldX * newScale - focusX + this.getLeft();
      this.offsetY = worldY * newScale - focusY + this.getTop();
    }
    this.clampOffsets();
  }

  private updateCurrentPage(): void {
    if (this.pageLayouts.length === 0 || this.canvasWidth <= 0 || this.canvasHeight <= 0) return;
    const s = this.getScale();
    if (s <= 0) return;
    const visibleTop = (this.offsetY - this.getTop()) / s;
    const visibleBottom = visibleTop + this.canvasHeight / s;
    let bestPage = Math.max(1, this.currentPage);
    let bestVisible = -1;
    for (let i = 0; i < this.pageLayouts.length; i++) {
      const page = this.pageLayouts[i];
      const visible = Math.max(0, Math.min(visibleBottom, page.y + page.height) - Math.max(visibleTop, page.y));
      if (visible > bestVisible + 0.01 || (Math.abs(visible - bestVisible) <= 0.01 && i + 1 === this.currentPage)) {
        bestVisible = visible;
        bestPage = i + 1;
      }
    }
    this.currentPage = bestPage;
    if (this.notifiedPage !== this.currentPage) {
      this.notifiedPage = this.currentPage;
      if (this.onSlideChange) {
        this.onSlideChange(this.currentPage, this.totalPages);
      }
    }
  }

  public jumpToPage(pageNumber: number): void {
    if (pageNumber < 1 || pageNumber > this.pageLayouts.length) return;
    if (this.canvasWidth <= 0 || this.canvasHeight <= 0) {
      this.pendingJumpPage = pageNumber;
      return;
    }
    this.pendingJumpPage = 0;
    this.stopFling();
    this.stopZoomTween();
    const targetLayout = this.pageLayouts[pageNumber - 1];
    const s = this.getScale();
    this.offsetX = 0;
    this.offsetY = targetLayout.y * s;
    this.clampOffsets();
    this.updateCurrentPage();
    this.redraw();
  }

  private stopFling(): void {
    this.flingRunning = false;
    this.lastVsyncTimestamp = 0;
    if (this.vsync) {
      try {
        this.vsync.stop();
      } catch (_e) {}
    }
    if (this.flingTimer !== -1) {
      clearTimeout(this.flingTimer);
      this.flingTimer = -1;
    }
    this.flingVx = 0;
    this.flingVy = 0;
  }

  private startFling(vx: number, vy: number): void {
    this.stopFling();
    const maxVelocity = 4000;
    const currentV = Math.hypot(vx, vy);
    if (currentV > maxVelocity) {
      const ratio = maxVelocity / currentV;
      vx *= ratio;
      vy *= ratio;
    }
    this.flingVx = vx;
    this.flingVy = vy;
    this.flingRunning = true;
    this.lastVsyncTimestamp = 0;
    this.lastFlingTime = Date.now();

    if (!this.vsync) {
      try {
        this.vsync = displaySync.create();
        this.vsync.on('frame', (frameInfo: displaySync.IntervalInfo) => {
          if (!this.flingRunning) return;
          const ts = frameInfo.timestamp;
          let dt = 0.016;
          if (this.lastVsyncTimestamp > 0 && ts > this.lastVsyncTimestamp) {
            dt = Math.min(0.032, Math.max(0.001, (ts - this.lastVsyncTimestamp) / 1e9));
          }
          this.lastVsyncTimestamp = ts;
          this.stepFlingWithDt(dt);
        });
      } catch (_e) {
        this.vsync = null;
      }
    }

    if (this.vsync) {
      try {
        this.vsync.start();
      } catch (_e) {
        this.vsync = null;
        this.flingTimer = setTimeout(this.stepFlingFallback, 16);
      }
    } else {
      this.flingTimer = setTimeout(this.stepFlingFallback, 16);
    }
  }

  private stepFlingWithDt(dt: number): void {
    if (!this.flingRunning || (this.flingVx === 0 && this.flingVy === 0)) {
      this.stopFling();
      return;
    }

    const friction = 2.8;
    const decay = Math.exp(-friction * dt);
    this.flingVx *= decay;
    this.flingVy *= decay;

    if (Math.hypot(this.flingVx, this.flingVy) < 25) {
      this.stopFling();
      return;
    }

    const prevX = this.offsetX;
    const prevY = this.offsetY;
    this.offsetX += this.flingVx * dt;
    this.offsetY += this.flingVy * dt;
    this.clampOffsets();

    if (this.offsetX === prevX) this.flingVx = 0;
    if (this.offsetY === prevY) this.flingVy = 0;

    this.updateCurrentPage();

    if (this.flingVx === 0 && this.flingVy === 0) {
      this.stopFling();
      this.redraw();
      return;
    }

    this.redraw();
  }

  private stepFlingFallback = (): void => {
    if (!this.flingRunning) return;
    const now = Date.now();
    const dt = Math.min(0.032, Math.max(0.001, (now - this.lastFlingTime) / 1000));
    this.lastFlingTime = now;
    this.stepFlingWithDt(dt);
    if (this.flingRunning) {
      this.flingTimer = setTimeout(this.stepFlingFallback, 16);
    }
  };

  private stopZoomTween(): void {
    if (this.zoomTweenTimer >= 0) {
      clearTimeout(this.zoomTweenTimer);
      this.zoomTweenTimer = -1;
    }
  }

  private startZoomTween(target: number, focusX: number, focusY: number, duration: number): void {
    this.stopZoomTween();
    const from = this.zoom;
    const to = this.clampZoom(target);
    if (duration <= 0 || Math.abs(to - from) < 0.002) {
      this.applyZoomAt(to, focusX, focusY);
      this.rawZoom = to;
      this.updateCurrentPage();
      this.redraw();
      return;
    }
    this.zoomTweenFrom = from;
    this.zoomTweenTo = to;
    this.zoomTweenFocusX = focusX;
    this.zoomTweenFocusY = focusY;
    this.zoomTweenDuration = duration;
    this.zoomTweenStart = Date.now();
    this.stepZoomTween();
  }

  private stepZoomTween = (): void => {
    this.zoomTweenTimer = -1;
    const elapsed = Date.now() - this.zoomTweenStart;
    const progress = this.zoomTweenDuration > 0 ? Math.min(1, elapsed / this.zoomTweenDuration) : 1;
    const eased = 1 - Math.pow(1 - progress, 3);
    const z = this.zoomTweenFrom + (this.zoomTweenTo - this.zoomTweenFrom) * eased;
    this.applyZoomAt(z, this.zoomTweenFocusX, this.zoomTweenFocusY);
    this.updateCurrentPage();
    this.redraw();
    if (progress < 1) {
      this.zoomTweenTimer = setTimeout(this.stepZoomTween, 16);
    } else {
      this.rawZoom = this.zoom;
    }
  };

  private settlePinchZoom(): void {
    const settled = this.clampZoom(this.zoom);
    if (Math.abs(settled - this.zoom) <= 0.002) {
      this.rawZoom = this.zoom;
      return;
    }
    const focusX = this.pinchFocusX > 0 ? this.pinchFocusX : (this.canvasWidth / 2);
    const focusY = this.pinchFocusY > 0 ? this.pinchFocusY : (this.canvasHeight / 2);
    this.startZoomTween(settled, focusX, focusY, RenderUtils.ZOOM_ANIMATION_MS);
  }

  private scheduleRedraw(): void {
    if (this.redrawTimer !== -1 || this.isDisappeared) return;
    this.redrawTimer = setTimeout(() => {
      this.redrawTimer = -1;
      if (!this.isDisappeared) {
        this.drawPptx();
      }
    }, 16);
  }

  private redraw(): void {
    this.drawPptx();
  }

  private requestVisibleImages(parts: string[]): void {
    for (const part of parts) {
      if (this.imageStore.cache.has(part) || this.loadingParts.has(part)) {
        continue;
      }
      this.loadingParts.add(part);
      this.imageStore.acquire(part);
      const gen = this.loadGeneration;
      this.imageStore.load(part).then((updated: boolean) => {
        this.loadingParts.delete(part);
        if (updated && !this.isDisappeared && this.loadGeneration === gen) {
          this.scheduleRedraw();
        }
      });
    }
  }

  private drawPptx(): void {
    if (!this.isReady || !this.document || this.canvasWidth <= 0 || this.canvasHeight <= 0) return;
    const ctx = this.ctx;
    const w = this.canvasWidth;
    const h = this.canvasHeight;

    ctx.clearRect(0, 0, w, h);

    // 全局背景底色：对齐 Android 端的 #e9ecef
    ctx.fillStyle = '#e9ecef';
    ctx.fillRect(0, 0, w, h);

    const scale = this.getScale();
    const left = this.getLeft();
    const top = this.getTop();

    const visibleTop = (this.offsetY - top) / scale;
    const visibleBottom = visibleTop + h / scale;

    ctx.save();
    ctx.translate(left - this.offsetX, top - this.offsetY);
    ctx.scale(scale, scale);

    const neededImageParts: string[] = [];

    for (let i = 0; i < this.pageLayouts.length; i++) {
      const layout = this.pageLayouts[i];
      // 视口裁剪：只绘制可见范围内的幻灯片
      if (layout.y + layout.height < visibleTop || layout.y > visibleBottom) {
        continue;
      }

      const slideLeft = (this.contentWidth - layout.width) / 2;

      ctx.save();
      ctx.translate(slideLeft, layout.y);

      // 1. 幻灯片白色/纯色卡片底色及淡灰色分割边框
      const bgCss = RenderUtils.argbToCss(layout.page.background) ?? '#ffffff';
      ctx.fillStyle = bgCss;
      ctx.fillRect(0, 0, layout.width, layout.height);

      ctx.strokeStyle = '#ced4da';
      ctx.lineWidth = 0.6;
      ctx.strokeRect(0, 0, layout.width, layout.height);

      // 2. 局部剪裁至单张 Slide 边界
      ctx.beginPath();
      ctx.rect(0, 0, layout.width, layout.height);
      ctx.clip();

      // 3. 矢量元素与图片绘制
      if (layout.page.elements) {
        for (const element of layout.page.elements) {
          if (element.type === 'IMAGE' && element.image) {
            neededImageParts.push(element.image);
          }
          CanvasElementDrawer.drawElement(ctx, element, this.imageStore.cache);
        }
      }

      ctx.restore();
    }

    ctx.restore();

    if (neededImageParts.length > 0) {
      this.requestVisibleImages(neededImageParts);
    }
  }

  private currentSlideAccessibilityLabel(): string {
    const currentIdx = Math.max(0, this.currentPage - 1);
    const page = this.pageLayouts[currentIdx]?.page ?? null;
    return buildSlideAccessibilityLabel(page, this.currentPage, this.totalPages);
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      Canvas(this.ctx)
        .width(this.canvasWidth > 0 ? this.canvasWidth : '100%')
        .height(this.canvasHeight > 0 ? this.canvasHeight : '100%')
        .onReady(() => {
          this.isReady = true;
          this.drawPptx();
        })
        .onAreaChange((_oldArea: Area, newArea: Area) => {
          const areaW = Number(newArea.width);
          const areaH = Number(newArea.height);
          if (areaW > 0) this.canvasWidth = areaW;
          if (areaH > 0) this.canvasHeight = areaH;
          if (this.isReady) {
            this.clampOffsets();
            if (this.pendingJumpPage > 0) {
              this.jumpToPage(this.pendingJumpPage);
            } else {
              this.drawPptx();
            }
          }
        })
        .gesture(
          GestureGroup(
            GestureMode.Parallel,
            TapGesture({ count: 2 })
              .onAction((event: GestureEvent) => {
                this.stopFling();
                const focusX = event.fingerList && event.fingerList.length > 0
                  ? event.fingerList[0].localX
                  : (this.canvasWidth / 2);
                const focusY = event.fingerList && event.fingerList.length > 0
                  ? event.fingerList[0].localY
                  : (this.canvasHeight / 2);
                const targetZoom = this.zoom > 1.1 ? 1.0 : 2.0;
                this.startZoomTween(targetZoom, focusX, focusY, RenderUtils.ZOOM_ANIMATION_MS);
              }),
            PinchGesture({ fingers: 2 })
              .onActionStart(() => {
                this.stopFling();
                this.stopZoomTween();
                this.isPinching = true;
                this.pinchStartZoom = this.clampZoom(this.zoom);
              })
              .onActionUpdate((event: GestureEvent) => {
                const focusX = event.pinchCenterX > 0 ? event.pinchCenterX : (this.canvasWidth / 2);
                const focusY = event.pinchCenterY > 0 ? event.pinchCenterY : (this.canvasHeight / 2);
                this.pinchFocusX = focusX;
                this.pinchFocusY = focusY;
                const raw = this.pinchStartZoom * event.scale;
                const settled = this.clampZoom(raw);
                const excess = raw - settled;
                const display = settled + RenderUtils.rubberBandZoom(
                  excess, excess > 0 ? RenderUtils.ZOOM_OVERFLOW_ABOVE : RenderUtils.ZOOM_OVERFLOW_BELOW);
                this.applyZoomAt(display, focusX, focusY);
                this.updateCurrentPage();
                this.redraw();
              })
              .onActionEnd(() => {
                this.isPinching = false;
                this.panStartX = this.offsetX;
                this.panStartY = this.offsetY;
                this.settlePinchZoom();
              })
              .onActionCancel(() => {
                this.isPinching = false;
                this.panStartX = this.offsetX;
                this.panStartY = this.offsetY;
                this.settlePinchZoom();
              }),
            PanGesture()
              .onActionStart(() => {
                if (this.isPinching) return;
                this.stopFling();
                this.panStartX = this.offsetX;
                this.panStartY = this.offsetY;
              })
              .onActionUpdate((event: GestureEvent) => {
                if (this.isPinching) return;
                this.stopFling();
                this.offsetX = this.panStartX - event.offsetX;
                this.offsetY = this.panStartY - event.offsetY;
                this.clampOffsets();
                this.updateCurrentPage();
                this.redraw();
              })
              .onActionEnd((event: GestureEvent) => {
                if (this.isPinching) return;
                const vx = event.velocityX ?? 0;
                const vy = event.velocityY ?? 0;
                if (Math.hypot(vx, vy) > 80) {
                  this.startFling(-vx, -vy);
                }
              })
          )
        )
        .accessibilityGroup(true)
        .accessibilityText(this.currentSlideAccessibilityLabel())

      if (this.totalPages > 1) {
        Text(`${this.currentPage} / ${this.totalPages}`)
          .fontSize(12)
          .fontColor('#ffffff')
          .backgroundColor('#8a000000')
          .borderRadius(14)
          .padding({ left: 12, right: 12, top: 4, bottom: 4 })
          .margin({ bottom: 20 })
          .hitTestBehavior(HitTestMode.None)
      }
    }
    .width('100%')
    .height('100%')
    .clip(true)
  }
}
