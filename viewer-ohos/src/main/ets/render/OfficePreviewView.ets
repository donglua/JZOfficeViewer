import { image } from '@kit.ImageKit';
import { displaySync } from '@kit.ArkGraphics2D';
import * as model from '../core/OfficeModel';
import { NativeCore } from '../core/NativeCore';
import { RenderUtils } from './RenderUtils';
import { CanvasElementDrawer, CanvasTextLineMetrics, OfficeRect, WrapObstacle } from './CanvasElementDrawer';
import {
  DocxWrapBlockInput,
  DocxWrapGroupPlan,
  isDocxFloatingWrap,
  planDocxWrapGroups,
  resolveDocxFloatBox,
  resolveDocxItemTopMargin
} from './DocxWrapLayout';
import { ImageStore } from './ImageStore';
import { SpreadsheetView } from './SpreadsheetView';
import { OfficeSearchBar } from './OfficeSearchBar';
import {
  PptxViewportPage,
  resolvePptxCurrentPage,
  resolvePptxVisibleRange
} from './PptxViewport';
import { SelectionMenuBubble, copyTextToPasteboard } from './SelectionMenuBubble';
import {
  BlockHighlightRect,
  DocumentTextLayout,
  TextBlockLayout,
  TextLineMetrics,
  TextPosition,
  TextRect,
  TextSelection,
  isSelectionEmpty,
  makeTextPosition,
  makeTextRect,
  makeTextSelection
} from './TextSelectionModel';

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

// MARK: - 文本选区公共常量与工具

/** 水滴手柄半径（vp），固定物理尺寸不随缩放变化 */
const SELECTION_HANDLE_RADIUS: number = 10;
/** 手柄命中热区半径（vp），略大于视觉半径以便手指按住 */
const SELECTION_HANDLE_HIT_RADIUS: number = 24;
/** 手柄圆心相对光标底端的下移量（vp），避免指腹遮挡选区端点 */
const SELECTION_HANDLE_DROP: number = 14;
/** 拖选时向命中测试传入的 Y 坐标上移补偿（vp），抵消指腹遮挡 */
const SELECTION_TOUCH_LIFT: number = 20;
/** 边缘自动滚动热区（vp） */
const SELECTION_EDGE_SCROLL_ZONE: number = 36;
/** 边缘自动滚动单帧最大步长（vp） */
const SELECTION_EDGE_SCROLL_MAX_STEP: number = 12;
/** 边缘自动滚动步进间隔（ms） */
const SELECTION_EDGE_SCROLL_INTERVAL: number = 16;
/** 长按选词触发时长（ms），与设计稿一致 */
const SELECTION_LONG_PRESS_MS: number = 400;
/** 手柄/选区不可见时使用的哨兵坐标，叠加层据此跳过绘制 */
const SELECTION_HIDDEN_COORD: number = -100000;
/** 选区高亮色（与 CanvasElementDrawer.drawSelectionHighlights 一致） */
const SELECTION_LINE_COLOR: string = '#1a73e8';

/** 二维点（避免借用文档位置类型承载坐标） */
interface PlanePoint {
  x: number;
  y: number;
}

/** ListItem 在未缩放的 List 容器坐标系下的矩形 */
interface DocxItemRect {
  x: number;
  y: number;
  width: number;
  height: number;
}

/** 选区手柄在屏幕坐标系下的锚点（x 固定，topY/bottomY 为光标竖线端点） */
interface SelectionHandleAnchor {
  x: number;
  y: number;
  bottomY: number;
}

/** 选区叠加层几何：一次性以数组传给子组件，避免多个 @Prop 各自触发重绘 */
interface SelectionOverlayGeometry {
  readonly startX: number;
  readonly startTopY: number;
  readonly startBottomY: number;
  readonly endX: number;
  readonly endTopY: number;
  readonly endBottomY: number;
}

/** 恒等仿射变换；每次返回新数组，避免共享可变矩阵被就地修改 */
function identityTransform(): number[] {
  const matrix: number[] = [1, 0, 0, 1, 0, 0];
  return matrix;
}

/** 由行度量推导块的容器局部包围框（行几何为空时退化为零矩形） */
function boundsFromLines(lines: TextLineMetrics[]): TextRect {
  if (lines.length === 0) {
    return makeTextRect(0, 0, 0, 0);
  }
  let left = lines[0].left;
  let top = lines[0].top;
  let right = lines[0].right;
  let bottom = lines[0].bottom;
  for (const line of lines) {
    if (line.left < left) left = line.left;
    if (line.top < top) top = line.top;
    if (line.right > right) right = line.right;
    if (line.bottom > bottom) bottom = line.bottom;
  }
  return makeTextRect(left, top, right, bottom);
}

/**
 * 构造一个「容器局部坐标 + 恒等变换」的文本块。
 *
 * 视图层各渲染单元的坐标系互不相同（ListItem 局部、绕排组画布局部、幻灯片内容坐标），
 * 因此统一在构建时把行度量平移到目标坐标系并把仿射矩阵归一为恒等矩阵：
 * 命中测试、选区矩形与手柄几何随后都只需处理轴对齐坐标，不再依赖逆矩阵。
 * 代价是旋转/翻转元素的高亮包围框按轴对齐外接矩形近似（复制出的文本仍然精确）。
 */
function makeContainerBlock(
  blockIndex: number,
  pageIndex: number,
  fullText: string,
  lines: TextLineMetrics[]
): TextBlockLayout {
  const block = new TextBlockLayout(
    blockIndex,
    pageIndex,
    boundsFromLines(lines),
    identityTransform(),
    fullText,
    lines
  );
  return block;
}

/**
 * 平移一组行度量（返回新数组，原度量保持不变）。
 *
 * <p>入参按 {@link TextBlockLayout#lines} 的声明类型 {@link TextLineMetrics} 接收，
 * 内部下转型为 {@link CanvasTextLineMetrics} 以复用其 {@code translatedBy}。
 * 不使用 {@code instanceof} 收窄——跨 .ts/.ets 边界的值判断在 ArkTS 下不保证可用。
 * 调用方传入的行度量全部由 {@code buildParagraphsBlockLines} /
 * {@code buildElementTextBlocks} 产出，类型不变式由这两个函数保证。
 */
function translateLineMetrics(lines: TextLineMetrics[], dx: number, dy: number): TextLineMetrics[] {
  const result: TextLineMetrics[] = [];
  for (const line of lines) {
    const canvasLine = line as CanvasTextLineMetrics;
    result.push(canvasLine.translatedBy(dx, dy));
  }
  return result;
}

/** 由起止块/字符编号重建选区；startBlock < 0 表示无选区 */
function buildSelectionFromNumbers(
  startBlock: number,
  startChar: number,
  endBlock: number,
  endChar: number
): TextSelection | null {
  if (startBlock < 0 || endBlock < 0) {
    return null;
  }
  return makeTextSelection(
    makeTextPosition(startBlock, startChar),
    makeTextPosition(endBlock, endChar)
  );
}

/** 判断块索引是否落在当前选区覆盖的块区间内（用于跳过无关子组件的矩形计算） */
function blockTouchesSelection(blockIndex: number, startBlock: number, endBlock: number): boolean {
  return startBlock >= 0 && blockIndex >= startBlock && blockIndex <= endBlock;
}

/**
 * 选区数值快照：以纯数字承载选区，供 @Prop 传递（避免 @Prop 深拷贝大型选区对象）。
 * startBlock < 0 表示当前无选区。
 */
interface SelectionSpan {
  readonly startBlock: number;
  readonly startChar: number;
  readonly endBlock: number;
  readonly endChar: number;
  readonly active: boolean;
}

/** 无选区快照 */
function emptySelectionSpan(): SelectionSpan {
  const span: SelectionSpan = {
    startBlock: -1,
    startChar: 0,
    endBlock: -1,
    endChar: 0,
    active: false
  };
  return span;
}

/** 选区逻辑起点（anchor/focus 中较早者） */
function spanStartPosition(selection: TextSelection): TextPosition {
  const a = selection.anchor;
  const b = selection.focus;
  if (a.blockIndex !== b.blockIndex) {
    return a.blockIndex < b.blockIndex ? a : b;
  }
  return a.charIndex <= b.charIndex ? a : b;
}

/** 选区逻辑终点（anchor/focus 中较晚者） */
function spanEndPosition(selection: TextSelection): TextPosition {
  const a = selection.anchor;
  const b = selection.focus;
  if (a.blockIndex !== b.blockIndex) {
    return a.blockIndex > b.blockIndex ? a : b;
  }
  return a.charIndex >= b.charIndex ? a : b;
}

/**
 * 将选区编码为 `"startBlock:startChar-endBlock:endChar"`。
 * ArkUI 的 @Prop 只观察简单类型，字符串既能驱动子组件刷新又不会触发大对象深拷贝。
 */
function encodeSelectionKey(selection: TextSelection | null): string {
  if (!selection || isSelectionEmpty(selection)) {
    return '';
  }
  const start = spanStartPosition(selection);
  const end = spanEndPosition(selection);
  return `${start.blockIndex}:${start.charIndex}-${end.blockIndex}:${end.charIndex}`;
}

/** 解析选区身份字符串；空串或格式非法返回无选区快照 */
function decodeSelectionKey(key: string): SelectionSpan {
  if (!key || key.length === 0) {
    return emptySelectionSpan();
  }
  const dash = key.indexOf('-');
  if (dash <= 0) {
    return emptySelectionSpan();
  }
  const head = key.substring(0, dash).split(':');
  const tail = key.substring(dash + 1).split(':');
  if (head.length !== 2 || tail.length !== 2) {
    return emptySelectionSpan();
  }
  const sb = Number(head[0]);
  const sc = Number(head[1]);
  const eb = Number(tail[0]);
  const ec = Number(tail[1]);
  if (!Number.isFinite(sb) || !Number.isFinite(sc) || !Number.isFinite(eb) || !Number.isFinite(ec)) {
    return emptySelectionSpan();
  }
  const span: SelectionSpan = {
    startBlock: sb,
    startChar: sc,
    endBlock: eb,
    endChar: ec,
    active: sb >= 0 && eb >= 0 && (sb !== eb || sc !== ec)
  };
  return span;
}

/** 由数值快照还原选区（供子组件计算自身块内高亮矩形） */
function selectionFromSpan(span: SelectionSpan): TextSelection | null {
  if (!span.active) {
    return null;
  }
  return buildSelectionFromNumbers(span.startBlock, span.startChar, span.endBlock, span.endChar);
}

// MARK: - DOCX 文本索引角色与纯文本拆分

/** 渲染单元角色：普通流式文本块（DocxTextBlockView） */
const DOCX_ROLE_TEXT: number = 1;
/** 渲染单元角色：表格（每个非空单元格一个块） */
const DOCX_ROLE_TABLE: number = 2;
/** 渲染单元角色：矢量形状内文字 */
const DOCX_ROLE_SHAPE: number = 3;
/** 渲染单元角色：绕排图文复合组（flows + floats） */
const DOCX_ROLE_GROUP: number = 4;
/** DocxTableView 的 Canvas 在 ListItem 内带 8vp 上外边距，块几何需同样下移 */
const TABLE_ITEM_CANVAS_TOP: number = 8;
/** DocxShapeView 内联时 Row 带 4vp 上外边距，块几何需同样下移 */
const SHAPE_INLINE_MARGIN_TOP: number = 4;

/** 一个 ListItem 在全局文本索引中占用的块区间 */
interface DocxItemTextPlan {
  readonly itemIndex: number;
  readonly blockBase: number;
  readonly blockCount: number;
  readonly role: number;
  readonly element: model.Element;
}

/** 普通流式文本块的段内 padding：与 DocxTextBlockView 的 Canvas 绘制保持一致 */
function docxTextPadding(element: model.Element): number {
  return Math.max(0, element.padding ?? 0);
}

/**
 * 搜索结果的身份字符串。ArkUI 的 @Prop 只能观察简单类型，普通属性在 LazyForEach 复用后
 * 不会随父组件更新，因此用字符串承载「当前命中」驱动 DOCX 子组件刷新。
 */
export function searchMatchKey(match: model.SearchMatch | null): string {
  if (!match) return '';
  return `${match.pageIndex}|${match.elementIndex}|${match.paragraphIndex}|${match.row}|${match.column}|${match.startChar}|${match.endChar}`;
}

/** 段落数组的纯文本（跳过空段落，段间以 \n 连接），与 buildParagraphsBlockLines 的 fullText 一致 */
function paragraphsPlainText(paragraphs: model.Paragraph[]): string {
  const parts: string[] = [];
  for (const para of paragraphs) {
    const plain = CanvasElementDrawer.paragraphPlainText(para);
    if (plain.length > 0) {
      parts.push(plain);
    }
  }
  return parts.join('\n');
}

/** 绕排组内全部 flow 块的纯文本（按 flows 数组顺序，每个 flow 一项） */
function docxGroupFlowTextParts(group: DocxWrapGroup): string[] {
  const parts: string[] = [];
  for (const flow of group.flows) {
    const text = paragraphsPlainText(flow.element.paragraphs ?? []);
    if (text.length > 0) {
      parts.push(text);
    }
  }
  return parts;
}

/** 绕排组内浮动元素内文字的纯文本（按 floats 数组顺序，每个含文字的浮动元素一项） */
function docxGroupFloatTextParts(group: DocxWrapGroup): string[] {
  const parts: string[] = [];
  for (const floatItem of group.floats) {
    const text = paragraphsPlainText(floatItem.element.paragraphs ?? []);
    if (text.length > 0) {
      parts.push(text);
    }
  }
  return parts;
}

/**
 * 选区控制钩子集合：子视图（DocxFlowView / PptxSlidesView / SpreadsheetView）在
 * aboutToAppear 时回填，由 OfficePreviewView 转交给 OfficePreviewActions / OfficePreviewController。
 *
 * <p>SpreadsheetView 内另有一份字段完全相同的声明，原因是本文件必须
 * `import { SpreadsheetView }` 才能渲染它，反向导入本文件的类型会形成模块环；
 * TypeScript 结构类型让两份声明可以直接互相赋值，无需断言。
 */
export interface SelectionControlHooks {
  selectAll: () => boolean;
  clearSelection: () => void;
  hasSelection: () => boolean;
  getSelectedText: () => string;
  copySelection: () => boolean;
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

/**
 * 全文检索监听回调接口（对齐 Android 端 OfficePreviewView.SearchListener）
 */
export interface SearchListener {
  onSearchResults?: (query: string, count: number) => void;
  onCurrentMatchChanged?: (index: number, count: number, currentMatch: model.SearchMatch | null) => void;
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
  search: (query: string, callback?: (matches: model.SearchMatch[]) => void) => void;
  findNext: () => boolean;
  findPrevious: () => boolean;
  clearSearch: () => void;
  getSearchMatches: () => model.SearchMatch[];
  getCurrentMatchIndex: () => number;
  isSearching: () => boolean;
  showSearchBar: () => void;
  hideSearchBar: () => void;
  isSearchBarVisible: () => boolean;
  // MARK: 文本选区控制（对齐 Android OfficePreviewView 的公开 API）
  /**
   * 全选正文：DOCX/PPTX 选中全部可选文本，XLSX 选中整表可见数据区（输出为 TSV）。
   * 无可选内容（空文档、全空工作表）或子视图未注册选区能力时返回 false。
   */
  selectAll: () => boolean;
  /** 清空选区并隐藏手柄与浮动气泡 */
  clearSelection: () => void;
  /** 当前是否存在非空选区 */
  hasSelection: () => boolean;
  /**
   * 当前选中的纯文本。DOCX/PPTX 跨块以 `\n` 连接；XLSX 为 TSV
   * （同行 `\t`、跨行 `\n`，隐藏行列跳过、合并从属位置留空）。无选区返回空串。
   */
  getSelectedText: () => string;
  /** 将选中文本写入系统剪贴板，无选区返回 false */
  copySelection: () => boolean;
}

/**
 * JZOffice 鸿蒙端预览控制器（对齐 Android 端 OfficePreviewView 控制方法）
 * 支持通过 addOnPageChangeListener 订阅页码/工作表状态变更，实现与 OfficeSheetTabs 等外围组件的自动联动
 */
export class OfficePreviewController {
  private actions: OfficePreviewActions | null = null;
  private readonly pageListeners: Set<(pageNumber: number, pageCount: number) => void> = new Set();
  private readonly searchListeners: Set<SearchListener> = new Set();

  bind(actions: OfficePreviewActions | null): void {
    this.actions = actions;
    if (actions) {
      this.notifyPageListeners(actions.getCurrentPage(), actions.getPageCount());
      const matches = actions.getSearchMatches();
      const idx = actions.getCurrentMatchIndex();
      this.notifyCurrentMatchChanged(idx, matches.length, idx >= 0 && idx < matches.length ? matches[idx] : null);
    } else {
      this.notifyPageListeners(0, 0);
      this.notifyCurrentMatchChanged(-1, 0, null);
    }
  }

  public addOnPageChangeListener(listener: (pageNumber: number, pageCount: number) => void): void {
    if (!listener) return;
    this.pageListeners.add(listener);
    listener(this.getCurrentPage(), this.getPageCount());
  }

  public removeOnPageChangeListener(listener: (pageNumber: number, pageCount: number) => void): void {
    if (!listener) return;
    this.pageListeners.delete(listener);
  }

  public notifyPageListeners(pageNumber: number, pageCount: number): void {
    const snapshot: Array<(pageNumber: number, pageCount: number) => void> = Array.from(this.pageListeners);
    for (const listener of snapshot) {
      listener(pageNumber, pageCount);
    }
  }

  public addSearchListener(listener: SearchListener): void {
    if (!listener) return;
    this.searchListeners.add(listener);
    const matches = this.getSearchMatches();
    const idx = this.getCurrentMatchIndex();
    if (listener.onCurrentMatchChanged) {
      listener.onCurrentMatchChanged(idx, matches.length, idx >= 0 && idx < matches.length ? matches[idx] : null);
    }
  }

  public removeSearchListener(listener: SearchListener): void {
    if (!listener) return;
    this.searchListeners.delete(listener);
  }

  public notifySearchResults(query: string, count: number): void {
    const snapshot = Array.from(this.searchListeners);
    for (const l of snapshot) {
      if (l.onSearchResults) {
        l.onSearchResults(query, count);
      }
    }
  }

