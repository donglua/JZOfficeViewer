import { displaySync } from '@kit.ArkGraphics2D';
import * as model from '../core/OfficeModel';
import { RenderUtils } from './RenderUtils';
import {
  EffectiveFrozen,
  FREEZE_LINE_COLOR,
  FreezeDocRect,
  FreezeQuadrant,
  MatchQuadrantRect,
  ScrollTarget,
  mapMatchRectToQuadrants,
  normalizeFrozen,
  resolveEffectiveFrozen,
  resolveFreezeQuadrants,
  resolveQuadrantMergeBounds,
  resolveScrollToTarget
} from './SheetFreeze';
import {
  CellCoord,
  CellRect,
  HEADER_SELECTED_COLOR,
  HEADER_SELECTED_TEXT_COLOR,
  SELECTION_FILL_COLOR,
  SELECTION_HANDLE_RADIUS,
  SELECTION_HANDLE_STROKE_WIDTH,
  SELECTION_HANDLE_TOUCH_RADIUS,
  SELECTION_STROKE_COLOR,
  SELECTION_STROKE_WIDTH,
  SelectionAxis,
  SelectionLayout,
  SheetSelection,
  allRange,
  createCoord,
  docRect,
  hitTest,
  resolve as resolveSheetSelection,
  selectedText,
  selectionContainsColumn,
  selectionContainsRow,
  selectionEquals,
  selectionScreenRect as computeSelectionScreenRect
} from './SheetSelectionModel';
import { SelectionMenuBubble, copyTextToPasteboard } from './SelectionMenuBubble';

/**
 * 选区控制钩子集合（表格视图侧）。
 *
 * <p>为什么在这里再声明一份、而不是从 `OfficePreviewView.ets` 导入规范定义：
 * `OfficePreviewView.ets` 必须 `import { SpreadsheetView }` 才能渲染本组件，
 * 本文件若反向导入它的类型就构成模块环；跨 `.ets` 的类型环解析在 ArkTS 下不做保证
 * （本仓库已因同类风险在 `translateLineMetrics` 处显式回避 `instanceof`）。
 * 而 `viewer-ohos/Index.ets` 又把 `SelectionControlHooks` 这个公开名字固定在
 * `OfficePreviewView` 导出上，因此无法把唯一定义搬到本文件，只能在两侧各留一份。
 *
 * <p>两份声明字段完全一致，TypeScript 的结构类型让父视图构造的对象可以直接传入
 * `registerControls` 的第 5 个参数，无需类型断言。本副本刻意不 `export`：
 * 对外只暴露 `OfficePreviewView` 那一份，避免同名类型出现两条公开导入路径。
 */
interface SelectionControlHooks {
  selectAll: () => boolean;
  clearSelection: () => void;
  hasSelection: () => boolean;
  getSelectedText: () => string;
  copySelection: () => boolean;
}

const HEADER_WIDTH = 42;
const HEADER_HEIGHT = 22;
const GRID_COLOR = '#dce1e5';
const HEADER_BG = '#f3f5f7';
const HEADER_TEXT = '#52606d';
/** 缩放补间与越界回弹时长，与 Android OfficePreviewView 的 ZOOM_ANIMATION_MS 保持一致 */
const ZOOM_TWEEN_MS = RenderUtils.ZOOM_ANIMATION_MS;
/** 表格缩放下限，与 Android 电子表格分支一致 */
const MIN_SCALE = 0.5;
/** 长按选格触发时长（ms）：与 DOCX/PPTX 长按选词一致，短于系统默认 500ms 以贴合拖选手感 */
const SELECTION_LONG_PRESS_MS: number = 400;
/** 拖选期间边缘自动滚动热区（vp） */
const SELECTION_EDGE_SCROLL_ZONE: number = 36;
/** 边缘自动滚动单帧最大步长（vp） */
const SELECTION_EDGE_SCROLL_MAX_STEP: number = 12;
/** 边缘自动滚动步进间隔（ms） */
const SELECTION_EDGE_SCROLL_INTERVAL: number = 16;
/** 浮动气泡延迟定位时长（ms）：手势停稳后延迟一拍，避免滚动/缩放过程中反复布局 */
const BUBBLE_SETTLE_MS: number = 32;

/** 选区拖拽模式：0 无 / 1 左上角手柄 / 2 右下角手柄 / 3 长按拖选 */
const DRAG_NONE: number = 0;
const DRAG_HANDLE_START: number = 1;
const DRAG_HANDLE_END: number = 2;
const DRAG_LONG_PRESS: number = 3;

/**
 * 预计算 0..255 列标字母，彻底消除表头绘制时的高频字符串循环拼接
 */
const COLUMN_LETTERS: string[] = (() => {
  const arr: string[] = new Array(256);
  for (let i = 0; i < 256; i++) {
    let letter = '';
    let temp = i;
    while (temp >= 0) {
      letter = String.fromCharCode((temp % 26) + 65) + letter;
      temp = Math.floor(temp / 26) - 1;
    }
    arr[i] = letter;
  }
  return arr;
})();

/**
 * 轴前缀和与二分查找空间索引
 */
class SheetAxis {
  readonly offsets: number[];
  readonly visible: number[];

  /** 用预计算的 offsets/visible 构造 */
  constructor(offsets: number[], visible?: number[]);
  /** 现场计算（兼容旧 core） */
  constructor(sizes: number[]);
  constructor(arg: number[], visible?: number[]) {
    if (visible !== undefined) {
      this.offsets = arg;
      const limit = Math.max(0, arg.length - 1);
      this.visible = visible.filter((idx: number) => idx >= 0 && idx < limit);
    } else {
      // 现场计算模式：arg 是 sizes
      const sizes = arg;
      this.offsets = new Array(sizes.length + 1);
      this.offsets[0] = 0;
      const vis: number[] = [];
      for (let i = 0; i < sizes.length; i++) {
        this.offsets[i + 1] = this.offsets[i] + sizes[i];
        if (sizes[i] > 0) {
          vis.push(i);
        }
      }
      this.visible = vis;
    }
  }

  // 二分查找：找到第一个使得 offsets[visible[mid] + 1] > position 的下标（在 visible 数组中的 index）
  first(position: number): number {
    let low = 0;
    let high = this.visible.length;
    while (low < high) {
      const mid = (low + high) >>> 1;
      if (this.offsets[this.visible[mid] + 1] <= position) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    return low;
  }
}

/**
 * 预计算的合并单元格元数据
 */
class SheetMergeItem {
  readonly left: number;
  readonly top: number;
  readonly right: number;
  readonly bottom: number;
  readonly startRow: number;
  readonly endRow: number;
  readonly anchor: model.Cell | null;

  constructor(left: number, top: number, right: number, bottom: number,
    startRow: number, endRow: number, anchor: model.Cell | null) {
    this.left = left;
    this.top = top;
    this.right = right;
    this.bottom = bottom;
    this.startRow = startRow;
    this.endRow = endRow;
    this.anchor = anchor;
  }
}

/**
 * 针对当前工作表的轻量级空间索引布局，完全对齐安卓端 SheetLayout 设计：
 * 1. 采用 rowStarts 稀疏索引与二分查找，仅遍历视口内可见单元格，彻底消除全表 O(N) 扫描
 * 2. 采用 Uint8Array 记录合并从属关系，消除每帧几十万次字符串分配与垃圾回收 (GC)
 * 3. 预先计算无缩放基础前缀和，重绘时零数组分配
 * 4. 采用 64 行分桶空间索引与代际去重，避免遍历全表千量级合并单元格
 */
class SheetLayoutData {
  static readonly BUCKET_ROW_SIZE = 64;
  readonly sheet: model.Sheet;
  readonly rows: SheetAxis;
  readonly columns: SheetAxis;
  readonly totalWidth: number;
  readonly totalHeight: number;
  readonly rowStarts: Int32Array;
  readonly mergedCells: Uint8Array;
  readonly merges: SheetMergeItem[];
  readonly mergeBuckets: Int32Array[];
  readonly mergeSeenGen: Int32Array;
  currentGen: number = 0;

  constructor(sheet: model.Sheet) {
    this.sheet = sheet;
    const g = sheet.geometry;
    if (g && SheetLayoutData.usable(g, sheet)) {
      // 使用 core 预计算的几何数据
      this.columns = new SheetAxis(g.columnOffsets, g.columnVisible);
      this.rows = new SheetAxis(g.rowOffsets, g.rowVisible);
      this.totalWidth = this.columns.offsets[this.columns.offsets.length - 1] ?? 0;
      this.totalHeight = this.rows.offsets[this.rows.offsets.length - 1] ?? 0;
      this.rowStarts = Int32Array.from(g.rowStarts);
      const totalCells = sheet.cells.length;
      this.mergedCells = new Uint8Array(totalCells);
      if (g.mergedCells) {
        for (let i = 0; i < Math.min(g.mergedCells.length, totalCells); i++) {
          this.mergedCells[i] = g.mergedCells[i] ? 1 : 0;
        }
      }
      this.merges = [];
      for (const r of g.mergeRects) {
        const anchorIdx = r.anchor >= 0 && r.anchor < totalCells ? r.anchor : -1;
        this.merges.push(new SheetMergeItem(r.left, r.top, r.right, r.bottom,
          r.startRow, r.endRow, anchorIdx >= 0 ? sheet.cells[anchorIdx] : null));
      }
    } else {
      // 回退：旧 core 无 geometry，现场计算
      this.rows = new SheetAxis(sheet.rowHeights);
      this.columns = new SheetAxis(sheet.columnWidths);
      this.totalWidth = this.columns.offsets[this.columns.offsets.length - 1] ?? 0;
      this.totalHeight = this.rows.offsets[this.rows.offsets.length - 1] ?? 0;

      const rowCount = sheet.rowHeights.length;
      this.rowStarts = new Int32Array(rowCount + 1);
      const totalCells = sheet.cells.length;
      let next = 0;
      for (let r = 0; r < rowCount; r++) {
        this.rowStarts[r] = next;
        while (next < totalCells && sheet.cells[next].row === r) {
          next++;
        }
      }
      this.rowStarts[rowCount] = next;

      this.mergedCells = new Uint8Array(totalCells);
      this.merges = [];

      if (sheet.merges) {
        for (const m of sheet.merges) {
          let anchor: model.Cell | null = null;
          for (let r = m.startRow; r <= m.endRow; r++) {
            if (r >= rowCount) break;
            const startIdx = this.firstCell(r, m.startColumn);
            const endIdx = this.rowStarts[r + 1];
            for (let i = startIdx; i < endIdx; i++) {
              const cell = sheet.cells[i];
              if (cell.column > m.endColumn) break;
              this.mergedCells[i] = 1;
              if (r === m.startRow && cell.column === m.startColumn) {
                anchor = cell;
              }
            }
          }
          const left = this.columns.offsets[Math.min(m.startColumn, this.columns.offsets.length - 1)] ?? 0;
          const top = this.rows.offsets[Math.min(m.startRow, this.rows.offsets.length - 1)] ?? 0;
          const right = this.columns.offsets[Math.min(m.endColumn + 1, this.columns.offsets.length - 1)] ?? 0;
          const bottom = this.rows.offsets[Math.min(m.endRow + 1, this.rows.offsets.length - 1)] ?? 0;
          this.merges.push(new SheetMergeItem(left, top, right, bottom, m.startRow, m.endRow, anchor));
        }
      }
    }

    const rowCount = sheet.rowHeights.length;
    const bucketCount = Math.max(1, Math.ceil(rowCount / SheetLayoutData.BUCKET_ROW_SIZE) + 1);
    const rawBuckets: number[][] = [];
    for (let b = 0; b < bucketCount; b++) {
      rawBuckets.push([]);
    }
    // 直接按自身携带的行范围分桶，不依赖 this.merges 与 sheet.merges 的下标一致性
    for (let mIdx = 0; mIdx < this.merges.length; mIdx++) {
      const m = this.merges[mIdx];
      const startB = Math.max(0, Math.min(bucketCount - 1, Math.floor(m.startRow / SheetLayoutData.BUCKET_ROW_SIZE)));
      const endB = Math.max(startB, Math.min(bucketCount - 1, Math.floor(m.endRow / SheetLayoutData.BUCKET_ROW_SIZE)));
      for (let b = startB; b <= endB; b++) {
        rawBuckets[b].push(mIdx);
      }
    }
    this.mergeBuckets = new Array(bucketCount);
    for (let b = 0; b < bucketCount; b++) {
      this.mergeBuckets[b] = new Int32Array(rawBuckets[b]);
    }
    this.mergeSeenGen = new Int32Array(this.merges.length);
  }

