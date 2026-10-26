import { displaySync } from '@kit.ArkGraphics2D';
import * as model from '../core/OfficeModel';
import { RenderUtils } from './RenderUtils';

const HEADER_WIDTH = 42;
const HEADER_HEIGHT = 22;
const GRID_COLOR = '#dce1e5';
const HEADER_BG = '#f3f5f7';
const HEADER_TEXT = '#52606d';

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

  constructor(sizes: number[]) {
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
  readonly anchor: model.Cell | null;

  constructor(left: number, top: number, right: number, bottom: number, anchor: model.Cell | null) {
    this.left = left;
    this.top = top;
    this.right = right;
    this.bottom = bottom;
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
        this.merges.push(new SheetMergeItem(left, top, right, bottom, anchor));
      }
    }

    const bucketCount = Math.max(1, Math.ceil(rowCount / SheetLayoutData.BUCKET_ROW_SIZE) + 1);
    const rawBuckets: number[][] = [];
    for (let b = 0; b < bucketCount; b++) {
      rawBuckets.push([]);
    }
    if (sheet.merges) {
      for (let mIdx = 0; mIdx < this.merges.length; mIdx++) {
        const m = sheet.merges[mIdx];
        const startB = Math.max(0, Math.min(bucketCount - 1, Math.floor(m.startRow / SheetLayoutData.BUCKET_ROW_SIZE)));
        const endB = Math.max(startB, Math.min(bucketCount - 1, Math.floor(m.endRow / SheetLayoutData.BUCKET_ROW_SIZE)));
        for (let b = startB; b <= endB; b++) {
          rawBuckets[b].push(mIdx);
        }
      }
    }
    this.mergeBuckets = new Array(bucketCount);
    for (let b = 0; b < bucketCount; b++) {
      this.mergeBuckets[b] = new Int32Array(rawBuckets[b]);
    }
    this.mergeSeenGen = new Int32Array(this.merges.length);
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
  onSheetChange?: (sheetNumber: number, sheetCount: number) => void;
  registerControls?: (
    selectSheet: (sheetNumber: number) => void,
    getZoom: () => number,
    setZoom: (value: number) => void
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

  // 惯性滑动 (Fling) 物理仿真状态与硬件 VSync
  private flingTimer: number = -1;
  private retryTimer: number = -1;
  private flingVx: number = 0;
  private flingVy: number = 0;
  private lastFlingTime: number = 0;
  private vsync: displaySync.DisplaySync | null = null;
  private flingRunning: boolean = false;
  private lastVsyncTimestamp: number = 0;

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
          const newScale = Math.min(4.0, Math.max(0.5, value));
          if (Math.abs(newScale - 1.0) <= 0.05) {
            this.scaleVal = 1.0;
            this.offsetX = 0;
            this.offsetY = 0;
          } else {
            const focusX = this.canvasWidth / 2;
            const focusY = this.canvasHeight / 2;
            const worldX = (focusX - HEADER_WIDTH - this.offsetX) / this.scaleVal;
            const worldY = (focusY - HEADER_HEIGHT - this.offsetY) / this.scaleVal;
            this.offsetX = focusX - HEADER_WIDTH - worldX * newScale;
            this.offsetY = focusY - HEADER_HEIGHT - worldY * newScale;
            this.scaleVal = newScale;
            this.clampOffsets();
          }
          this.redraw();
        }
      );
    }
  }

  private switchSheet(idx: number): void {
    const sheets = this.document?.sheets;
    if (!sheets || idx < 0 || idx >= sheets.length) return;
    this.stopFling();
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
        this.stepFlingFallback();
      }
    } else {
      this.stepFlingFallback();
    }
  }

  private stepFlingWithDt(dt: number): void {
    if (!this.flingRunning || (this.flingVx === 0 && this.flingVy === 0)) {
      this.stopFling();
      return;
    }

    // 指数阻尼衰减
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

      // 计算无缩放坐标系下的可见视口范围
      const unscaledScrollX = -ox / s;
      const unscaledScrollY = -oy / s;
      const unscaledBodyRight = (bodyRight - HEADER_WIDTH - ox) / s;
      const unscaledBodyBottom = (bodyBottom - HEADER_HEIGHT - oy) / s;

      const firstRowIdx = rows.first(unscaledScrollY);
      const firstColIdx = columns.first(unscaledScrollX);

      // 1. 表格主体区域
      if (bodyRight > HEADER_WIDTH && bodyBottom > HEADER_HEIGHT) {
        ctx.save();
        ctx.beginPath();
        ctx.rect(
          HEADER_WIDTH,
          HEADER_HEIGHT,
          bodyRight - HEADER_WIDTH,
          bodyBottom - HEADER_HEIGHT
        );
        ctx.clip();

        // 1.1 白色底板
        ctx.fillStyle = '#ffffff';
        ctx.fillRect(HEADER_WIDTH, HEADER_HEIGHT, bodyRight - HEADER_WIDTH, bodyBottom - HEADER_HEIGHT);

        // 1.2 绘制普通非合并单元格填充与文本（仅二分遍历视口内部可见单元格）
        if (firstColIdx < columns.visible.length && firstRowIdx < rows.visible.length) {
          const firstCol = columns.visible[firstColIdx];

          for (let r = firstRowIdx; r < rows.visible.length; r++) {
            const row = rows.visible[r];
            if (rows.offsets[row] >= unscaledBodyBottom) break;
            const rowTop = HEADER_HEIGHT + oy + rows.offsets[row] * s;
            const rowH = (rows.offsets[row + 1] - rows.offsets[row]) * s;

            const cellStart = layout.firstCell(row, firstCol);
            const cellEnd = layout.rowStarts[row + 1];

            for (let i = cellStart; i < cellEnd; i++) {
              const cell = sheet.cells[i];
              if (columns.offsets[cell.column] >= unscaledBodyRight) break;
              if (layout.mergedCells[i] === 1 || sheet.columnWidths[cell.column] === 0) continue;

              const colLeft = HEADER_WIDTH + ox + columns.offsets[cell.column] * s;
              const colW = (columns.offsets[cell.column + 1] - columns.offsets[cell.column]) * s;

              this.drawSingleCell(ctx, cell, colLeft, rowTop, colW, rowH, s);
            }
          }
        }

        // 1.3 绘制整表网格线（仅绘制视口可见区域内的线条）
        ctx.strokeStyle = GRID_COLOR;
        ctx.lineWidth = 0.5;
        ctx.beginPath();
        for (let r = firstRowIdx; r < rows.visible.length; r++) {
          const row = rows.visible[r];
          if (rows.offsets[row] >= unscaledBodyBottom) break;
          const y = HEADER_HEIGHT + oy + rows.offsets[row + 1] * s;
          if (y < HEADER_HEIGHT) continue;
          ctx.moveTo(HEADER_WIDTH, y);
          ctx.lineTo(bodyRight, y);
        }
        for (let c = firstColIdx; c < columns.visible.length; c++) {
          const col = columns.visible[c];
          if (columns.offsets[col] >= unscaledBodyRight) break;
          const x = HEADER_WIDTH + ox + columns.offsets[col + 1] * s;
          if (x < HEADER_WIDTH) continue;
          ctx.moveTo(x, HEADER_HEIGHT);
          ctx.lineTo(x, bodyBottom);
        }
        ctx.stroke();

        // 1.4 绘制可见的合并单元格（覆盖内部网格线并绘制锚点文本，使用行分桶与代际去重）
        const visibleMerges: SheetMergeItem[] = [];
        layout.currentGen++;
        if (layout.currentGen >= 0x7FFFFFFF) {
          layout.currentGen = 1;
          layout.mergeSeenGen.fill(0);
        }
        const currentGen = layout.currentGen;

        const startRow = firstRowIdx < rows.visible.length ? rows.visible[firstRowIdx] : 0;
        let endRow = startRow;
        const lastVisIdx = rows.first(unscaledBodyBottom);
        if (lastVisIdx < rows.visible.length) {
          endRow = rows.visible[lastVisIdx];
        } else if (rows.visible.length > 0) {
          endRow = rows.visible[rows.visible.length - 1];
        }
        const startB = Math.max(0, Math.min(layout.mergeBuckets.length - 1, Math.floor(startRow / SheetLayoutData.BUCKET_ROW_SIZE)));
        const endB = Math.max(startB, Math.min(layout.mergeBuckets.length - 1, Math.floor(endRow / SheetLayoutData.BUCKET_ROW_SIZE)));

        for (let b = startB; b <= endB; b++) {
          const bucket = layout.mergeBuckets[b];
          for (let k = 0; k < bucket.length; k++) {
            const mIdx = bucket[k];
            if (layout.mergeSeenGen[mIdx] === currentGen) {
              continue;
            }
            layout.mergeSeenGen[mIdx] = currentGen;
            const m = layout.merges[mIdx];
            if (m.right <= unscaledScrollX || m.left >= unscaledBodyRight ||
                m.bottom <= unscaledScrollY || m.top >= unscaledBodyBottom) {
              continue;
            }
            visibleMerges.push(m);
            const left = HEADER_WIDTH + ox + m.left * s;
            const top = HEADER_HEIGHT + oy + m.top * s;
            const right = HEADER_WIDTH + ox + m.right * s;
            const bottom = HEADER_HEIGHT + oy + m.bottom * s;
            const mergeW = right - left;
            const mergeH = bottom - top;
            if (mergeW <= 0 || mergeH <= 0) continue;

            ctx.fillStyle = '#ffffff';
            ctx.fillRect(left, top, mergeW, mergeH);
            if (m.anchor) {
              this.drawSingleCell(ctx, m.anchor, left, top, mergeW, mergeH, s);
            }
            ctx.strokeStyle = GRID_COLOR;
            ctx.lineWidth = 0.5;
            ctx.strokeRect(left, top, mergeW, mergeH);
          }
        }

        // 1.5 绘制可见单元格边框 (style.borders)
        if (firstColIdx < columns.visible.length && firstRowIdx < rows.visible.length) {
          const firstCol = columns.visible[firstColIdx];
          for (let r = firstRowIdx; r < rows.visible.length; r++) {
            const row = rows.visible[r];
            if (rows.offsets[row] >= unscaledBodyBottom) break;
            const rowTop = HEADER_HEIGHT + oy + rows.offsets[row] * s;
            const rowBottom = HEADER_HEIGHT + oy + rows.offsets[row + 1] * s;

            const cellStart = layout.firstCell(row, firstCol);
            const cellEnd = layout.rowStarts[row + 1];

            for (let i = cellStart; i < cellEnd; i++) {
              const cell = sheet.cells[i];
              if (columns.offsets[cell.column] >= unscaledBodyRight) break;
              if (layout.mergedCells[i] === 1 || sheet.columnWidths[cell.column] === 0) continue;

              const style = this.document?.cellStyles?.[cell.style];
              if (!style || !style.borders) continue;

              const colLeft = HEADER_WIDTH + ox + columns.offsets[cell.column] * s;
              const colRight = HEADER_WIDTH + ox + columns.offsets[cell.column + 1] * s;
              this.drawCellBorders(ctx, colLeft, rowTop, colRight, rowBottom, style);
            }
          }
        }
        for (const m of visibleMerges) {
          if (!m.anchor) continue;
          const style = this.document?.cellStyles?.[m.anchor.style];
          if (!style || !style.borders) continue;
          const left = HEADER_WIDTH + ox + m.left * s;
          const top = HEADER_HEIGHT + oy + m.top * s;
          const right = HEADER_WIDTH + ox + m.right * s;
          const bottom = HEADER_HEIGHT + oy + m.bottom * s;
          this.drawCellBorders(ctx, left, top, right, bottom, style);
        }

        ctx.restore();
      }

      // 2. 顶部列头 (A, B, C...)
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

      for (let c = firstColIdx; c < columns.visible.length; c++) {
        const col = columns.visible[c];
        if (columns.offsets[col] >= unscaledBodyRight) break;
        const left = HEADER_WIDTH + ox + columns.offsets[col] * s;
        const colW = (columns.offsets[col + 1] - columns.offsets[col]) * s;
        if (left + colW < HEADER_WIDTH) continue;

        ctx.strokeRect(left, 0, colW, HEADER_HEIGHT);
        ctx.fillText(this.indexToColumnLetter(col), left + colW / 2, HEADER_HEIGHT / 2);
      }
      ctx.restore();

      // 3. 左侧行头 (1, 2, 3...)
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

      for (let r = firstRowIdx; r < rows.visible.length; r++) {
        const row = rows.visible[r];
        if (rows.offsets[row] >= unscaledBodyBottom) break;
        const top = HEADER_HEIGHT + oy + rows.offsets[row] * s;
        const rowH = (rows.offsets[row + 1] - rows.offsets[row]) * s;
        if (top + rowH < HEADER_HEIGHT) continue;

        ctx.strokeRect(0, top, HEADER_WIDTH, rowH);
        ctx.fillText(`${row + 1}`, HEADER_WIDTH - 6, top + rowH / 2);
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
    } catch (err) {
      console.error(`SpreadsheetView draw failed: ${err}`);
    }
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

    const fontSize = Math.max(8, (style?.fontSize ?? 11) * scale);
    const bold = style?.bold ? 'bold ' : '';
    const italic = style?.italic ? 'italic ' : '';
    ctx.font = `${italic}${bold}${fontSize}vp sans-serif`;
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
      if (align !== 0 || style?.underline) {
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
        Stack() {
          Canvas(this.context2D)
            .width(this.canvasWidth > 0 ? this.canvasWidth : '100%')
            .height(this.canvasHeight > 0 ? this.canvasHeight : '100%')
            .backgroundColor('#ffffff')
            .onReady(() => {
              this.isReady = true;
              this.redraw();
            })
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
        .gesture(
          GestureGroup(
            GestureMode.Parallel,
            // 双击快速缩放：已放大则恢复 1.0x，否则放大为 2.0x（完全对齐安卓端）
            TapGesture({ count: 2 })
              .onAction((event: GestureEvent) => {
                this.stopFling();
                if (this.scaleVal > 1.1) {
                  this.scaleVal = 1.0;
                  this.offsetX = 0;
                  this.offsetY = 0;
                } else {
                  const focusX = event.fingerList && event.fingerList.length > 0
                    ? event.fingerList[0].localX
                    : (this.canvasWidth / 2);
                  const focusY = event.fingerList && event.fingerList.length > 0
                    ? event.fingerList[0].localY
                    : (this.canvasHeight / 2);
                  const oldS = this.scaleVal;
                  const newS = 2.0;
                  const worldX = (focusX - HEADER_WIDTH - this.offsetX) / oldS;
                  const worldY = (focusY - HEADER_HEIGHT - this.offsetY) / oldS;
                  this.offsetX = focusX - HEADER_WIDTH - worldX * newS;
                  this.offsetY = focusY - HEADER_HEIGHT - worldY * newS;
                  this.scaleVal = newS;
                }
                this.clampOffsets();
                this.redraw();
              }),
            // 双指缩放：以双指中心点为锚点动态补偿对齐，平滑不漂移
            PinchGesture({ fingers: 2 })
              .onActionStart((event: GestureEvent) => {
                this.stopFling();
                this.pinchStartScale = this.scaleVal;
                this.pinchStartOffsetX = this.offsetX;
                this.pinchStartOffsetY = this.offsetY;
              })
              .onActionUpdate((event: GestureEvent) => {
                const newScale = Math.min(4.0, Math.max(0.5, this.pinchStartScale * event.scale));
                const focusX = event.pinchCenterX > 0 ? event.pinchCenterX : (this.canvasWidth / 2);
                const focusY = event.pinchCenterY > 0 ? event.pinchCenterY : (this.canvasHeight / 2);
                const worldX = (focusX - HEADER_WIDTH - this.pinchStartOffsetX) / this.pinchStartScale;
                const worldY = (focusY - HEADER_HEIGHT - this.pinchStartOffsetY) / this.pinchStartScale;
                this.offsetX = focusX - HEADER_WIDTH - worldX * newScale;
                this.offsetY = focusY - HEADER_HEIGHT - worldY * newScale;
                this.scaleVal = newScale;
                this.clampOffsets();
                this.redraw();
              }),
            // 单指拖拽平移表格，松手支持物理惯性平滑滑动 (Fling)
            PanGesture()
              .onActionStart(() => {
                this.stopFling();
                this.panStartX = this.offsetX;
                this.panStartY = this.offsetY;
              })
              .onActionUpdate((event: GestureEvent) => {
                this.stopFling();
                this.offsetX = this.panStartX + event.offsetX;
                this.offsetY = this.panStartY + event.offsetY;
                this.clampOffsets();
                this.redraw();
              })
              .onActionEnd((event: GestureEvent) => {
                const vx = event.velocityX ?? 0;
                const vy = event.velocityY ?? 0;
                if (Math.hypot(vx, vy) > 80) {
                  this.startFling(vx, vy);
                }
              })
          )
        )
        .accessibilityGroup(true)
        .accessibilityText(this.sheetAccessibilityLabel())

        if (this.document.sheets && this.document.sheets.length > 1) {
          Scroll() {
            Row({ space: 8 }) {
              ForEach(this.document.sheets, (sheet: model.Sheet, idx: number) => {
                Text(sheet.name || `Sheet ${idx + 1}`)
                  .fontSize(13)
                  .fontColor(this.currentSheetIndex === idx ? '#0a59f7' : '#5f6368')
                  .fontWeight(this.currentSheetIndex === idx ? FontWeight.Medium : FontWeight.Normal)
                  .backgroundColor(this.currentSheetIndex === idx ? '#e8f0fe' : '#f1f3f4')
                  .borderRadius(4)
                  .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                  .onClick(() => {
                    this.switchSheet(idx);
                  })
              }, (_sheet: model.Sheet, idx: number) => `sheet-${idx}-${this.currentSheetIndex === idx}`)
            }
            .padding({ left: 12, right: 12 })
            .alignItems(VerticalAlign.Center)
          }
          .scrollable(ScrollDirection.Horizontal)
          .width('100%')
          .height(44)
          .backgroundColor('#ffffff')
          .border({ width: { top: 0.5 }, color: '#e0e0e0' })
        }
      }
      .width('100%')
      .height('100%')
    }
  }
}