  public notifyCurrentMatchChanged(index: number, count: number, match: model.SearchMatch | null): void {
    const snapshot = Array.from(this.searchListeners);
    for (const l of snapshot) {
      if (l.onCurrentMatchChanged) {
        l.onCurrentMatchChanged(index, count, match);
      }
    }
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

  public search(query: string, callback?: (matches: model.SearchMatch[]) => void): void {
    this.actions?.search(query, callback);
  }

  public findNext(): boolean {
    return this.actions ? this.actions.findNext() : false;
  }

  public findPrevious(): boolean {
    return this.actions ? this.actions.findPrevious() : false;
  }

  public clearSearch(): void {
    this.actions?.clearSearch();
  }

  public getSearchMatches(): model.SearchMatch[] {
    return this.actions ? this.actions.getSearchMatches() : [];
  }

  public getCurrentMatchIndex(): number {
    return this.actions ? this.actions.getCurrentMatchIndex() : -1;
  }

  public isSearching(): boolean {
    return this.actions ? this.actions.isSearching() : false;
  }

  public showSearchBar(): void {
    this.actions?.showSearchBar();
  }

  public hideSearchBar(): void {
    this.actions?.hideSearchBar();
  }

  public isSearchBarVisible(): boolean {
    return this.actions ? this.actions.isSearchBarVisible() : false;
  }

  /**
   * 全选正文：DOCX/PPTX 选中全部可选文本，XLSX 选中整表可见数据区。
   * 无可选内容（空文档、全空工作表）或预览尚未绑定时返回 false。
   */
  public selectAll(): boolean {
    return this.actions ? this.actions.selectAll() : false;
  }

  /** 清空当前选区、手柄与浮动操作气泡 */
  public clearSelection(): void {
    this.actions?.clearSelection();
  }

  /** 当前是否存在非空选区 */
  public hasSelection(): boolean {
    return this.actions ? this.actions.hasSelection() : false;
  }

  /**
   * 当前选中的纯文本。DOCX/PPTX 跨段落/跨块以换行符连接；
   * XLSX 为 TSV（同行制表符、跨行换行符）。无选区返回空串。
   */
  public getSelectedText(): string {
    return this.actions ? this.actions.getSelectedText() : '';
  }

  /** 将当前选中文本写入系统剪贴板；无选区返回 false */
  public copySelection(): boolean {
    return this.actions ? this.actions.copySelection() : false;
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
  private childScrollToMatch: ((match: model.SearchMatch) => void) | null = null;
  // 选区控制委派给当前格式的子视图（DOCX / PPTX / XLSX 都会注册）；
  // 子视图未注册时（如加载失败、尚未挂载）相关 API 返回 false / 空串
  private childSelectAll: (() => boolean) | null = null;
  private childClearSelection: (() => void) | null = null;
  private childHasSelection: (() => boolean) | null = null;
  private childGetSelectedText: (() => string) | null = null;
  private childCopySelection: (() => boolean) | null = null;

  @State searchMatches: model.SearchMatch[] = [];
  @State currentMatchIndex: number = -1;
  @State isSearching: boolean = false;
  @State searchQuery: string = '';
  @State isSearchBarShown: boolean = false;

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
      },
      search: (query: string, callback?: (matches: model.SearchMatch[]) => void): void => {
        this.search(query, callback);
      },
      findNext: (): boolean => this.findNext(),
      findPrevious: (): boolean => this.findPrevious(),
      clearSearch: (): void => this.clearSearch(),
      getSearchMatches: (): model.SearchMatch[] => this.searchMatches,
      getCurrentMatchIndex: (): number => this.currentMatchIndex,
      isSearching: (): boolean => this.isSearching,
      showSearchBar: (): void => {
        this.isSearchBarShown = true;
      },
      hideSearchBar: (): void => {
        this.isSearchBarShown = false;
        this.clearSearch();
      },
      isSearchBarVisible: (): boolean => this.isSearchBarShown,
      selectAll: (): boolean => {
        if (this.childSelectAll) return this.childSelectAll();
        return false;
      },
      clearSelection: (): void => {
        if (this.childClearSelection) this.childClearSelection();
      },
      hasSelection: (): boolean => (this.childHasSelection ? this.childHasSelection() : false),
      getSelectedText: (): string => (this.childGetSelectedText ? this.childGetSelectedText() : ''),
      copySelection: (): boolean => (this.childCopySelection ? this.childCopySelection() : false)
    });
  }

  public async search(query: string, callback?: (matches: model.SearchMatch[]) => void): Promise<void> {
    const trimmed = query ? query.trim() : '';
    this.searchQuery = trimmed;
    if (!trimmed || !this.filePath || !this.rawDocument) {
      this.clearSearch();
      if (callback) callback([]);
      return;
    }
    this.isSearching = true;
    const token = this.loadGeneration;
    try {
      const matches = await NativeCore.searchDocumentAsync(this.filePath, trimmed);
      if (token !== this.loadGeneration) return;
      this.isSearching = false;
      this.searchMatches = matches;
      this.currentMatchIndex = matches.length > 0 ? 0 : -1;
      this.onCurrentMatchUpdated();
      this.controller?.notifySearchResults(trimmed, matches.length);
      if (callback) callback(matches);
    } catch (e) {
      if (token !== this.loadGeneration) return;
      this.isSearching = false;
      this.searchMatches = [];
      this.currentMatchIndex = -1;
      this.onCurrentMatchUpdated();
      this.controller?.notifySearchResults(trimmed, 0);
      if (callback) callback([]);
    }
  }

  public findNext(): boolean {
    if (this.searchMatches.length === 0) return false;
    this.currentMatchIndex = (this.currentMatchIndex + 1) % this.searchMatches.length;
    this.onCurrentMatchUpdated();
    return true;
  }

  public findPrevious(): boolean {
    if (this.searchMatches.length === 0) return false;
    this.currentMatchIndex = (this.currentMatchIndex - 1 + this.searchMatches.length) % this.searchMatches.length;
    this.onCurrentMatchUpdated();
    return true;
  }

  public clearSearch(): void {
    this.searchQuery = '';
    this.searchMatches = [];
    this.currentMatchIndex = -1;
    this.isSearching = false;
    this.onCurrentMatchUpdated();
    this.controller?.notifySearchResults('', 0);
  }

  private onCurrentMatchUpdated(): void {
    const cur = (this.currentMatchIndex >= 0 && this.currentMatchIndex < this.searchMatches.length)
      ? this.searchMatches[this.currentMatchIndex]
      : null;
    this.controller?.notifyCurrentMatchChanged(this.currentMatchIndex, this.searchMatches.length, cur);
    if (cur && this.childScrollToMatch) {
      this.childScrollToMatch(cur);
    }
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
    this.controller?.notifyPageListeners(pageNumber, pageCount);
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
    this.childScrollToMatch = null;
    this.clearChildSelectionHooks();
    this.clearSearch();
    this.controller?.bind(null);
  }

  /**
   * 解绑子视图的选区控制回调。
   * 文档切换或组件销毁时子视图即将消失，其选区与定时器由子视图自身清理，
   * 此处只清除父视图持有的函数引用，避免控制器调用到已销毁的子组件。
   */
  private clearChildSelectionHooks(): void {
    this.childSelectAll = null;
    this.childClearSelection = null;
    this.childHasSelection = null;
    this.childGetSelectedText = null;
    this.childCopySelection = null;
  }

  /** 接收子视图回填的选区控制钩子（子视图未提供时视为不支持选区） */
  private applySelectionHooks(hooks?: SelectionControlHooks): void {
    if (!hooks) {
      this.clearChildSelectionHooks();
      return;
    }
    this.childSelectAll = hooks.selectAll;
    this.childClearSelection = hooks.clearSelection;
    this.childHasSelection = hooks.hasSelection;
    this.childGetSelectedText = hooks.getSelectedText;
    this.childCopySelection = hooks.copySelection;
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
    this.childScrollToMatch = null;
    this.clearChildSelectionHooks();
    this.clearSearch();
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
    Stack({ alignContent: Alignment.Top }) {
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
            searchMatches: this.searchMatches,
            currentMatchIndex: this.currentMatchIndex,
            registerControls: (
              jumpToPage: (pageNumber: number) => void,
              getZoom: () => number,
              setZoom: (value: number) => void,
              scrollToMatch?: (match: model.SearchMatch) => void,
              selection?: SelectionControlHooks
            ): void => {
              this.childJumpToPage = jumpToPage;
              this.childGetZoom = getZoom;
              this.childSetZoom = setZoom;
              this.childScrollToMatch = scrollToMatch ?? null;
              this.applySelectionHooks(selection);
            }
          })
            .id(`doc-${this.docRevision}-${this.rawDocument?.kind ?? ''}`)
            .width('100%')
            .height('100%')
        } else if (this.rawDocument.kind === 'PPTX') {
          PptxSlidesView({
            document: this.rawDocument,
            filePath: this.filePath,
            searchMatches: this.searchMatches,
            currentMatchIndex: this.currentMatchIndex,
            onSlideChange: (pageNumber: number, pageCount: number): void => {
              this.notifyPageChanged(pageNumber, pageCount);
            },
            registerControls: (
              jumpToPage: (pageNumber: number) => void,
              getZoom: () => number,
              setZoom: (value: number) => void,
              scrollToMatch?: (match: model.SearchMatch) => void,
              selection?: SelectionControlHooks
            ): void => {
              this.childJumpToPage = jumpToPage;
              this.childGetZoom = getZoom;
              this.childSetZoom = setZoom;
              this.childScrollToMatch = scrollToMatch ?? null;
              this.applySelectionHooks(selection);
            }
          })
            .id(`doc-${this.docRevision}-${this.rawDocument?.kind ?? ''}`)
            .width('100%')
            .height('100%')
        } else if (this.rawDocument.kind === 'XLSX') {
          SpreadsheetView({
            document: this.rawDocument,
            searchMatches: this.searchMatches,
            currentMatchIndex: this.currentMatchIndex,
            onSheetChange: (sheetNumber: number, sheetCount: number): void => {
              this.notifyPageChanged(sheetNumber, sheetCount);
            },
            registerControls: (
              selectSheet: (sheetNumber: number) => void,
              getZoom: () => number,
              setZoom: (value: number) => void,
              scrollToMatch?: (match: model.SearchMatch) => void,
              selection?: SelectionControlHooks
            ): void => {
              this.childSelectSheet = selectSheet;
              this.childGetZoom = getZoom;
              this.childSetZoom = setZoom;
              this.childScrollToMatch = scrollToMatch ?? null;
              this.applySelectionHooks(selection);
            }
          })
            .id(`doc-${this.docRevision}-${this.rawDocument?.kind ?? ''}`)
            .width('100%')
            .height('100%')
        }
      }

      if (this.isSearchBarShown) {
        Row() {
          OfficeSearchBar({
            query: this.searchQuery,
            currentIndex: this.currentMatchIndex,
            totalMatches: this.searchMatches.length,
            isSearching: this.isSearching,
            onQueryChange: (q: string) => {
              this.search(q);
            },
            onSearchSubmit: (q: string) => {
              this.search(q);
            },
            onNext: () => {
              this.findNext();
            },
            onPrevious: () => {
              this.findPrevious();
            },
            onClose: () => {
              this.isSearchBarShown = false;
              this.clearSearch();
            }
          })
            .width('92%')
            .constraintSize({ maxWidth: 460 })
        }
        .width('100%')
        .justifyContent(FlexAlign.Center)
        .padding({ top: 12 })
        .hitTestBehavior(HitTestMode.Transparent)
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
  // 检索结果与当前命中必须可观察，否则 LazyForEach 复用后子组件拿不到新值
  @Prop @Watch('onSearchChanged') searchMatches: model.SearchMatch[] = [];
  @Prop @Watch('onCurrentMatchChanged') currentMatchIndex: number = -1;
  @State private reuseVersion: number = 0;
  registerControls?: (
    jumpToPage: (pageNumber: number) => void,
    getZoom: () => number,
    setZoom: (value: number) => void,
    scrollToMatch?: (match: model.SearchMatch) => void,
    selection?: SelectionControlHooks
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

  // MARK: - 文本选区状态
  /** 选区身份字符串（空串表示无选区），作为 @Prop 下发给各块驱动高亮刷新 */
  @State private selectionKey: string = '';
  /** 叠加层是否可见；仅在选区出现/消失时切换，避免高频手势反复触发整树脏检查 */
  @State private hasSelectionLayer: boolean = false;
  /** 浮动气泡状态：仅在手势停稳后更新，拖选与缩放过程中保持关闭 */
  @State private bubbleShown: boolean = false;
  @State private bubbleAnchorX: number = 0;
  @State private bubbleAnchorY: number = 0;
  @State private bubbleBottomY: number = 0;
  @State private bubbleShowSelectAll: boolean = true;
  /** 拖选期间关闭列表滚动交互，防止 List 抢走纵向手势 */
  @State private isSelectionDragging: boolean = false;

  private selection: TextSelection | null = null;
  /** 拖拽模式：0 无 / 1 起点手柄 / 2 终点手柄 / 3 长按拖选 */
  private dragMode: number = 0;
  private overlayCtx: CanvasRenderingContext2D = new CanvasRenderingContext2D(new RenderingContextSettings(true));
  private overlayReady: boolean = false;
  /** 起止手柄屏幕锚点，供命中测试与绘制共用；对端不可见时为 null 但槽位保持不变 */
  private startHandleAnchor: SelectionHandleAnchor | null = null;
  private endHandleAnchor: SelectionHandleAnchor | null = null;
  private lastTouchX: number = 0;
  private lastTouchY: number = 0;
  private edgeScrollTimer: number = -1;
  private edgeScrollDirection: number = 0;
  /** 选区超时重定位：手势停稳后延迟计算气泡位置 */
  private bubbleTimer: number = -1;

  // MARK: - 文本索引（全量轻量索引 + 按 ListItem 懒测量）
  private textLayout: DocumentTextLayout | null = null;
  private itemTextPlans: Map<number, DocxItemTextPlan> = new Map();
  private blockToItem: Map<number, number> = new Map();
  /** 已测量行几何的 ListItem 布局缓存，键为 ListItem 索引 */
  private measuredItemLayouts: Map<number, DocumentTextLayout> = new Map();
  /** 已测量的内容宽度，宽度变化时清空行几何缓存 */
  private measuredContentWidth: number = 0;
  /** 当前可见 ListItem 区间，由 onScrollIndex 维护 */
  private visibleStart: number = 0;
  private visibleEnd: number = 0;

  onCurrentMatchChanged(): void {
    this.reuseVersion++;
  }

  onSearchChanged(): void {
    this.reuseVersion++;
  }

  aboutToAppear(): void {
    this.imageStore = new ImageStore(this.filePath);
    // 将页眉块插入到正文开头、页脚块追加到正文末尾，实现基础页眉页脚展示
    const headerBlocks = this.document?.headerBlocks ?? [];
    const bodyBlocks = this.document?.blocks ?? [];
    const footerBlocks = this.document?.footerBlocks ?? [];
    this.headerCount = headerBlocks.length;
    this.bodyCount = bodyBlocks.length;
    this.blockSource = new ArrayDataSource([...headerBlocks, ...bodyBlocks, ...footerBlocks]);
    this.rebuildWrapPlan(this.getContentWidth());
    this.rebuildTextIndex();
    if (this.registerControls) {
      this.registerControls(
        (_pageNumber: number): void => {
          this.scroller.scrollToIndex(0);
        },
        (): number => this.zoom,
        (value: number): void => {
          this.isGesturing = false;
          this.setZoom(value, this.viewportWidth / 2, this.viewportHeight / 2);
        },
        (match: model.SearchMatch): void => {
          this.reuseVersion++;
          if (match.elementIndex >= 0 && match.elementIndex < this.blockSource.totalCount()) {
            const hostIndex = this.consumedToGroup.get(match.elementIndex);
            const targetIndex = hostIndex !== undefined ? hostIndex : match.elementIndex;
            this.scroller.scrollToIndex(targetIndex, true, ScrollAlign.CENTER);
          }
        },
        this.buildSelectionHooks()
      );
    }
  }

  aboutToDisappear(): void {
    this.stopEdgeScroll();
    this.cancelBubbleTimer();
    this.selection = null;
    this.startHandleAnchor = null;
    this.endHandleAnchor = null;
    this.measuredItemLayouts.clear();
    this.overlayReady = false;
    this.imageStore.release();
  }

  /** 组装选区控制钩子，交给 OfficePreviewController 统一调度 */
  private buildSelectionHooks(): SelectionControlHooks {
    const hooks: SelectionControlHooks = {
      selectAll: (): boolean => this.selectAll(),
      clearSelection: (): void => this.clearSelection(),
      hasSelection: (): boolean => this.hasSelection(),
      getSelectedText: (): string => this.getSelectedText(),
      copySelection: (): boolean => this.copySelection()
    };
    return hooks;
  }

  private pinchStartZoom: number = 1.0;
  private pinchStartOffsetX: number = 0;
  private pinchFocusX: number = 0;
  private panStartX: number = 0;
  private viewportWidth: number = 0;
  private viewportHeight: number = 0;
  @State private layoutRevision: number = 0;
  private plannedWidth: number = 0;
  private measureCtx: OffscreenCanvasRenderingContext2D | null = null;
  private wrapGroups: Map<number, DocxWrapGroup> = new Map();
  private consumedToGroup: Map<number, number> = new Map();

  private ensureMeasureCtx(): OffscreenCanvasRenderingContext2D {
    if (!this.measureCtx) {
      this.measureCtx = new OffscreenCanvas(1, 1).getContext('2d', new RenderingContextSettings(true));
    }
    return this.measureCtx;
  }

  private getContentWidth(): number {
    const base = this.viewportWidth > 0 ? this.viewportWidth : (this.document?.width && this.document.width > 0 ? this.document.width : 360);
    return Math.max(100, base - 32);
  }

  private rebuildWrapPlan(contentWidth: number): void {
    const groups: Map<number, DocxWrapGroup> = new Map();
    const doc = this.document;
    if (!doc) {
      this.wrapGroups = groups;
      this.consumedToGroup = new Map();
      this.plannedWidth = contentWidth;
      return;
    }
    const allBlocks: model.Element[] = [
      ...(doc.headerBlocks ?? []),
      ...(doc.blocks ?? []),
      ...(doc.footerBlocks ?? [])
    ];
    const blockInputs: DocxWrapBlockInput[] = allBlocks.map((el: model.Element): DocxWrapBlockInput => toWrapBlockInput(el));
    const secRanges: [number, number][] = [
      [0, this.headerCount],
      [this.headerCount, this.headerCount + this.bodyCount],
      [this.headerCount + this.bodyCount, allBlocks.length]
    ];
    const ctx = this.ensureMeasureCtx();
    const plan = planDocxWrapGroups(
      blockInputs,
      secRanges,
      doc.width,
      doc.marginLeft ?? 0,
      doc.marginRight ?? 0,
      contentWidth,
      (blockIndex: number, startY: number, obstacles: WrapObstacle[]): number => {
        const tEl = allBlocks[blockIndex];
        return CanvasElementDrawer.measureParagraphsHeight(
          ctx, tEl.paragraphs ?? [], contentWidth, true, obstacles, startY, 0
        );
      }
    );
    plan.groups.forEach((groupPlan: DocxWrapGroupPlan, key: number) => {
      const floats: DocxPlacedFloat[] = groupPlan.floats.map((f): DocxPlacedFloat => ({
        element: allBlocks[f.blockIndex],
        x: f.x,
        y: f.y,
        width: f.width,
        height: f.height,
        behind: f.behind
      }));
      const flows: DocxFlowTextItem[] = groupPlan.flowBlockIndices.map((idx: number): DocxFlowTextItem => ({
        blockIndex: idx,
        element: allBlocks[idx]
      }));
      groups.set(key, {
        renderIndex: groupPlan.renderIndex,
        endIndex: groupPlan.endIndex,
        width: groupPlan.width,
        height: groupPlan.height,
        flowStartY: groupPlan.flowStartY,
        floats,
        flows,
        obstacles: groupPlan.obstacles
      });
    });
    this.wrapGroups = groups;
    this.consumedToGroup = plan.consumedToGroup;
    this.plannedWidth = contentWidth;
  }

  // MARK: - 文本索引构建

  /**
   * 构建全量文本索引：按与 LazyForEach 完全相同的遍历顺序为每个渲染单元分配 blockIndex，
   * 初始只提取纯文本（不触发 Canvas measureText），保证未滚动到的块也能参与全选与复制。
   */
  private rebuildTextIndex(): void {
    const plans: Map<number, DocxItemTextPlan> = new Map();
    const blockToItem: Map<number, number> = new Map();
    const blocks: TextBlockLayout[] = [];
    let base = 0;
    const total = this.blockSource.totalCount();
    for (let index = 0; index < total; index++) {
      const element = this.blockSource.getData(index);
      if (this.consumedToGroup.has(index)) {
        continue;
      }
      const group = this.wrapGroups.get(index);
      const parts: string[] = [];
      let role: number = DOCX_ROLE_TEXT;
      if (group) {
        role = DOCX_ROLE_GROUP;
        const flowParts = docxGroupFlowTextParts(group);
        for (const part of flowParts) {
          parts.push(part);
        }
        const floatParts = docxGroupFloatTextParts(group);
        for (const part of floatParts) {
          parts.push(part);
        }
      } else if (element.type === 'TABLE' && element.rows && element.rows.length > 0) {
        role = DOCX_ROLE_TABLE;
        const cellParts = CanvasElementDrawer.extractElementFullText(element);
        for (const part of cellParts) {
          parts.push(part);
        }
      } else if (element.type === 'RECT' || element.type === 'ELLIPSE' || element.type === 'LINE' || element.type === 'PATH') {
        role = DOCX_ROLE_SHAPE;
        const shapeParts = CanvasElementDrawer.extractElementFullText(element);
        for (const part of shapeParts) {
          parts.push(part);
        }
      } else if (element.paragraphs && element.paragraphs.length > 0) {
        role = DOCX_ROLE_TEXT;
        const textParts = CanvasElementDrawer.extractElementFullText(element);
        for (const part of textParts) {
          parts.push(part);
        }
      }
      if (parts.length === 0) {
        continue;
      }
      const plan: DocxItemTextPlan = {
        itemIndex: index,
        blockBase: base,
        blockCount: parts.length,
        role: role,
        element: element
      };
      plans.set(index, plan);
      for (let k = 0; k < parts.length; k++) {
        blockToItem.set(base + k, index);
        blocks.push(makeContainerBlock(base + k, 0, parts[k], []));
      }
      base += parts.length;
    }
    this.itemTextPlans = plans;
    this.blockToItem = blockToItem;
    this.textLayout = new DocumentTextLayout(blocks);
    this.measuredItemLayouts.clear();
    this.measuredContentWidth = this.getContentWidth();
  }

  /** 行几何缓存是否已因内容宽度变化而失效 */
  private ensureMeasuredWidth(): void {
    const width = this.getContentWidth();
    if (Math.abs(width - this.measuredContentWidth) > 0.5) {
      this.measuredContentWidth = width;
      this.measuredItemLayouts.clear();
    }
  }

  /**
   * 懒测量单个 ListItem 内的行几何（ListItem 局部坐标 + 恒等仿射变换）。
   * 命中测试、选区矩形与手柄几何都基于同一份结果，与子组件 Canvas 的绘制参数保持一致。
   */
  private ensureItemLayout(itemIndex: number): DocumentTextLayout | null {
    this.ensureMeasuredWidth();
    const cached = this.measuredItemLayouts.get(itemIndex);
    if (cached) {
      return cached;
    }
    const plan = this.itemTextPlans.get(itemIndex);
    if (!plan) {
      return null;
    }
    const ctx = this.ensureMeasureCtx();
    const blocks: TextBlockLayout[] = [];
    if (plan.role === DOCX_ROLE_GROUP) {
      const group = this.wrapGroups.get(itemIndex);
      if (group) {
        this.appendGroupBlocks(ctx, group, blocks, plan.blockBase);
      }
    } else if (plan.role === DOCX_ROLE_TABLE) {
      const rawBlocks = CanvasElementDrawer.buildElementTextBlocks(ctx, plan.element, plan.blockBase, 0);
      for (const block of rawBlocks) {
        // 表格画布在 ListItem 内带有 8vp 上外边距，块几何需同样下移
        const lines = translateLineMetrics(block.lines, 0, TABLE_ITEM_CANVAS_TOP);
        blocks.push(makeContainerBlock(block.blockIndex, 0, block.fullText, lines));
      }
    } else if (plan.role === DOCX_ROLE_SHAPE) {
      // 与 DocxShapeView 完全一致：内联形状的 Row 带 4vp 上外边距，浮动形状则以 floatingOffsetX 左移
      const floating = isDocxFloating(plan.element);
      const floatOffsetX = floating ? this.getStandaloneOffsetX(plan.element) : 0;
      const pad = Math.max(0, plan.element.padding ?? 4);
      const availW = Math.max(1, (plan.element.width > 0 ? plan.element.width : this.getContentWidth()) - pad * 2);
      const layout = CanvasElementDrawer.buildParagraphsBlockLines(
        ctx,
        plan.element.paragraphs ?? [],
        pad,
        availW,
        plan.element.height,
        plan.element.verticalAlignment,
        plan.element.textWrap !== false
      );
      if (layout.fullText.length > 0) {
        const dy = floating ? 0 : SHAPE_INLINE_MARGIN_TOP;
        const dx = floatOffsetX > 0 ? floatOffsetX : 0;
        const lines = translateLineMetrics(layout.lines, dx, dy);
        blocks.push(makeContainerBlock(plan.blockBase, 0, layout.fullText, lines));
      }
    } else {
      // 与 DocxTextBlockView 完全一致：普通流式块 padding 缺省为 0，可用宽度取 ListItem 内容宽度，
      // 块高度未知（core 下发 height 为 0），因此 verticalAlignment 不产生纵向偏移
      const pad = docxTextPadding(plan.element);
      const availW = Math.max(1, this.getContentWidth() - pad * 2);
      const layout = CanvasElementDrawer.buildParagraphsBlockLines(
        ctx,
        plan.element.paragraphs ?? [],
        pad,
        availW,
        0,
        plan.element.verticalAlignment,
        plan.element.textWrap !== false
      );
      if (layout.fullText.length > 0) {
        blocks.push(makeContainerBlock(plan.blockBase, 0, layout.fullText, layout.lines));
      }
    }
    const layout = new DocumentTextLayout(blocks);
    this.measuredItemLayouts.set(itemIndex, layout);
    return layout;
  }

  /** 追加上绕排组内各 flow 与浮动文本的行几何（与 DocxWrappedBlockView 的索引顺序一致） */
  private appendGroupBlocks(
    ctx: OffscreenCanvasRenderingContext2D,
    group: DocxWrapGroup,
    blocks: TextBlockLayout[],
    base: number
  ): void {
    let blockIndex = base;
    let curY = group.flowStartY;
    for (const flow of group.flows) {
      const paras = flow.element.paragraphs ?? [];
      const layout = CanvasElementDrawer.buildParagraphsBlockLines(
        ctx, paras, 0, group.width, 0, 'TOP', true, group.obstacles, curY, 0
      );
      if (layout.fullText.length > 0) {
        blocks.push(makeContainerBlock(blockIndex, 0, layout.fullText, translateLineMetrics(layout.lines, 0, curY)));
        blockIndex++;
      }
      // 与 drawComposite 一致地推进 flow 纵向位置，保证后续 flow 的块几何不偏移
      for (let pIdx = 0; pIdx < paras.length; pIdx++) {
        const para = paras[pIdx];
        curY += Math.max(0, para.before || 0);
        const lines = CanvasElementDrawer.layoutParagraph(ctx, para, group.width, true, group.obstacles, curY, 0);
        let drawnH = 0;
        for (const line of lines) {
          drawnH += line.height;
        }
        curY += drawnH + Math.max(0, para.after || 0);
      }
      curY += 8;
    }
    for (const floatItem of group.floats) {
      const paras = floatItem.element.paragraphs ?? [];
      if (paras.length === 0) {
        continue;
      }
      const pad = Math.max(0, floatItem.element.padding ?? 4);
      const rawW = floatItem.element.width > 0 ? floatItem.element.width : floatItem.width;
      const availW = Math.max(1, rawW - pad * 2);
      const layout = CanvasElementDrawer.buildParagraphsBlockLines(
        ctx, paras, pad, availW, floatItem.height, floatItem.element.verticalAlignment,
        floatItem.element.textWrap !== false
      );
      if (layout.fullText.length > 0) {
        blocks.push(makeContainerBlock(
          blockIndex, 0, layout.fullText, translateLineMetrics(layout.lines, floatItem.x, floatItem.y)
        ));
        blockIndex++;
      }
    }
  }

  // MARK: - 选区控制 API

  /** 全选正文：使用全局轻量索引，无需等待各行测量完成 */
  public selectAll(): boolean {
    const layout = this.textLayout;
    if (!layout || !layout.hasText()) {
      return false;
    }
    const range = layout.allTextRange();
    if (!range || isSelectionEmpty(range)) {
      return false;
    }
    this.setSelection(range);
    this.scheduleBubble();
    return true;
  }

  /** 清空选区、手柄与浮动气泡 */
  public clearSelection(): void {
    this.stopEdgeScroll();
    this.cancelBubbleTimer();
    this.setSelection(null);
  }

  /** 当前是否存在非空选区 */
  public hasSelection(): boolean {
    return this.selection !== null && !isSelectionEmpty(this.selection);
  }

  /** 当前选中的纯文本（跨块以换行连接） */
  public getSelectedText(): string {
    const layout = this.textLayout;
    const selection = this.selection;
    if (!layout || !selection) {
      return '';
    }
    return layout.selectedText(selection);
  }

  /** 将选中文本写入系统剪贴板 */
  public copySelection(): boolean {
    const text = this.getSelectedText();
    if (text.length === 0) {
      return false;
    }
    return copyTextToPasteboard(text);
  }

  /** 更新选区并同步子组件与叠加层 */
  private setSelection(selection: TextSelection | null): void {
    if (selection && isSelectionEmpty(selection)) {
      selection = null;
    }
    this.selection = selection;
    this.selectionKey = encodeSelectionKey(selection);
    const visible = selection !== null;
    if (this.hasSelectionLayer !== visible) {
      this.hasSelectionLayer = visible;
    }
    if (!visible) {
      this.startHandleAnchor = null;
      this.endHandleAnchor = null;
      this.bubbleShown = false;
    }
    this.refreshSelectionOverlay();
  }

  // MARK: - 屏幕坐标映射

  /**
   * 屏幕坐标 -> List 容器（未缩放、未平移）坐标。
   * 外层 Stack 以自身中心为缩放原点，再整体平移 (offsetX, offsetY)：
   *   screen = center + zoom * (panel - center) + offset
   * 反解得 panel = (screen - offset - center) / zoom + center。
   */
  private screenToPanel(screenX: number, screenY: number): PlanePoint {
    const zoom = this.zoom > 0 ? this.zoom : 1.0;
    const centerX = this.viewportWidth / 2;
    const centerY = this.viewportHeight / 2;
    const point: PlanePoint = {
      x: (screenX - this.offsetX - centerX) / zoom + centerX,
      y: (screenY - this.offsetY - centerY) / zoom + centerY
    };
    return point;
  }

  /** List 容器坐标 -> 屏幕坐标（screenToPanel 的正向变换） */
  private panelToScreen(panelX: number, panelY: number): PlanePoint {
    const zoom = this.zoom > 0 ? this.zoom : 1.0;
    const centerX = this.viewportWidth / 2;
    const centerY = this.viewportHeight / 2;
    const point: PlanePoint = {
      x: centerX + (panelX - centerX) * zoom + this.offsetX,
      y: centerY + (panelY - centerY) * zoom + this.offsetY
    };
    return point;
  }

  /** 读取 ListItem 在 List 容器坐标系下的矩形（不可见或控制器未绑定时返回 null） */
  private itemRectOf(itemIndex: number): DocxItemRect | null {
    const total = this.blockSource.totalCount();
    if (itemIndex < 0 || itemIndex >= total) {
      return null;
    }
    try {
      const rect = this.scroller.getItemRect(itemIndex);
      if (!rect || Math.abs(rect.width) < 0.01 || Math.abs(rect.height) < 0.01) {
        return null;
      }
      const result: DocxItemRect = {
        x: rect.x,
        y: rect.y,
        width: rect.width,
        height: rect.height
      };
      return result;
    } catch (_e) {
      return null;
    }
  }

  /**
   * 当前参与命中测试的 ListItem 索引区间（可见区间前后各留 2 项缓冲）。
   * onScrollIndex 尚未回调时可见区间未知（start==end==0），此时退化为全量扫描：
   * getItemRect 对未进入节点树的 ListItem 返回空矩形，遍历开销可接受且不会漏命中。
   */
  private hitScanRange(): number[] {
    const total = this.blockSource.totalCount();
    if (total <= 0) {
      return [0, -1];
    }
    const windowKnown = this.visibleEnd > this.visibleStart || this.visibleStart > 0;
    if (!windowKnown) {
      return [0, total - 1];
    }
    const first = Math.max(0, this.visibleStart - 2);
    const last = Math.min(total - 1, Math.max(this.visibleEnd, first) + 2);
    return [first, last];
  }

  /**
   * 屏幕坐标命中：先按 ListItem 矩形筛选，再在单元局部坐标系内做字符级命中；
   * 未落在任何单元内时取最近单元，保证跨行空白间隙拖选不跳断。
   */
  private hitTestScreen(screenX: number, screenY: number, lift: number): TextPosition | null {
    const panel = this.screenToPanel(screenX, screenY - lift);
    const range = this.hitScanRange();
    let nearestPosition: TextPosition | null = null;
    let nearestDistance = Number.POSITIVE_INFINITY;
    for (let index = range[0]; index <= range[1]; index++) {
      const rect = this.itemRectOf(index);
      if (!rect) {
        continue;
      }
      const layout = this.ensureItemLayout(index);
      if (!layout || !layout.hasText()) {
        continue;
      }
      const localX = panel.x - rect.x;
      const localY = panel.y - rect.y;
      const inside = localX >= -8 && localX <= rect.width + 8 && localY >= -4 && localY <= rect.height + 4;
      const position = layout.hitTest(localX, localY);
      if (!position) {
        continue;
      }
      if (inside) {
        return position;
      }
      const dx = Math.max(rect.x - panel.x, 0, panel.x - (rect.x + rect.width));
      const dy = Math.max(rect.y - panel.y, 0, panel.y - (rect.y + rect.height));
      const distance = Math.sqrt(dx * dx + dy * dy);
      if (distance < nearestDistance) {
        nearestDistance = distance;
        nearestPosition = position;
      }
    }
    return nearestPosition;
  }

  /** 计算某个文本位置的屏幕手柄锚点（不可见时返回 null） */
  private resolveHandleAnchor(position: TextPosition): SelectionHandleAnchor | null {
    const itemIndex = this.blockToItem.get(position.blockIndex);
    if (itemIndex === undefined) {
      return null;
    }
    const rect = this.itemRectOf(itemIndex);
    if (!rect) {
      return null;
    }
    const layout = this.ensureItemLayout(itemIndex);
    if (!layout) {
      return null;
    }
    const handles = layout.handleGeometry(makeTextSelection(position, position));
    if (!handles) {
      return null;
    }
    const top = this.panelToScreen(rect.x + handles.start.docX, rect.y + handles.start.docTopY);
    const bottom = this.panelToScreen(rect.x + handles.start.docX, rect.y + handles.start.docBottomY);
    const anchor: SelectionHandleAnchor = { x: top.x, y: top.y, bottomY: bottom.y };
    return anchor;
  }

  /** 重算起止手柄锚点并重绘叠加层（手柄与气泡不进入 ArkUI 脏检查，只做 Canvas 重绘） */
  private refreshSelectionOverlay(): void {
    const selection = this.selection;
    if (selection && !isSelectionEmpty(selection)) {
      this.startHandleAnchor = this.resolveHandleAnchor(spanStartPosition(selection));
      this.endHandleAnchor = this.resolveHandleAnchor(spanEndPosition(selection));
    } else {
      this.startHandleAnchor = null;
      this.endHandleAnchor = null;
    }
    this.drawOverlayCanvas();
  }

  /** 绘制屏幕坐标系的起止光标竖线与水滴手柄 */
  private drawOverlayCanvas(): void {
    if (!this.overlayReady) {
      return;
    }
    const ctx = this.overlayCtx;
    const width = ctx.width;
    const height = ctx.height;
    if (width <= 0 || height <= 0) {
      return;
    }
    ctx.clearRect(0, 0, width, height);
    const start = this.startHandleAnchor;
    const end = this.endHandleAnchor;
    if (start) {
      this.drawHandle(ctx, start, true);
    }
    if (end) {
      this.drawHandle(ctx, end, false);
    }
  }

  /** 单个手柄：2vp 光标竖线 + 固定物理尺寸的水滴圆头 */
  private drawHandle(ctx: CanvasRenderingContext2D, anchor: SelectionHandleAnchor, isStart: boolean): void {
    const topY = Math.min(anchor.y, anchor.bottomY);
    const bottomY = Math.max(anchor.y, anchor.bottomY);
    ctx.save();
    ctx.strokeStyle = SELECTION_LINE_COLOR;
    ctx.lineWidth = 2;
    ctx.beginPath();
    ctx.moveTo(anchor.x, topY);
    ctx.lineTo(anchor.x, bottomY);
    ctx.stroke();
    const centerY = bottomY + SELECTION_HANDLE_DROP;
    ctx.fillStyle = SELECTION_LINE_COLOR;
    ctx.beginPath();
    ctx.arc(anchor.x, centerY, SELECTION_HANDLE_RADIUS, 0, Math.PI * 2);
    ctx.fill();
    // 圆头内圈留白，视觉上指向光标底端（起始手柄朝左下、结束手柄朝右下）
    ctx.strokeStyle = '#ffffff';
    ctx.lineWidth = 1.5;
    ctx.beginPath();
    ctx.moveTo(anchor.x, centerY + SELECTION_HANDLE_RADIUS - 1);
    ctx.lineTo(anchor.x + (isStart ? -4 : 4), centerY + SELECTION_HANDLE_RADIUS + 3);
    ctx.stroke();
    ctx.restore();
  }

  /** 命中起止手柄热区：返回 1（起点）或 2（终点），未命中返回 0 */
  private hitHandle(screenX: number, screenY: number): number {
    if (this.hitsHandleAnchor(this.startHandleAnchor, screenX, screenY)) {
      return 1;
    }
    if (this.hitsHandleAnchor(this.endHandleAnchor, screenX, screenY)) {
      return 2;
    }
    return 0;
  }

  /** 触点是否落在某个手柄圆心（光标底端下移 SELECTION_HANDLE_DROP）的热区内 */
  private hitsHandleAnchor(anchor: SelectionHandleAnchor | null, screenX: number, screenY: number): boolean {
    if (!anchor) {
      return false;
    }
    const cx = anchor.x;
    const cy = Math.max(anchor.y, anchor.bottomY) + SELECTION_HANDLE_DROP;
    const dx = screenX - cx;
    const dy = screenY - cy;
    return Math.sqrt(dx * dx + dy * dy) <= SELECTION_HANDLE_HIT_RADIUS;
  }

  // MARK: - 手势处理

  /** 手柄优先拦截 + 拖选跟随；不消费事件，列表滚动仍由 List 自行处理 */
  private handleDocxTouch(event: TouchEvent): void {
    const touches = event.touches;
    if (!touches || touches.length === 0) {
      return;
    }
    const touch = touches[0];
    if (event.type === TouchType.Down) {
      this.lastTouchX = touch.x;
      this.lastTouchY = touch.y;
      const hit = this.hitHandle(touch.x, touch.y);
      if (hit !== 0) {
        this.beginDrag(hit);
      }
      return;
    }
    if (event.type === TouchType.Move) {
      if (this.dragMode === 0) {
        return;
      }
      this.lastTouchX = touch.x;
      this.lastTouchY = touch.y;
      this.updateDrag(touch.x, touch.y);
      this.updateEdgeScroll(touch.x, touch.y);
      return;
    }
    if (this.dragMode !== 0) {
      this.endDrag();
    }
  }

  /** 进入拖拽：锁定锚点、停止边缘滚动、隐藏气泡并接管纵向手势 */
  private beginDrag(mode: number): void {
    const selection = this.selection;
    if (!selection) {
      return;
    }
    this.stopEdgeScroll();
    this.cancelBubbleTimer();
    this.bubbleShown = false;
    this.dragMode = mode;
    if (this.isSelectionDragging !== true) {
      this.isSelectionDragging = true;
    }
  }

  /** 拖拽更新焦点；手柄拖拽时锚点固定为选区另一端，长按拖选时锚点固定为首次选词起点 */
  private updateDrag(screenX: number, screenY: number): void {
    const selection = this.selection;
    if (!selection) {
      return;
    }
    const position = this.hitTestScreen(screenX, screenY, SELECTION_TOUCH_LIFT);
    if (!position) {
      return;
    }
    let anchor = selection.anchor;
    if (this.dragMode === 1) {
      // 拖起点手柄：锚点保持原选区终点
      anchor = spanEndPosition(selection);
    } else if (this.dragMode === 2) {
      // 拖终点手柄：锚点保持原选区起点
      anchor = spanStartPosition(selection);
    }
    this.setSelection(makeTextSelection(anchor, position));
  }

  /** 结束拖拽：恢复列表滚动并在下一帧重定位气泡 */
  private endDrag(): void {
    this.dragMode = 0;
    this.stopEdgeScroll();
    if (this.isSelectionDragging) {
      this.isSelectionDragging = false;
    }
    this.refreshSelectionOverlay();
    if (this.hasSelection()) {
      this.scheduleBubble();
    } else {
      this.bubbleShown = false;
    }
  }

  /** 长按选词：命中文字后立即进入拖选态，允许不抬手继续滑动扩选 */
  private handleLongPress(event: GestureEvent): void {
    if (this.isGesturing || !this.document) {
      return;
    }
    const fingerList = event.fingerList;
    if (!fingerList || fingerList.length === 0) {
      return;
    }
    const screenX = fingerList[0].localX;
    const screenY = fingerList[0].localY;
    this.lastTouchX = screenX;
    this.lastTouchY = screenY;
    const position = this.hitTestScreen(screenX, screenY, 0);
    if (!position) {
      return;
    }
    const layout = this.textLayout;
    if (!layout) {
      return;
    }
    const range = layout.wordRange(position);
    if (!range) {
      return;
    }
    this.stopEdgeScroll();
    this.cancelBubbleTimer();
    this.bubbleShown = false;
    this.dragMode = 3;
    if (this.isSelectionDragging !== true) {
      this.isSelectionDragging = true;
    }
    this.setSelection(range);
  }

  /** 单击：存在选区时清除并消费本次点击，避免误触发其它行为 */
  private handleSingleTap(): void {
    if (this.hasSelection()) {
      this.clearSelection();
    }
  }

  // MARK: - 边缘自动滚动

  /** 触点进入上下边缘热区时启动定时滚动，步长随深入程度线性递增 */
  private updateEdgeScroll(screenX: number, screenY: number): void {
    let direction = 0;
    if (screenY < SELECTION_EDGE_SCROLL_ZONE) {
      direction = -1;
    } else if (screenY > this.viewportHeight - SELECTION_EDGE_SCROLL_ZONE) {
      direction = 1;
    }
    if (direction === 0) {
      this.stopEdgeScroll();
      return;
    }
    if (this.edgeScrollTimer !== -1 && this.edgeScrollDirection === direction) {
      return;
    }
    this.stopEdgeScroll();
    this.edgeScrollDirection = direction;
    this.edgeScrollTimer = setInterval(() => {
      this.stepEdgeScroll();
    }, SELECTION_EDGE_SCROLL_INTERVAL);
  }

  /** 单步边缘滚动：按到边缘的距离决定步长，滚动后以最新触点重算焦点 */
  private stepEdgeScroll(): void {
    if (this.dragMode === 0 || this.edgeScrollDirection === 0) {
      this.stopEdgeScroll();
      return;
    }
    const zone = SELECTION_EDGE_SCROLL_ZONE;
    let depth = 0;
    if (this.edgeScrollDirection < 0) {
      depth = Math.max(0, zone - this.lastTouchY);
    } else {
      depth = Math.max(0, this.lastTouchY - (this.viewportHeight - zone));
    }
    if (depth <= 0) {
      this.stopEdgeScroll();
      return;
    }
    const ratio = Math.min(1, depth / zone);
    const step = Math.max(1, SELECTION_EDGE_SCROLL_MAX_STEP * ratio);
    this.scroller.scrollBy(0, step * this.edgeScrollDirection);
    this.updateDrag(this.lastTouchX, this.lastTouchY);
    this.refreshSelectionOverlay();
  }

  private stopEdgeScroll(): void {
    if (this.edgeScrollTimer !== -1) {
      clearInterval(this.edgeScrollTimer);
      this.edgeScrollTimer = -1;
    }
    this.edgeScrollDirection = 0;
  }

  // MARK: - 浮动气泡

  /** 手势停稳后延迟一拍再定位气泡，避免在滚动/缩放过程中反复布局 */
  private scheduleBubble(): void {
    this.cancelBubbleTimer();
    this.bubbleTimer = setTimeout(() => {
      this.bubbleTimer = -1;
      this.repositionBubble();
    }, 32);
  }

  private cancelBubbleTimer(): void {
    if (this.bubbleTimer !== -1) {
      clearTimeout(this.bubbleTimer);
      this.bubbleTimer = -1;
    }
  }

  /** 依据选区整体屏幕包围框定位气泡，并判断是否已全选 */
  private repositionBubble(): void {
    const selection = this.selection;
    if (!selection || isSelectionEmpty(selection)) {
      this.bubbleShown = false;
      return;
    }
    const bounds = this.selectionScreenBounds(selection);
    if (!bounds) {
      // 选区当前不在可见区域（如全选后尚未滚动到），不展示气泡避免悬空
      this.bubbleShown = false;
      return;
    }
    this.bubbleAnchorX = (bounds.left + bounds.right) / 2;
    this.bubbleAnchorY = bounds.top;
    this.bubbleBottomY = bounds.bottom;
    this.bubbleShowSelectAll = !this.isWholeDocumentSelected(selection);
    this.bubbleShown = true;
  }

  /** 选区在屏幕坐标系下的整体包围框（仅统计可见 ListItem 内的矩形） */
  private selectionScreenBounds(selection: TextSelection): TextRect | null {
    const start = spanStartPosition(selection);
    const end = spanEndPosition(selection);
    const range = this.hitScanRange();
    let left = 0;
    let top = 0;
    let right = 0;
    let bottom = 0;
    let found = false;
    for (let index = range[0]; index <= range[1]; index++) {
      const plan = this.itemTextPlans.get(index);
      if (!plan) {
        continue;
      }
      if (plan.blockBase + plan.blockCount - 1 < start.blockIndex || plan.blockBase > end.blockIndex) {
        continue;
      }
      const rect = this.itemRectOf(index);
      const layout = this.ensureItemLayout(index);
      if (!rect || !layout) {
        continue;
      }
      const localRects = layout.selectionRects(selection);
      for (const highlight of localRects) {
        const docRect = highlight.docBounds;
        const p1 = this.panelToScreen(rect.x + docRect.left, rect.y + docRect.top);
        const p2 = this.panelToScreen(rect.x + docRect.right, rect.y + docRect.bottom);
        const x1 = Math.min(p1.x, p2.x);
        const x2 = Math.max(p1.x, p2.x);
        const y1 = Math.min(p1.y, p2.y);
        const y2 = Math.max(p1.y, p2.y);
        if (!found) {
          left = x1;
          top = y1;
          right = x2;
          bottom = y2;
          found = true;
        } else {
          left = Math.min(left, x1);
          top = Math.min(top, y1);
          right = Math.max(right, x2);
          bottom = Math.max(bottom, y2);
        }
      }
    }
    if (!found) {
      return null;
    }
    return makeTextRect(left, top, right, bottom);
  }

  /** 选区是否已覆盖全文（用于隐藏气泡中的「全选」） */
  private isWholeDocumentSelected(selection: TextSelection): boolean {
    const layout = this.textLayout;
    if (!layout) {
      return false;
    }
    const all = layout.allTextRange();
    if (!all) {
      return false;
    }
    const allStart = spanStartPosition(all);
    const allEnd = spanEndPosition(all);
    const start = spanStartPosition(selection);
    const end = spanEndPosition(selection);
    return start.blockIndex === allStart.blockIndex && start.charIndex <= allStart.charIndex &&
      end.blockIndex === allEnd.blockIndex && end.charIndex >= allEnd.charIndex;
  }

  /** 气泡「复制」：写入剪贴板后清除选区并隐藏气泡 */
  private onBubbleCopy(): void {
    if (this.copySelection()) {
      this.clearSelection();
    } else {
      this.bubbleShown = false;
    }
  }

  /** 气泡「全选」：全选正文并重定位气泡 */
  private onBubbleSelectAll(): void {
    if (this.selectAll()) {
      this.scheduleBubble();
    }
  }

  /** List 滚动中：手柄跟随滚动实时刷新，气泡整段隐藏，停稳后再出现 */
  private onListScrolled(): void {
    if (this.hasSelection()) {
      if (this.bubbleShown) {
        this.bubbleShown = false;
      }
      this.refreshSelectionOverlay();
    }
  }

  /** List 滚动停稳：刷新手柄并重新弹出气泡 */
  private onScrollSettled(): void {
    if (this.hasSelection()) {
      this.refreshSelectionOverlay();
      this.scheduleBubble();
    }
  }

  private matchesOfGroup(group: DocxWrapGroup | null): model.SearchMatch[] {
    if (!group) return [];
    const result: model.SearchMatch[] = [];
    for (const m of this.searchMatches) {
      if (m.elementIndex >= group.renderIndex && m.elementIndex <= group.endIndex) {
        result.push(m);
      }
    }
    return result;
  }

  private getStandaloneOffsetX(element: model.Element): number {
    if (!this.document || !isDocxFloating(element)) return 0;
    return resolveDocxFloatBox(
      this.document.width,
      this.document.marginLeft ?? 0,
      this.document.marginRight ?? 0,
      toWrapBlockInput(element),
      this.getContentWidth()
    ).x;
  }

  private computeItemTopMargin(index: number, element: model.Element): number {
    if (this.consumedToGroup.has(index)) {
      return 0;
    }
    return resolveDocxItemTopMargin(
      index,
      this.headerCount,
      this.bodyCount,
      this.sectionGap,
      this.wrapGroups.has(index),
      element.wrapMode,
      element.y,
      element.distTop ?? 0
    );
  }

  private computeItemBottomMargin(index: number, element: model.Element): number {
    if (this.consumedToGroup.has(index)) {
      return 0;
    }
    const endIdx = this.wrapGroups.get(index)?.endIndex ?? index;
    const secBottom = (this.headerCount > 0 && endIdx === this.headerCount - 1) ? this.sectionGap : 0;
    const floatBottom = (!this.wrapGroups.has(index) && element.wrapMode === 'TOP_AND_BOTTOM')
      ? Math.max(0, element.distBottom || 0)
      : 0;
    return 8 + secBottom + floatBottom;
  }

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
    // 缩放后手柄锚点必须按新变换重算
    if (this.hasSelection()) {
      this.refreshSelectionOverlay();
      this.scheduleBubble();
    }
  }

  /** 当前命中的身份字符串，作为 @Prop 传给子组件以驱动高亮刷新 */
  private currentMatchKey(): string {
    const idx = this.currentMatchIndex;
    if (idx < 0 || idx >= this.searchMatches.length) return '';
    return searchMatchKey(this.searchMatches[idx]);
  }

  /** 取某个块上的命中；返回新数组，避免 @Prop 深拷贝共享引用 */
  private matchesOfBlock(index: number): model.SearchMatch[] {
    const result: model.SearchMatch[] = [];
    for (const m of this.searchMatches) {
      if (m.elementIndex === index) result.push(m);
    }
    return result;
  }

  /** 某个渲染单元在全局文本索引中的起始块编号 */
  private blockBaseOf(index: number): number {
    const plan = this.itemTextPlans.get(index);
    return plan ? plan.blockBase : -1;
  }

  /** 计算块在 LazyForEach 中的缓存键，保证当前命中切换与环绕布局刷新 */
  private getBlockKey(index: number): string {
    if (this.consumedToGroup.has(index)) {
      return `consumed-${index}-r${this.layoutRevision}`;
    }
    const group = this.wrapGroups.get(index);
    const startIdx = group ? group.renderIndex : index;
    const endIdx = group ? group.endIndex : index;
    const hasMatches = this.searchMatches && this.searchMatches.some(
      (m: model.SearchMatch): boolean => m.elementIndex >= startIdx && m.elementIndex <= endIdx
    );
    if (!hasMatches) {
      return `block-${index}-r${this.layoutRevision}`;
    }
    const curMatch = (this.currentMatchIndex >= 0 && this.currentMatchIndex < this.searchMatches.length)
      ? this.searchMatches[this.currentMatchIndex]
      : null;
    const isCurrent = curMatch !== null && curMatch.elementIndex >= startIdx && curMatch.elementIndex <= endIdx;
    return `block-${index}-r${this.layoutRevision}-${this.reuseVersion}-${isCurrent ? this.currentMatchIndex : 'idle'}`;
  }

  build() {
    if (this.document) {
      Stack() {
        Stack() {
          List({ space: 0, scroller: this.scroller }) {
            LazyForEach(
              this.blockSource,
              (element: model.Element, index: number) => {
                ListItem() {
                  if (this.consumedToGroup.has(index)) {
                    Row().width(0).height(0)
                  } else if (this.wrapGroups.has(index)) {
                    DocxWrappedBlockView({
                      group: this.wrapGroups.get(index) ?? null,
                      imageStore: this.imageStore,
                      groupMatches: this.matchesOfGroup(this.wrapGroups.get(index) ?? null),
                      currentMatchKey: this.currentMatchKey(),
                      blockBaseIndex: this.blockBaseOf(index),
                      selectionKey: this.selectionKey
                    })
                  } else if (element.type === 'TABLE' && element.rows && element.rows.length > 0) {
                    DocxTableView({
                      element: element,
                      imageStore: this.imageStore,
                      blockMatches: this.matchesOfBlock(index),
                      currentMatchKey: this.currentMatchKey(),
                      blockBaseIndex: this.blockBaseOf(index),
                      selectionKey: this.selectionKey
                    })
                  } else if (element.type === 'IMAGE') {
                    DocxImageView({
                      element: element,
                      imageStore: this.imageStore,
                      floatingOffsetX: isDocxFloating(element) ? this.getStandaloneOffsetX(element) : -1
                    })
                  } else if (element.type === 'RECT' || element.type === 'ELLIPSE' || element.type === 'LINE' || element.type === 'PATH') {
                    DocxShapeView({
                      element: element,
                      imageStore: this.imageStore,
                      floatingOffsetX: isDocxFloating(element) ? this.getStandaloneOffsetX(element) : -1,
                      blockBaseIndex: this.blockBaseOf(index),
                      selectionKey: this.selectionKey
                    })
                  } else if (element.paragraphs && element.paragraphs.length > 0) {
                    DocxTextBlockView({
                      element: element,
                      blockMatches: this.matchesOfBlock(index),
                      currentMatchKey: this.currentMatchKey(),
                      blockBaseIndex: this.blockBaseOf(index),
                      selectionKey: this.selectionKey,
                      contentWidth: this.getContentWidth()
                    })
                  }
                }
                .reuseId(this.consumedToGroup.has(index) ? 'CONSUMED' : (this.wrapGroups.has(index) ? 'WRAP_GROUP' : element.type))
                // 页眉最后一块之后、页脚第一块之前额外留白，让页眉页脚与正文视觉分开
                .margin({
                  top: this.computeItemTopMargin(index, element),
                  bottom: this.computeItemBottomMargin(index, element)
                })
              },
              (_element: model.Element, index: number): string => this.getBlockKey(index)
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
          // 拖选期间禁用列表滚动，避免纵向手势被 List 抢走
          .enableScrollInteraction(!this.isSelectionDragging)
          .onScrollIndex((start: number, end: number, _center: number) => {
            this.visibleStart = start;
            this.visibleEnd = end;
            this.onListScrolled();
          })
          .onScrollStop(() => {
            this.onScrollSettled();
          })
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
        const nextContentW = this.getContentWidth();
        if (Math.abs(nextContentW - this.plannedWidth) > 1) {
          this.rebuildWrapPlan(nextContentW);
          this.rebuildTextIndex();
          this.layoutRevision++;
        }
        this.clampOffsets();
        this.syncSettledZoomPad();
        if (this.hasSelection()) {
          this.refreshSelectionOverlay();
        }
      })
      .onTouch((event: TouchEvent) => {
        this.handleDocxTouch(event);
      })
      .gesture(
        GestureGroup(
          GestureMode.Parallel,
          // 双击缩放优先于单击清除选区，避免双击第二次点击误清选区
          GestureGroup(
            GestureMode.Exclusive,
            TapGesture({ count: 2, distanceThreshold: 3 })
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
            // 单击：存在选区时清除选区并消费本次点击
            TapGesture({ count: 1 })
              .onAction((_event: GestureEvent) => {
                this.handleSingleTap();
              })
          ),
          // 长按 400ms 选词，之后不抬手即可滑动扩选
          LongPressGesture({ duration: SELECTION_LONG_PRESS_MS, repeat: false })
            .onAction((event: GestureEvent) => {
              this.handleLongPress(event);
            })
            .onActionEnd(() => {
              if (this.dragMode === 3) {
                this.endDrag();
              }
            })
            .onActionCancel(() => {
              if (this.dragMode === 3) {
                this.endDrag();
              }
            }),
          PinchGesture({ fingers: 2 })
            .onActionStart(() => {
              if (this.dragMode !== 0) {
                this.dragMode = 0;
                this.isSelectionDragging = false;
                this.stopEdgeScroll();
              }
              this.isGesturing = true;
              this.pinchStartZoom = Math.max(1.0, Math.min(RenderUtils.ZOOM_MAX, this.zoom));
              this.pinchStartOffsetX = this.offsetX;
              this.bubbleShown = false;
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
              if (this.hasSelection()) {
                this.refreshSelectionOverlay();
              }
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
              if (this.hasSelection()) {
                this.refreshSelectionOverlay();
                this.scheduleBubble();
              }
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
              if (this.hasSelection()) {
                this.refreshSelectionOverlay();
                this.scheduleBubble();
              }
            }),
          PanGesture({ direction: PanDirection.Horizontal })
            .onActionStart(() => {
              if (this.isSelectionDragging) return;
              this.isGesturing = true;
              this.panStartX = this.offsetX;
            })
            .onActionUpdate((event: GestureEvent) => {
              if (this.isSelectionDragging) return;
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

      // 手柄叠加层：全尺寸透明 Canvas，不参与命中测试，只做屏幕坐标绘制
      if (this.hasSelectionLayer) {
        Canvas(this.overlayCtx)
          .width('100%')
          .height('100%')
          .hitTestBehavior(HitTestMode.None)
          .onReady(() => {
            this.overlayReady = true;
            this.drawOverlayCanvas();
          })
          .onAreaChange(() => {
            this.drawOverlayCanvas();
          })
      }

      // 浮动操作气泡：仅在停稳后出现
      if (this.bubbleShown) {
        SelectionMenuBubble({
          anchorX: this.bubbleAnchorX,
          anchorY: this.bubbleAnchorY,
          anchorBottomY: this.bubbleBottomY,
          viewportWidth: this.viewportWidth,
          viewportHeight: this.viewportHeight,
          showSelectAll: this.bubbleShowSelectAll,
          onCopy: (): void => {
            this.onBubbleCopy();
          },
          onSelectAll: (): void => {
            this.onBubbleSelectAll();
          }
        })
      }
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
  floatingOffsetX: number = -1;

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
    this.floatingOffsetX = params['floatingOffsetX'] !== undefined ? (params['floatingOffsetX'] as number) : -1;
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
    .justifyContent(this.floatingOffsetX >= 0 ? FlexAlign.Start : resolveInlineFlexAlign(this.element))
    .padding(this.floatingOffsetX > 0 ? { left: this.floatingOffsetX } : undefined)
    .margin(this.floatingOffsetX >= 0 ? { top: 0, bottom: 0 } : { top: 4, bottom: 6 })
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
  floatingOffsetX: number = -1;
  /** 形状内文字在全局文本索引中的起始块编号（无文字时为 -1） */
  @Prop blockBaseIndex: number = -1;
  /** 选区身份字符串；变化即重绘以刷新形状内文字的选区高亮 */
  @Prop @Watch('onSelectionChanged') selectionKey: string = '';
  @State private reuseVersion: number = 0;

  private settings: RenderingContextSettings = new RenderingContextSettings(true);
  private ctx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings);
  private measureCtx: OffscreenCanvasRenderingContext2D | null = null;
  private isReady: boolean = false;

  onSelectionChanged(): void {
    if (this.isReady) {
      this.drawShape();
    }
  }

  aboutToReuse(params: Record<string, Object>): void {
    if (params['element']) {
      this.element = params['element'] as model.Element;
    }
    if (params['imageStore']) {
      this.imageStore = params['imageStore'] as ImageStore;
    }
    this.floatingOffsetX = params['floatingOffsetX'] !== undefined ? (params['floatingOffsetX'] as number) : -1;
    this.blockBaseIndex = params['blockBaseIndex'] !== undefined ? (params['blockBaseIndex'] as number) : -1;
    this.selectionKey = params['selectionKey'] !== undefined ? (params['selectionKey'] as string) : '';
    this.reuseVersion++;
    if (this.isReady) {
      this.drawShape();
    }
  }

  private ensureMeasureCtx(): OffscreenCanvasRenderingContext2D {
    if (!this.measureCtx) {
      this.measureCtx = new OffscreenCanvas(1, 1).getContext('2d', new RenderingContextSettings(true));
    }
    return this.measureCtx;
  }

  /**
   * 形状内文字的选区高亮矩形（形状元素局部坐标）。
   * 行度量由 CanvasElementDrawer 以与 drawElement 相同的 padding / 可用宽度构建，
   * 因此可直接叠加在已绘制的文字之上。
   */
  private selectionRects(): TextRect[] {
    const el = this.element;
    if (!el || !this.selectionKey || this.blockBaseIndex < 0) {
      return [];
    }
    const paragraphs = el.paragraphs ?? [];
    if (paragraphs.length === 0) {
      return [];
    }
    const span = decodeSelectionKey(this.selectionKey);
    if (!span.active || !blockTouchesSelection(this.blockBaseIndex, span.startBlock, span.endBlock)) {
      return [];
    }
    const selection = selectionFromSpan(span);
    if (!selection) {
      return [];
    }
    const padding = Math.max(0, el.padding ?? 4);
    const availW = Math.max(1, el.width - padding * 2);
    const layout = CanvasElementDrawer.buildParagraphsBlockLines(
      this.ensureMeasureCtx(), paragraphs, padding, availW, el.height, el.verticalAlignment, el.textWrap !== false
    );
    if (layout.fullText.length === 0) {
      return [];
    }
    const block = makeContainerBlock(this.blockBaseIndex, 0, layout.fullText, layout.lines);
    return new DocumentTextLayout([block]).blockSelectionRects(selection, this.blockBaseIndex);
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
    const selRects = this.selectionRects();
    if (selRects.length > 0) {
      CanvasElementDrawer.drawSelectionHighlights(ctx, selRects);
    }
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
      .justifyContent(this.floatingOffsetX >= 0 ? FlexAlign.Start : resolveInlineFlexAlign(this.element))
      .padding(this.floatingOffsetX > 0 ? { left: this.floatingOffsetX } : undefined)
      .margin(this.floatingOffsetX >= 0 ? { top: 0, bottom: 0 } : { top: 4, bottom: 6 })
    }
  }
}

function resolveInlineFlexAlign(element: model.Element | null): FlexAlign {
  const align = element?.horizontalAlign ?? 0;
  if (align === 1) {
    return FlexAlign.Start;
  }
  if (align === 2) {
    return FlexAlign.Center;
  }
  if (align === 3) {
    return FlexAlign.End;
  }
  return FlexAlign.Center;
}

interface DocxPlacedFloat {
  element: model.Element;
  x: number;
  y: number;
  width: number;
  height: number;
  behind: boolean;
}

interface DocxFlowTextItem {
  blockIndex: number;
  element: model.Element;
}

interface DocxWrapGroup {
  renderIndex: number;
  endIndex: number;
  width: number;
  height: number;
  flowStartY: number;
  floats: DocxPlacedFloat[];
  flows: DocxFlowTextItem[];
  obstacles: WrapObstacle[];
}

function isDocxFloating(el: model.Element): boolean {
  return isDocxFloatingWrap(el.wrapMode);
}

function toWrapBlockInput(el: model.Element): DocxWrapBlockInput {
  return {
    type: el.type,
    x: el.x,
    y: el.y,
    width: el.width,
    height: el.height,
    wrapMode: el.wrapMode ?? 'INLINE',
    horizontalAlign: el.horizontalAlign ?? 0,
    behindDoc: el.behindDoc === true,
    distTop: el.distTop ?? 0,
    distBottom: el.distBottom ?? 0,
    distLeft: el.distLeft ?? 0,
    distRight: el.distRight ?? 0,
    hasParagraphs: el.paragraphs !== undefined && el.paragraphs.length > 0
  };
}

function cloneElementForCanvas(src: model.Element, width: number, height: number): model.Element {
  return {
    type: src.type,
    x: 0,
    y: 0,
    width,
    height,
    transform: src.transform,
    padding: src.padding,
    fill: src.fill,
    stroke: src.stroke,
    strokeWidth: src.strokeWidth,
    image: src.image,
    imageBounds: src.imageBounds,
    verticalAlignment: src.verticalAlignment,
    textWrap: src.textWrap,
    paragraphs: src.paragraphs,
    rows: src.rows,
    columnWidths: src.columnWidths,
    cellFills: src.cellFills,
    cellValigns: src.cellValigns,
    cellBorders: src.cellBorders,
    strokeDash: src.strokeDash,
    paths: src.paths,
    fillGradient: src.fillGradient,
    merges: src.merges
  };
}

/**
 * DOCX 浮动图文与环绕文本复合 Canvas 视图：按 behind -> wrapped flow -> front 顺序绘制
 */
@Reusable
@Component
struct DocxWrappedBlockView {
  group: DocxWrapGroup | null = null;
  imageStore: ImageStore = new ImageStore('');
  @Prop @Watch('onHighlightsChanged') groupMatches: model.SearchMatch[] = [];
  @Prop @Watch('onHighlightsChanged') currentMatchKey: string = '';
  /** 组内首个 flow 块在全局文本索引中的起始块编号；floats 文本紧随其后 */
  @Prop blockBaseIndex: number = -1;
  /** 选区身份字符串；变化即重绘以刷新组内选区高亮 */
  @Prop @Watch('onHighlightsChanged') selectionKey: string = '';

  private settings: RenderingContextSettings = new RenderingContextSettings(true);
  private ctx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings);
  private isReady: boolean = false;
  private isDisappeared: boolean = false;
  private acquiredParts: string[] = [];
  private loadGeneration: number = 0;

  onHighlightsChanged(): void {
    this.drawComposite();
  }

  aboutToAppear(): void {
    this.isDisappeared = false;
    this.loadImages();
  }

  aboutToDisappear(): void {
    this.isDisappeared = true;
    this.loadGeneration++;
    this.releaseAcquired();
  }

  aboutToRecycle(): void {
    this.loadGeneration++;
    this.releaseAcquired();
  }

  aboutToReuse(params: Record<string, Object>): void {
    this.isDisappeared = false;
    if (params['group']) {
      this.group = params['group'] as DocxWrapGroup;
    }
    if (params['imageStore']) {
      this.imageStore = params['imageStore'] as ImageStore;
    }
    if (params['groupMatches']) {
      this.groupMatches = params['groupMatches'] as model.SearchMatch[];
    }
    if (params['currentMatchKey'] !== undefined) {
      this.currentMatchKey = params['currentMatchKey'] as string;
    }
    this.blockBaseIndex = params['blockBaseIndex'] !== undefined ? (params['blockBaseIndex'] as number) : -1;
    this.selectionKey = params['selectionKey'] !== undefined ? (params['selectionKey'] as string) : '';
    this.releaseAcquired();
    this.loadImages();
    this.drawComposite();
  }

  /**
   * 组内选区高亮矩形（组画布局部坐标）。
   * 块编号顺序与 DocxFlowView 的全量索引一致：先按 flows 顺序，再按 floats 顺序，
   * 只对含文字的 flow/float 递增编号，因此这里的累加必须与索引构建完全同步。
   */
  private selectionRects(): TextRect[] {
    const group = this.group;
    if (!group || !this.selectionKey || this.blockBaseIndex < 0) {
      return [];
    }
    const span = decodeSelectionKey(this.selectionKey);
    if (!span.active || span.endBlock < this.blockBaseIndex) {
      return [];
    }
    const selection = selectionFromSpan(span);
    if (!selection) {
      return [];
    }
    const result: TextRect[] = [];
    let blockIndex = this.blockBaseIndex;
    let curY = group.flowStartY;
    for (const flow of group.flows) {
      const paras = flow.element.paragraphs ?? [];
      const layout = CanvasElementDrawer.buildParagraphsBlockLines(
        this.ctx, paras, 0, group.width, 0, 'TOP', true, group.obstacles, curY, 0
      );
      if (layout.fullText.length > 0) {
        if (blockTouchesSelection(blockIndex, span.startBlock, span.endBlock)) {
          const lines = translateLineMetrics(layout.lines, 0, curY);
          const block = makeContainerBlock(blockIndex, 0, layout.fullText, lines);
          const rects = new DocumentTextLayout([block]).blockSelectionRects(selection, blockIndex);
          for (const rect of rects) {
            result.push(rect);
          }
        }
        blockIndex++;
      }
      // 同步推进纵向位置：绘制侧同样按 before/行高/after 累加
      for (const para of paras) {
        curY += Math.max(0, para.before || 0);
        const lines = CanvasElementDrawer.layoutParagraph(this.ctx, para, group.width, true, group.obstacles, curY, 0);
        let drawnH = 0;
        for (const line of lines) {
          drawnH += line.height;
        }
        curY += drawnH + Math.max(0, para.after || 0);
      }
      curY += 8;
    }
    for (const floatItem of group.floats) {
      const paras = floatItem.element.paragraphs ?? [];
      if (paras.length === 0) {
        continue;
      }
      const pad = Math.max(0, floatItem.element.padding ?? 4);
      const rawW = floatItem.element.width > 0 ? floatItem.element.width : floatItem.width;
      const availW = Math.max(1, rawW - pad * 2);
      const layout = CanvasElementDrawer.buildParagraphsBlockLines(
        this.ctx, paras, pad, availW, floatItem.height, floatItem.element.verticalAlignment,
        floatItem.element.textWrap !== false
      );
      if (layout.fullText.length === 0) {
        continue;
      }
      if (blockTouchesSelection(blockIndex, span.startBlock, span.endBlock)) {
        const lines = translateLineMetrics(layout.lines, floatItem.x, floatItem.y);
        const block = makeContainerBlock(blockIndex, 0, layout.fullText, lines);
        const rects = new DocumentTextLayout([block]).blockSelectionRects(selection, blockIndex);
        for (const rect of rects) {
          result.push(rect);
        }
      }
      blockIndex++;
    }
    return result;
  }

  private releaseAcquired(): void {
    for (const part of this.acquiredParts) {
      this.imageStore.releasePart(part);
    }
    this.acquiredParts = [];
  }

  private async loadImages(): Promise<void> {
    if (!this.group) return;
    const gen = ++this.loadGeneration;
    const parts: string[] = [];
    for (const f of this.group.floats) {
      const part = f.element.image;
      if (part && parts.indexOf(part) < 0) {
        parts.push(part);
        this.imageStore.acquire(part);
        this.acquiredParts.push(part);
      }
    }
    if (parts.length === 0) return;
    const budget = Math.max(120_000, Math.min(2_000_000, Math.round(this.group.width * this.group.height * 4)));
    for (const part of parts) {
      if (!this.imageStore.cache.has(part)) {
        try {
          await this.imageStore.load(part, budget);
        } catch (_e) {
          // 忽略单张浮动图片解码失败，保留其余内容与占位
        }
      }
    }
    if (!this.isDisappeared && this.loadGeneration === gen && this.isReady) {
      this.drawComposite();
    }
  }

  private drawFloat(f: DocxPlacedFloat): void {
    const src = f.element;
    const rawW = src.width > 0 ? src.width : f.width;
    const rawH = src.height > 0 ? src.height : f.height;
    const canvasEl = cloneElementForCanvas(src, rawW, rawH);
    this.ctx.save();
    this.ctx.translate(f.x, f.y);
    if (rawW > 0 && rawH > 0 && (Math.abs(f.width - rawW) > 0.5 || Math.abs(f.height - rawH) > 0.5)) {
      this.ctx.scale(f.width / rawW, f.height / rawH);
    }
    CanvasElementDrawer.drawElement(this.ctx, canvasEl, this.imageStore.cache);
    this.ctx.restore();
  }

  private drawComposite(): void {
    if (!this.isReady || !this.group) return;
    const w = this.ctx.width;
    const h = this.ctx.height;
    if (w <= 0 || h <= 0) return;
    this.ctx.clearRect(0, 0, w, h);

    for (const f of this.group.floats) {
      if (f.behind) {
        this.drawFloat(f);
      }
    }

    let curY = this.group.flowStartY;
    for (const flow of this.group.flows) {
      const paras = flow.element.paragraphs ?? [];
      for (let pIdx = 0; pIdx < paras.length; pIdx++) {
        const para = paras[pIdx];
        curY += Math.max(0, para.before || 0);
        for (const m of this.groupMatches) {
          if (m.elementIndex === flow.blockIndex && m.paragraphIndex === pIdx) {
            const rects = CanvasElementDrawer.computeParagraphHighlightRects(
              this.ctx, para, m.startChar, m.endChar, 0, curY, this.group.width, true,
              this.group.obstacles, curY, 0
            );
            const isCur = this.currentMatchKey.length > 0 && searchMatchKey(m) === this.currentMatchKey;
            this.ctx.fillStyle = isCur ? '#FFA726' : '#FFF59D';
            for (const r of rects) {
              this.ctx.fillRect(r.x, r.y, r.width, r.height);
            }
          }
        }
        const lines = CanvasElementDrawer.layoutParagraph(
          this.ctx, para, this.group.width, true, this.group.obstacles, curY, 0
        );
        const drawnH = CanvasElementDrawer.drawParagraphLines(
          this.ctx, para, lines, 0, curY, this.group.width
        );
        curY += drawnH + Math.max(0, para.after || 0);
      }
      curY += 8;
    }

    for (const f of this.group.floats) {
      if (!f.behind) {
        this.drawFloat(f);
      }
    }

    // 选区高亮最后绘制，保证覆盖在绕排文字与检索高亮之上
    const selRects = this.selectionRects();
    if (selRects.length > 0) {
      CanvasElementDrawer.drawSelectionHighlights(this.ctx, selRects);
    }
  }

  build() {
    if (this.group) {
      Row() {
        Canvas(this.ctx)
          .width('100%')
          .height(this.group.height)
          .onReady(() => {
            this.isReady = true;
            this.drawComposite();
          })
          .onAreaChange(() => {
            this.drawComposite();
          })
      }
      .width('100%')
    }
  }
}


/**
 * DOCX 普通流式文本块：单个自测量 Canvas 绘制全部段落。
 *
 * 从 ArkUI Text/Span 迁移到 Canvas 的原因：只有 Canvas 才能拿到逐行几何与字符 X 偏移，
 * 从而支持跨段落连续划词、精确高亮与手柄定位；同时与 DocxWrappedBlockView / DocxTableView
 * 共用 CanvasElementDrawer 的同一套排版规则，使普通块与绕排块的间距、缩进、
 * 上下标、下划线、删除线、字间距与两端对齐完全一致。
 *
 * 保留 @Reusable 与 List + LazyForEach 虚拟化：每个 ListItem 依然是独立可回收组件，
 * Canvas 只在 onReady / onAreaChange / 命中/选区变化时重绘。
 */
@Reusable
@Component
struct DocxTextBlockView {
  element: model.Element | null = null;
  @Prop @Watch('onMatchesChanged') blockMatches: model.SearchMatch[] = [];
  @Prop @Watch('onCurrentMatchKeyChanged') currentMatchKey: string = '';
  /** 本块在全局文本索引中的起始块编号（普通元素块数恒为 1） */
  @Prop blockBaseIndex: number = -1;
  /** 选区身份字符串；变化即重绘以刷新块内选区高亮 */
  @Prop @Watch('onSelectionChanged') selectionKey: string = '';
  /**
   * ListItem 内容宽度（vp）。与 DocxFlowView 建立文本索引时使用的宽度同源，
   * 保证命中测试/选区矩形与这里实际绘制的折行结果完全一致。
   */
  contentWidth: number = 0;
  @State private reuseVersion: number = 0;
  @State private measuredHeight: number = 0;

  private settings: RenderingContextSettings = new RenderingContextSettings(true);
  private ctx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings);
  private measureCtx: OffscreenCanvasRenderingContext2D | null = null;
  private isReady: boolean = false;
  private measuredWidth: number = 0;
  /**
   * 本块的行几何、拼接纯文本与预构建文本块。
   * 只在 memo 宽度/内容变化时重建：CanvasTextLineMetrics 内部会缓存逐字 X 偏移，
   * 复用它可避免拖选时每帧对整块正文重新 measureText。
   */
  private block: TextBlockLayout | null = null;
  private blockLayout: DocumentTextLayout | null = null;

  onCurrentMatchKeyChanged(): void {
    this.drawBlock();
  }

  onMatchesChanged(): void {
    this.drawBlock();
  }

  onSelectionChanged(): void {
    this.drawBlock();
  }

  aboutToAppear(): void {
    this.measureHeight();
    if (this.isReady) {
      this.drawBlock();
    }
  }

  aboutToReuse(params: Record<string, Object>): void {
    this.reuseVersion++;
    if (params['element']) {
      this.element = params['element'] as model.Element;
    }
    if (params['blockMatches']) {
      this.blockMatches = params['blockMatches'] as model.SearchMatch[];
    }
    if (params['currentMatchKey'] !== undefined) {
      this.currentMatchKey = params['currentMatchKey'] as string;
    }
    this.blockBaseIndex = params['blockBaseIndex'] !== undefined ? (params['blockBaseIndex'] as number) : -1;
    this.selectionKey = params['selectionKey'] !== undefined ? (params['selectionKey'] as string) : '';
    this.contentWidth = params['contentWidth'] !== undefined ? (params['contentWidth'] as number) : 0;
    this.measuredWidth = 0;
    this.measureHeight();
    this.drawBlock();
  }

  private ensureMeasureCtx(): OffscreenCanvasRenderingContext2D {
    if (!this.measureCtx) {
      this.measureCtx = new OffscreenCanvas(1, 1).getContext('2d', new RenderingContextSettings(true));
    }
    return this.measureCtx;
  }

  /** 段内水平内边距：普通流式块 core 下发 padding 为 0，缺省时同样按 0 处理 */
  private resolvePadding(): number {
    const el = this.element;
    return el ? docxTextPadding(el) : 0;
  }

  /**
   * 可用排版宽度（vp），与 buildParagraphsBlockLines 的 availableWidth 参数一致。
   * 优先用实测画布宽度（Canvas 为 100% 宽，即 ListItem 内容宽度），
   * 首帧尚未测量时回退到父组件下发的 contentWidth，两者同源因此不会产生折行差异。
   */
  private resolveAvailableWidth(): number {
    const padding = this.resolvePadding();
    const base = this.measuredWidth > 0
      ? this.measuredWidth
      : (this.contentWidth > 0 ? this.contentWidth : 320);
    return Math.max(1, base - padding * 2);
  }

  /**
   * 测量块高度：以与绘制完全相同的参数调用 buildParagraphsBlockLines，
   * 累加行高与段落 before/after，得到 Canvas 需要占用的纵向尺寸。
   */
  private measureHeight(): void {
    const el = this.element;
    if (!el || !el.paragraphs || el.paragraphs.length === 0) {
      if (this.measuredHeight !== 0) {
        this.measuredHeight = 0;
      }
      return;
    }
    const ctx = this.ensureMeasureCtx();
    const padding = this.resolvePadding();
    const availW = this.resolveAvailableWidth();
    const layout = CanvasElementDrawer.buildParagraphsBlockLines(
      ctx,
      el.paragraphs,
      padding,
      availW,
      0,
      el.verticalAlignment,
      el.textWrap !== false
    );
    const contentHeight = CanvasElementDrawer.measureParagraphsHeight(
      ctx,
      el.paragraphs,
      availW,
      el.textWrap !== false
    );
    const total = contentHeight + padding * 2;
    const next = Math.max(1, Math.ceil(total));
    if (Math.abs(next - this.measuredHeight) > 0.5) {
      this.measuredHeight = next;
    }
    // 预构建文本块：选区高亮与手柄几何直接复用这份行度量（含逐字偏移缓存）
    if (this.blockBaseIndex >= 0 && layout.fullText.length > 0) {
      this.block = makeContainerBlock(this.blockBaseIndex, 0, layout.fullText, layout.lines);
      this.blockLayout = new DocumentTextLayout([this.block]);
    } else {
      this.block = null;
      this.blockLayout = null;
    }
  }

  /** 本块在选区中的高亮矩形（块局部坐标） */
  private selectionRects(): TextRect[] {
    if (!this.selectionKey || this.blockBaseIndex < 0) {
      return [];
    }
    const span = decodeSelectionKey(this.selectionKey);
    if (!span.active || !blockTouchesSelection(this.blockBaseIndex, span.startBlock, span.endBlock)) {
      return [];
    }
    const selection = selectionFromSpan(span);
    if (!selection || !this.blockLayout) {
      return [];
    }
    return this.blockLayout.blockSelectionRects(selection, this.blockBaseIndex);
  }

  private drawBlock(): void {
    if (!this.isReady || !this.element) {
      return;
    }
    const w = this.ctx.width;
    const h = this.ctx.height;
    if (w <= 0 || h <= 0) {
      return;
    }
    const ctx = this.ctx;
    ctx.clearRect(0, 0, w, h);
    const el = this.element;
    const paragraphs = el.paragraphs ?? [];
    if (paragraphs.length === 0) {
      return;
    }
    const padding = this.resolvePadding();
    const availW = Math.max(1, w - padding * 2);
    const wrap = el.textWrap !== false;

    // 逐段绘制：与 buildParagraphsBlockLines 相同的 before/after 与纵向累加规则
    let curY = padding;
    for (let pIdx = 0; pIdx < paragraphs.length; pIdx++) {
      const para = paragraphs[pIdx];
      curY += Math.max(0, para.before || 0);
      const lines = CanvasElementDrawer.layoutParagraph(ctx, para, availW, wrap);
      const drawnH = CanvasElementDrawer.drawParagraphLines(ctx, para, lines, padding, curY, availW);
      curY += drawnH + Math.max(0, para.after || 0);
    }

    // 检索高亮：在文字之上叠加半透明底色，当前命中加重
    if (this.blockMatches && this.blockMatches.length > 0) {
      for (const m of this.blockMatches) {
        const isCurrent = this.currentMatchKey.length > 0 && searchMatchKey(m) === this.currentMatchKey;
        if (m.paragraphIndex < 0 || m.paragraphIndex >= paragraphs.length) {
          continue;
        }
        const para = paragraphs[m.paragraphIndex];
        // 计算该段起始 Y：重放 before/after 累加，避免依赖未导出的内部布局表
        let paraY = padding;
        for (let i = 0; i < m.paragraphIndex; i++) {
          const prev = paragraphs[i];
          paraY += Math.max(0, prev.before || 0);
          const prevLines = CanvasElementDrawer.layoutParagraph(ctx, prev, availW, wrap);
          for (const line of prevLines) {
            paraY += line.height;
          }
          paraY += Math.max(0, prev.after || 0);
        }
        paraY += Math.max(0, para.before || 0);
        const rects = CanvasElementDrawer.computeParagraphHighlightRects(
          ctx, para, m.startChar, m.endChar, padding, paraY, availW, wrap
        );
        for (const r of rects) {
          if (isCurrent) {
            ctx.fillStyle = 'rgba(255, 160, 0, 0.75)';
            ctx.fillRect(r.x, r.y, r.width, r.height);
            ctx.strokeStyle = '#e65100';
            ctx.lineWidth = 1.5;
            ctx.strokeRect(r.x, r.y, r.width, r.height);
          } else {
            ctx.fillStyle = 'rgba(255, 235, 59, 0.45)';
            ctx.fillRect(r.x, r.y, r.width, r.height);
          }
        }
      }
    }

    // 选区高亮最后绘制，保证覆盖在文字与检索高亮之上
    const selRects = this.selectionRects();
    if (selRects.length > 0) {
      CanvasElementDrawer.drawSelectionHighlights(ctx, selRects);
    }
  }

  build() {
    if (this.element && this.element.paragraphs && this.element.paragraphs.length > 0) {
      Row() {
        Canvas(this.ctx)
          .width('100%')
          .height(this.measuredHeight > 0 ? this.measuredHeight : 1)
          .constraintSize({ maxWidth: '100%' })
          .onReady(() => {
            this.isReady = true;
            this.measureHeight();
            this.drawBlock();
          })
          .onAreaChange((_oldVal: Area, newVal: Area) => {
            const newW = Number(newVal.width);
            if (newW > 0 && Math.abs(newW - this.measuredWidth) > 0.5) {
              this.measuredWidth = newW;
              // 宽度变化会改变折行结果与块高度，必须重新测量后重绘
              this.measureHeight();
              this.drawBlock();
            }
          })
      }
      .id(`text-${this.reuseVersion}`)
      .width('100%')
      .justifyContent(resolveInlineFlexAlign(this.element))
    }
  }
}

@Reusable
@Component
struct DocxTableView {
  element: model.Element | null = null;
  imageStore: ImageStore = new ImageStore('');
  @Prop @Watch('onMatchesChanged') blockMatches: model.SearchMatch[] = [];
  // Canvas 不会被 ArkUI 自动重绘，@Watch 保证「当前命中」变化时立即重画
  @Prop @Watch('onCurrentMatchKeyChanged') currentMatchKey: string = '';
  /** 表格首个非空单元格在全局文本索引中的起始块编号，其余单元格按行优先依次递增 */
  @Prop blockBaseIndex: number = -1;
  /** 选区身份字符串；变化即重绘以刷新单元格内选区高亮 */
  @Prop @Watch('onSelectionChanged') selectionKey: string = '';
  @State private reuseVersion: number = 0;
  @State private measuredHeight: number = 60;

  private settings: RenderingContextSettings = new RenderingContextSettings(true);
  private ctx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings);
  private isReady: boolean = false;

  aboutToAppear(): void {
    this.updateHeight();
    this.preloadImages();
  }

  aboutToDisappear(): void {
    this.releaseImages();
  }

  onCurrentMatchKeyChanged(): void {
    this.drawTable();
  }

  onMatchesChanged(): void {
    this.drawTable();
  }

  onSelectionChanged(): void {
    this.drawTable();
  }

  aboutToReuse(params: Record<string, Object>): void {
    this.releaseImages();
    if (params['element']) {
      this.element = params['element'] as model.Element;
    }
    if (params['imageStore']) {
      this.imageStore = params['imageStore'] as ImageStore;
    }
    if (params['blockMatches']) {
      this.blockMatches = params['blockMatches'] as model.SearchMatch[];
    }
    if (params['currentMatchKey'] !== undefined) {
      this.currentMatchKey = params['currentMatchKey'] as string;
    }
    this.blockBaseIndex = params['blockBaseIndex'] !== undefined ? (params['blockBaseIndex'] as number) : -1;
    this.selectionKey = params['selectionKey'] !== undefined ? (params['selectionKey'] as string) : '';
    this.reuseVersion++;
    this.updateHeight();
    this.preloadImages();
    if (this.isReady) {
      this.drawTable();
    }
  }

  /**
   * 表格内各单元格的选区高亮矩形（表格元素局部坐标）。
   * 每个非空单元格独立成一个文本块，块编号从 blockBaseIndex 起按行优先递增，
   * 与 DocxFlowView 建立的全量索引、CanvasElementDrawer.buildElementTextBlocks 完全一致。
   */
  private selectionRects(): TextRect[] {
    const el = this.element;
    if (!el || !this.selectionKey || this.blockBaseIndex < 0) {
      return [];
    }
    const span = decodeSelectionKey(this.selectionKey);
    if (!span.active || span.endBlock < this.blockBaseIndex) {
      return [];
    }
    const selection = selectionFromSpan(span);
    if (!selection) {
      return [];
    }
    const blocks = CanvasElementDrawer.buildElementTextBlocks(this.ctx, el, this.blockBaseIndex, 0);
    const result: TextRect[] = [];
    for (const block of blocks) {
      if (!blockTouchesSelection(block.blockIndex, span.startBlock, span.endBlock)) {
        continue;
      }
      const layout = new DocumentTextLayout([block]);
      const rects = layout.blockSelectionRects(selection, block.blockIndex);
      for (const rect of rects) {
        result.push(rect);
      }
    }
    return result;
  }

  private preloadImages(): void {
    if (!this.element?.rows) return;
    for (const row of this.element.rows) {
      for (const cell of row) {
        for (const p of cell) {
          if (p.image) {
            this.imageStore.acquire(p.image);
            if (!this.imageStore.cache.has(p.image)) {
              this.imageStore.load(p.image).then(() => {
                this.updateHeight();
                if (this.isReady) this.drawTable();
              });
            }
          }
        }
      }
    }
  }

  private releaseImages(): void {
    if (!this.element?.rows) return;
    for (const row of this.element.rows) {
      for (const cell of row) {
        for (const p of cell) {
          if (p.image) {
            this.imageStore.releasePart(p.image);
          }
        }
      }
    }
  }

  private updateHeight(): void {
    if (!this.element) return;
    const availW = this.element.width && this.element.width > 0 ? this.element.width : undefined;
    const h = CanvasElementDrawer.measureTableHeight(this.element, availW, this.isReady ? this.ctx : null);
    this.measuredHeight = Math.max(20, h);
  }

  private drawTable(): void {
    if (!this.isReady || !this.element) return;
    const w = this.ctx.width;
    const h = this.ctx.height;
    if (w <= 0 || h <= 0) return;
    const ctx = this.ctx;
    ctx.clearRect(0, 0, w, h);
    CanvasElementDrawer.drawTable(ctx, this.element, this.imageStore.cache);

    if (this.blockMatches && this.blockMatches.length > 0) {
      for (let mIdx = 0; mIdx < this.blockMatches.length; mIdx++) {
        const m = this.blockMatches[mIdx];
        const isCurrent = this.currentMatchKey.length > 0 && searchMatchKey(m) === this.currentMatchKey;
        const rects = CanvasElementDrawer.computeElementHighlightRects(ctx, this.element, m);
        for (let rIdx = 0; rIdx < rects.length; rIdx++) {
          const r = rects[rIdx];
          if (isCurrent) {
            ctx.fillStyle = 'rgba(255, 160, 0, 0.75)';
            ctx.fillRect(r.x, r.y, r.width, r.height);
            ctx.strokeStyle = '#e65100';
            ctx.lineWidth = 1.5;
            ctx.strokeRect(r.x, r.y, r.width, r.height);
          } else {
            ctx.fillStyle = 'rgba(255, 235, 59, 0.45)';
            ctx.fillRect(r.x, r.y, r.width, r.height);
          }
        }
      }
    }

    // 选区高亮叠加在表格文字之上，保证与检索高亮可区分（drawTable 已直接在局部坐标绘制）
    const selRects = this.selectionRects();
    if (selRects.length > 0) {
      CanvasElementDrawer.drawSelectionHighlights(ctx, selRects);
    }
  }

  build() {
    if (this.element) {
      Row() {
        Canvas(this.ctx)
          .width(this.element.width && this.element.width > 0 ? this.element.width : '100%')
          .height(this.measuredHeight)
          .constraintSize({ maxWidth: '100%' })
          .onReady(() => {
            this.isReady = true;
            this.drawTable();
          })
          .onAreaChange((_oldVal: Area, newVal: Area) => {
            const newW = Number(newVal.width);
            if (newW > 0 && (!this.element?.width || Math.abs(this.element.width - newW) > 1)) {
              if (this.element) {
                this.element.width = newW;
              }
              this.updateHeight();
            }
            this.drawTable();
          })
      }
      .id(`table-${this.reuseVersion}`)
      .width('100%')
      .justifyContent(FlexAlign.Start)
      .margin({ top: 8, bottom: 8 })
    }
  }
}

interface PptxPageLayout extends PptxViewportPage {
  readonly page: model.Page;
  readonly width: number;
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
  @Prop @Watch('onSearchChanged') searchMatches: model.SearchMatch[] = [];
  @Prop @Watch('onSearchChanged') currentMatchIndex: number = -1;
  onSlideChange?: (pageNumber: number, pageCount: number) => void;
  registerControls?: (
    jumpToPage: (pageNumber: number) => void,
    getZoom: () => number,
    setZoom: (value: number) => void,
    scrollToMatch?: (match: model.SearchMatch) => void,
    selection?: SelectionControlHooks
  ) => void;

  private imageStore: ImageStore = new ImageStore('');
  private settings: RenderingContextSettings = new RenderingContextSettings(true);
  private ctx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings);
  private isReady: boolean = false;
  private isDisappeared: boolean = false;

  // MARK: - 文本选区状态
  /** 选区身份字符串（空串表示无选区），变化即触发 Canvas 重绘 */
  @State private selectionKey: string = '';
  /** 浮动气泡状态：仅在手势停稳后更新 */
  @State private bubbleShown: boolean = false;
  @State private bubbleAnchorX: number = 0;
  @State private bubbleAnchorY: number = 0;
  @State private bubbleBottomY: number = 0;
  @State private bubbleShowSelectAll: boolean = true;
  /** 拖选期间屏蔽 PanGesture，防止画布在拖选时抢占手指 */
  @State private isSelectionDragging: boolean = false;

  private selection: TextSelection | null = null;
  /** 拖拽模式：0 无 / 1 起点手柄 / 2 终点手柄 / 3 长按拖选 */
  private dragMode: number = 0;
  /** 起止手柄屏幕锚点；对端所在页不可见时为 null 但槽位保持不变 */
  private startHandleAnchor: SelectionHandleAnchor | null = null;
  private endHandleAnchor: SelectionHandleAnchor | null = null;
  private lastTouchX: number = 0;
  private lastTouchY: number = 0;
  private edgeScrollTimer: number = -1;
  private edgeScrollDirectionX: number = 0;
  private edgeScrollDirectionY: number = 0;
  private bubbleTimer: number = -1;

  // MARK: - 文本索引（按页懒构建）
  /** 全量轻量索引：所有页的纯文本，用于全选与复制 */
  private textLayout: DocumentTextLayout | null = null;
  /** 页 -> 该页首个块的全局块编号 */
  private pageBlockBase: Map<number, number> = new Map();
  /** 已构建完整行度量的页布局，键为页索引 */
  private measuredPageLayouts: Map<number, DocumentTextLayout> = new Map();

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
  // 仅保留当前可见幻灯片所需图片的引用；否则长 PPTX 滚动后所有图片均不可淘汰，
  // 会造成 PixelMap 累积、GC 与解码竞争，直接表现为滑动掉帧。
  private readonly visibleImageParts: Set<string> = new Set();
  private loadGeneration: number = 0;

  private onSearchChanged(): void {
    if (this.isReady) {
      this.redraw();
    }
  }

  aboutToAppear(): void {
    this.isDisappeared = false;
    this.imageStore = new ImageStore(this.filePath);
    this.initLayouts();
    this.rebuildTextIndex();
    if (this.registerControls) {
      this.registerControls(
        (pageNumber: number): void => {
          this.jumpToPage(pageNumber);
        },
        (): number => this.zoom,
        (value: number): void => {
          this.startZoomTween(value, this.canvasWidth / 2, this.canvasHeight / 2, RenderUtils.ZOOM_ANIMATION_MS);
        },
        (match: model.SearchMatch): void => {
          this.scrollToMatch(match);
        },
        this.buildSelectionHooks()
      );
    }
  }

  /** 组装选区控制钩子，交给 OfficePreviewController 统一调度 */
  private buildSelectionHooks(): SelectionControlHooks {
    const hooks: SelectionControlHooks = {
      selectAll: (): boolean => this.selectAll(),
      clearSelection: (): void => this.clearSelection(),
      hasSelection: (): boolean => this.hasSelection(),
      getSelectedText: (): string => this.getSelectedText(),
      copySelection: (): boolean => this.copySelection()
    };
    return hooks;
  }

  // MARK: - 文本索引构建

  /**
   * 按页构建全量文本索引：每页按 elements 顺序、每元素按单元格/段落顺序分配 blockIndex。
   * 初始只提取纯文本（不触发 Canvas measureText），使 selectAll 与 getSelectedText
   * 在未访问过的远端页上也能立即返回完整结果；行几何在该页绘制或命中时懒补齐。
   */
  private rebuildTextIndex(): void {
    const blocks: TextBlockLayout[] = [];
    const pageBase: Map<number, number> = new Map();
    let blockIndex = 0;
    for (let pageIdx = 0; pageIdx < this.pageLayouts.length; pageIdx++) {
      const layout = this.pageLayouts[pageIdx];
      pageBase.set(pageIdx, blockIndex);
      for (const element of layout.page.elements ?? []) {
        const parts = CanvasElementDrawer.extractElementFullText(element);
        for (const part of parts) {
          blocks.push(makeContainerBlock(blockIndex, pageIdx, part, []));
          blockIndex++;
        }
      }
    }
    this.textLayout = new DocumentTextLayout(blocks);
    this.pageBlockBase = pageBase;
    this.measuredPageLayouts.clear();
  }

  /** 某一页在全局索引中的块区间 [首个块编号, 末块编号]；无文本时返回 [-1, -1] */
  private pageBlockRange(pageIdx: number): number[] {
    const base = this.pageBlockBase.get(pageIdx);
    if (base === undefined) {
      return [-1, -1];
    }
    const nextBase = this.pageBlockBase.get(pageIdx + 1);
    let end = (nextBase !== undefined ? nextBase : Number.MAX_SAFE_INTEGER) - 1;
    const layout = this.textLayout;
    if (layout) {
      const total = layout.blocks.length;
      if (nextBase === undefined) {
        end = total - 1;
      }
    }
    return [base, end];
  }

  /**
   * 懒构建单页的完整行度量（页内容坐标 + 恒等仿射变换）。
   * 与 drawPptx 中 `translate(slideLeft, layout.y); drawElement()` 的绘制路径一致，
   * 行度量以「页左上角为原点」表达，屏幕映射时再叠加 slideLeft / layout.y / 视口变换。
   */
  private ensurePageLayout(pageIdx: number): DocumentTextLayout | null {
    const cached = this.measuredPageLayouts.get(pageIdx);
    if (cached) {
      return cached;
    }
    const layout = this.pageLayouts[pageIdx];
    if (!layout) {
      return null;
    }
    const baseInfo = this.pageBlockRange(pageIdx);
    if (baseInfo[0] < 0) {
      return null;
    }
    const blocks: TextBlockLayout[] = [];
    let blockIndex = baseInfo[0];
    for (const element of layout.page.elements ?? []) {
      const rawBlocks = CanvasElementDrawer.buildElementTextBlocks(this.ctx, element, blockIndex, pageIdx);
      for (const block of rawBlocks) {
        blocks.push(block);
        blockIndex++;
      }
    }
    const pageLayout = new DocumentTextLayout(blocks);
    this.measuredPageLayouts.set(pageIdx, pageLayout);
    return pageLayout;
  }

  // MARK: - 选区控制 API

  /** 全选全部幻灯片的文本 */
  public selectAll(): boolean {
    const layout = this.textLayout;
    if (!layout || !layout.hasText()) {
      return false;
    }
    const range = layout.allTextRange();
    if (!range || isSelectionEmpty(range)) {
      return false;
    }
    this.setSelection(range);
    this.scheduleBubble();
    return true;
  }

  /** 清空选区、手柄与浮动气泡 */
  public clearSelection(): void {
    this.stopEdgeScroll();
    this.cancelBubbleTimer();
    this.setSelection(null);
  }

  /** 当前是否存在非空选区 */
  public hasSelection(): boolean {
    return this.selection !== null && !isSelectionEmpty(this.selection);
  }

  /** 当前选中的纯文本（跨页跨块以换行连接） */
  public getSelectedText(): string {
    const layout = this.textLayout;
    const selection = this.selection;
    if (!layout || !selection) {
      return '';
    }
    return layout.selectedText(selection);
  }

  /** 将选中文本写入系统剪贴板 */
  public copySelection(): boolean {
    const text = this.getSelectedText();
    if (text.length === 0) {
      return false;
    }
    return copyTextToPasteboard(text);
  }

  /** 更新选区并触发重绘 */
  private setSelection(selection: TextSelection | null): void {
    if (selection && isSelectionEmpty(selection)) {
      selection = null;
    }
    this.selection = selection;
    this.selectionKey = encodeSelectionKey(selection);
    if (!selection) {
      this.startHandleAnchor = null;
      this.endHandleAnchor = null;
      this.bubbleShown = false;
    }
    this.refreshSelectionOverlay();
    this.redraw();
  }

  // MARK: - 屏幕坐标映射与手柄

  /**
   * 屏幕坐标 -> 幻灯片内容坐标。
   * drawPptx 的变换链为：ctx.translate(left - offsetX, top - offsetY); ctx.scale(scale, scale)，
   * 页内再 translate(slideLeft, layout.y)，因此反解为：
   *   content = (screen + offset - left/top) / scale - (slideLeft, layout.y)
   */
  private screenToSlide(screenX: number, screenY: number): PlanePoint {
    const scale = this.getScale();
    const left = this.getLeft();
    const top = this.getTop();
    const point: PlanePoint = {
      x: (scale > 0 ? (screenX + this.offsetX - left) / scale : 0),
      y: (scale > 0 ? (screenY + this.offsetY - top) / scale : 0)
    };
    return point;
  }

  /** 幻灯片内容坐标 -> 屏幕坐标 */
  private slideToScreen(contentX: number, contentY: number): PlanePoint {
    const scale = this.getScale();
    const left = this.getLeft();
    const top = this.getTop();
    const point: PlanePoint = {
      x: contentX * scale + left - this.offsetX,
      y: contentY * scale + top - this.offsetY
    };
    return point;
  }

  /** 内容坐标 -> 某页页内局部坐标 */
  private toPageLocal(contentX: number, contentY: number, pageIdx: number): PlanePoint {
    const layout = this.pageLayouts[pageIdx];
    const point: PlanePoint = { x: contentX, y: contentY };
    if (!layout) {
      return point;
    }
    const slideLeft = (this.contentWidth - layout.width) / 2;
    const local: PlanePoint = { x: contentX - slideLeft, y: contentY - layout.y };
    return local;
  }

  /** 在可见页内做字符级命中；未落在任何页内时取纵向最近页 */
  private hitTestScreen(screenX: number, screenY: number, lift: number): TextPosition | null {
    if (this.pageLayouts.length === 0) {
      return null;
    }
    const content = this.screenToSlide(screenX, screenY - lift);
    const range = resolvePptxVisibleRange(
      this.pageLayouts, content.y - 1, content.y + 1
    );
    const first = Math.max(0, Math.min(this.pageLayouts.length - 1, range.start - 1));
    const last = Math.max(first, Math.min(this.pageLayouts.length - 1, range.end));
    let nearest: TextPosition | null = null;
    let nearestDistance = Number.POSITIVE_INFINITY;
    for (let pageIdx = first; pageIdx <= last; pageIdx++) {
      const pageLayout = this.ensurePageLayout(pageIdx);
      if (!pageLayout || !pageLayout.hasText()) {
        continue;
      }
      const local = this.toPageLocal(content.x, content.y, pageIdx);
      const position = pageLayout.hitTest(local.x, local.y);
      if (!position) {
        continue;
      }
      const layout = this.pageLayouts[pageIdx];
      const inside = local.x >= -8 && local.x <= layout.width + 8 && local.y >= -4 && local.y <= layout.height + 4;
      if (inside) {
        return position;
      }
      const distance = Math.abs(local.y - layout.height / 2);
      if (distance < nearestDistance) {
        nearestDistance = distance;
        nearest = position;
      }
    }
    return nearest;
  }

  /** 计算某个文本位置的屏幕手柄锚点（所在页当前不可见时返回 null） */
  private resolveHandleAnchor(position: TextPosition): SelectionHandleAnchor | null {
    const layout = this.textLayout;
    if (!layout) {
      return null;
    }
    const block = layout.blockAt(position.blockIndex);
    if (!block) {
      return null;
    }
    const pageIdx = block.pageIndex;
    const pageLayout = this.ensurePageLayout(pageIdx);
    if (!pageLayout) {
      return null;
    }
    const localBlock = pageLayout.blockAt(position.blockIndex);
    if (!localBlock) {
      return null;
    }
    const handles = pageLayout.handleGeometry(makeTextSelection(position, position));
    if (!handles) {
      return null;
    }
    const pageInfo = this.pageLayouts[pageIdx];
    if (!pageInfo) {
      return null;
    }
    const slideLeft = (this.contentWidth - pageInfo.width) / 2;
    const contentX = slideLeft + handles.start.docX;
    const topPoint = this.slideToScreen(contentX, pageInfo.y + handles.start.docTopY);
    const bottomPoint = this.slideToScreen(contentX, pageInfo.y + handles.start.docBottomY);
    const anchor: SelectionHandleAnchor = { x: topPoint.x, y: topPoint.y, bottomY: bottomPoint.y };
    return anchor;
  }

  /** 重算起止手柄锚点（供 forceDraw 复用） */
  private refreshSelectionOverlay(): void {
    const selection = this.selection;
    if (selection && !isSelectionEmpty(selection)) {
      this.startHandleAnchor = this.resolveHandleAnchor(spanStartPosition(selection));
      this.endHandleAnchor = this.resolveHandleAnchor(spanEndPosition(selection));
    } else {
      this.startHandleAnchor = null;
      this.endHandleAnchor = null;
    }
  }

  /** 命中起止手柄热区：返回 1（起点）或 2（终点），未命中返回 0 */
  private hitHandle(screenX: number, screenY: number): number {
    if (this.hitsHandleAnchor(this.startHandleAnchor, screenX, screenY)) {
      return 1;
    }
    if (this.hitsHandleAnchor(this.endHandleAnchor, screenX, screenY)) {
      return 2;
    }
    return 0;
  }

  /** 触点是否落在某个手柄圆心（光标底端下移 SELECTION_HANDLE_DROP）的热区内 */
  private hitsHandleAnchor(anchor: SelectionHandleAnchor | null, screenX: number, screenY: number): boolean {
    if (!anchor) {
      return false;
    }
    const cx = anchor.x;
    const cy = Math.max(anchor.y, anchor.bottomY) + SELECTION_HANDLE_DROP;
    const dx = screenX - cx;
    const dy = screenY - cy;
    return Math.sqrt(dx * dx + dy * dy) <= SELECTION_HANDLE_HIT_RADIUS;
  }

  /** 在当前红色绘制上下文中绘制手柄（屏幕坐标系，位于 ctx.restore() 之后） */
  private drawSelectionHandles(): void {
    const ctx = this.ctx;
    const start = this.startHandleAnchor;
    const end = this.endHandleAnchor;
    if (start) {
      this.drawHandle(ctx, start, true);
    }
    if (end) {
      this.drawHandle(ctx, end, false);
    }
  }

  /** 单个手柄：2vp 光标竖线 + 固定物理尺寸的水滴圆头 */
  private drawHandle(ctx: CanvasRenderingContext2D, anchor: SelectionHandleAnchor, isStart: boolean): void {
    const topY = Math.min(anchor.y, anchor.bottomY);
    const bottomY = Math.max(anchor.y, anchor.bottomY);
    ctx.save();
    ctx.strokeStyle = SELECTION_LINE_COLOR;
    ctx.lineWidth = 2;
    ctx.beginPath();
    ctx.moveTo(anchor.x, topY);
    ctx.lineTo(anchor.x, bottomY);
    ctx.stroke();
    const centerY = bottomY + SELECTION_HANDLE_DROP;
    ctx.fillStyle = SELECTION_LINE_COLOR;
    ctx.beginPath();
    ctx.arc(anchor.x, centerY, SELECTION_HANDLE_RADIUS, 0, Math.PI * 2);
    ctx.fill();
    ctx.strokeStyle = '#ffffff';
    ctx.lineWidth = 1.5;
    ctx.beginPath();
    ctx.moveTo(anchor.x, centerY + SELECTION_HANDLE_RADIUS - 1);
    ctx.lineTo(anchor.x + (isStart ? -4 : 4), centerY + SELECTION_HANDLE_RADIUS + 3);
    ctx.stroke();
    ctx.restore();
  }

  // MARK: - 手势处理

  /** 手柄优先拦截；拖选期间不消费事件但独占移动跟随 */
  private handlePptxTouch(event: TouchEvent): void {
    const touches = event.touches;
    if (!touches || touches.length === 0) {
      return;
    }
    const touch = touches[0];
    if (event.type === TouchType.Down) {
      this.lastTouchX = touch.x;
      this.lastTouchY = touch.y;
      const hit = this.hitHandle(touch.x, touch.y);
      if (hit !== 0) {
        this.beginDrag(hit);
      }
      return;
    }
    if (event.type === TouchType.Move) {
      if (this.dragMode === 0) {
        return;
      }
      this.lastTouchX = touch.x;
      this.lastTouchY = touch.y;
      this.updateDrag(touch.x, touch.y);
      this.updateEdgeScroll(touch.x, touch.y);
      return;
    }
    if (this.dragMode !== 0) {
      this.endDrag();
    }
  }

  /** 进入拖拽：停止惯性/补间、隐藏气泡并屏蔽平移手势 */
  private beginDrag(mode: number): void {
    if (!this.selection) {
      return;
    }
    this.stopFling();
    this.stopZoomTween();
    this.stopEdgeScroll();
    this.cancelBubbleTimer();
    this.bubbleShown = false;
    this.dragMode = mode;
    if (this.isSelectionDragging !== true) {
      this.isSelectionDragging = true;
    }
  }

  /** 拖拽更新焦点；手柄拖拽固定另一端为锚点 */
  private updateDrag(screenX: number, screenY: number): void {
    const selection = this.selection;
    if (!selection) {
      return;
    }
    const position = this.hitTestScreen(screenX, screenY, SELECTION_TOUCH_LIFT);
    if (!position) {
      return;
    }
    let anchor = selection.anchor;
    if (this.dragMode === 1) {
      anchor = spanEndPosition(selection);
    } else if (this.dragMode === 2) {
      anchor = spanStartPosition(selection);
    }
    this.setSelection(makeTextSelection(anchor, position));
  }

  /** 结束拖拽并重定位气泡 */
  private endDrag(): void {
    this.dragMode = 0;
    this.stopEdgeScroll();
    if (this.isSelectionDragging) {
      this.isSelectionDragging = false;
    }
    if (this.hasSelection()) {
      this.scheduleBubble();
    } else {
      this.bubbleShown = false;
    }
    this.redraw();
  }

  /** 长按选词：命中文字后进入拖选态 */
  private handleLongPress(event: GestureEvent): void {
    if (this.isPinching) {
      return;
    }
    const fingerList = event.fingerList;
    if (!fingerList || fingerList.length === 0) {
      return;
    }
    const screenX = fingerList[0].localX;
    const screenY = fingerList[0].localY;
    this.lastTouchX = screenX;
    this.lastTouchY = screenY;
    const position = this.hitTestScreen(screenX, screenY, 0);
    if (!position) {
      return;
    }
    const layout = this.textLayout;
    if (!layout) {
      return;
    }
    const range = layout.wordRange(position);
    if (!range) {
      return;
    }
    this.stopFling();
    this.stopZoomTween();
    this.stopEdgeScroll();
    this.cancelBubbleTimer();
    this.bubbleShown = false;
    this.dragMode = 3;
    if (this.isSelectionDragging !== true) {
      this.isSelectionDragging = true;
    }
    this.setSelection(range);
  }

  /** 单击：存在选区时清除并消费本次点击 */
  private handleSingleTap(): void {
    if (this.hasSelection()) {
      this.clearSelection();
    }
  }

  // MARK: - 边缘自动平移

  /** 触点进入四边热区时启动定时平移，步长随深入程度线性递增 */
  private updateEdgeScroll(screenX: number, screenY: number): void {
    let dx = 0;
    let dy = 0;
    if (screenY < SELECTION_EDGE_SCROLL_ZONE) {
      dy = -1;
    } else if (screenY > this.canvasHeight - SELECTION_EDGE_SCROLL_ZONE) {
      dy = 1;
    }
    if (screenX < SELECTION_EDGE_SCROLL_ZONE) {
      dx = -1;
    } else if (screenX > this.canvasWidth - SELECTION_EDGE_SCROLL_ZONE) {
      dx = 1;
    }
    if (dx === 0 && dy === 0) {
      this.stopEdgeScroll();
      return;
    }
    if (this.edgeScrollTimer !== -1 && this.edgeScrollDirectionX === dx && this.edgeScrollDirectionY === dy) {
      return;
    }
    this.stopEdgeScroll();
    this.edgeScrollDirectionX = dx;
    this.edgeScrollDirectionY = dy;
    this.edgeScrollTimer = setInterval(() => {
      this.stepEdgeScroll();
    }, SELECTION_EDGE_SCROLL_INTERVAL);
  }

  /** 单步边缘平移：按到边缘的距离决定步长，平移后以最新触点重算焦点 */
  private stepEdgeScroll(): void {
    if (this.dragMode === 0 || (this.edgeScrollDirectionX === 0 && this.edgeScrollDirectionY === 0)) {
      this.stopEdgeScroll();
      return;
    }
    const zone = SELECTION_EDGE_SCROLL_ZONE;
    let depthX = 0;
    let depthY = 0;
    if (this.edgeScrollDirectionX < 0) {
      depthX = Math.max(0, zone - this.lastTouchX);
    } else if (this.edgeScrollDirectionX > 0) {
      depthX = Math.max(0, this.lastTouchX - (this.canvasWidth - zone));
    }
    if (this.edgeScrollDirectionY < 0) {
      depthY = Math.max(0, zone - this.lastTouchY);
    } else if (this.edgeScrollDirectionY > 0) {
      depthY = Math.max(0, this.lastTouchY - (this.canvasHeight - zone));
    }
    if (depthX <= 0 && depthY <= 0) {
      this.stopEdgeScroll();
      return;
    }
    const stepX = this.edgeScrollDirectionX === 0
      ? 0
      : Math.max(1, SELECTION_EDGE_SCROLL_MAX_STEP * Math.min(1, depthX / zone));
    const stepY = this.edgeScrollDirectionY === 0
      ? 0
      : Math.max(1, SELECTION_EDGE_SCROLL_MAX_STEP * Math.min(1, depthY / zone));
    this.offsetX = this.offsetX + stepX * this.edgeScrollDirectionX;
    this.offsetY = this.offsetY + stepY * this.edgeScrollDirectionY;
    this.clampOffsets();
    this.updateCurrentPage();
    this.updateDrag(this.lastTouchX, this.lastTouchY);
    this.redraw();
  }

  private stopEdgeScroll(): void {
    if (this.edgeScrollTimer !== -1) {
      clearInterval(this.edgeScrollTimer);
      this.edgeScrollTimer = -1;
    }
    this.edgeScrollDirectionX = 0;
    this.edgeScrollDirectionY = 0;
  }

  // MARK: - 浮动气泡

  /** 手势停稳后延迟一拍再定位气泡 */
  private scheduleBubble(): void {
    this.cancelBubbleTimer();
    this.bubbleTimer = setTimeout(() => {
      this.bubbleTimer = -1;
      this.repositionBubble();
    }, 32);
  }

  private cancelBubbleTimer(): void {
    if (this.bubbleTimer !== -1) {
      clearTimeout(this.bubbleTimer);
      this.bubbleTimer = -1;
    }
  }

  /** 依据选区整体屏幕包围框定位气泡 */
  private repositionBubble(): void {
    const selection = this.selection;
    if (!selection || isSelectionEmpty(selection)) {
      this.bubbleShown = false;
      return;
    }
    const bounds = this.selectionScreenBounds(selection);
    if (!bounds) {
      this.bubbleShown = false;
      return;
    }
    this.bubbleAnchorX = (bounds.left + bounds.right) / 2;
    this.bubbleAnchorY = bounds.top;
    this.bubbleBottomY = bounds.bottom;
    this.bubbleShowSelectAll = !this.isWholeDocumentSelected(selection);
    this.bubbleShown = true;
  }

  /** 当前视口覆盖的页索引闭区间；页面布局尚未就绪时退化为首页 */
  private visiblePageRange(): number[] {
    const total = this.pageLayouts.length;
    if (total === 0) {
      return [0, -1];
    }
    const scale = this.getScale();
    if (scale <= 0) {
      return [0, 0];
    }
    const visibleTop = (this.offsetY - this.getTop()) / scale;
    const visibleBottom = visibleTop + this.canvasHeight / scale;
    const range = resolvePptxVisibleRange(this.pageLayouts, visibleTop, visibleBottom);
    const first = Math.max(0, Math.min(total - 1, range.start));
    const last = Math.max(first, Math.min(total - 1, range.end));
    return [first, last];
  }

  /** 选区在屏幕坐标系下的整体包围框（仅统计可见页，避免全选后遍历整本幻灯片做排版） */
  private selectionScreenBounds(selection: TextSelection): TextRect | null {
    const start = spanStartPosition(selection);
    const end = spanEndPosition(selection);
    const visible = this.visiblePageRange();
    let left = 0;
    let top = 0;
    let right = 0;
    let bottom = 0;
    let found = false;
    for (let pageIdx = visible[0]; pageIdx <= visible[1]; pageIdx++) {
      const range = this.pageBlockRange(pageIdx);
      if (range[0] < 0 || range[1] < start.blockIndex || range[0] > end.blockIndex) {
        continue;
      }
      const pageLayout = this.ensurePageLayout(pageIdx);
      if (!pageLayout) {
        continue;
      }
      const localRects = pageLayout.selectionRects(selection);
      if (localRects.length === 0) {
        continue;
      }
      const pageInfo = this.pageLayouts[pageIdx];
      const slideLeft = (this.contentWidth - pageInfo.width) / 2;
      for (const highlight of localRects) {
        const docRect = highlight.docBounds;
        const p1 = this.slideToScreen(slideLeft + docRect.left, pageInfo.y + docRect.top);
        const p2 = this.slideToScreen(slideLeft + docRect.right, pageInfo.y + docRect.bottom);
        const x1 = Math.min(p1.x, p2.x);
        const x2 = Math.max(p1.x, p2.x);
        const y1 = Math.min(p1.y, p2.y);
        const y2 = Math.max(p1.y, p2.y);
        if (!found) {
          left = x1;
          top = y1;
          right = x2;
          bottom = y2;
          found = true;
        } else {
          left = Math.min(left, x1);
          top = Math.min(top, y1);
          right = Math.max(right, x2);
          bottom = Math.max(bottom, y2);
        }
      }
    }
    if (!found) {
      return null;
    }
    return makeTextRect(left, top, right, bottom);
  }

  /** 选区是否已覆盖全文 */
  private isWholeDocumentSelected(selection: TextSelection): boolean {
    const layout = this.textLayout;
    if (!layout) {
      return false;
    }
    const all = layout.allTextRange();
    if (!all) {
      return false;
    }
    const allStart = spanStartPosition(all);
    const allEnd = spanEndPosition(all);
    const start = spanStartPosition(selection);
    const end = spanEndPosition(selection);
    return start.blockIndex === allStart.blockIndex && start.charIndex <= allStart.charIndex &&
      end.blockIndex === allEnd.blockIndex && end.charIndex >= allEnd.charIndex;
  }

  /** 气泡「复制」：写入剪贴板后清除选区 */
  private onBubbleCopy(): void {
    if (this.copySelection()) {
      this.clearSelection();
    } else {
      this.bubbleShown = false;
    }
  }

  /** 气泡「全选」 */
  private onBubbleSelectAll(): void {
    if (this.selectAll()) {
      this.scheduleBubble();
    }
  }

  public scrollToMatch(match: model.SearchMatch): void {
    if (match.pageIndex < 0 || match.pageIndex >= this.pageLayouts.length) return;
    const targetPage = match.pageIndex + 1;
    if (this.currentPage !== targetPage) {
      this.jumpToPage(targetPage);
    }
    const layout = this.pageLayouts[match.pageIndex];
    if (!layout.page.elements || match.elementIndex >= layout.page.elements.length) {
      return;
    }
    const element = layout.page.elements[match.elementIndex];
    const rects = CanvasElementDrawer.computeElementHighlightRects(this.ctx, element, match);
    const slideLeft = (this.contentWidth - layout.width) / 2;

    let targetX = slideLeft + layout.width / 2;
    let targetY = layout.y + layout.height / 2;
    if (rects.length > 0) {
      let minX = rects[0].x;
      let maxX = rects[0].x + rects[0].width;
      let minY = rects[0].y;
      let maxY = rects[0].y + rects[0].height;
      for (let k = 1; k < rects.length; k++) {
        minX = Math.min(minX, rects[k].x);
        maxX = Math.max(maxX, rects[k].x + rects[k].width);
        minY = Math.min(minY, rects[k].y);
        maxY = Math.max(maxY, rects[k].y + rects[k].height);
      }
      targetX = slideLeft + (minX + maxX) / 2;
      targetY = layout.y + (minY + maxY) / 2;
    }

    const s = this.getScale();
    const targetOx = targetX * s + this.getLeft() - this.canvasWidth / 2;
    const targetOy = targetY * s + this.getTop() - this.canvasHeight / 2;

    this.stopFling();
    this.stopZoomTween();
    this.offsetX = Math.max(0, Math.min(this.maxX(), Math.round(targetOx)));
    this.offsetY = Math.max(0, Math.min(this.maxY(), Math.round(targetOy)));
    this.updateCurrentPage();
    this.redraw();
  }

  aboutToDisappear(): void {
    this.loadGeneration++;
    this.isDisappeared = true;
    this.isReady = false;
    this.stopFling();
    this.stopZoomTween();
    // 文档销毁：取消边缘平移、气泡定时器并清空选区与索引缓存
    this.stopEdgeScroll();
    this.cancelBubbleTimer();
    this.selection = null;
    this.startHandleAnchor = null;
    this.endHandleAnchor = null;
    this.measuredPageLayouts.clear();
    this.textLayout = null;
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
    this.visibleImageParts.clear();
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
    const bestPage = resolvePptxCurrentPage(
      this.pageLayouts,
      this.currentPage,
      this.offsetY,
      this.maxY(),
      visibleTop,
      visibleBottom
    );
    // 高频手势中只在页码真正变化时触发 ArkUI 更新与回调。
    if (this.currentPage !== bestPage) {
      this.currentPage = bestPage;
    }
    if (this.notifiedPage !== bestPage) {
      this.notifiedPage = bestPage;
      if (this.onSlideChange) {
        this.onSlideChange(bestPage, this.totalPages);
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
    // 拖动、缩放和惯性事件可能高于屏幕刷新率，合并到下一帧只绘制最新视口。
    this.scheduleRedraw();
  }

  private requestVisibleImages(parts: Map<string, number>): void {
    const nextVisible = new Set<string>();
    for (const part of parts.keys()) {
      if (part) nextVisible.add(part);
    }

    // 图像引用必须随视口滚动释放。原实现只 acquire、不 release，长文档中每张
    // 已浏览幻灯片都会永久占用 LRU，超过预算后无法逐出，导致持续内存压力与掉帧。
    for (const part of this.visibleImageParts) {
      if (!nextVisible.has(part)) {
        this.imageStore.releasePart(part);
      }
    }
    for (const part of nextVisible) {
      if (!this.visibleImageParts.has(part)) {
        this.imageStore.acquire(part);
      }
    }
    this.visibleImageParts.clear();
    for (const part of nextVisible) this.visibleImageParts.add(part);

    for (const part of nextVisible) {
      // 根据图片在当前视口中的投影面积下采样；保留 2 倍余量，捏合放大时
      // ImageStore 会按 1.5 倍阈值升级更高清版本，避免首屏固定解码 4MP。
      const desiredPixels = Math.max(262_144, Math.min(4_000_000, parts.get(part) ?? 262_144));
      if (this.loadingParts.has(part) || !this.imageStore.needsLoad(part, desiredPixels)) {
        continue;
      }
      this.loadingParts.add(part);
      const gen = this.loadGeneration;
      this.imageStore.load(part, desiredPixels).then((updated: boolean) => {
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

    // part -> 当前帧所需解码像素。相同图片可能多次出现，只保留最高显示需求。
    const neededImageParts: Map<string, number> = new Map();

    // 页面 y 单调递增，先二分定位可见区间。长 PPTX 每帧只访问屏内通常 1～2 页，
    // 避免此前从首页线性扫到末页造成的滚动开销。
    const visibleRange = resolvePptxVisibleRange(this.pageLayouts, visibleTop, visibleBottom);
    for (let i = visibleRange.start; i < visibleRange.end; i++) {
      const layout = this.pageLayouts[i];
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
            // 当前屏幕投影面积的 2 倍作为解码预算，为旋转、裁剪与一次缩放升级留余量。
            const projectedPixels = Math.max(1, Math.ceil(element.width * scale) * Math.ceil(element.height * scale));
            const desiredPixels = Math.min(4_000_000, Math.max(262_144, projectedPixels * 2));
            const previous = neededImageParts.get(element.image) ?? 0;
            if (desiredPixels > previous) neededImageParts.set(element.image, desiredPixels);
          }
          CanvasElementDrawer.drawElement(ctx, element, this.imageStore.cache);
        }
      }

      // 4. 绘制全文检索高亮 (普通淡黄，当前亮橙色+边框)
      if (this.searchMatches && this.searchMatches.length > 0) {
        for (let mIdx = 0; mIdx < this.searchMatches.length; mIdx++) {
          const m = this.searchMatches[mIdx];
          if (m.pageIndex !== i) continue;
          if (!layout.page.elements || m.elementIndex >= layout.page.elements.length) continue;
          const element = layout.page.elements[m.elementIndex];
          const rects = CanvasElementDrawer.computeElementHighlightRects(ctx, element, m);
          const isCurrent = (mIdx === this.currentMatchIndex);
          for (const r of rects) {
            if (isCurrent) {
              ctx.fillStyle = 'rgba(255, 160, 0, 0.75)';
              ctx.fillRect(r.x, r.y, r.width, r.height);
              ctx.strokeStyle = '#e65100';
              ctx.lineWidth = 1.5;
              ctx.strokeRect(r.x, r.y, r.width, r.height);
            } else {
              ctx.fillStyle = 'rgba(255, 235, 59, 0.45)';
              ctx.fillRect(r.x, r.y, r.width, r.height);
            }
          }
        }
      }

      // 5. 绘制当前页的选区高亮（页内容坐标，经元素仿射变换映射至局部坐标绘制，保留旋转/位移）
      const selHighlights = this.pageSelectionHighlights(i);
      for (const highlight of selHighlights) {
        const m = highlight.transform;
        ctx.save();
        if (m.length >= 6) {
          ctx.transform(m[0], m[1], m[2], m[3], m[4], m[5]);
        }
        CanvasElementDrawer.drawSelectionHighlights(ctx, [highlight.localRect]);
        ctx.restore();
      }

      ctx.restore();
    }

    ctx.restore();

    // 6. 屏幕坐标系绘制起止手柄（固定物理尺寸，不随缩放变形）
    if (this.selection !== null) {
      this.refreshSelectionOverlay();
      this.drawSelectionHandles();
    }

    this.requestVisibleImages(neededImageParts);
  }

  /**
   * 某一页各选中块的高亮矩形及对应元素仿射变换（相对于幻灯片内容坐标原点）。
   */
  private pageSelectionHighlights(pageIdx: number): BlockHighlightRect[] {
    const selection = this.selection;
    if (!selection || isSelectionEmpty(selection)) {
      return [];
    }
    const start = spanStartPosition(selection);
    const end = spanEndPosition(selection);
    const range = this.pageBlockRange(pageIdx);
    if (range[0] < 0 || range[1] < start.blockIndex || range[0] > end.blockIndex) {
      return [];
    }
    const pageLayout = this.ensurePageLayout(pageIdx);
    if (!pageLayout) {
      return [];
    }
    return pageLayout.selectionRects(selection);
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
        // 手指按下即终止惯性：PanGesture 需要移动达到识别距离才会回调 onActionStart，
        // 若只在 Pan 开始处停 Fling，惯性运行中按住不动时幻灯片仍会继续滑动（安卓 onDown 已 forceFinished）
        .onTouch((event: TouchEvent) => {
          if (event.type === TouchType.Down) {
            this.stopFling();
          }
          // 手柄优先拦截与拖选跟随
          this.handlePptxTouch(event);
        })
        .gesture(
          GestureGroup(
            GestureMode.Parallel,
            // 双击缩放优先于单击清除选区，避免双击第二次点击误清选区
            GestureGroup(
              GestureMode.Exclusive,
              TapGesture({ count: 2, distanceThreshold: 3 })
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
              // 单击：存在选区时清除选区并消费本次点击
              TapGesture({ count: 1 })
                .onAction((_event: GestureEvent) => {
                  this.handleSingleTap();
                })
            ),
            // 长按 400ms 选词，之后不抬手即可滑动扩选（捏合过程中跳过）
            LongPressGesture({ duration: SELECTION_LONG_PRESS_MS, repeat: false })
              .onAction((event: GestureEvent) => {
                this.handleLongPress(event);
              })
              .onActionEnd(() => {
                if (this.dragMode === 3) {
                  this.endDrag();
                }
              })
              .onActionCancel(() => {
                if (this.dragMode === 3) {
                  this.endDrag();
                }
              }),
            PinchGesture({ fingers: 2 })
              .onActionStart(() => {
                if (this.dragMode !== 0) {
                  this.dragMode = 0;
                  this.isSelectionDragging = false;
                  this.stopEdgeScroll();
                }
                this.stopFling();
                this.stopZoomTween();
                this.isPinching = true;
                this.pinchStartZoom = this.clampZoom(this.zoom);
                this.bubbleShown = false;
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
                if (this.isPinching || this.isSelectionDragging) return;
                this.stopFling();
                this.stopZoomTween();
                this.panStartX = this.offsetX;
                this.panStartY = this.offsetY;
              })
              .onActionUpdate((event: GestureEvent) => {
                if (this.isPinching || this.isSelectionDragging) return;
                this.stopFling();
                this.offsetX = this.panStartX - event.offsetX;
                this.offsetY = this.panStartY - event.offsetY;
                this.clampOffsets();
                this.updateCurrentPage();
                this.redraw();
              })
              .onActionEnd((event: GestureEvent) => {
                if (this.isPinching || this.isSelectionDragging) return;
                const vx = event.velocityX ?? 0;
                const vy = event.velocityY ?? 0;
                if (Math.hypot(vx, vy) > 80) {
                  this.startFling(-vx, -vy);
                }
                // 滚动停稳后重定位选区手柄与气泡
                if (this.hasSelection()) {
                  this.scheduleBubble();
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

      // 浮动操作气泡：仅在停稳后出现
      if (this.bubbleShown) {
        SelectionMenuBubble({
          anchorX: this.bubbleAnchorX,
          anchorY: this.bubbleAnchorY,
          anchorBottomY: this.bubbleBottomY,
          viewportWidth: this.canvasWidth,
          viewportHeight: this.canvasHeight,
          showSelectAll: this.bubbleShowSelectAll,
          onCopy: (): void => {
            this.onBubbleCopy();
          },
          onSelectAll: (): void => {
            this.onBubbleSelectAll();
          }
        })
      }
    }
    .width('100%')
    .height('100%')
    .clip(true)
  }
}