  /** 预计算几何是否可直接使用：长度须与行列维度、单元格数量匹配，否则回退现场计算 */
  private static usable(g: model.SheetGeometry, sheet: model.Sheet): boolean {
    return Array.isArray(g.columnOffsets) && g.columnOffsets.length === sheet.columnWidths.length + 1
      && Array.isArray(g.rowOffsets) && g.rowOffsets.length === sheet.rowHeights.length + 1
      && Array.isArray(g.rowStarts) && g.rowStarts.length === sheet.rowHeights.length + 1
      && Array.isArray(g.columnVisible) && Array.isArray(g.rowVisible)
      && (!g.mergedCells || g.mergedCells.length === sheet.cells.length)
      && Array.isArray(g.mergeRects) && g.mergeRects.length === (sheet.merges ? sheet.merges.length : 0);
  }

  // 二分查找：找到指定行中，列号 >= column 的第一个单元格下标
  firstCell(row: number, column: number): number {
    let low = this.rowStarts[row];
    let high = this.rowStarts[row + 1];
    while (low < high) {
      const mid = (low + high) >>> 1;
      if (this.sheet.cells[mid].column < column) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    return low;
  }
}

interface CachedCellWrap {
  readonly scaleKey: number;
  readonly availWKey: number;
  readonly maxLines: number;
  readonly lines: string[];
}

/**
 * XLSX 电子表格原生渲染组件：支持多工作表 Sheet 切换、视口虚拟化渲染、物理惯性滑动与手势缩放
 */
@Component
export struct SpreadsheetView {
  // 使用普通属性避免 @Prop 对大型电子表格 AST 结构进行递归深拷贝造成卡顿或属性丢失
  document: model.OfficeDocument | null = null;
  @Prop @Watch('onSearchChanged') searchMatches: model.SearchMatch[] = [];
  @Prop @Watch('onSearchChanged') currentMatchIndex: number = -1;
  onSheetChange?: (sheetNumber: number, sheetCount: number) => void;
  /**
   * 回填控制回调给父视图。
   *
   * <p>第 5 个参数 `selection` 为本组件新增的选区钩子：父视图（OfficePreviewView）把它
   * 转发给 `OfficePreviewController`，使 `selectAll` / `clearSelection` / `hasSelection` /
   * `getSelectedText` / `copySelection` 在 XLSX 下与 DOCX / PPTX 行为一致。
   * 追加为可选尾参以保持既有 4 参调用点的兼容。
   */
  registerControls?: (
    selectSheet: (sheetNumber: number) => void,
    getZoom: () => number,
    setZoom: (value: number) => void,
    scrollToMatch?: (match: model.SearchMatch) => void,
    selection?: SelectionControlHooks
  ) => void;
  @State currentSheetIndex: number = 0;

  // 使用普通私有属性避免 @State 频繁触发 ArkUI 全组件响应式脏检查与重排
  private offsetX: number = 0;
  private offsetY: number = 0;
  private scaleVal: number = 1.0;

  private settings: RenderingContextSettings = new RenderingContextSettings(true);
  private context2D: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings);
  @State canvasWidth: number = 0;
  @State canvasHeight: number = 0;
  private isReady: boolean = false;
  private retryCount: number = 0;
  private lastDocument: model.OfficeDocument | null = null;

  private panStartX: number = 0;
  private panStartY: number = 0;
  private pinchStartScale: number = 1.0;
  private pinchStartOffsetX: number = 0;
  private pinchStartOffsetY: number = 0;
  private pinchFocusX: number = 0;
  private pinchFocusY: number = 0;

  // MARK: - XLSX 选区状态

  /** 当前选区（null 表示无选区）；变化即触发重绘，行列标头联动高亮共享同一份数据 */
  private selection: SheetSelection | null = null;
  /** 拖拽锚点：长按选格时固定为命中单元格，手柄拖拽时固定为选区另一端 */
  private dragAnchor: CellCoord | null = null;
  /** 拖拽模式，取值见 DRAG_* 常量 */
  private selectionDragMode: number = 0;
  /** 拖拽期间屏蔽 PanGesture 的平移分支，防止画布在拖选时抢走手指 */
  @State private isSelectionDragging: boolean = false;
  /** 最近一次触点（屏幕 vp），边缘自动滚动每帧据此重算焦点 */
  private lastTouchX: number = 0;
  private lastTouchY: number = 0;
  /**
   * 本次触摸是否已由长按/手柄拖拽接管。
   *
   * <p>GestureGroup 是 Parallel 模式，各个手势独立识别：长按建立选区后抬手，
   * 并行的 TapGesture 仍会照常触发，若不加这道闸门就会在建立选区的同一帧把它清掉。
   * 每次 Down 复位，长按或手柄接管时置位。
   */
  private touchConsumedBySelection: boolean = false;
  /** 边缘自动滚动状态 */
  private edgeScrollTimer: number = -1;
  private edgeScrollDirectionX: number = 0;
  private edgeScrollDirectionY: number = 0;
  /** 浮动气泡状态：仅在手势停稳后展示，位置为选区包围框（屏幕 vp） */
  @State private bubbleShown: boolean = false;
  @State private bubbleAnchorX: number = 0;
  @State private bubbleAnchorY: number = 0;
  @State private bubbleBottomY: number = 0;
  @State private bubbleShowSelectAll: boolean = true;
  private bubbleTimer: number = -1;

  // 惯性滑动 (Fling) 物理仿真状态与硬件 VSync
  private flingTimer: number = -1;
  private retryTimer: number = -1;
  private flingVx: number = 0;
  private flingVy: number = 0;
  private lastFlingTime: number = 0;
  private vsync: displaySync.DisplaySync | null = null;
  private flingRunning: boolean = false;
  private lastVsyncTimestamp: number = 0;

  // 缩放补间状态：Canvas 直接绘制，缩放动画需要自建补间驱动重绘
  private zoomTweenTimer: number = -1;
  private zoomTweenFrom: number = 1.0;
  private zoomTweenTo: number = 1.0;
  private zoomTweenDuration: number = 0;
  private zoomTweenStart: number = 0;
  private zoomTweenFocusX: number = 0;
  private zoomTweenFocusY: number = 0;
  private zoomTweenResetOffsets: boolean = false;

  // 单元格折行排版 WeakMap 缓存，避免平移滑动时重复进行 measureText 二分折行排版
  private readonly cellWrapCache: WeakMap<model.Cell, CachedCellWrap> = new WeakMap();

  // 缓存当前 Sheet 的空间索引与几何布局（完全对齐安卓端的 SheetLayout）
  private cachedSheet: model.Sheet | null = null;
  private cachedLayout: SheetLayoutData | null = null;

  private ensureSheetLayout(sheet: model.Sheet): SheetLayoutData {
    if (this.cachedSheet === sheet && this.cachedLayout) {
      return this.cachedLayout;
    }
    this.cachedSheet = sheet;
    this.cachedLayout = new SheetLayoutData(sheet);
    return this.cachedLayout;
  }

  /** 为读屏软件生成工作表摘要：Canvas 自绘内容本身不可被朗读，需显式提供等效文本 */
  private sheetAccessibilityLabel(): string {
    const sheets = this.document?.sheets ?? [];
    const sheet = sheets[this.currentSheetIndex];
    if (!sheet) return '电子表格';
    const name = sheet.name || `Sheet ${this.currentSheetIndex + 1}`;
    const rows = sheet.rowHeights?.length ?? 0;
    const columns = sheet.columnWidths?.length ?? 0;
    return `工作表 ${name}，第 ${this.currentSheetIndex + 1} 个，共 ${sheets.length} 个工作表，数据区域 ${rows} 行 × ${columns} 列`;
  }

  private onSearchChanged(): void {
    if (this.isReady) {
      this.redraw();
    }
  }

  aboutToAppear(): void {
    this.currentSheetIndex = 0;
    this.offsetX = 0;
    this.offsetY = 0;
    this.scaleVal = 1.0;
    if (this.registerControls) {
      this.registerControls(
        (sheetNumber: number): void => {
          this.switchSheet(sheetNumber - 1);
        },
        (): number => this.scaleVal,
        (value: number): void => {
          if (isNaN(value) || !isFinite(value)) return;
          this.stopFling();
          const reset = Math.abs(this.clampScale(value) - 1.0) <= 0.05;
          // 外部按钮缩放走同一套补间，避免放大缩小两步之间出现瞬跳
          this.startZoomTween(reset ? 1.0 : value, this.canvasWidth / 2, this.canvasHeight / 2,
            ZOOM_TWEEN_MS, reset);
        },
        (match: model.SearchMatch): void => {
          this.scrollToMatch(match);
        },
        this.buildSelectionHooks()
      );
    }
  }

  /** 组装选区控制钩子，交给 OfficePreviewView 转交 OfficePreviewController */
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

  public scrollToMatch(match: model.SearchMatch): void {
    if (match.pageIndex !== this.currentSheetIndex) {
      this.switchSheet(match.pageIndex);
    }
    const sheet = this.document?.sheets?.[this.currentSheetIndex];
    if (!sheet) return;
    const layout = this.ensureSheetLayout(sheet);
    const r = match.row !== undefined && match.row >= 0 ? match.row : 0;
    const c = match.column !== undefined && match.column >= 0 ? match.column : 0;
    const s = this.scaleVal;

    // 命中矩形取合并区域或单元格区域（文档坐标）
    const hitRect = this.resolveCellDocRect(r, c, layout);
    if (!hitRect) return;

    // 跳转前先按当前视口算出本帧生效冻结数与合法滚动范围
    const frozen = this.resolveFrameFrozen(sheet, layout, s, this.canvasWidth, this.canvasHeight);
    const totalGridWidth = layout.totalWidth * s;
    const totalGridHeight = layout.totalHeight * s;
    const maxScrollX = Math.max(0, totalGridWidth - (this.canvasWidth - HEADER_WIDTH));
    const maxScrollY = Math.max(0, totalGridHeight - (this.canvasHeight - HEADER_HEIGHT));
    const frozenScreenW = frozen.effFrozenCols > 0 ? (layout.columns.offsets[frozen.effFrozenCols] ?? 0) * s : 0;
    const frozenScreenH = frozen.effFrozenRows > 0 ? (layout.rows.offsets[frozen.effFrozenRows] ?? 0) * s : 0;

    // 冻结侧保持当前偏移，滚动侧居中到可滚动视口中心并钳位
    const target: ScrollTarget = resolveScrollToTarget({
      row: r,
      column: c,
      rect: hitRect,
      effFrozenRows: frozen.effFrozenRows,
      effFrozenCols: frozen.effFrozenCols,
      frozenDataW: frozenScreenW,
      frozenDataH: frozenScreenH,
      headerW: HEADER_WIDTH,
      headerH: HEADER_HEIGHT,
      viewWidth: this.canvasWidth,
      viewHeight: this.canvasHeight,
      scale: s,
      currentOffsetX: this.offsetX,
      currentOffsetY: this.offsetY,
      maxScrollX: maxScrollX,
      maxScrollY: maxScrollY
    });

    this.offsetX = target.offsetX;
    this.offsetY = target.offsetY;
    this.clampOffsets();
    this.redraw();
    this.rescheduleBubbleIfSelected();
  }

  /** 解析单元格或合并区域的文档矩形；行列超出表维度时返回 null */
  private resolveCellDocRect(row: number, column: number, layout: SheetLayoutData): FreezeDocRect | null {
    if (layout.merges && layout.merges.length > 0) {
      for (const m of layout.merges) {
        if (m.anchor && m.anchor.row === row && m.anchor.column === column) {
          return { left: m.left, top: m.top, right: m.right, bottom: m.bottom };
        }
      }
    }
    if (row < 0 || column < 0 ||
        row >= layout.rows.offsets.length - 1 || column >= layout.columns.offsets.length - 1) {
      return null;
    }
    return {
      left: layout.columns.offsets[column],
      top: layout.rows.offsets[row],
      right: layout.columns.offsets[column + 1],
      bottom: layout.rows.offsets[row + 1]
    };
  }

  /** 检索命中的文档矩形（供高亮切片使用） */
  private resolveMatchDocRect(match: model.SearchMatch, layout: SheetLayoutData): FreezeDocRect | null {
    const r = match.row !== undefined && match.row >= 0 ? match.row : 0;
    const c = match.column !== undefined && match.column >= 0 ? match.column : 0;
    return this.resolveCellDocRect(r, c, layout);
  }

  // MARK: - XLSX 选区：布局适配

  /**
   * 把 `SheetLayoutData` 包装成纯模型所需的 `SelectionLayout`。
   *
   * <p>两者唯一的差异是坐标系原点：`SheetLayoutData` 的前缀和以数据区左上角为 0，
   * 而模型约定 `offsets[0]` = 外围标头 gutter（对齐 Android `SheetLayout`）。
   * 因此这里补上 HEADER_WIDTH / HEADER_HEIGHT 偏移，其余（可见索引、rowStarts、
   * 合并区域行列号）完全共享，不复制任何大数组，也不会因两份几何不一致而错位。
   */
  private selectionLayoutOf(layout: SheetLayoutData): SelectionLayout {
    const rowOffsets: number[] = [];
    for (let i = 0; i < layout.rows.offsets.length; i++) {
      rowOffsets.push(layout.rows.offsets[i] + HEADER_HEIGHT);
    }
    const columnOffsets: number[] = [];
    for (let i = 0; i < layout.columns.offsets.length; i++) {
      columnOffsets.push(layout.columns.offsets[i] + HEADER_WIDTH);
    }
    const rows: SelectionAxis = { offsets: rowOffsets, visible: layout.rows.visible };
    const columns: SelectionAxis = { offsets: columnOffsets, visible: layout.columns.visible };
    return { rows: rows, columns: columns, rowStarts: layout.rowStarts };
  }

  /** 当前工作表（越界或未加载时返回 null） */
  private currentSheet(): model.Sheet | null {
    const sheets = this.document?.sheets;
    if (!sheets || sheets.length === 0) return null;
    const idx = Math.min(Math.max(0, this.currentSheetIndex), sheets.length - 1);
    return sheets[idx];
  }

  // MARK: - XLSX 选区：坐标换算与命中

  /**
   * 屏幕触点 → 单元格坐标，按冻结边界消解滚动偏移。
   *
   * <p>`clampToBounds` 为 true 时越界会贴到表格边缘，供拖拽扩选持续扩展；
   * 长按选格用 false，避免在表头或表格空白处误建立选区。
   */
  private hitTestSheetCell(screenX: number, screenY: number, clampToBounds: boolean): CellCoord | null {
    const sheet = this.currentSheet();
    if (!sheet) return null;
    const layout = this.ensureSheetLayout(sheet);
    const frozen = this.resolveFrameFrozen(sheet, layout, this.scaleVal, this.canvasWidth, this.canvasHeight);
    const s = this.scaleVal > 0 ? this.scaleVal : 1;

    // 模型入参统一是「视图数据坐标」：以表头右/下边缘为原点、1 单位 = 1 个文档单位。
    // 表头是固定 42/22vp 不随缩放变化，正文单元才随缩放变化，因此这里只能把
    // 「表头之后的那段屏幕距离」除以缩放，绝不能把整个 screenX 直接除（那会把
    // 表头宽度也当成会缩放，s != 1 时选区整体偏移 HEADER_WIDTH*(1/s - 1)）。
    const viewX = HEADER_WIDTH + (screenX - HEADER_WIDTH) / s;
    const viewY = HEADER_HEIGHT + (screenY - HEADER_HEIGHT) / s;

    // 冻结区尺寸（文档单位，未乘缩放）与滚动量（屏幕偏移取负后除以缩放）同量纲
    const frozenDataW = frozen.effFrozenCols > 0
      ? (layout.columns.offsets[frozen.effFrozenCols] ?? 0) : 0;
    const frozenDataH = frozen.effFrozenRows > 0
      ? (layout.rows.offsets[frozen.effFrozenRows] ?? 0) : 0;
    const scrollDataX = -this.offsetX / s;
    const scrollDataY = -this.offsetY / s;

    return hitTest(this.selectionLayoutOf(layout), frozen.effFrozenRows, frozen.effFrozenCols,
      frozenDataW, frozenDataH, scrollDataX, scrollDataY, viewX, viewY, clampToBounds);
  }

  // MARK: - XLSX 选区：状态变更

  /** 更新选区并按需同步气泡与重绘 */
  private applySelection(next: SheetSelection | null): void {
    this.selection = next;
    if (next === null) {
      this.bubbleShown = false;
      this.cancelBubbleTimer();
    }
    this.redraw();
  }

  /** 清空选区、拖拽状态与气泡（切表、重新加载、双击缩放复位共用） */
  private resetSelection(showRedraw: boolean = true): void {
    this.stopEdgeScroll();
    this.cancelBubbleTimer();
    this.selectionDragMode = DRAG_NONE;
    if (this.isSelectionDragging) {
      this.isSelectionDragging = false;
    }
    this.dragAnchor = null;
    this.bubbleShown = false;
    this.selection = null;
    if (showRedraw) {
      this.redraw();
    }
  }

  // MARK: - XLSX 选区：手势入口

  /**
   * 长按选格：把触点命中的单元格设为锚点与焦点，并进入不抬手即可扩选的状态。
   *
   * <p>与 DOCX/PPTX 的自由划词一致，长按后直接进入 `DRAG_LONG_PRESS`，
   * 锚点固定为命中单元格，焦点随手指移动由 `applySelectionFocus` 更新。
   */
  private handleLongPress(event: GestureEvent): void {
    // 正在拖拽手柄时不重新建选，防止按住手柄停顿 ≥400ms 后把选区折叠回单格
    if (!this.document || this.selectionDragMode !== DRAG_NONE) return;
    const fingerList = event.fingerList;
    if (!fingerList || fingerList.length === 0) return;
    const screenX = fingerList[0].localX;
    const screenY = fingerList[0].localY;
    this.lastTouchX = screenX;
    this.lastTouchY = screenY;
    const hit = this.hitTestSheetCell(screenX, screenY, false);
    if (!hit) return;
    const sheet = this.currentSheet();
    if (!sheet) return;
    const resolved = resolveSheetSelection(sheet, hit, hit);
    if (!resolved) return;
    this.stopFling();
    this.stopZoomTween();
    this.cancelBubbleTimer();
    this.bubbleShown = false;
    this.selectionDragMode = DRAG_LONG_PRESS;
    this.touchConsumedBySelection = true;
    if (!this.isSelectionDragging) {
      this.isSelectionDragging = true;
    }
    this.dragAnchor = hit;
    this.applySelection(resolved);
  }

  /**
   * 单击：存在选区时清除并消费本次点击。
   *
   * <p>长按建选与手柄拖拽之后的抬手不算「单击」，由 `touchConsumedBySelection` 拦下，
   * 否则并行手势下刚建立的选区会被同一次抬手的 Tap 立即清空。
   */
  private handleSingleTap(): void {
    if (this.touchConsumedBySelection) {
      this.touchConsumedBySelection = false;
      return;
    }
    if (this.hasSelection()) {
      this.clearSelection();
    }
  }

  /**
   * 触摸事件总入口：接管选区拖拽的按下/移动/抬起。
   *
   * <p>为什么用 `onTouch` 而不是把扩展逻辑挂在 `PanGesture` 上：`PanGesture` 需要移动超过
   * 识别距离才回调 `onActionStart`，而选区扩选必须在**手指按下那一刻**就能判定手柄命中，
   * 并且长按后不抬手直接拖动就要生效（Android 侧的 TOUCH_LONG_PRESS_DRAG 同款语义）。
   * 用 `onTouch` 可以在 Down 阶段命中手柄、在 Move 阶段持续更新焦点，且与并行的
   * Pan/Pinch/Tap 手势互不抢占——拖拽期间通过 `isSelectionDragging` 让 Pan 分支让步。
   */
  private handleSheetTouch(event: TouchEvent): void {
    const touches = event.touches;
    // 抬手/取消时 touches 为空，必须先把进行中的拖拽收尾，再返回
    if (!touches || touches.length === 0) {
      if (this.selectionDragMode !== DRAG_NONE) {
        this.endSelectionDrag();
      }
      return;
    }
    const touch = touches[0];
    const x = touch.x;
    const y = touch.y;
    if (event.type === TouchType.Down) {
      this.lastTouchX = x;
      this.lastTouchY = y;
      this.touchConsumedBySelection = false;
      // 按下即命中对角手柄：命中则接管，后续 Move 走扩选而不是平移
      if (this.beginHandleDrag(x, y)) {
        this.touchConsumedBySelection = true;
      }
      return;
    }
    if (event.type === TouchType.Move) {
      if (this.selectionDragMode === DRAG_NONE) return;
      this.lastTouchX = x;
      this.lastTouchY = y;
      this.applySelectionFocus(x, y);
      this.updateEdgeScroll(x, y);
      return;
    }
    if (this.selectionDragMode !== DRAG_NONE) {
      this.endSelectionDrag();
    }
  }

  /**
   * 把触点映射为新的焦点单元格并刷新选区。
   *
   * <p>锚点始终固定为 `dragAnchor`，焦点可越过锚点，由 `resolveSheetSelection`（模型 `resolve`）给出规范化闭区间
   * 并自动并入相交的合并区域（设计文档 §3.1.1 的不动点闭包）。
   */
  private applySelectionFocus(screenX: number, screenY: number): void {
    const anchor = this.dragAnchor;
    if (!anchor) return;
    const sheet = this.currentSheet();
    if (!sheet) return;
    // 表格单元格远大于手指偏移，不做 Y 上移防遮挡（与 Android 对齐），避免第 0 行上部误入表头
    const focus = this.hitTestSheetCell(screenX, screenY, true);
    if (!focus) return;
    const resolved = resolveSheetSelection(sheet, anchor, focus);
    if (!resolved) return;
    this.selection = resolved;
    this.redraw();
  }

  /**
   * 命中左上/右下角手柄时接管本次触摸，返回是否已接管。
   *
   * <p>手柄重叠时优先右下角（与 Android `beginSheetHandleDrag` 一致）：
   * 拖起始手柄时锚点固定在选区右下角，拖结束手柄时锚点固定在左上角。
   */
  private beginHandleDrag(screenX: number, screenY: number): boolean {
    const rect = this.selectionScreenRect();
    if (!rect) return false;
    const selection = this.selection;
    if (!selection) return false;
    const onEnd = this.hitSelectionHandle(screenX, screenY, rect.right, rect.bottom);
    const onStart = this.hitSelectionHandle(screenX, screenY, rect.left, rect.top);
    if (!onStart && !onEnd) return false;
    this.stopEdgeScroll();
    this.cancelBubbleTimer();
    this.bubbleShown = false;
    this.selectionDragMode = onEnd ? DRAG_HANDLE_END : DRAG_HANDLE_START;
    if (!this.isSelectionDragging) {
      this.isSelectionDragging = true;
    }
    this.dragAnchor = onEnd
      ? createCoord(selection.startRow, selection.startColumn)
      : createCoord(selection.endRow, selection.endColumn);
    this.lastTouchX = screenX;
    this.lastTouchY = screenY;
    return true;
  }

  /** 触点是否落在手柄热区内（圆形热区，半径 SELECTION_HANDLE_TOUCH_RADIUS） */
  private hitSelectionHandle(screenX: number, screenY: number, handleX: number, handleY: number): boolean {
    const dx = screenX - handleX;
    const dy = screenY - handleY;
    return Math.sqrt(dx * dx + dy * dy) <= SELECTION_HANDLE_TOUCH_RADIUS;
  }

  /** 结束一次选区拖拽：恢复平移手势，非空选区在下一拍重新定位气泡 */
  private endSelectionDrag(): void {
    this.selectionDragMode = DRAG_NONE;
    this.stopEdgeScroll();
    if (this.isSelectionDragging) {
      this.isSelectionDragging = false;
    }
    this.dragAnchor = null;
    this.redraw();
    if (this.hasSelection()) {
      this.scheduleBubble();
    } else {
      this.bubbleShown = false;
    }
  }

  // MARK: - XLSX 选区：屏幕几何

  /**
   * 选区在屏幕坐标系下的外接矩形，用于放置浮动气泡与对角手柄。
   *
   * <p>委托纯模型 {@link computeSelectionScreenRect} 按冻结边界把冻结段与滚动段各自裁剪后求并集：
   * 冻结区内的选区在滚动后仍贴合屏幕上的冻结位置，滚动区完全被冻结区遮挡的选区返回 null。
   */
  private selectionScreenRect(): CellRect | null {
    const selection = this.selection;
    if (!selection) return null;
    const sheet = this.currentSheet();
    if (!sheet) return null;
    const layout = this.ensureSheetLayout(sheet);
    const s = this.scaleVal > 0 ? this.scaleVal : 1;
    const frozen = this.resolveFrameFrozen(sheet, layout, s, this.canvasWidth, this.canvasHeight);
    const frozenDataW = frozen.effFrozenCols > 0
      ? (layout.columns.offsets[frozen.effFrozenCols] ?? 0) : 0;
    const frozenDataH = frozen.effFrozenRows > 0
      ? (layout.rows.offsets[frozen.effFrozenRows] ?? 0) : 0;
    return computeSelectionScreenRect(
      this.selectionLayoutOf(layout),
      selection,
      frozen.effFrozenRows,
      frozen.effFrozenCols,
      frozenDataW,
      frozenDataH,
      this.offsetX,
      this.offsetY,
      s,
      this.canvasWidth,
      this.canvasHeight
    );
  }

  // MARK: - XLSX 选区：边缘自动滚动

  /**
   * 触点进入视口边缘热区时启动定时滚动，步长随深入程度线性递增
   * （设计文档 §3.2.1 第 3 条与 Android `updateEdgeScroll` / `stepEdgeScroll`）。
   * 拖选期间滚动后立刻以最新触点重算焦点，选区因此能持续扩展到屏幕外的单元格。
   */
  private updateEdgeScroll(screenX: number, screenY: number): void {
    let directionX = 0;
    let directionY = 0;
    if (screenX < HEADER_WIDTH + SELECTION_EDGE_SCROLL_ZONE) {
      directionX = -1;
    } else if (screenX > this.canvasWidth - SELECTION_EDGE_SCROLL_ZONE) {
      directionX = 1;
    }
    if (screenY < HEADER_HEIGHT + SELECTION_EDGE_SCROLL_ZONE) {
      directionY = -1;
    } else if (screenY > this.canvasHeight - SELECTION_EDGE_SCROLL_ZONE) {
      directionY = 1;
    }
    if (directionX === 0 && directionY === 0) {
      this.stopEdgeScroll();
      return;
    }
    if (this.edgeScrollTimer !== -1
      && this.edgeScrollDirectionX === directionX && this.edgeScrollDirectionY === directionY) {
      return;
    }
    this.stopEdgeScroll();
    this.edgeScrollDirectionX = directionX;
    this.edgeScrollDirectionY = directionY;
    this.edgeScrollTimer = setInterval(() => {
      this.stepEdgeScroll();
    }, SELECTION_EDGE_SCROLL_INTERVAL);
  }

  /** 单步边缘滚动：按到边缘的距离决定步长，滚动后以最新触点重算焦点 */
  private stepEdgeScroll(): void {
    if (this.selectionDragMode === DRAG_NONE
      || (this.edgeScrollDirectionX === 0 && this.edgeScrollDirectionY === 0)) {
      this.stopEdgeScroll();
      return;
    }
    const zone = SELECTION_EDGE_SCROLL_ZONE;
    let depthX = 0;
    if (this.edgeScrollDirectionX < 0) {
      depthX = Math.max(0, zone - (this.lastTouchX - HEADER_WIDTH));
    } else if (this.edgeScrollDirectionX > 0) {
      depthX = Math.max(0, this.lastTouchX - (this.canvasWidth - zone));
    }
    let depthY = 0;
    if (this.edgeScrollDirectionY < 0) {
      depthY = Math.max(0, zone - (this.lastTouchY - HEADER_HEIGHT));
    } else if (this.edgeScrollDirectionY > 0) {
      depthY = Math.max(0, this.lastTouchY - (this.canvasHeight - zone));
    }
    if (depthX <= 0 && depthY <= 0) {
      this.stopEdgeScroll();
      return;
    }
    if (depthX > 0) {
      const ratioX = Math.min(1, depthX / zone);
      // 屏幕偏移恒 <= 0：向右拖（方向 1）应减小 offsetX 以显示右侧内容
      this.offsetX -= Math.max(1, SELECTION_EDGE_SCROLL_MAX_STEP * ratioX) * this.edgeScrollDirectionX;
    }
    if (depthY > 0) {
      const ratioY = Math.min(1, depthY / zone);
      this.offsetY -= Math.max(1, SELECTION_EDGE_SCROLL_MAX_STEP * ratioY) * this.edgeScrollDirectionY;
    }
    this.clampOffsets();
    this.applySelectionFocus(this.lastTouchX, this.lastTouchY);
  }

  private stopEdgeScroll(): void {
    if (this.edgeScrollTimer !== -1) {
      clearInterval(this.edgeScrollTimer);
      this.edgeScrollTimer = -1;
    }
    this.edgeScrollDirectionX = 0;
    this.edgeScrollDirectionY = 0;
  }

  // MARK: - XLSX 选区：浮动气泡

  /** 立即隐藏气泡并取消延迟调度定时器 */
  private hideBubble(): void {
    this.cancelBubbleTimer();
    this.bubbleShown = false;
  }

  /** 若当前存在非拖拽态选区，在手势/动画停稳后重新把气泡贴回选区 */
  private rescheduleBubbleIfSelected(): void {
    if (this.hasSelection() && this.selectionDragMode === DRAG_NONE) {
      this.scheduleBubble();
    }
  }

  /** 手势停稳后延迟一拍再定位气泡，避免在滚动/缩放过程中反复布局 */
  private scheduleBubble(): void {
    this.cancelBubbleTimer();
    this.bubbleTimer = setTimeout(() => {
      this.bubbleTimer = -1;
      this.repositionBubble();
    }, BUBBLE_SETTLE_MS);
  }

  private cancelBubbleTimer(): void {
    if (this.bubbleTimer !== -1) {
      clearTimeout(this.bubbleTimer);
      this.bubbleTimer = -1;
    }
  }

  /** 依据选区屏幕包围框定位气泡，并按「是否已全选」决定是否展示「全选」按钮 */
  private repositionBubble(): void {
    const selection = this.selection;
    if (!selection) {
      this.bubbleShown = false;
      return;
    }
    const bounds = this.selectionScreenRect();
    if (!bounds) {
      // 选区当前不可见（如全选后尚未滚动到），不展示气泡避免悬空
      this.bubbleShown = false;
      return;
    }
    this.bubbleAnchorX = (bounds.left + bounds.right) / 2;
    this.bubbleAnchorY = bounds.top;
    this.bubbleBottomY = bounds.bottom;
    this.bubbleShowSelectAll = !this.isWholeSheetSelected(selection);
    this.bubbleShown = true;
  }

  /** 当前选区是否已覆盖整表（用于隐藏气泡里无效的「全选」按钮） */
  private isWholeSheetSelected(selection: SheetSelection): boolean {
    const sheet = this.currentSheet();
    if (!sheet) return false;
    const layout = this.ensureSheetLayout(sheet);
    const all = allRange(sheet, this.selectionLayoutOf(layout));
    return all !== null && selectionEquals(all, selection);
  }

  /** 气泡「复制」：写入剪贴板后退出选区态，与系统复制行为一致 */
  private onBubbleCopy(): void {
    if (!this.copySelection()) return;
    this.clearSelection();
  }

  /** 气泡「全选」：切换为整表选区并刷新气泡（已全选时按钮隐藏，无需处理切换） */
  private onBubbleSelectAll(): void {
    this.selectAll();
  }

  // MARK: - XLSX 选区：公开控制 API

  /** 全选：覆盖首个到末个可见单元格；工作表全空或无可见行列时返回 false */
  public selectAll(): boolean {
    const sheet = this.currentSheet();
    if (!sheet) return false;
    const layout = this.ensureSheetLayout(sheet);
    const all = allRange(sheet, this.selectionLayoutOf(layout));
    if (!all) return false;
    this.stopFling();
    this.stopZoomTween();
    this.stopEdgeScroll();
    this.selectionDragMode = DRAG_NONE;
    if (this.isSelectionDragging) {
      this.isSelectionDragging = false;
    }
    this.dragAnchor = null;
    this.selection = all;
    this.redraw();
    this.scheduleBubble();
    return true;
  }

  /** 清空选区、手柄与浮动气泡；无选区时为空操作 */
  public clearSelection(): void {
    this.resetSelection(true);
  }

  /** 当前是否存在选区（仅反映状态，不触发重绘） */
  public hasSelection(): boolean {
    return this.selection !== null;
  }

  /**
   * 当前选中的纯文本。
   *
   * <p>XLSX 返回 TSV：同行以 `"\t"`、跨行以 `"\n"` 分隔，隐藏行列跳过、
   * 合并单元格从属位置留空（设计文档 §3.1.3）。
   */
  public getSelectedText(): string {
    const selection = this.selection;
    if (!selection) return '';
    const sheet = this.currentSheet();
    if (!sheet) return '';
    const layout = this.ensureSheetLayout(sheet);
    const text = selectedText(sheet, this.selectionLayoutOf(layout), selection);
    return text === null ? '' : text;
  }

  /** 把当前选中文本写入系统剪贴板；无选区或剪贴板不可用时返回 false */
  public copySelection(): boolean {
    const text = this.getSelectedText();
    if (text.length === 0) return false;
    return copyTextToPasteboard(text);
  }

  private switchSheet(idx: number): void {
    const sheets = this.document?.sheets;
    if (!sheets || idx < 0 || idx >= sheets.length) return;
    this.stopFling();
    // 切表必须清除选区：行号/列号在新工作表上指向完全不同的数据（设计文档 §全局约束）
    this.resetSelection(false);
    if (this.currentSheetIndex !== idx) {
      this.currentSheetIndex = idx;
      this.cachedSheet = null;
      this.cachedLayout = null;
    }
    this.offsetX = 0;
    this.offsetY = 0;
    this.scaleVal = 1.0;
    this.redraw();
    if (this.onSheetChange) {
      this.onSheetChange(idx + 1, sheets.length);
    }
  }

  aboutToDisappear(): void {
    this.isReady = false;
    this.stopFling();
    // 组件销毁时清理选区相关定时器，避免定时器持有已销毁组件的闭包
    this.stopEdgeScroll();
    this.cancelBubbleTimer();
    this.selectionDragMode = DRAG_NONE;
    this.isSelectionDragging = false;
    this.selection = null;
    this.dragAnchor = null;
    if (this.vsync) {
      try {
        this.vsync.off('frame');
      } catch (_e) {
        // ignore
      }
      this.vsync = null;
    }
    if (this.retryTimer !== -1) {
      clearTimeout(this.retryTimer);
      this.retryTimer = -1;
    }
    this.cachedSheet = null;
    this.cachedLayout = null;
  }

  private stopFling(): void {
    this.flingRunning = false;
    this.lastVsyncTimestamp = 0;
    if (this.vsync) {
      try {
        this.vsync.stop();
      } catch (_e) {
        // ignore
      }
    }
    if (this.flingTimer !== -1) {
      clearTimeout(this.flingTimer);
      this.flingTimer = -1;
    }
    this.flingVx = 0;
    this.flingVy = 0;
    this.stopZoomTween();
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
      this.rescheduleBubbleIfSelected();
      return;
    }

    // 指数阻尼衰减
    const friction = 2.8;
    const decay = Math.exp(-friction * dt);
    this.flingVx *= decay;
    this.flingVy *= decay;

    if (Math.hypot(this.flingVx, this.flingVy) < 25) {
      this.stopFling();
      this.rescheduleBubbleIfSelected();
      return;
    }

    const prevX = this.offsetX;
    const prevY = this.offsetY;
    this.offsetX += this.flingVx * dt;
    this.offsetY += this.flingVy * dt;
    this.clampOffsets();

    if (this.offsetX === prevX) this.flingVx = 0;
    if (this.offsetY === prevY) this.flingVy = 0;
    if (this.flingVx === 0 && this.flingVy === 0) {
      this.stopFling();
      this.redraw();
      this.rescheduleBubbleIfSelected();
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

  private getCurrentSheet(): model.Sheet | undefined {
    if (!this.document || !this.document.sheets || this.document.sheets.length === 0) {
      return undefined;
    }
    const idx = Math.min(Math.max(0, this.currentSheetIndex), this.document.sheets.length - 1);
    return this.document.sheets[idx];
  }

  private clampOffsets(): void {
    const sheet = this.getCurrentSheet();
    if (!sheet || this.canvasWidth <= 0 || this.canvasHeight <= 0) return;
    const layout = this.ensureSheetLayout(sheet);
    const s = this.scaleVal;
    const totalGridWidth = layout.totalWidth * s;
    const totalGridHeight = layout.totalHeight * s;
    const minOx = Math.min(0, this.canvasWidth - HEADER_WIDTH - totalGridWidth);
    const minOy = Math.min(0, this.canvasHeight - HEADER_HEIGHT - totalGridHeight);
    this.offsetX = Math.min(0, Math.max(minOx, this.offsetX));
    this.offsetY = Math.min(0, Math.max(minOy, this.offsetY));
  }

  private clampScale(value: number): number {
    return Math.min(RenderUtils.ZOOM_MAX, Math.max(MIN_SCALE, value));
  }

  /** 归一化当前工作表的冻结行列数：缺省/非法值按 0 处理，小数取整并钳位到表维度 */
  private resolveSheetFrozen(sheet: model.Sheet): EffectiveFrozen {
    const rowCount = sheet.rowHeights ? sheet.rowHeights.length : 0;
    const colCount = sheet.columnWidths ? sheet.columnWidths.length : 0;
    return {
      effFrozenRows: normalizeFrozen(sheet.frozenRows, rowCount),
      effFrozenCols: normalizeFrozen(sheet.frozenColumns, colCount)
    };
  }

  /**
   * 计算本帧生效的冻结行列数（含视口占比保护）。
   * 冻结区尺寸用屏幕 vp：前 N 行的文档高度前缀和乘以缩放，与设计文档 §3.2.2 一致。
   */
  private resolveFrameFrozen(sheet: model.Sheet, layout: SheetLayoutData, s: number,
    canvasW: number, canvasH: number): EffectiveFrozen {
    const frozen = this.resolveSheetFrozen(sheet);
    const rowCount = sheet.rowHeights ? sheet.rowHeights.length : 0;
    const colCount = sheet.columnWidths ? sheet.columnWidths.length : 0;
    const frozenDataH = frozen.effFrozenRows > 0
      ? (layout.rows.offsets[frozen.effFrozenRows] ?? 0) * s : 0;
    const frozenDataW = frozen.effFrozenCols > 0
      ? (layout.columns.offsets[frozen.effFrozenCols] ?? 0) * s : 0;
    return resolveEffectiveFrozen({
      frozenRows: frozen.effFrozenRows,
      frozenColumns: frozen.effFrozenCols,
      rowCount: rowCount,
      colCount: colCount,
      availBodyW: Math.max(0, canvasW - HEADER_WIDTH),
      availBodyH: Math.max(0, canvasH - HEADER_HEIGHT),
      frozenDataW: frozenDataW,
      frozenDataH: frozenDataH
    });
  }

  /** 以焦点为锚点套用一次缩放，供捏合与补间共用；逻辑值由调用方决定是否越界 */
  private applyScaleAt(newScale: number, focusX: number, focusY: number): void {
    const oldScale = this.scaleVal;
    if (oldScale > 0) {
      const worldX = (focusX - HEADER_WIDTH - this.offsetX) / oldScale;
      const worldY = (focusY - HEADER_HEIGHT - this.offsetY) / oldScale;
      this.offsetX = focusX - HEADER_WIDTH - worldX * newScale;
      this.offsetY = focusY - HEADER_HEIGHT - worldY * newScale;
    }
    this.scaleVal = newScale;
    this.clampOffsets();
  }

  /**
   * 缩放补间：捏合松手的越界回弹、双击与外部按钮缩放共用。
   * 用三次减速曲线逐帧重绘，duration 为 0 时直接落位。
   */
  private startZoomTween(target: number, focusX: number, focusY: number, duration: number,
    resetOffsets: boolean = false): void {
    this.stopZoomTween();
    const from = this.scaleVal;
    const to = this.clampScale(target);
    // 缩放复位（双击 2x -> 1x、外部「重置缩放」）会连带把表头与偏移归零，
    // 选区在归零后的坐标系里不再对应原来的数据，必须一并清除（设计文档 §全局约束）
    if (resetOffsets) {
      this.clearSelection();
    } else if (this.hasSelection()) {
      this.hideBubble();
    }
    if (duration <= 0 || Math.abs(to - from) < 0.002) {
      if (resetOffsets) {
        this.offsetX = 0;
        this.offsetY = 0;
      }
      this.applyScaleAt(to, focusX, focusY);
      this.redraw();
      this.rescheduleBubbleIfSelected();
      return;
    }
    this.zoomTweenFrom = from;
    this.zoomTweenTo = to;
    this.zoomTweenFocusX = focusX;
    this.zoomTweenFocusY = focusY;
    this.zoomTweenDuration = duration;
    this.zoomTweenResetOffsets = resetOffsets;
    this.zoomTweenStart = Date.now();
    this.stepZoomTween();
  }

  private stepZoomTween = (): void => {
    this.zoomTweenTimer = -1;
    const elapsed = Date.now() - this.zoomTweenStart;
    const progress = this.zoomTweenDuration > 0 ? Math.min(1, elapsed / this.zoomTweenDuration) : 1;
    const eased = 1 - Math.pow(1 - progress, 3);
    const scale = this.zoomTweenFrom + (this.zoomTweenTo - this.zoomTweenFrom) * eased;
    this.applyScaleAt(scale, this.zoomTweenFocusX, this.zoomTweenFocusY);
    // 缩放先落位再回正偏移，避免最后一步的锚点换算把清零覆盖成近似值
    if (progress >= 1 && this.zoomTweenResetOffsets) {
      this.offsetX = 0;
      this.offsetY = 0;
    }
    this.redraw();
    if (progress < 1) {
      this.zoomTweenTimer = setTimeout(this.stepZoomTween, 16);
    } else {
      this.rescheduleBubbleIfSelected();
    }
  };

  private stopZoomTween(): void {
    if (this.zoomTweenTimer >= 0) {
      clearTimeout(this.zoomTweenTimer);
      this.zoomTweenTimer = -1;
    }
  }

  /** 捏合松手：越界量用一段减速动画弹回已夹的缩放值，未越界时直接把气泡贴回选区 */
  private settlePinchScale(): void {
    const settled = this.clampScale(this.scaleVal);
    if (Math.abs(settled - this.scaleVal) <= 0.002) {
      this.rescheduleBubbleIfSelected();
      return;
    }
    const focusX = this.pinchFocusX > 0 ? this.pinchFocusX : (this.canvasWidth / 2);
    const focusY = this.pinchFocusY > 0 ? this.pinchFocusY : (this.canvasHeight / 2);
    this.startZoomTween(settled, focusX, focusY, ZOOM_TWEEN_MS);
  }

  private redraw(): void {
    if (!this.isReady) return;
    if (this.document !== this.lastDocument) {
      this.lastDocument = this.document;
      this.currentSheetIndex = 0;
      this.offsetX = 0;
      this.offsetY = 0;
      this.scaleVal = 1.0;
      this.cachedSheet = null;
      this.cachedLayout = null;
      // 文档重新加载后旧选区的行列号指向另一份数据，必须清除（设计文档 §全局约束）
      this.resetSelection(false);
    }
    const sheet = this.getCurrentSheet();
    const ctx = this.context2D;
    const w = this.canvasWidth;
    const h = this.canvasHeight;
    if (!sheet || w <= 0 || h <= 0) {
      if (this.isReady && (this.canvasWidth <= 0 || this.canvasHeight <= 0) && this.retryCount < 20) {
        this.retryCount++;
        if (this.retryTimer !== -1) {
          clearTimeout(this.retryTimer);
        }
        this.retryTimer = setTimeout(() => {
          this.retryTimer = -1;
          if (this.isReady) this.redraw();
        }, 50);
      }
      return;
    }
    if (this.retryTimer !== -1) {
      clearTimeout(this.retryTimer);
      this.retryTimer = -1;
    }
    this.retryCount = 0;

    try {
      ctx.clearRect(0, 0, w, h);
      ctx.fillStyle = '#e9ecef';
      ctx.fillRect(0, 0, w, h);

      const canvasW = w;
      const canvasH = h;
      const layout = this.ensureSheetLayout(sheet);
      const rows = layout.rows;
      const columns = layout.columns;

      const s = this.scaleVal;
      const totalGridWidth = layout.totalWidth * s;
      const totalGridHeight = layout.totalHeight * s;

      // 限制滚动边界，避免拖出左上角空白
      const minOx = Math.min(0, canvasW - HEADER_WIDTH - totalGridWidth);
      const minOy = Math.min(0, canvasH - HEADER_HEIGHT - totalGridHeight);
      this.offsetX = Math.min(0, Math.max(minOx, this.offsetX));
      this.offsetY = Math.min(0, Math.max(minOy, this.offsetY));
      const ox = this.offsetX;
      const oy = this.offsetY;

      const bodyRight = Math.min(canvasW, HEADER_WIDTH + ox + totalGridWidth);
      const bodyBottom = Math.min(canvasH, HEADER_HEIGHT + oy + totalGridHeight);

      // 计算无缩放坐标系下的可见视口范围（正文区与表头各自裁剪时复用）
      const unscaledBodyRight = (bodyRight - HEADER_WIDTH - ox) / s;
      const unscaledBodyBottom = (bodyBottom - HEADER_HEIGHT - oy) / s;
      // 列头从滚动可见的首列开始遍历；行头在冻结分段内单独二分
      const firstColIdx = columns.first(-ox / s);

      // 1. 表格主体区域：按冻结象限分别裁剪绘制（无冻结时退化为单一滚动区，与改造前完全一致）
      const frozen = this.resolveFrameFrozen(sheet, layout, s, canvasW, canvasH);
      const frozenRowsCount = frozen.effFrozenRows;
      const frozenColsCount = frozen.effFrozenCols;
      const frozenScreenW = frozenColsCount > 0 ? (columns.offsets[frozenColsCount] ?? 0) * s : 0;
      const frozenScreenH = frozenRowsCount > 0 ? (rows.offsets[frozenRowsCount] ?? 0) * s : 0;
      const quadrants = resolveFreezeQuadrants({
        headerW: HEADER_WIDTH,
        headerH: HEADER_HEIGHT,
        offsetX: ox,
        offsetY: oy,
        frozenDataW: frozenScreenW,
        frozenDataH: frozenScreenH,
        bodyRight: bodyRight,
        bodyBottom: bodyBottom,
        rowCount: sheet.rowHeights.length,
        colCount: sheet.columnWidths.length,
        effFrozenRows: frozenRowsCount,
        effFrozenCols: frozenColsCount
      });

      for (const quadrant of quadrants) {
        this.drawQuadrant(ctx, sheet, layout, quadrant, s);
      }

      // 1.6 绘制全文检索高亮：按象限切片裁剪，滚动区高亮绝不覆盖冻结区
      if (this.searchMatches && this.searchMatches.length > 0) {
        this.drawSearchHighlights(ctx, layout, s, ox, oy, frozenScreenW, frozenScreenH, bodyRight, bodyBottom);
      }

      // 1.7 绘制选区：与检索高亮同样走象限切片，两者可共存（选区叠在检索高亮之上，
      //     让"当前选中区域"始终可辨认；这一点与 Android 的绘制顺序一致）
      this.drawSelection(ctx, layout, s, ox, oy, frozenScreenW, frozenScreenH, bodyRight, bodyBottom);

      // 2. 顶部列头 (A, B, C...)：先画滚动列标头，再在冻结列区间内锁定 X 绘制冻结列标头
      const frozenRight = HEADER_WIDTH + frozenScreenW;
      const frozenBottom = HEADER_HEIGHT + frozenScreenH;
      ctx.save();
      ctx.beginPath();
      ctx.rect(HEADER_WIDTH, 0, canvasW - HEADER_WIDTH, HEADER_HEIGHT);
      ctx.clip();
      ctx.fillStyle = HEADER_BG;
      ctx.fillRect(HEADER_WIDTH, 0, canvasW - HEADER_WIDTH, HEADER_HEIGHT);
      ctx.strokeStyle = GRID_COLOR;
      ctx.lineWidth = 0.5;
      ctx.fillStyle = HEADER_TEXT;
      ctx.font = '10vp sans-serif';
      ctx.textBaseline = 'middle';
      ctx.textAlign = 'center';

      // 2.1 可滚动列标头：裁剪在 [frozenRight .. bodyRight] 内
      ctx.save();
      ctx.beginPath();
      ctx.rect(frozenRight, 0, Math.max(0, bodyRight - frozenRight), HEADER_HEIGHT);
      ctx.clip();
      for (let c = firstColIdx; c < columns.visible.length; c++) {
        const col = columns.visible[c];
        if (col < frozenColsCount) continue;
        if (columns.offsets[col] >= unscaledBodyRight) break;
        const left = HEADER_WIDTH + ox + columns.offsets[col] * s;
        const colW = (columns.offsets[col + 1] - columns.offsets[col]) * s;
        if (left + colW < frozenRight) continue;

        this.drawColumnHeader(ctx, col, left, colW);
      }
      ctx.restore();

      // 2.2 冻结列标头：锁定 X，裁剪在 [HEADER_WIDTH .. frozenRight] 内
      if (frozenColsCount > 0) {
        ctx.save();
        ctx.beginPath();
        ctx.rect(HEADER_WIDTH, 0, frozenScreenW, HEADER_HEIGHT);
        ctx.clip();
        for (let col = 0; col < frozenColsCount; col++) {
          const left = HEADER_WIDTH + columns.offsets[col] * s;
          const colW = (columns.offsets[col + 1] - columns.offsets[col]) * s;
          if (colW <= 0) continue;
          this.drawColumnHeader(ctx, col, left, colW);
        }
        ctx.restore();
      }
      ctx.restore();

      // 3. 左侧行头 (1, 2, 3...)：先画滚动行标头，再在冻结行区间内锁定 Y 绘制冻结行标头
      // 可滚动行标头的起始行取冻结边界（无冻结时即视口顶行），不能取正文底边
      const unscaledScrollTop = (frozenBottom - HEADER_HEIGHT - oy) / s;
      ctx.save();
      ctx.beginPath();
      ctx.rect(0, HEADER_HEIGHT, HEADER_WIDTH, canvasH - HEADER_HEIGHT);
      ctx.clip();
      ctx.fillStyle = HEADER_BG;
      ctx.fillRect(0, HEADER_HEIGHT, HEADER_WIDTH, canvasH - HEADER_HEIGHT);
      ctx.strokeStyle = GRID_COLOR;
      ctx.lineWidth = 0.5;
      ctx.fillStyle = HEADER_TEXT;
      ctx.font = '10vp sans-serif';
      ctx.textBaseline = 'middle';
      ctx.textAlign = 'right';

      // 3.1 可滚动行标头：裁剪在 [frozenBottom .. bodyBottom] 内
      ctx.save();
      ctx.beginPath();
      ctx.rect(0, frozenBottom, HEADER_WIDTH, Math.max(0, bodyBottom - frozenBottom));
      ctx.clip();
      const firstScrollRowIdx = rows.first(unscaledScrollTop);
      for (let r = firstScrollRowIdx; r < rows.visible.length; r++) {
        const row = rows.visible[r];
        if (row < frozenRowsCount) continue;
        if (rows.offsets[row] >= unscaledBodyBottom) break;
        const top = HEADER_HEIGHT + oy + rows.offsets[row] * s;
        const rowH = (rows.offsets[row + 1] - rows.offsets[row]) * s;
        if (top + rowH < frozenBottom) continue;

        this.drawRowHeader(ctx, row, top, rowH);
      }
      ctx.restore();

      // 3.2 冻结行标头：锁定 Y，裁剪在 [HEADER_HEIGHT .. frozenBottom] 内
      if (frozenRowsCount > 0) {
        ctx.save();
        ctx.beginPath();
        ctx.rect(0, HEADER_HEIGHT, HEADER_WIDTH, frozenScreenH);
        ctx.clip();
        for (let row = 0; row < frozenRowsCount; row++) {
          const top = HEADER_HEIGHT + rows.offsets[row] * s;
          const rowH = (rows.offsets[row + 1] - rows.offsets[row]) * s;
          if (rowH <= 0) continue;
          this.drawRowHeader(ctx, row, top, rowH);
        }
        ctx.restore();
      }
      ctx.restore();

      // 4. 左上角交叉块与表头分隔线
      ctx.fillStyle = HEADER_BG;
      ctx.fillRect(0, 0, HEADER_WIDTH, HEADER_HEIGHT);
      ctx.strokeStyle = '#bfc7cd';
      ctx.lineWidth = 0.75;
      ctx.beginPath();
      ctx.moveTo(HEADER_WIDTH, 0);
      ctx.lineTo(HEADER_WIDTH, canvasH);
      ctx.moveTo(0, HEADER_HEIGHT);
      ctx.lineTo(canvasW, HEADER_HEIGHT);
      ctx.stroke();

      // 5. 冻结分割线：颜色区别于普通网格线与表头分隔线，压在顶层保证清晰可见
      ctx.strokeStyle = FREEZE_LINE_COLOR;
      ctx.lineWidth = 1;
      ctx.beginPath();
      if (frozenColsCount > 0) {
        const lineX = Math.min(frozenRight, bodyRight);
        ctx.moveTo(lineX, 0);
        ctx.lineTo(lineX, bodyBottom);
      }
      if (frozenRowsCount > 0) {
        const lineY = Math.min(frozenBottom, bodyBottom);
        ctx.moveTo(0, lineY);
        ctx.lineTo(bodyRight, lineY);
      }
      ctx.stroke();

      // 6. 选区对角手柄：在屏幕坐标系绘制，缩放 0.5x..4x 时保持稳定物理尺寸
      this.drawSelectionHandles(ctx);
    } catch (err) {
      console.error(`SpreadsheetView draw failed: ${err}`);
    }
  }

  /** 递增合并单元格代际计数，用于跨象限绘制时去重；溢出时重置以避免脏数据 */
  private nextMergeGen(layout: SheetLayoutData): number {
    layout.currentGen++;
    if (layout.currentGen >= 0x7FFFFFFF) {
      layout.currentGen = 1;
      layout.mergeSeenGen.fill(0);
    }
    return layout.currentGen;
  }

  /**
   * 绘制单个冻结象限：独立 save -> clip -> 白底 -> 普通单元格 -> 网格线 -> 相交合并单元格 -> 单元格边框 -> restore。
   * 象限的行列范围与屏幕偏移由 SheetFreeze 统一给出，锁定轴的偏移恒为 0，因此冻结区不随对应轴滚动。
   */
  private drawQuadrant(
    ctx: CanvasRenderingContext2D,
    sheet: model.Sheet,
    layout: SheetLayoutData,
    quadrant: FreezeQuadrant,
    s: number
  ): void {
    if (quadrant.clip.width <= 0 || quadrant.clip.height <= 0) return;
    const rows = layout.rows;
    const columns = layout.columns;
    const qx = quadrant.offsetX;
    const qy = quadrant.offsetY;
    const clipRight = quadrant.clip.x + quadrant.clip.width;
    const clipBottom = quadrant.clip.y + quadrant.clip.height;

    ctx.save();
    ctx.beginPath();
    ctx.rect(quadrant.clip.x, quadrant.clip.y, quadrant.clip.width, quadrant.clip.height);
    ctx.clip();

    // 白色底板
    ctx.fillStyle = '#ffffff';
    ctx.fillRect(quadrant.clip.x, quadrant.clip.y, quadrant.clip.width, quadrant.clip.height);

    // 该象限在无缩放坐标系下的可见范围
    const unscaledLeft = (quadrant.clip.x - HEADER_WIDTH - qx) / s;
    const unscaledTop = (quadrant.clip.y - HEADER_HEIGHT - qy) / s;
    const unscaledRight = (clipRight - HEADER_WIDTH - qx) / s;
    const unscaledBottom = (clipBottom - HEADER_HEIGHT - qy) / s;

    const firstRowIdx = rows.first(unscaledTop);
    const firstColIdx = columns.first(unscaledLeft);

    // 普通非合并单元格填充与文本
    if (firstColIdx < columns.visible.length && firstRowIdx < rows.visible.length) {
      const firstCol = columns.visible[firstColIdx];
      for (let r = firstRowIdx; r < rows.visible.length; r++) {
        const row = rows.visible[r];
        if (row >= quadrant.rowEnd) break;
        if (rows.offsets[row] >= unscaledBottom) break;
        if (row < quadrant.rowStart) continue;
        const rowTop = HEADER_HEIGHT + qy + rows.offsets[row] * s;
        const rowH = (rows.offsets[row + 1] - rows.offsets[row]) * s;

        const cellStart = layout.firstCell(row, firstCol);
        const cellEnd = layout.rowStarts[row + 1];
        for (let i = cellStart; i < cellEnd; i++) {
          const cell = sheet.cells[i];
          if (cell.column >= quadrant.colEnd) break;
          if (columns.offsets[cell.column] >= unscaledRight) break;
          if (cell.column < quadrant.colStart) continue;
          if (layout.mergedCells[i] === 1 || sheet.columnWidths[cell.column] === 0) continue;

          const colLeft = HEADER_WIDTH + qx + columns.offsets[cell.column] * s;
          const colW = (columns.offsets[cell.column + 1] - columns.offsets[cell.column]) * s;
          this.drawSingleCell(ctx, cell, colLeft, rowTop, colW, rowH, s);
        }
      }
    }

    // 网格线
    ctx.strokeStyle = GRID_COLOR;
    ctx.lineWidth = 0.5;
    ctx.beginPath();
    for (let r = firstRowIdx; r < rows.visible.length; r++) {
      const row = rows.visible[r];
      if (row >= quadrant.rowEnd) break;
      if (rows.offsets[row] >= unscaledBottom) break;
      if (row < quadrant.rowStart) continue;
      const y = HEADER_HEIGHT + qy + rows.offsets[row + 1] * s;
      if (y < quadrant.clip.y) continue;
      ctx.moveTo(quadrant.clip.x, y);
      ctx.lineTo(clipRight, y);
    }
    for (let c = firstColIdx; c < columns.visible.length; c++) {
      const col = columns.visible[c];
      if (col >= quadrant.colEnd) break;
      if (columns.offsets[col] >= unscaledRight) break;
      if (col < quadrant.colStart) continue;
      const x = HEADER_WIDTH + qx + columns.offsets[col + 1] * s;
      if (x < quadrant.clip.x) continue;
      ctx.moveTo(x, quadrant.clip.y);
      ctx.lineTo(x, clipBottom);
    }
    ctx.stroke();

    // 相交的合并单元格：用分桶索引定位，跨冻结边界的合并可能在多个象限各画一次，由各自 clip 裁掉越界部分
    // 每个象限单独取一代：跨冻结边界的合并需要在相邻象限各绘制一次，代际只在象限内去重
    const currentGen = this.nextMergeGen(layout);
    const visibleMerges: SheetMergeItem[] = [];
    // 分桶范围取「象限行范围 ∩ 本象限可见行范围」，避免无冻结时退化为遍历全表合并单元格
    const bucketSize = SheetLayoutData.BUCKET_ROW_SIZE;
    let visibleStartRow = quadrant.rowStart;
    if (firstRowIdx < rows.visible.length) {
      visibleStartRow = Math.max(visibleStartRow, rows.visible[firstRowIdx]);
    }
    const lastRowIdx = rows.first(unscaledBottom);
    let visibleEndRow = quadrant.rowEnd - 1;
    if (lastRowIdx < rows.visible.length) {
      visibleEndRow = Math.min(visibleEndRow, rows.visible[lastRowIdx]);
    } else if (rows.visible.length > 0) {
      visibleEndRow = Math.min(visibleEndRow, rows.visible[rows.visible.length - 1]);
    }
    const startB = Math.max(0, Math.min(layout.mergeBuckets.length - 1,
      Math.floor(Math.max(0, Math.min(visibleStartRow, visibleEndRow)) / bucketSize)));
    const endB = Math.max(startB, Math.min(layout.mergeBuckets.length - 1,
      Math.floor(Math.max(0, visibleEndRow) / bucketSize)));
    for (let b = startB; b <= endB; b++) {
      const bucket = layout.mergeBuckets[b];
      for (let k = 0; k < bucket.length; k++) {
        const mIdx = bucket[k];
        if (layout.mergeSeenGen[mIdx] === currentGen) continue;
        layout.mergeSeenGen[mIdx] = currentGen;
        const m = layout.merges[mIdx];
        // 合并区域必须与象限行列范围有交集
        if (m.endRow < quadrant.rowStart || m.startRow >= quadrant.rowEnd) continue;
        const rect = resolveQuadrantMergeBounds(m.left, m.top, m.right, m.bottom,
          quadrant, HEADER_WIDTH, HEADER_HEIGHT, s);
        if (!rect) continue;
        visibleMerges.push(m);

        ctx.fillStyle = '#ffffff';
        ctx.fillRect(rect.x, rect.y, rect.width, rect.height);
        if (m.anchor) {
          this.drawSingleCell(ctx, m.anchor, rect.x, rect.y, rect.width, rect.height, s);
        }
        ctx.strokeStyle = GRID_COLOR;
        ctx.lineWidth = 0.5;
        ctx.strokeRect(rect.x, rect.y, rect.width, rect.height);
      }
    }

    // 单元格边框
    if (firstColIdx < columns.visible.length && firstRowIdx < rows.visible.length) {
      const firstCol = columns.visible[firstColIdx];
      for (let r = firstRowIdx; r < rows.visible.length; r++) {
        const row = rows.visible[r];
        if (row >= quadrant.rowEnd) break;
        if (rows.offsets[row] >= unscaledBottom) break;
        if (row < quadrant.rowStart) continue;
        const rowTop = HEADER_HEIGHT + qy + rows.offsets[row] * s;
        const rowBottom = HEADER_HEIGHT + qy + rows.offsets[row + 1] * s;

        const cellStart = layout.firstCell(row, firstCol);
        const cellEnd = layout.rowStarts[row + 1];
        for (let i = cellStart; i < cellEnd; i++) {
          const cell = sheet.cells[i];
          if (cell.column >= quadrant.colEnd) break;
          if (columns.offsets[cell.column] >= unscaledRight) break;
          if (cell.column < quadrant.colStart) continue;
          if (layout.mergedCells[i] === 1 || sheet.columnWidths[cell.column] === 0) continue;

          const style = this.document?.cellStyles?.[cell.style];
          if (!style || !style.borders) continue;

          const colLeft = HEADER_WIDTH + qx + columns.offsets[cell.column] * s;
          const colRight = HEADER_WIDTH + qx + columns.offsets[cell.column + 1] * s;
          this.drawCellBorders(ctx, colLeft, rowTop, colRight, rowBottom, style);
        }
      }
    }
    for (const m of visibleMerges) {
      if (!m.anchor) continue;
      const style = this.document?.cellStyles?.[m.anchor.style];
      if (!style || !style.borders) continue;
      const rect = resolveQuadrantMergeBounds(m.left, m.top, m.right, m.bottom,
        quadrant, HEADER_WIDTH, HEADER_HEIGHT, s);
      if (!rect) continue;
      this.drawCellBorders(ctx, rect.x, rect.y, rect.x + rect.width, rect.y + rect.height, style);
    }

    ctx.restore();
  }

  /**
   * 绘制全文检索高亮：每块高亮都在其所属象限的 clip 内绘制，
   * 因此落在滚动区的部分绝不覆盖冻结区，落在冻结区的部分只随未冻结轴滚动。
   */
  private drawSearchHighlights(
    ctx: CanvasRenderingContext2D,
    layout: SheetLayoutData,
    s: number,
    ox: number,
    oy: number,
    frozenScreenW: number,
    frozenScreenH: number,
    bodyRight: number,
    bodyBottom: number
  ): void {
    const frozenDocW = s > 0 ? frozenScreenW / s : 0;
    const frozenDocH = s > 0 ? frozenScreenH / s : 0;
    for (let mIdx = 0; mIdx < this.searchMatches.length; mIdx++) {
      const match = this.searchMatches[mIdx];
      if (match.pageIndex !== this.currentSheetIndex) continue;
      const rect = this.resolveMatchDocRect(match, layout);
      if (!rect) continue;
      const isCurrent = (mIdx === this.currentMatchIndex);
      const pieces = mapMatchRectToQuadrants({
        rect: rect,
        headerW: HEADER_WIDTH,
        headerH: HEADER_HEIGHT,
        offsetX: ox,
        offsetY: oy,
        scale: s,
        frozenDocW: frozenDocW,
        frozenDocH: frozenDocH,
        bodyRight: bodyRight,
        bodyBottom: bodyBottom
      });
      for (const piece of pieces) {
        this.drawHighlightPiece(ctx, piece, isCurrent);
      }
    }
  }

  /** 在切片所属象限内绘制单块高亮 */
  private drawHighlightPiece(ctx: CanvasRenderingContext2D, piece: MatchQuadrantRect, isCurrent: boolean): void {
    ctx.save();
    ctx.beginPath();
    ctx.rect(piece.clip.x, piece.clip.y, piece.clip.width, piece.clip.height);
    ctx.clip();
    if (isCurrent) {
      ctx.fillStyle = 'rgba(255, 160, 0, 0.75)';
      ctx.fillRect(piece.rect.x, piece.rect.y, piece.rect.width, piece.rect.height);
      ctx.strokeStyle = '#e65100';
      ctx.lineWidth = 1.5;
      ctx.strokeRect(piece.rect.x, piece.rect.y, piece.rect.width, piece.rect.height);
    } else {
      ctx.fillStyle = 'rgba(255, 235, 59, 0.45)';
      ctx.fillRect(piece.rect.x, piece.rect.y, piece.rect.width, piece.rect.height);
    }
    ctx.restore();
  }

  // MARK: - 选区绘制

  /**
   * 单个列标格：命中选区时改用 `HEADER_SELECTED_COLOR` 底色与加粗深蓝文字。
   *
   * <p>裁剪边界由调用方（滚动段 / 冻结段各自 save-clip）决定，因此冻结窗格下
   * 列标高亮与选区自身的四象限绘制天然对齐（设计文档 §3.2.1 第 2 条）。
   */
  private drawColumnHeader(ctx: CanvasRenderingContext2D, column: number, left: number, colW: number): void {
    const selection = this.selection;
    const selected = selection !== null && selectionContainsColumn(selection, column);
    if (selected) {
      ctx.fillStyle = HEADER_SELECTED_COLOR;
      ctx.fillRect(left, 0, colW, HEADER_HEIGHT);
    }
    ctx.strokeStyle = GRID_COLOR;
    ctx.lineWidth = 0.5;
    ctx.strokeRect(left, 0, colW, HEADER_HEIGHT);
    ctx.fillStyle = selected ? HEADER_SELECTED_TEXT_COLOR : HEADER_TEXT;
    ctx.font = selected ? 'bold 10vp sans-serif' : '10vp sans-serif';
    ctx.textBaseline = 'middle';
    ctx.textAlign = 'center';
    ctx.fillText(this.indexToColumnLetter(column), left + colW / 2, HEADER_HEIGHT / 2);
  }

  /** 单个行号标格：命中选区时改用 `HEADER_SELECTED_COLOR` 底色与加粗深蓝文字 */
  private drawRowHeader(ctx: CanvasRenderingContext2D, row: number, top: number, rowH: number): void {
    const selection = this.selection;
    const selected = selection !== null && selectionContainsRow(selection, row);
    if (selected) {
      ctx.fillStyle = HEADER_SELECTED_COLOR;
      ctx.fillRect(0, top, HEADER_WIDTH, rowH);
    }
    ctx.strokeStyle = GRID_COLOR;
    ctx.lineWidth = 0.5;
    ctx.strokeRect(0, top, HEADER_WIDTH, rowH);
    ctx.fillStyle = selected ? HEADER_SELECTED_TEXT_COLOR : HEADER_TEXT;
    ctx.font = selected ? 'bold 10vp sans-serif' : '10vp sans-serif';
    ctx.textBaseline = 'middle';
    ctx.textAlign = 'right';
    ctx.fillText(`${row + 1}`, HEADER_WIDTH - 6, top + rowH / 2);
  }

  /**
   * 绘制选区半透明填充与外框（按象限分别绘制），对角手柄由 {@link drawSelectionHandles} 单独绘制。
   *
   * <p><b>填充与外框都必须逐象限平移并裁剪</b>（设计文档 §3.2.1：选区矩形「在各个象限分别
   * 平移与裁剪绘制」）。原因是冻结窗格下同一个选区矩形在各象限使用的滚动量不同：
   * 滚动区叠加 `offsetX`/`offsetY`，冻结区则被固定在 `HEADER_WIDTH`/`HEADER_HEIGHT` 处不随滚动位移。
   * 若整块矩形只按一套偏移描边，当选区起点落在冻结列/冻结行内且存在滚动量时，冻结侧那条边
   * 会被额外平移一个滚动量，与它本应包住的单元格错位；而 `ox == 0 && oy == 0`（未滚动）时
   * 两种画法恰好重合，因此这个错误在无滚动路径上不会暴露。只在象限内裁剪后绘制，
   * 跨冻结边界的选区就会呈现「冻结窗格里一段、滚动窗格里一段、在分隔线处被裁断」的观感，
   * 与 Excel 的冻结窗格表现一致。
   *
   * <p>描边排在填充之后、且同样受象限裁剪，因此线宽不会被相邻象限的填充覆盖。
   * 线宽用屏幕 vp 常量：此处坐标系已含缩放，恒为 1.5vp 的物理粗细。
   */
  private drawSelection(
    ctx: CanvasRenderingContext2D,
    layout: SheetLayoutData,
    s: number,
    ox: number,
    oy: number,
    frozenScreenW: number,
    frozenScreenH: number,
    bodyRight: number,
    bodyBottom: number
  ): void {
    const selection = this.selection;
    if (!selection) return;
    const rect = docRect(this.selectionLayoutOf(layout), selection);
    if (!rect) return;
    if (rect.right <= rect.left || rect.bottom <= rect.top) return;

    // docRect 返回含表头 gutter 的文档坐标，而 SheetFreeze 的象限映射接受的是
    // 「不含 gutter 的正文文档坐标」（表头宽高由 headerW/headerH 单独给出），故先扣掉 gutter
    const bodyRect: FreezeDocRect = {
      left: rect.left - HEADER_WIDTH,
      top: rect.top - HEADER_HEIGHT,
      right: rect.right - HEADER_WIDTH,
      bottom: rect.bottom - HEADER_HEIGHT
    };
    const frozenDocW = s > 0 ? frozenScreenW / s : 0;
    const frozenDocH = s > 0 ? frozenScreenH / s : 0;

    // 填充与外框逐象限绘制：每块都在自己的象限裁剪内先填充后描边，
    // 滚动区绝不越界盖住冻结区，冻结区也不会被滚动量额外平移
    const pieces = mapMatchRectToQuadrants({
      rect: bodyRect,
      headerW: HEADER_WIDTH,
      headerH: HEADER_HEIGHT,
      offsetX: ox,
      offsetY: oy,
      scale: s,
      frozenDocW: frozenDocW,
      frozenDocH: frozenDocH,
      bodyRight: bodyRight,
      bodyBottom: bodyBottom
    });
    for (const piece of pieces) {
      ctx.save();
      ctx.beginPath();
      ctx.rect(piece.clip.x, piece.clip.y, piece.clip.width, piece.clip.height);
      ctx.clip();
      ctx.fillStyle = SELECTION_FILL_COLOR;
      ctx.fillRect(piece.rect.x, piece.rect.y, piece.rect.width, piece.rect.height);
      // 描边在同一象限裁剪内、填充之后，避免线宽被相邻象限的填充覆盖
      ctx.strokeStyle = SELECTION_STROKE_COLOR;
      ctx.lineWidth = SELECTION_STROKE_WIDTH;
      ctx.strokeRect(piece.rect.x, piece.rect.y, piece.rect.width, piece.rect.height);
      ctx.restore();
    }
  }

  /**
   * 绘制选区左上 / 右下两个对角拖拽手柄。
   *
   * <p>固定物理尺寸（半径 SELECTION_HANDLE_RADIUS vp，不随缩放变化），实心圆 + 白色描边；
   * 表格选区是矩形，对角手柄天然表达「拉伸两条边」的语义（设计文档 §3.2.1 第 3 条）。
   */
  private drawSelectionHandles(ctx: CanvasRenderingContext2D): void {
    if (!this.selection) return;
    const rect = this.selectionScreenRect();
    if (!rect) return;
    this.drawSelectionHandle(ctx, rect.left, rect.top);
    this.drawSelectionHandle(ctx, rect.right, rect.bottom);
  }

  /** 单个圆形拖拽手柄：实心圆点 + 白色描边，热区由 hitSelectionHandle 单独判定 */
  private drawSelectionHandle(ctx: CanvasRenderingContext2D, x: number, y: number): void {
    ctx.beginPath();
    ctx.arc(x, y, SELECTION_HANDLE_RADIUS, 0, Math.PI * 2);
    ctx.fillStyle = SELECTION_STROKE_COLOR;
    ctx.fill();
    ctx.strokeStyle = '#ffffff';
    ctx.lineWidth = SELECTION_HANDLE_STROKE_WIDTH;
    ctx.stroke();
  }

  private static readonly MAX_CELL_PREVIEW_LENGTH = 4096;

  private drawSingleCell(
    ctx: CanvasRenderingContext2D,
    cell: model.Cell,
    left: number,
    top: number,
    colW: number,
    rowH: number,
    scale: number
  ): void {
    const style = this.document?.cellStyles?.[cell.style];
    if (style && style.fill !== 0) {
      const fillCss = RenderUtils.argbToCss(style.fill);
      if (fillCss) {
        ctx.fillStyle = fillCss;
        ctx.fillRect(left, top, colW, rowH);
      }
    }

    if (!cell.text || colW <= 4 || rowH <= 2) return;

    let effectiveFs = style?.fontSize ?? 11;
    if (style?.vertAlign) effectiveFs *= 0.65;
    const fontSize = Math.max(6, effectiveFs * scale);
    const italic = style?.italic ? 'italic ' : '';
    const fontFace = RenderUtils.resolveFontFamily(style?.fontFace, true);
    const fontWeight = RenderUtils.resolveFontBold(style?.fontFace, style?.bold) ? 'bold ' : '';
    ctx.font = `${italic}${fontWeight}${fontSize}vp ${fontFace}`;
    ctx.fillStyle = style?.color ? (RenderUtils.argbToCss(style.color) ?? '#202124') : '#202124';
    ctx.textBaseline = 'middle';
    ctx.textAlign = 'left';

    const align = style?.alignment === 3 ? (cell.numeric ? 2 : 0) : (style?.alignment ?? 0);
    const availW = Math.max(1, colW - 4);
    const availH = Math.max(1, rowH - 2);
    const lineHeight = fontSize * 1.25;
    const maxLines = Math.max(1, Math.ceil(availH / lineHeight) + 1);

    // 字符截断已在 Rust core 完成；此处保留兜底保护（对齐 Android previewText：代理对安全 + 省略号）
    let rawText = cell.text;
    if (rawText.length > SpreadsheetView.MAX_CELL_PREVIEW_LENGTH) {
      let end = SpreadsheetView.MAX_CELL_PREVIEW_LENGTH - 1;
      const prevCode = rawText.charCodeAt(end - 1);
      const nextCode = rawText.charCodeAt(end);
      if (prevCode >= 0xD800 && prevCode <= 0xDBFF && nextCode >= 0xDC00 && nextCode <= 0xDFFF) {
        end--;
      }
      rawText = rawText.substring(0, end) + '\u2026';
    }

    let finalLines: string[] = [];
    if (style?.wrap) {
      const scaleKey = Math.round(scale * 1000);
      const availWKey = Math.round(availW);
      const cached = this.cellWrapCache.get(cell);
      if (cached && cached.scaleKey === scaleKey && cached.availWKey === availWKey && cached.maxLines === maxLines) {
        finalLines = cached.lines;
      } else {
        const paragraphs = rawText.split('\n');
        for (const p of paragraphs) {
          if (finalLines.length >= maxLines) break;
          if (p.length === 0) {
            finalLines.push('');
            continue;
          }
          let remaining = p;
          while (remaining.length > 0 && finalLines.length < maxLines) {
            const w = ctx.measureText(remaining).width;
            if (w <= availW) {
              finalLines.push(remaining);
              break;
            }
            // 二分查找单行最大字符数
            let low = 1;
            let high = remaining.length;
            let best = 1;
            while (low <= high) {
              const mid = (low + high) >>> 1;
              if (ctx.measureText(remaining.substring(0, mid)).width <= availW) {
                best = mid;
                low = mid + 1;
              } else {
                high = mid - 1;
              }
            }
            // 代理对保护：切到高代理时避免劈半产生非法 Unicode 字符
            if (best < remaining.length && remaining.charCodeAt(best - 1) >= 0xD800 && remaining.charCodeAt(best - 1) <= 0xDBFF) {
              best = best > 1 ? best - 1 : best + 1;
            }
            finalLines.push(remaining.substring(0, best));
            remaining = remaining.substring(best);
          }
        }
        this.cellWrapCache.set(cell, {
          scaleKey,
          availWKey,
          maxLines,
          lines: finalLines
        });
      }
    } else {
      if (rawText.indexOf('\n') !== -1) {
        const parts = rawText.split('\n');
        for (let i = 0; i < Math.min(parts.length, maxLines); i++) {
          finalLines.push(parts[i]);
        }
      } else {
        finalLines.push(rawText);
      }
    }

    if (finalLines.length === 0) return;

    const lineCount = finalLines.length;
    const totalTextH = lineCount * lineHeight;

    let startY = top + 1 + (availH - totalTextH) / 2 + lineHeight / 2;
    if (style?.verticalAlignment === 'TOP') {
      startY = top + 2 + lineHeight / 2;
    } else if (style?.verticalAlignment === 'BOTTOM') {
      startY = top + rowH - 2 - totalTextH + lineHeight / 2;
    }

    ctx.save();
    ctx.beginPath();
    ctx.rect(left + 2, top + 1, availW, availH);
    ctx.clip();

    for (let i = 0; i < lineCount; i++) {
      const line = finalLines[i];
      let textX = left + 2;
      let textW = 0;
      if (align !== 0 || style?.underline || style?.strike) {
        textW = ctx.measureText(line).width;
        if (align === 1) {
          textX += (availW - textW) / 2;
        } else if (align === 2) {
          textX += availW - textW;
        }
      }
      const lineY = startY + i * lineHeight;
      ctx.fillText(line, textX, lineY);

      if (style?.underline && textW > 0) {
        ctx.strokeStyle = ctx.fillStyle;
        ctx.lineWidth = Math.max(0.75, fontSize * 0.06);
        ctx.beginPath();
        ctx.moveTo(textX, lineY + fontSize * 0.45);
        ctx.lineTo(textX + textW, lineY + fontSize * 0.45);
        ctx.stroke();
      }

      if (style?.strike && textW > 0) {
        ctx.strokeStyle = ctx.fillStyle;
        ctx.lineWidth = Math.max(0.75, fontSize * 0.06);
        ctx.beginPath();
        ctx.moveTo(textX, lineY);
        ctx.lineTo(textX + textW, lineY);
        ctx.stroke();
      }
    }

    ctx.restore();
  }

  private drawCellBorders(
    ctx: CanvasRenderingContext2D,
    left: number,
    top: number,
    right: number,
    bottom: number,
    style?: model.CellStyle
  ): void {
    if (!style || !style.borders) return;
    ctx.lineWidth = 1;
    for (let side = 0; side < 4; side++) {
      const colorInt = style.borders[side];
      if (colorInt === null || colorInt === undefined) continue;
      const css = RenderUtils.argbToCss(colorInt);
      if (!css) continue;
      ctx.strokeStyle = css;
      ctx.beginPath();
      if (side === 0) {
        ctx.moveTo(left, top);
        ctx.lineTo(left, bottom);
      } else if (side === 1) {
        ctx.moveTo(left, top);
        ctx.lineTo(right, top);
      } else if (side === 2) {
        ctx.moveTo(right, top);
        ctx.lineTo(right, bottom);
      } else {
        ctx.moveTo(left, bottom);
        ctx.lineTo(right, bottom);
      }
      ctx.stroke();
    }
  }

  private indexToColumnLetter(index: number): string {
    if (index >= 0 && index < COLUMN_LETTERS.length) {
      return COLUMN_LETTERS[index];
    }
    let letter = '';
    let temp = index;
    while (temp >= 0) {
      letter = String.fromCharCode((temp % 26) + 65) + letter;
      temp = Math.floor(temp / 26) - 1;
    }
    return letter;
  }

  build() {
    if (this.document) {
      Column() {
        Stack({ alignContent: Alignment.TopStart }) {
          Canvas(this.context2D)
            .width(this.canvasWidth > 0 ? this.canvasWidth : '100%')
            .height(this.canvasHeight > 0 ? this.canvasHeight : '100%')
            .backgroundColor('#ffffff')
            .onReady(() => {
              this.isReady = true;
              this.redraw();
            })

          // 选区浮动操作气泡：仅在手势停稳后出现，锚定选区包围框上方
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
        .layoutWeight(1)
        .onAreaChange((_oldArea: Area, newArea: Area) => {
          const areaW = Number(newArea.width);
          const areaH = Number(newArea.height);
          if (areaW > 0) this.canvasWidth = areaW;
          if (areaH > 0) this.canvasHeight = areaH;
          if (this.isReady) {
            this.clampOffsets();
            this.redraw();
          }
        })
        // 手指按下即终止惯性：PanGesture 需要移动达到识别距离才会回调 onActionStart，
        // 若只在 Pan 开始处停 Fling，惯性运行中按住不动时表格仍会继续滑动（安卓 onDown 已 forceFinished）
        .onTouch((event: TouchEvent) => {
          if (event.type === TouchType.Down) {
            this.stopFling();
          }
          this.handleSheetTouch(event);
        })
        .gesture(
          GestureGroup(
            GestureMode.Parallel,
            // 双击缩放优先于单击清选，避免双击放大（1x -> 2x）第一下误清选区
            GestureGroup(
              GestureMode.Exclusive,
              // 双击快速缩放：已放大则恢复 1.0x（同时清选区），否则放大为 2.0x
              TapGesture({ count: 2, distanceThreshold: 3 })
                .onAction((event: GestureEvent) => {
                  this.stopFling();
                  const focusX = event.fingerList && event.fingerList.length > 0
                    ? event.fingerList[0].localX
                    : (this.canvasWidth / 2);
                  const focusY = event.fingerList && event.fingerList.length > 0
                    ? event.fingerList[0].localY
                    : (this.canvasHeight / 2);
                  const reset = this.scaleVal > 1.1;
                  // 复位到 1.0x 时表头回正，与改动前的落点一致
                  this.startZoomTween(reset ? 1.0 : 2.0, focusX, focusY, ZOOM_TWEEN_MS, reset);
                }),
              // 单击：存在选区时清除并消费本次点击
              TapGesture({ count: 1 })
                .onAction((_event: GestureEvent) => {
                  this.handleSingleTap();
                })
            ),
            // 长按 400ms 选格：之后不抬手即可拖动扩选（与 DOCX/PPTX 长按选词手感一致）
            LongPressGesture({ duration: SELECTION_LONG_PRESS_MS, repeat: false })
              .onAction((event: GestureEvent) => {
                this.handleLongPress(event);
              })
              .onActionEnd(() => {
                if (this.selectionDragMode === DRAG_LONG_PRESS) {
                  this.endSelectionDrag();
                }
              })
              .onActionCancel(() => {
                if (this.selectionDragMode === DRAG_LONG_PRESS) {
                  this.endSelectionDrag();
                }
              }),
            // 双指缩放：以双指中心点为锚点动态补偿对齐，平滑不漂移
            PinchGesture({ fingers: 2 })
              .onActionStart((event: GestureEvent) => {
                this.stopFling();
                this.stopZoomTween();
                // 双指缩放接管手势：放弃进行中的选区拖拽（选区本身保留），并隐藏气泡
                if (this.selectionDragMode !== DRAG_NONE) {
                  this.selectionDragMode = DRAG_NONE;
                  this.dragAnchor = null;
                  this.stopEdgeScroll();
                  if (this.isSelectionDragging) {
                    this.isSelectionDragging = false;
                  }
                }
                this.cancelBubbleTimer();
                this.bubbleShown = false;
                this.pinchStartScale = this.clampScale(this.scaleVal);
                this.pinchStartOffsetX = this.offsetX;
                this.pinchStartOffsetY = this.offsetY;
              })
              .onActionUpdate((event: GestureEvent) => {
                const focusX = event.pinchCenterX > 0 ? event.pinchCenterX : (this.canvasWidth / 2);
                const focusY = event.pinchCenterY > 0 ? event.pinchCenterY : (this.canvasHeight / 2);
                this.pinchFocusX = focusX;
                this.pinchFocusY = focusY;
                const raw = this.pinchStartScale * event.scale;
                const settled = this.clampScale(raw);
                // 顶到边界后继续捏合按抵抗曲线让步，松手再弹回，避免硬停让手势显得失去响应
                const excess = raw - settled;
                const display = settled + RenderUtils.rubberBandZoom(
                  excess, excess > 0 ? RenderUtils.ZOOM_OVERFLOW_ABOVE : RenderUtils.ZOOM_OVERFLOW_BELOW);
                const worldX = (focusX - HEADER_WIDTH - this.pinchStartOffsetX) / this.pinchStartScale;
                const worldY = (focusY - HEADER_HEIGHT - this.pinchStartOffsetY) / this.pinchStartScale;
                this.offsetX = focusX - HEADER_WIDTH - worldX * display;
                this.offsetY = focusY - HEADER_HEIGHT - worldY * display;
                this.scaleVal = display;
                this.clampOffsets();
                this.redraw();
              })
              .onActionEnd(() => {
                this.settlePinchScale();
              })
              .onActionCancel(() => {
                this.settlePinchScale();
              }),
            // 单指拖拽平移表格，松手支持物理惯性平滑滑动 (Fling)
            // 选区拖拽期间（长按扩选 / 手柄拉伸）本手势让步，焦点更新由 onTouch 驱动，
            // 否则画布会与选区争夺同一根手指（与 DOCX 的 isSelectionDragging 屏蔽方式一致）
            PanGesture()
              .onActionStart(() => {
                this.stopFling();
                this.stopZoomTween();
                if (this.isSelectionDragging) return;
                this.hideBubble();
                this.panStartX = this.offsetX;
                this.panStartY = this.offsetY;
              })
              .onActionUpdate((event: GestureEvent) => {
                this.stopFling();
                if (this.isSelectionDragging) return;
                this.offsetX = this.panStartX + event.offsetX;
                this.offsetY = this.panStartY + event.offsetY;
                this.clampOffsets();
                this.redraw();
              })
              .onActionEnd((event: GestureEvent) => {
                if (this.isSelectionDragging) return;
                const vx = event.velocityX ?? 0;
                const vy = event.velocityY ?? 0;
                if (Math.hypot(vx, vy) > 80) {
                  this.startFling(vx, vy);
                } else {
                  this.rescheduleBubbleIfSelected();
                }
              })
              .onActionCancel(() => {
                if (!this.isSelectionDragging) {
                  this.rescheduleBubbleIfSelected();
                }
              })
          )
        )
        .accessibilityGroup(true)
        .accessibilityText(this.sheetAccessibilityLabel())
      }
      .width('100%')
      .height('100%')
    }
  }
}
