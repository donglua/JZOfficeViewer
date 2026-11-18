import { image } from '@kit.ImageKit';
import * as model from '../core/OfficeModel';
import { DocxWrapObstacle } from './DocxWrapLayout';
import { RenderUtils } from './RenderUtils';
import { TextLineMetrics, TextRect, TextBlockLayout } from './TextSelectionModel';

export interface TextSegment {
  text: string;
  font: string;
  fontSize: number;
  color: string;
  underline: boolean;
  strike?: boolean;
  vertAlign?: string;
  spacing?: number;
  width: number;
  background?: number;
}

export interface WrappedLine {
  segments: TextSegment[];
  width: number;
  height: number;
  maxFontSize: number;
  leftIndent: number;
  rightIndent: number;
}

export type WrapObstacle = DocxWrapObstacle;

interface CachedParagraphEntry {
  readonly widthKey: number;
  readonly wrap: boolean;
  readonly lines: WrappedLine[];
}

export type OfficeCanvasContext = CanvasRenderingContext2D | OffscreenCanvasRenderingContext2D;

export interface OfficeRect {
  x: number;
  y: number;
  width: number;
  height: number;
}

export interface TableGeometry {
  cols: number;
  colWidths: number[];
  colX: number[];
  rowTops: number[];
}

/**
 * 段落/表格单元格折行后的纯文本与行度量结果。
 * lines 使用具体类型 CanvasTextLineMetrics（TextLineMetrics 的子类型），
 * 调用方可直接平移/组合，无需再做类型判定与强制转换。
 */
export interface CanvasParagraphsLayout {
  fullText: string;
  lines: CanvasTextLineMetrics[];
}

/** 行内字符范围（相对页面文本，单位 UTF-16 码元） */
interface CanvasCharRange {
  start: number;
  end: number;
}

/**
 * 基于 Canvas 行段（WrappedLine）测得的单行度量，实现 TextSelectionModel.TextLineMetrics。
 *
 * 与 drawParagraphLines / computeParagraphHighlightRects 共用完全同一套坐标规则：
 * 两端对齐 justifiedLineStarts、字符间距 measureSpacedText、居中/右对齐 lineX、
 * 段落 before/after 纵向偏移与元素 verticalAlignment 均在构建本对象时确定。
 */
export class CanvasTextLineMetrics implements TextLineMetrics {
  readonly left: number;
  readonly top: number;
  readonly right: number;
  readonly bottom: number;
  readonly lineX: number;
  readonly charStart: number;
  readonly charEnd: number;
  readonly paraBaseOffset: number;
  private readonly ctx: OfficeCanvasContext | null;
  private readonly segments: TextSegment[];
  private readonly justifyStarts: number[] | null;
  private unitStartsCache: number[] | null = null;

  constructor(
    ctx: OfficeCanvasContext | null,
    left: number,
    top: number,
    right: number,
    bottom: number,
    lineX: number,
    charStart: number,
    charEnd: number,
    paraBaseOffset: number,
    segments: TextSegment[],
    justifyStarts: number[] | null
  ) {
    this.ctx = ctx;
    this.left = left;
    this.top = top;
    this.right = right;
    this.bottom = bottom;
    this.lineX = lineX;
    this.charStart = charStart;
    this.charEnd = charEnd;
    this.paraBaseOffset = paraBaseOffset;
    this.segments = segments;
    this.justifyStarts = justifyStarts;
  }

  /** 行内字符的 UTF-16 码元总数 */
  unitCount(): number {
    let total = 0;
    for (const seg of this.segments) {
      total += seg.text.length;
    }
    return total;
  }

  /** 返回纵向平移 delta 后的新度量（元素 verticalAlignment 生效时使用） */
  shiftedBy(delta: number): CanvasTextLineMetrics {
    return this.translatedBy(0, delta);
  }

  /** 返回同时平移 (dx, dy) 后的新度量（表格单元格/绕排块叠加局部原点时使用） */
  translatedBy(dx: number, dy: number): CanvasTextLineMetrics {
    return new CanvasTextLineMetrics(
      this.ctx,
      this.left + dx,
      this.top + dy,
      this.right + dx,
      this.bottom + dy,
      this.lineX + dx,
      this.charStart,
      this.charEnd,
      this.paraBaseOffset,
      this.segments,
      this.justifyStarts
    );
  }

  /** 行内某字符的相对 X 坐标（相对 lineX），越界自动夹紧 */
  horizontalOffset(localCharIndex: number): number {
    const starts = this.ensureUnitStarts();
    const last = starts.length - 1;
    if (last < 0) {
      return 0;
    }
    const index = Math.max(0, Math.min(last, Math.round(localCharIndex)));
    return starts[index];
  }

  /** 按行内 X 坐标（相对 lineX）反查最邻近字符索引：越过字形中点即落到下一字符边界 */
  charIndexForX(relativeX: number): number {
    const starts = this.ensureUnitStarts();
    const last = starts.length - 1;
    if (last <= 0) {
      return 0;
    }
    if (relativeX <= starts[0]) {
      return 0;
    }
    for (let i = 0; i < last; i++) {
      const start = starts[i];
      const end = starts[i + 1];
      // 代理对的两个码元共用起点，零宽度单元不参与命中，避免切分 Emoji
      if (end <= start) {
        continue;
      }
      if (relativeX < (start + end) / 2) {
        return i;
      }
    }
    return last;
  }

  /** 生成（并缓存）行内每个 UTF-16 单元的绘制起点，长度恒为「码元数 + 1」 */
  private ensureUnitStarts(): number[] {
    const cached = this.unitStartsCache;
    if (cached !== null) {
      return cached;
    }
    const total = this.unitCount();
    let starts: number[];
    const justify = this.justifyStarts;
    if (justify !== null && justify.length >= total + 1) {
      starts = justify.slice(0, total + 1);
    } else {
      starts = new Array<number>(total + 1).fill(0);
      const ctx = this.ctx;
      let x = 0;
      let unit = 0;
      for (const seg of this.segments) {
        const text = seg.text;
        const segLen = text.length;
        if (segLen === 0) {
          continue;
        }
        const runSpacing = seg.spacing !== undefined && Number.isFinite(seg.spacing) ? seg.spacing : 0;
        // 与 justifiedLineStarts 一致：逐字测量前必须切到该分段的字体，否则量到的是上一个分段的字形宽度
        if (ctx !== null) {
          ctx.font = seg.font;
        }
        // 无画笔时按字符数均分 run 宽度，保证与 layoutParagraph 的折行结果一致
        const avgUnitWidth = seg.width / segLen;
        let i = 0;
        let firstInSeg = true;
        while (i < segLen) {
          const code = text.charCodeAt(i);
          const paired = code >= 0xD800 && code <= 0xDBFF && i + 1 < segLen;
          const step = paired ? 2 : 1;
          if (!firstInSeg) {
            x += runSpacing;
          }
          starts[unit] = x;
          // 代理对的两个 UTF-16 单元共用一个起点，避免被拆开绘制
          if (step === 2) {
            starts[unit + 1] = x;
          }
          let width = avgUnitWidth * step;
          if (ctx !== null) {
            const measured = ctx.measureText(text.substring(i, i + step)).width;
            if (measured > 0) {
              width = measured;
            }
          }
          x += width;
          unit += step;
          i += step;
          firstInSeg = false;
        }
      }
      starts[total] = x;
    }
    this.unitStartsCache = starts;
    return starts;
  }
}

export class CanvasElementDrawer {
  // 缓存已构建的 Path2D，避免滑动时每帧重复解析成百上千条矢量指令
  private static readonly pathCache: WeakMap<model.Path, Path2D> = new WeakMap();
  private static readonly paragraphCache: WeakMap<model.Paragraph, CachedParagraphEntry[]> = new WeakMap();

  /**
   * 归一化虚线点线序列：仅接受 2..=16 个有限正数（上限 10000 point），
   * 其余情况整体回退为实线，与 core 的 strokeDash 协议校验保持一致。
   */
  private static dashArrayOf(element: model.Element): number[] {
    const dash = element.strokeDash;
    if (dash === undefined || dash.length < 2 || dash.length > 16) {
      return [];
    }
    for (const value of dash) {
      if (!Number.isFinite(value) || value <= 0 || value > 10000) {
        return [];
      }
    }
    return dash;
  }

  public static drawElement(
    ctx: OfficeCanvasContext,
    element: model.Element,
    imageCache?: Map<string, image.PixelMap>
  ): void {
    ctx.save();

    // 1. 应用 2D 仿射变换矩阵 [a, b, c, d, e, f]
    if (element.transform && element.transform.length >= 6) {
      const m = element.transform;
      ctx.transform(m[0], m[1], m[2], m[3], m[4], m[5]);
    } else if (element.x !== 0 || element.y !== 0) {
      ctx.translate(element.x, element.y);
    }

    const w = element.width;
    const h = element.height;
    const fillStyle = CanvasElementDrawer.resolveFillStyle(ctx, element);
    const strokeCss = RenderUtils.argbToCss(element.stroke);

    // 2. 绘制 PATH 复杂几何路径
    if (element.type === 'PATH' && element.paths && element.paths.length > 0) {
      for (const p of element.paths) {
        if (!p.commands || p.commands.length === 0) continue;
        let path2d = CanvasElementDrawer.pathCache.get(p);
        if (!path2d) {
          path2d = RenderUtils.buildPath2D(p.commands);
          CanvasElementDrawer.pathCache.set(p, path2d);
        }

        if (p.fill && fillStyle) {
          ctx.fillStyle = fillStyle;
          ctx.fill(path2d);
        }

        if (p.stroke && strokeCss) {
          ctx.strokeStyle = strokeCss;
          ctx.lineWidth = Math.max(0.5, element.strokeWidth || 1);
          // 虚线仅作用于描边，绘制后立即恢复实线，避免影响后续子路径与元素
          ctx.setLineDash(CanvasElementDrawer.dashArrayOf(element));
          ctx.stroke(path2d);
          ctx.setLineDash([]);
        }
      }
    } else {
      // 3. 基础几何图形 (RECT / ELLIPSE / LINE)，支持纯色与线性渐变填充
      if (fillStyle && element.type !== 'LINE') {
        ctx.fillStyle = fillStyle;
        if (element.type === 'ELLIPSE') {
          ctx.beginPath();
          ctx.ellipse(w / 2, h / 2, Math.max(0, w / 2), Math.max(0, h / 2), 0, 0, Math.PI * 2);
          ctx.fill();
        } else {
          ctx.fillRect(0, 0, w, h);
        }
      }

      if (strokeCss) {
        ctx.strokeStyle = strokeCss;
        ctx.lineWidth = Math.max(0.5, element.strokeWidth || 1);
        ctx.setLineDash(CanvasElementDrawer.dashArrayOf(element));
        if (element.type === 'ELLIPSE') {
          ctx.beginPath();
          ctx.ellipse(w / 2, h / 2, Math.max(0, w / 2), Math.max(0, h / 2), 0, 0, Math.PI * 2);
          ctx.stroke();
        } else if (element.type === 'LINE') {
          ctx.beginPath();
          ctx.moveTo(0, 0);
          ctx.lineTo(w, h);
          ctx.stroke();
        } else if (element.stroke !== 0) {
          ctx.strokeRect(0, 0, w, h);
        }
        ctx.setLineDash([]);
      }
    }

    // 4. 绘制图片 (IMAGE)，裁剪至元素边界以正确呈現 imageBounds 局部裁剪效果
    if (element.type === 'IMAGE') {
      ctx.save();
      if (w > 0 && h > 0) {
        ctx.beginPath();
        ctx.rect(0, 0, w, h);
        ctx.clip();
      }
      const pixelMap = element.image && imageCache ? imageCache.get(element.image) : undefined;
      if (pixelMap) {
        if (element.imageBounds && element.imageBounds.length >= 4) {
          const ib = element.imageBounds;
          ctx.drawImage(pixelMap, ib[0], ib[1], ib[2] - ib[0], ib[3] - ib[1]);
        } else {
          ctx.drawImage(pixelMap, 0, 0, w, h);
        }
      } else {
        ctx.fillStyle = '#e8eaed';
        ctx.fillRect(0, 0, w, h);
      }
      ctx.restore();
    }

    // 5. 绘制表格 (TABLE)
    if (element.type === 'TABLE' && element.rows && element.rows.length > 0) {
      CanvasElementDrawer.drawTable(ctx, element, imageCache);
    }

    // 6. 绘制文本段落 (TEXT 或形状内文字)
    if (element.paragraphs && element.paragraphs.length > 0) {
      CanvasElementDrawer.drawParagraphs(ctx, element);
    }

    ctx.restore();
  }

  private static resolveFillStyle(
    ctx: OfficeCanvasContext,
    e: model.Element
  ): string | CanvasGradient | null {
    if (e.fillGradient && e.fillGradient.colors && e.fillGradient.colors.length >= 2) {
      const g = e.fillGradient;
      let x0 = g.points[0];
      let y0 = g.points[1];
      let x1 = g.points[2];
      let y1 = g.points[3];
      if (g.transform && g.transform.length >= 6) {
        const m = g.transform;
        const nx0 = m[0] * x0 + m[2] * y0 + m[4];
        const ny0 = m[1] * x0 + m[3] * y0 + m[5];
        const nx1 = m[0] * x1 + m[2] * y1 + m[4];
        const ny1 = m[1] * x1 + m[3] * y1 + m[5];
        x0 = nx0;
        y0 = ny0;
        x1 = nx1;
        y1 = ny1;
      }
      const grad = ctx.createLinearGradient(x0, y0, x1, y1);
      for (let i = 0; i < g.colors.length; i++) {
        const stopCss = RenderUtils.argbToCss(g.colors[i]) ?? 'rgba(0,0,0,0)';
        grad.addColorStop(Math.min(1, Math.max(0, g.positions[i] ?? 0)), stopCss);
      }
      return grad;
    }
    return RenderUtils.argbToCss(e.fill);
  }

  public static findMerge(
    merges: model.CellRange[] | undefined,
    r: number,
    c: number
  ): model.CellRange | null {
    if (!merges || merges.length === 0) return null;
    for (let i = 0; i < merges.length; i++) {
      const m = merges[i];
      if (r >= m.startRow && r <= m.endRow && c >= m.startColumn && c <= m.endColumn) {
        return m;
      }
    }
    return null;
  }

  /**
   * 解析单元格文字起排的垂直偏移。
   *
   * 三处调用方（drawTable、computeElementHighlightRects、buildElementTextBlocks）必须共用本方法，
   * 保证正文绘制、全文检索高亮与文本选区三套坐标完全一致：
   * - 0（顶部对齐）恒为 5；
   * - 1（垂直居中，缺省行为）剩余空间充足时居中，否则回退到 5；
   * - 2（底部对齐）剩余空间充足时贴近底部并预留 5 的内边距，否则回退到 5。
   * 查询坐标必须传入合并区域的锚点 (r, c)，与文字实际存放的单元格保持一致。
   */
  public static resolveCellVerticalOffset(
    element: model.Element,
    r: number,
    c: number,
    cellH: number,
    cellContentH: number
  ): number {
    // 缺省（无 cellValigns 或坐标越界）一律按 1 垂直居中，兼容既有表格
    let valign = 1;
    const valigns = element.cellValigns;
    if (valigns !== undefined && r >= 0 && r < valigns.length) {
      const rowValigns = valigns[r];
      if (rowValigns !== undefined && c >= 0 && c < rowValigns.length) {
        valign = rowValigns[c];
      }
    }

    // 剩余空间不足时任何对齐方式都退回 5 的基准内边距，避免文字被贴边裁切
    const remaining = cellH - cellContentH;
    if (remaining <= 10 || valign === 0) {
      return 5;
    }
    if (valign === 2) {
      return Math.max(5, remaining - 5);
    }
    return Math.max(5, remaining / 2);
  }

  /**
   * 按单元格四边独立边框绘制线条。
   *
   * borders 顺序为 [top, right, bottom, left]；仅绘制线宽大于 0 且颜色 alpha 不为 0 的边，
   * 因此边框全为 none 的无框表不会再被默认网格灰框覆盖。
   */
  private static drawCellBorderEdges(
    ctx: OfficeCanvasContext,
    borders: model.CellBorder[],
    x1: number,
    y1: number,
    cellW: number,
    cellH: number
  ): void {
    const left = x1;
    const top = y1;
    const right = x1 + cellW;
    const bottom = y1 + cellH;
    const edgeX1: number[] = [left, right, left, left];
    const edgeY1: number[] = [top, top, bottom, top];
    const edgeX2: number[] = [right, right, right, left];
    const edgeY2: number[] = [top, bottom, bottom, bottom];

    const count = Math.min(4, borders.length);
    for (let i = 0; i < count; i++) {
      const border = borders[i];
      if (!border || border.width <= 0) {
        continue;
      }
      const css = RenderUtils.argbToCss(border.color);
      if (!css) {
        continue;
      }
      ctx.strokeStyle = css;
      ctx.lineWidth = border.width;
      ctx.beginPath();
      ctx.moveTo(edgeX1[i], edgeY1[i]);
      ctx.lineTo(edgeX2[i], edgeY2[i]);
      ctx.stroke();
    }
  }

  public static resolveColumnWidths(
    element: model.Element,
    cols: number,
    tableW: number
  ): number[] {
    const raw = element.columnWidths ?? [];
    let totalWeight = 0;
    for (let i = 0; i < raw.length; i++) {
      totalWeight += Math.max(1, raw[i]);
    }
    const result: number[] = [];
    for (let c = 0; c < cols; c++) {
      if (raw.length === cols && totalWeight > 0) {
        if (Math.abs(totalWeight - tableW) < 0.5) {
          result.push(Math.max(1, raw[c]));
        } else {
          result.push((tableW * Math.max(1, raw[c])) / totalWeight);
        }
      } else {
        result.push(tableW / cols);
      }
    }
    return result;
  }

  public static computeTableGeometry(
    ctx: OfficeCanvasContext | null,
    element: model.Element,
    availableWidth?: number
  ): TableGeometry {
    const rows = element.rows ?? [];
    let cols = 0;
    for (let i = 0; i < rows.length; i++) {
      cols = Math.max(cols, rows[i].length);
    }
    const numRows = rows.length;
    if (cols === 0 || numRows === 0) {
      const emptyGeom: TableGeometry = {
        cols: 0,
        colWidths: [],
        colX: [0],
        rowTops: [0]
      };
      return emptyGeom;
    }

    const tableW = element.width && element.width > 0
      ? element.width
      : (availableWidth && availableWidth > 0 ? availableWidth : 500);
    const colWidths = CanvasElementDrawer.resolveColumnWidths(element, cols, tableW);
    const colX: number[] = new Array<number>(cols + 1).fill(0);
    for (let c = 0; c < cols; c++) {
      colX[c + 1] = colX[c] + colWidths[c];
    }

    const rowTops: number[] = new Array<number>(numRows + 1).fill(0);
    let currentY = 0;

    for (let r = 0; r < numRows; r++) {
      rowTops[r] = currentY;
      let rowHeight = 20;
      const row = rows[r];

      for (let c = 0; c < cols; c++) {
        const m = CanvasElementDrawer.findMerge(element.merges, r, c);
        if (m && (m.startRow !== r || m.startColumn !== c)) {
          continue;
        }
        const x1 = colX[c];
        const x2 = m ? colX[Math.min(cols, m.endColumn + 1)] : colX[c + 1];
        const cellW = Math.max(1, x2 - x1);
        const cellParas = c < row.length ? row[c] : [];
        if (cellParas && cellParas.length > 0) {
          const availW = Math.max(1, cellW - 10);
          let cellTextH = 0;
          for (let pIdx = 0; pIdx < cellParas.length; pIdx++) {
            const para = cellParas[pIdx];
            cellTextH += Math.max(0, para.before || 0);
            if (para.image && para.imageWidth && para.imageHeight && para.imageWidth > 0 && para.imageHeight > 0) {
              const fitW = Math.min(availW, para.imageWidth);
              const fitH = para.imageHeight * (fitW / para.imageWidth);
              cellTextH += fitH;
            } else if (ctx) {
              const lines = CanvasElementDrawer.layoutParagraph(ctx, para, availW, true);
              for (let lIdx = 0; lIdx < lines.length; lIdx++) {
                cellTextH += lines[lIdx].height;
              }
            } else {
              let charCount = 0;
              let maxFontSize = 12;
              if (para.runs) {
                for (let rIdx = 0; rIdx < para.runs.length; rIdx++) {
                  charCount += (para.runs[rIdx].text || '').length;
                  maxFontSize = Math.max(maxFontSize, para.runs[rIdx].size || 12);
                }
              }
              const linesEstimate = Math.max(1, Math.ceil((charCount * maxFontSize * 0.6) / availW));
              cellTextH += linesEstimate * CanvasElementDrawer.computeLineHeight(para, maxFontSize);
            }
            cellTextH += Math.max(0, para.after || 0);
          }
          rowHeight = Math.max(rowHeight, cellTextH + 10);
        }
      }
      currentY += rowHeight;
    }
    rowTops[numRows] = currentY;

    const geom: TableGeometry = {
      cols,
      colWidths,
      colX,
      rowTops
    };
    return geom;
  }

  public static measureTableHeight(
    element: model.Element,
    availableWidth?: number,
    ctx?: OfficeCanvasContext | null
  ): number {
    const geom = CanvasElementDrawer.computeTableGeometry(ctx ?? null, element, availableWidth);
    return geom.rowTops[geom.rowTops.length - 1] ?? 0;
  }

  public static drawTable(
    ctx: OfficeCanvasContext,
    element: model.Element,
    imageCache?: Map<string, image.PixelMap>
  ): void {
    const rows = element.rows ?? [];
    let cols = 0;
    for (let i = 0; i < rows.length; i++) {
      cols = Math.max(cols, rows[i].length);
    }
    const numRows = rows.length;
    if (cols === 0 || numRows === 0) return;

    const geom = CanvasElementDrawer.computeTableGeometry(ctx, element);
    const colX = geom.colX;
    const rowTops = geom.rowTops;
    const cellFills = element.cellFills ?? [];
    const strokeCss = element.stroke ? (RenderUtils.argbToCss(element.stroke) || '#b7bec7') : '#b7bec7';
    const strokeWidth = element.strokeWidth > 0 ? element.strokeWidth : 0.6;

    for (let r = 0; r < numRows; r++) {
      const row = rows[r];
      for (let c = 0; c < cols; c++) {
        const m = CanvasElementDrawer.findMerge(element.merges, r, c);
        let x1: number;
        let x2: number;
        let y1: number;
        let y2: number;

        if (m) {
          if (m.startRow !== r || m.startColumn !== c) {
            continue;
          }
          x1 = colX[c];
          x2 = colX[Math.min(cols, m.endColumn + 1)];
          y1 = rowTops[r];
          y2 = rowTops[Math.min(numRows, m.endRow + 1)];
        } else {
          x1 = colX[c];
          x2 = colX[c + 1];
          y1 = rowTops[r];
          y2 = rowTops[r + 1];
        }

        const cellW = Math.max(1, x2 - x1);
        const cellH = Math.max(1, y2 - y1);

        const fillInt = cellFills[r]?.[c] ?? 0;
        const fillCss = RenderUtils.argbToCss(fillInt);
        if (fillCss) {
          ctx.fillStyle = fillCss;
          ctx.fillRect(x1, y1, cellW, cellH);
        }

        // 存在单元格级四边边框时按边独立绘制，否则沿用表格级统一网格框
        let cellBorderEdges: model.CellBorder[] | undefined = undefined;
        const cellBorders = element.cellBorders;
        if (cellBorders !== undefined && cellBorders.length > 0) {
          cellBorderEdges = cellBorders[r]?.[c];
        }
        if (cellBorderEdges !== undefined && cellBorderEdges.length > 0) {
          CanvasElementDrawer.drawCellBorderEdges(ctx, cellBorderEdges, x1, y1, cellW, cellH);
        } else {
          // 表格级统一网格框使用 element 级 stroke，按元素虚线绘制后恢复实线
          ctx.strokeStyle = strokeCss;
          ctx.lineWidth = strokeWidth;
          ctx.setLineDash(CanvasElementDrawer.dashArrayOf(element));
          ctx.strokeRect(x1, y1, cellW, cellH);
          ctx.setLineDash([]);
        }

        const cellParas = c < row.length ? row[c] : [];
        if (cellParas && cellParas.length > 0) {
          ctx.save();
          ctx.beginPath();
          ctx.rect(x1, y1, cellW, cellH);
          ctx.clip();

          const availW = Math.max(1, cellW - 10);
          let cellContentH = 0;
          for (let pIdx = 0; pIdx < cellParas.length; pIdx++) {
            const para = cellParas[pIdx];
            cellContentH += Math.max(0, para.before || 0);
            if (para.image && para.imageWidth && para.imageHeight && para.imageWidth > 0 && para.imageHeight > 0) {
              const fitW = Math.min(availW, para.imageWidth);
              const fitH = para.imageHeight * (fitW / para.imageWidth);
              cellContentH += fitH;
            } else {
              const lines = CanvasElementDrawer.layoutParagraph(ctx, para, availW, true);
              for (let lIdx = 0; lIdx < lines.length; lIdx++) {
                cellContentH += lines[lIdx].height;
              }
            }
            cellContentH += Math.max(0, para.after || 0);
          }

          const vOffset = CanvasElementDrawer.resolveCellVerticalOffset(element, r, c, cellH, cellContentH);
          let paraY = y1 + vOffset;

          for (let pIdx = 0; pIdx < cellParas.length; pIdx++) {
            const para = cellParas[pIdx];
            if (para.image && imageCache) {
              const pixelMap = imageCache.get(para.image);
              if (pixelMap && para.imageWidth && para.imageHeight && para.imageWidth > 0 && para.imageHeight > 0) {
                paraY += Math.max(0, para.before || 0);
                const fitW = Math.min(availW, para.imageWidth);
                const fitH = para.imageHeight * (fitW / para.imageWidth);
                let imgX = x1 + 5;
                if (para.alignment === 1) {
                  imgX += Math.max(0, (availW - fitW) / 2);
                } else if (para.alignment === 2) {
                  imgX += Math.max(0, availW - fitW);
                }
                ctx.drawImage(pixelMap, imgX, paraY, fitW, fitH);
                paraY += fitH + Math.max(0, para.after || 0);
                continue;
              }
            }
            paraY += Math.max(0, para.before || 0);
            const lines = CanvasElementDrawer.layoutParagraph(ctx, para, availW, true);
            const h = CanvasElementDrawer.drawParagraphLines(
              ctx,
              para,
              lines,
              x1 + 5,
              paraY,
              availW
            );
            paraY += h + Math.max(0, para.after || 0);
          }
          ctx.restore();
        }
      }
    }
  }

  public static drawParagraphs(
    ctx: OfficeCanvasContext,
    element: model.Element,
    obstacles?: WrapObstacle[],
    baseY: number = 0,
    originX: number = 0
  ): void {
    const paragraphs = element.paragraphs ?? [];
    if (paragraphs.length === 0) return;
    const padding = Math.max(0, element.padding ?? 4);
    const availableWidth = Math.max(1, element.width - padding * 2);
    const wrap = element.textWrap !== false;

    // 单次测量复用：一次性排版全部段落，避免测量高度和绘制各执行一遍
    const laidOutParagraphs: WrappedLine[][] = [];
    let totalTextHeight = 0;
    for (const para of paragraphs) {
      totalTextHeight += Math.max(0, para.before || 0);
      const lines = CanvasElementDrawer.layoutParagraph(
        ctx,
        para,
        availableWidth,
        wrap,
        obstacles,
        baseY + padding + totalTextHeight,
        originX + padding
      );
      laidOutParagraphs.push(lines);
      for (const line of lines) {
        totalTextHeight += line.height;
      }
      totalTextHeight += Math.max(0, para.after || 0);
    }

    let offsetY = padding;
    const remaining = Math.max(0, element.height - padding * 2 - totalTextHeight);
    if (element.verticalAlignment === 'CENTER') {
      offsetY += remaining / 2;
    } else if (element.verticalAlignment === 'BOTTOM') {
      offsetY += remaining;
    }

    ctx.save();
    if (wrap && element.width > 0 && element.height > 0) {
      ctx.beginPath();
      ctx.rect(0, 0, element.width, element.height);
      ctx.clip();
    }

    for (let i = 0; i < paragraphs.length; i++) {
      const para = paragraphs[i];
      const lines = laidOutParagraphs[i];
      offsetY += Math.max(0, para.before || 0);
      const h = CanvasElementDrawer.drawParagraphLines(ctx, para, lines, padding, offsetY, availableWidth);
      offsetY += h + Math.max(0, para.after || 0);
    }
    ctx.restore();
  }

  public static measureParagraphsHeight(
    ctx: OfficeCanvasContext,
    paragraphs: model.Paragraph[],
    availableWidth: number,
    wrap: boolean,
    obstacles?: WrapObstacle[],
    baseY: number = 0,
    originX: number = 0
  ): number {
    let total = 0;
    for (const para of paragraphs) {
      total += Math.max(0, para.before || 0);
      const lines = CanvasElementDrawer.layoutParagraph(
        ctx,
        para,
        availableWidth,
        wrap,
        obstacles,
        baseY + total,
        originX
      );
      for (const line of lines) {
        total += line.height;
      }
      total += Math.max(0, para.after || 0);
    }
    return total;
  }

  /**
   * 测量带字符间距的文本；按 Unicode 码点逐字测量，避免拆开代理对。
   */
  private static measureSpacedText(ctx: OfficeCanvasContext, text: string, spacing?: number): number {
    if (!spacing || !Number.isFinite(spacing) || text.length <= 1) {
      return ctx.measureText(text).width;
    }
    let width = 0;
    let index = 0;
    let charIndex = 0;
    while (index < text.length) {
      const code = text.charCodeAt(index);
      const step = code >= 0xD800 && code <= 0xDBFF && index + 1 < text.length ? 2 : 1;
      const char = text.substring(index, index + step);
      if (charIndex > 0) width += spacing;
      width += ctx.measureText(char).width;
      index += char.length;
      charIndex++;
    }
    return width;
  }

  /** 无字符间距时保留整段绘制快路径，有间距时按码点逐字绘制。 */
  private static fillSpacedText(
    ctx: OfficeCanvasContext,
    text: string,
    x: number,
    y: number,
    spacing?: number
  ): void {
    if (!spacing || !Number.isFinite(spacing) || text.length <= 1) {
      ctx.fillText(text, x, y);
      return;
    }
    let currentX = x;
    let index = 0;
    let charIndex = 0;
    while (index < text.length) {
      const code = text.charCodeAt(index);
      const step = code >= 0xD800 && code <= 0xDBFF && index + 1 < text.length ? 2 : 1;
      const char = text.substring(index, index + step);
      if (charIndex > 0) currentX += spacing;
      ctx.fillText(char, currentX, y);
      currentX += ctx.measureText(char).width;
      index += char.length;
      charIndex++;
    }
  }

  /** 空格类字符：半角空格、制表符、全角空格 */
  private static isBlankCode(code: number): boolean {
    return code === 0x20 || code === 0x09 || code === 0x3000;
  }

  /** CJK 及全角字符，与 Word 的字间断行/对齐规则保持一致 */
  private static isCjkCode(code: number): boolean {
    return code >= 0x2E80 && code <= 0x9FFF;
  }

  /**
   * 两端对齐（alignment === 3）时，计算一行内每个 UTF-16 单元的绘制起点（相对行左端）。
   * 拉伸只发生在空格后与相邻 CJK 字之间，字形本身不缩放，与 Android 的 INTER_WORD、
   * macOS 的 CTLineCreateJustifiedLine 保持一致；该行无可拉伸间隙时返回 null 表示按左对齐绘制。
   * 返回数组长度为「行内字符数 + 1」，末位是拉伸后的行尾，便于高亮区间复用同一套坐标。
   */
  private static justifiedLineStarts(
    ctx: OfficeCanvasContext | null,
    line: WrappedLine,
    lineAvailWidth: number
  ): number[] | null {
    if (lineAvailWidth - line.width <= 0.5) return null;

    const charWidths: number[] = [];
    const charSpacings: number[] = [];
    const charCodes: number[] = [];
    const charUnits: number[] = [];
    const unitStarts: number[] = [];
    let totalUnits = 0;
    let totalCharsWidth = 0;
    for (const seg of line.segments) {
      const text = seg.text;
      const segLen = text.length;
      if (segLen === 0) continue;
      if (ctx) ctx.font = seg.font;
      // 无画笔时按字符数均分 run 宽度，保证与 layoutParagraph 的折行结果一致
      const avgUnitWidth = seg.width / segLen;
      const runSpacing = seg.spacing !== undefined && Number.isFinite(seg.spacing) ? seg.spacing : 0;
      let i = 0;
      while (i < segLen) {
        const code = text.charCodeAt(i);
        const paired = code >= 0xD800 && code <= 0xDBFF && i + 1 < segLen;
        const step = paired ? 2 : 1;
        let width = avgUnitWidth * step;
        if (ctx) {
          const measured = ctx.measureText(text.substring(i, i + step)).width;
          if (measured > 0) width = measured;
        }
        charWidths.push(width);
        charSpacings.push(i > 0 ? runSpacing : 0);
        totalCharsWidth += (i > 0 ? runSpacing : 0) + width;
        charCodes.push(code);
        charUnits.push(step);
        unitStarts.push(totalUnits);
        totalUnits += step;
        i += step;
      }
    }
    const count = charWidths.length;
    if (count === 0) return null;

    const extra = lineAvailWidth - totalCharsWidth;
    if (extra <= 0.5) return null;

    const gapAfter: boolean[] = [];
    let gapCount = 0;
    for (let k = 0; k < count; k++) {
      let stretchable = false;
      if (k < count - 1) {
        const cur = charCodes[k];
        const next = charCodes[k + 1];
        stretchable = CanvasElementDrawer.isBlankCode(cur) ||
          (CanvasElementDrawer.isCjkCode(cur) && CanvasElementDrawer.isCjkCode(next));
      }
      gapAfter.push(stretchable);
      if (stretchable) gapCount++;
    }
    if (gapCount === 0) return null;

    const gapWidth = extra / gapCount;
    const starts: number[] = [];
    for (let u = 0; u <= totalUnits; u++) {
      starts.push(0);
    }
    let x = 0;
    for (let k = 0; k < count; k++) {
      const u = unitStarts[k];
      starts[u] = x;
      // 代理对的两个 UTF-16 单元共用一个起点，避免被拆开绘制
      if (charUnits[k] === 2) starts[u + 1] = x;
      x += charSpacings[k] + charWidths[k];
      if (gapAfter[k]) x += gapWidth;
    }
    starts[totalUnits] = x;
    return starts;
  }

  /**
   * 按预设字符起点逐字绘制两端对齐行：整段 fillText 无法表达字间拉伸，
   * 故仅在两端对齐时退化为逐字符绘制（表格单元格静态绘制一次，不影响滚动帧率）
   */
  private static drawJustifiedLine(
    ctx: OfficeCanvasContext,
    line: WrappedLine,
    lineX: number,
    baselineY: number,
    starts: number[],
    curY: number
  ): void {
    let unitCursor = 0;
    for (const seg of line.segments) {
      const text = seg.text;
      const segLen = text.length;
      if (segLen === 0) continue;
      if (seg.background && seg.background !== 0) {
        const hlCss = RenderUtils.argbToCss(seg.background);
        if (hlCss) {
          ctx.fillStyle = hlCss;
          ctx.fillRect(lineX + starts[unitCursor], curY, starts[unitCursor + segLen] - starts[unitCursor], line.height);
        }
      }
      ctx.font = seg.font;
      ctx.fillStyle = seg.color;
      let drawY = baselineY;
      if (seg.vertAlign === 'superscript') {
        drawY -= seg.fontSize * 0.45;
      } else if (seg.vertAlign === 'subscript') {
        drawY += seg.fontSize * 0.25;
      }
      let k = 0;
      while (k < segLen) {
        const code = text.charCodeAt(k);
        const paired = code >= 0xD800 && code <= 0xDBFF && k + 1 < segLen;
        const step = paired ? 2 : 1;
        ctx.fillText(text.substring(k, k + step), lineX + starts[unitCursor + k], drawY);
        k += step;
      }
      if (seg.underline) {
        const underlineLeft = lineX + starts[unitCursor];
        const underlineRight = lineX + starts[unitCursor + segLen];
        if (underlineRight > underlineLeft) {
          ctx.strokeStyle = seg.color;
          ctx.lineWidth = Math.max(0.75, seg.fontSize * 0.06);
          ctx.beginPath();
          ctx.moveTo(underlineLeft, drawY + seg.fontSize * 0.12);
          ctx.lineTo(underlineRight, drawY + seg.fontSize * 0.12);
          ctx.stroke();
        }
      }
      if (seg.strike) {
        const strikeLeft = lineX + starts[unitCursor];
        const strikeRight = lineX + starts[unitCursor + segLen];
        if (strikeRight > strikeLeft) {
          ctx.strokeStyle = seg.color;
          ctx.lineWidth = Math.max(0.75, seg.fontSize * 0.06);
          ctx.beginPath();
          ctx.moveTo(strikeLeft, drawY - seg.fontSize * 0.28);
          ctx.lineTo(strikeRight, drawY - seg.fontSize * 0.28);
          ctx.stroke();
        }
      }
      unitCursor += segLen;
    }
  }

  public static drawParagraphLines(
    ctx: OfficeCanvasContext,
    para: model.Paragraph,
    lines: WrappedLine[],
    startX: number,
    startY: number,
    availableWidth: number
  ): number {
    let totalHeight = 0;
    for (let i = 0; i < lines.length; i++) {
      totalHeight += lines[i].height;
    }

    if (totalHeight > 0 && para.background && para.background !== 0) {
      const bgCss = RenderUtils.argbToCss(para.background);
      if (bgCss) {
        ctx.fillStyle = bgCss;
        ctx.fillRect(startX, startY, availableWidth, totalHeight);
      }
    }

    if (totalHeight > 0 && para.borderWidth && para.borderWidth > 0) {
      const bw = para.borderWidth;
      ctx.lineWidth = bw;
      if (para.borderTop && para.borderTop !== 0) {
        ctx.strokeStyle = RenderUtils.argbToCss(para.borderTop) ?? '#000000';
        ctx.beginPath();
        ctx.moveTo(startX, startY + bw / 2);
        ctx.lineTo(startX + availableWidth, startY + bw / 2);
        ctx.stroke();
      }
      if (para.borderBottom && para.borderBottom !== 0) {
        ctx.strokeStyle = RenderUtils.argbToCss(para.borderBottom) ?? '#000000';
        ctx.beginPath();
        ctx.moveTo(startX, startY + totalHeight - bw / 2);
        ctx.lineTo(startX + availableWidth, startY + totalHeight - bw / 2);
        ctx.stroke();
      }
      if (para.borderLeft && para.borderLeft !== 0) {
        ctx.strokeStyle = RenderUtils.argbToCss(para.borderLeft) ?? '#000000';
        ctx.beginPath();
        ctx.moveTo(startX + bw / 2, startY);
        ctx.lineTo(startX + bw / 2, startY + totalHeight);
        ctx.stroke();
      }
      if (para.borderRight && para.borderRight !== 0) {
        ctx.strokeStyle = RenderUtils.argbToCss(para.borderRight) ?? '#000000';
        ctx.beginPath();
        ctx.moveTo(startX + availableWidth - bw / 2, startY);
        ctx.lineTo(startX + availableWidth - bw / 2, startY + totalHeight);
        ctx.stroke();
      }
    }

    ctx.textBaseline = 'alphabetic';
    ctx.textAlign = 'left';

    let curY = startY;
    for (let i = 0; i < lines.length; i++) {
      const line = lines[i];
      const leftIndent = line.leftIndent;
      const lineRightIndent = line.rightIndent;
      const lineAvailWidth = Math.max(1, availableWidth - leftIndent - lineRightIndent);

      let lineX = startX + leftIndent;
      if (para.alignment === 1) {
        lineX += (lineAvailWidth - line.width) / 2;
      } else if (para.alignment === 2) {
        lineX += lineAvailWidth - line.width;
      }

      const baselineY = curY + (line.height + line.maxFontSize * 0.7) / 2;
      // 两端对齐按字间间隙拉伸绘制，段落末行保持左对齐（与 Word 规则一致）
      const justifyStarts = para.alignment === 3 && i < lines.length - 1
        ? CanvasElementDrawer.justifiedLineStarts(ctx, line, lineAvailWidth)
        : null;
      if (justifyStarts) {
        CanvasElementDrawer.drawJustifiedLine(ctx, line, lineX, baselineY, justifyStarts, curY);
        curY += line.height;
        continue;
      }

      let segX = lineX;
      for (const seg of line.segments) {
        if (seg.background && seg.background !== 0) {
          const hlCss = RenderUtils.argbToCss(seg.background);
          if (hlCss) {
            ctx.fillStyle = hlCss;
            ctx.fillRect(segX, curY, seg.width, line.height);
          }
        }
        ctx.font = seg.font;
        ctx.fillStyle = seg.color;
        let drawY = baselineY;
        if (seg.vertAlign === 'superscript') {
          drawY -= seg.fontSize * 0.45;
        } else if (seg.vertAlign === 'subscript') {
          drawY += seg.fontSize * 0.25;
        }
        CanvasElementDrawer.fillSpacedText(ctx, seg.text, segX, drawY, seg.spacing);
        if (seg.underline && seg.width > 0) {
          ctx.strokeStyle = seg.color;
          ctx.lineWidth = Math.max(0.75, seg.fontSize * 0.06);
          ctx.beginPath();
          ctx.moveTo(segX, drawY + seg.fontSize * 0.12);
          ctx.lineTo(segX + seg.width, drawY + seg.fontSize * 0.12);
          ctx.stroke();
        }
        if (seg.strike && seg.width > 0) {
          ctx.strokeStyle = seg.color;
          ctx.lineWidth = Math.max(0.75, seg.fontSize * 0.06);
          ctx.beginPath();
          ctx.moveTo(segX, drawY - seg.fontSize * 0.28);
          ctx.lineTo(segX + seg.width, drawY - seg.fontSize * 0.28);
          ctx.stroke();
        }
        segX += seg.width;
      }
      curY += line.height;
    }
    return curY - startY;
  }

  /**
   * 高性能段落折行：无绕排障碍时带 WeakMap 缓存；存在浮动障碍物时按每行 Y 区间动态计算左/右缩进
   */
  public static layoutParagraph(
    ctx: OfficeCanvasContext,
    para: model.Paragraph,
    maxWidth: number,
    wrap: boolean,
    obstacles?: WrapObstacle[],
    paraY: number = 0,
    originX: number = 0
  ): WrappedLine[] {
    const hasObstacles = wrap && obstacles !== undefined && obstacles.length > 0;
    if (!hasObstacles) {
      const widthKey = Math.round(maxWidth * 10);
      const cachedEntries = CanvasElementDrawer.paragraphCache.get(para);
      if (cachedEntries) {
        for (const entry of cachedEntries) {
          if (entry.widthKey === widthKey && entry.wrap === wrap) {
            return entry.lines;
          }
        }
      }

      const lines = CanvasElementDrawer.layoutParagraphInternal(ctx, para, maxWidth, wrap);

      // 每个段落最多保留最近 2 组排版结果（适应常规与旋转/缩放视图）
      const entries: CachedParagraphEntry[] = cachedEntries ? cachedEntries.slice(-1) : [];
      entries.push({ widthKey, wrap, lines });
      CanvasElementDrawer.paragraphCache.set(para, entries);

      return lines;
    }

    return CanvasElementDrawer.layoutParagraphInternal(ctx, para, maxWidth, wrap, obstacles, paraY, originX);
  }

  /**
   * 高性能段落折行内部实现：整段测量优先，仅在超出宽度时按需切分，使用 vp 字号单位对齐画布坐标系
   */
  private static layoutParagraphInternal(
    ctx: OfficeCanvasContext,
    para: model.Paragraph,
    availableWidth: number,
    wrap: boolean,
    obstacles?: WrapObstacle[],
    paraY: number = 0,
    originX: number = 0
  ): WrappedLine[] {
    const rightIndent = Math.max(0, para.rightIndent || 0);
    const baseIndent = Math.max(0, para.indent || 0);
    const firstIndent = Math.max(0, baseIndent + (para.firstLineIndent || 0));

    const runs: model.Run[] = [];
    if (para.bullet && para.bullet.length > 0) {
      const firstRun = para.runs && para.runs.length > 0 ? para.runs[0] : null;
      runs.push({
        text: para.bullet,
        fontFace: firstRun?.fontFace ?? '',
        size: firstRun?.size ?? 12,
        bold: firstRun?.bold ?? false,
        italic: firstRun?.italic ?? false,
        underline: false,
        color: firstRun?.color ?? 0xff202124,
      });
    }
    if (para.runs) {
      for (const r of para.runs) {
        if (r.text && r.text.length > 0) {
          runs.push(r);
        }
      }
    }
    const defaultSize = para.runs && para.runs.length > 0 ? Math.max(1, para.runs[0].size) : 12;
    const defaultLineH = CanvasElementDrawer.computeLineHeight(para, defaultSize);
    const activeObs: WrapObstacle[] = wrap && obstacles && obstacles.length > 0
      ? obstacles.filter((o: WrapObstacle): boolean => o.bottom > paraY)
      : [];
    const resolveLineIndents = (lineIdx: number, lineTop: number, estLineH: number): [number, number] => {
      let l = lineIdx === 0 ? firstIndent : baseIndent;
      let r = rightIndent;
      if (activeObs.length > 0) {
        const lineBottom = lineTop + estLineH;
        for (const obs of activeObs) {
          if (obs.bottom > lineTop && obs.top < lineBottom) {
            if (obs.side === 'left') {
              l = Math.max(l, Math.max(0, obs.right - originX));
            } else {
              r = Math.max(r, Math.max(0, (originX + availableWidth) - obs.left));
            }
          }
        }
        const minLineW = Math.max(1, Math.min(availableWidth, 24));
        const maxSum = Math.max(0, availableWidth - minLineW);
        if (l + r > maxSum) {
          l = Math.min(l, maxSum);
          r = Math.min(r, Math.max(0, maxSum - l));
        }
      }
      return [l, r];
    };

    if (runs.length === 0) {
      const indents = resolveLineIndents(0, paraY, defaultLineH);
      return [{
        segments: [],
        width: 0,
        height: defaultLineH,
        maxFontSize: defaultSize,
        leftIndent: indents[0],
        rightIndent: indents[1],
      }];
    }

    const rawLines: TextSegment[][] = [[]];
    const lineIndents: [number, number][] = [resolveLineIndents(0, paraY, defaultLineH)];
    let curY = paraY;
    let currentLineWidth = 0;
    const pushNewLine = (): void => {
      const prev = rawLines[rawLines.length - 1];
      let maxFs = defaultSize;
      for (const s of prev) {
        if (s.fontSize > maxFs) maxFs = s.fontSize;
      }
      curY += CanvasElementDrawer.computeLineHeight(para, maxFs);
      rawLines.push([]);
      lineIndents.push(resolveLineIndents(rawLines.length - 1, curY, defaultLineH));
      currentLineWidth = 0;
    };
    const maxLineW = (lineIdx: number): number => {
      if (!wrap) return 1000000;
      const pair = lineIndents[lineIdx];
      return Math.max(1, availableWidth - pair[0] - pair[1]);
    };

    for (const run of runs) {
      let fontSize = Math.max(1, run.size || 12);
      if (run.vertAlign === 'superscript' || run.vertAlign === 'subscript') {
        fontSize = Math.max(1, fontSize * 0.65);
      }
      const fontStyle = run.italic ? 'italic ' : '';
      const fontWeight = RenderUtils.resolveFontBold(run.fontFace, run.bold, run.weight) ? 'bold ' : '';
      // 使用 vp 作为字号单位，并对齐 Android 的 Impact / 思源黑体 Light 字体兼容映射
      const fontFace = RenderUtils.resolveFontFamily(run.fontFace, true);
      const fontStr = `${fontStyle}${fontWeight}${fontSize}vp ${fontFace}`;
      const colorCss = RenderUtils.argbToCss(run.color) ?? '#202124';
      ctx.font = fontStr;

      const subParts = run.text.split('\n');
      for (let p = 0; p < subParts.length; p++) {
        if (p > 0) {
          pushNewLine();
        }
        let remainingText = subParts[p];
        if (remainingText.length === 0) continue;

        while (remainingText.length > 0) {
          const limit = maxLineW(rawLines.length - 1);
          const fullW = CanvasElementDrawer.measureSpacedText(ctx, remainingText, run.spacing);

          // 快路径：如果整段文字直接放得下，0 拆分直接入列！
          if (!wrap || currentLineWidth + fullW <= limit) {
            rawLines[rawLines.length - 1].push({
              text: remainingText,
              font: fontStr,
              fontSize,
              color: colorCss,
              underline: run.underline,
              strike: run.strike,
              vertAlign: run.vertAlign,
              spacing: run.spacing,
              width: fullW,
              background: run.background,
            });
            currentLineWidth += fullW;
            break;
          }

          // 若当前行已有内容且放不下，先换新行再试
          const availInLine = limit - currentLineWidth;
          if (availInLine <= fontSize * 0.5 && currentLineWidth > 0) {
            pushNewLine();
            continue;
          }

          // 二分查找当前行能容纳的最大字符数，避免逐字遍历测量
          let low = 1;
          let high = remainingText.length;
          let bestCount = 1;
          let bestWidth = CanvasElementDrawer.measureSpacedText(ctx, remainingText.substring(0, 1), run.spacing);

          while (low <= high) {
            const mid = (low + high) >>> 1;
            const sub = remainingText.substring(0, mid);
            const w = CanvasElementDrawer.measureSpacedText(ctx, sub, run.spacing);
            if (w <= availInLine) {
              bestCount = mid;
              bestWidth = w;
              low = mid + 1;
            } else {
              high = mid - 1;
            }
          }

          // 代理对保护：避免将高/低代理项劈开导致乱码
          if (bestCount < remainingText.length && remainingText.charCodeAt(bestCount - 1) >= 0xD800 && remainingText.charCodeAt(bestCount - 1) <= 0xDBFF) {
            bestCount = bestCount > 1 ? bestCount - 1 : bestCount + 1;
            bestWidth = CanvasElementDrawer.measureSpacedText(ctx, remainingText.substring(0, bestCount), run.spacing);
          }

          // 英文按词折行保护：若截断处在单词中间且前部有空格，优先在空格处断行
          if (bestCount < remainingText.length && !/\s/.test(remainingText.charAt(bestCount))) {
            const candidate = remainingText.substring(0, bestCount);
            const lastSpace = candidate.lastIndexOf(' ');
            if (lastSpace > 0 && lastSpace >= bestCount * 0.4) {
              bestCount = lastSpace + 1;
              bestWidth = CanvasElementDrawer.measureSpacedText(ctx, remainingText.substring(0, bestCount), run.spacing);
            }
          }

          if (bestCount === 1 && currentLineWidth > 0 && bestWidth > availInLine) {
            pushNewLine();
            continue;
          }

          const fitText = remainingText.substring(0, bestCount);
          rawLines[rawLines.length - 1].push({
            text: fitText,
            font: fontStr,
            fontSize,
            color: colorCss,
            underline: run.underline,
            strike: run.strike,
            vertAlign: run.vertAlign,
            spacing: run.spacing,
            width: bestWidth,
            background: run.background,
          });
          remainingText = remainingText.substring(bestCount);
          if (remainingText.length > 0) {
            pushNewLine();
          } else {
            currentLineWidth += bestWidth;
          }
        }
      }
    }

    return rawLines.map((segs, idx): WrappedLine => {
      let w = 0;
      let maxFs = runs[0].size || 12;
      for (const s of segs) {
        w += s.width;
        if (s.fontSize > maxFs) maxFs = s.fontSize;
      }
      const pair = lineIndents[idx] ?? [firstIndent, rightIndent];
      return {
        segments: segs,
        width: w,
        height: CanvasElementDrawer.computeLineHeight(para, maxFs),
        maxFontSize: maxFs,
        leftIndent: pair[0],
        rightIndent: pair[1],
      };
    });
  }

  private static computeLineHeight(para: model.Paragraph, maxFontSize: number): number {
    const natural = maxFontSize * 1.2;
    if (para.lineSpacingRule === 'EXACT') {
      return Math.max(1, para.lineSpacing || natural);
    }
    if (para.lineSpacingRule === 'AT_LEAST') {
      return Math.max(natural, para.lineSpacing || natural);
    }
    const factor = para.lineSpacing && para.lineSpacing > 0 ? para.lineSpacing : 1;
    return Math.max(1, natural * factor);
  }

  // MARK: - 全文检索高亮位置计算

  public static computeParagraphHighlightRects(
    ctx: OfficeCanvasContext | null,
    para: model.Paragraph,
    startChar: number,
    endChar: number,
    startX: number,
    startY: number,
    availableWidth: number,
    wrap: boolean = true,
    obstacles?: WrapObstacle[],
    paraY?: number,
    originX?: number
  ): OfficeRect[] {
    if (startChar >= endChar) return [];
    let lines: WrappedLine[];
    if (ctx) {
      lines = CanvasElementDrawer.layoutParagraph(
        ctx, para, availableWidth, wrap, obstacles, paraY ?? startY, originX ?? startX
      );
    } else {
      const cached = CanvasElementDrawer.paragraphCache.get(para);
      if (cached && cached.length > 0) {
        lines = cached[0].lines;
      } else {
        return [{
          x: startX,
          y: startY,
          width: Math.max(10, (endChar - startChar) * 12),
          height: 16
        }];
      }
    }

    const rects: OfficeRect[] = [];
    let curY = startY;
    let globalCharOffset = 0;

    for (let i = 0; i < lines.length; i++) {
      const line = lines[i];
      const leftIndent = line.leftIndent;
      const lineRightIndent = line.rightIndent;
      const lineAvailWidth = Math.max(1, availableWidth - leftIndent - lineRightIndent);

      let lineX = startX + leftIndent;
      if (para.alignment === 1) {
        lineX += (lineAvailWidth - line.width) / 2;
      } else if (para.alignment === 2) {
        lineX += lineAvailWidth - line.width;
      }

      let segX = lineX;
      let lineHighlightMinX = -1;
      let lineHighlightMaxX = -1;
      const lineCharBase = globalCharOffset;
      // 与 drawParagraphLines 使用同一套两端对齐坐标，保证高亮框贴合拉伸后的字形
      const justifyStarts = para.alignment === 3 && i < lines.length - 1
        ? CanvasElementDrawer.justifiedLineStarts(ctx, line, lineAvailWidth)
        : null;

      for (const seg of line.segments) {
        const segLen = seg.text.length;
        const segStart = globalCharOffset;
        const segEnd = globalCharOffset + segLen;

        if (endChar > segStart && startChar < segEnd) {
          const matchStartInSeg = Math.max(0, startChar - segStart);
          const matchEndInSeg = Math.min(segLen, endChar - segStart);

          let hLeft = 0;
          let hRight = 0;
          if (justifyStarts) {
            const lastIdx = justifyStarts.length - 1;
            const leftIdx = Math.min(lastIdx, Math.max(0, (segStart - lineCharBase) + matchStartInSeg));
            const rightIdx = Math.min(lastIdx, Math.max(0, (segStart - lineCharBase) + matchEndInSeg));
            hLeft = lineX + justifyStarts[leftIdx];
            hRight = lineX + justifyStarts[rightIdx];
          } else {
            let x1 = 0;
            let x2 = seg.width;
            if (ctx && segLen > 0) {
              ctx.font = seg.font;
              if (matchStartInSeg > 0) {
                x1 = CanvasElementDrawer.measureSpacedText(ctx, seg.text.substring(0, matchStartInSeg), seg.spacing);
              }
              if (matchEndInSeg < segLen) {
                x2 = CanvasElementDrawer.measureSpacedText(ctx, seg.text.substring(0, matchEndInSeg), seg.spacing);
              }
            } else if (segLen > 0) {
              x1 = (matchStartInSeg / segLen) * seg.width;
              x2 = (matchEndInSeg / segLen) * seg.width;
            }
            hLeft = segX + x1;
            hRight = segX + x2;
          }

          if (lineHighlightMinX < 0 || hLeft < lineHighlightMinX) {
            lineHighlightMinX = hLeft;
          }
          if (lineHighlightMaxX < 0 || hRight > lineHighlightMaxX) {
            lineHighlightMaxX = hRight;
          }
        }

        segX += seg.width;
        globalCharOffset += segLen;
      }

      if (lineHighlightMinX >= 0 && lineHighlightMaxX > lineHighlightMinX) {
        rects.push({
          x: lineHighlightMinX,
          y: curY,
          width: Math.max(2, lineHighlightMaxX - lineHighlightMinX),
          height: line.height
        });
      }

      curY += line.height;
    }

    return rects;
  }

  public static computeElementHighlightRects(
    ctx: OfficeCanvasContext | null,
    element: model.Element,
    match: model.SearchMatch
  ): OfficeRect[] {
    const rawRects: OfficeRect[] = [];

    if (element.type === 'TABLE' && element.rows && element.rows.length > 0) {
      const rows = element.rows;
      let cols = 0;
      for (let i = 0; i < rows.length; i++) {
        cols = Math.max(cols, rows[i].length);
      }
      const numRows = rows.length;
      if (cols === 0 || numRows === 0) return [];

      const targetR = match.row !== undefined && match.row >= 0 ? match.row : 0;
      const targetC = match.column !== undefined && match.column >= 0 ? match.column : 0;
      if (targetR >= numRows || targetC >= cols) return [];

      const geom = CanvasElementDrawer.computeTableGeometry(ctx, element);
      const colX = geom.colX;
      const rowTops = geom.rowTops;

      const m = CanvasElementDrawer.findMerge(element.merges, targetR, targetC);
      if (m && (m.startRow !== targetR || m.startColumn !== targetC)) {
        return [];
      }
      const anchorR = m ? m.startRow : targetR;
      const anchorC = m ? m.startColumn : targetC;
      const x1 = colX[anchorC];
      const x2 = m ? colX[Math.min(cols, m.endColumn + 1)] : colX[anchorC + 1];
      const availW = Math.max(1, x2 - x1 - 10);
      const cellY = rowTops[anchorR];
      const cellH = Math.max(1, (m ? rowTops[Math.min(numRows, m.endRow + 1)] : rowTops[anchorR + 1]) - cellY);

      // 文字始终存放在合并区域的起始单元格，坐标一律以 anchor 为准
      const cellParas = (anchorR < rows.length && anchorC < rows[anchorR].length)
        ? rows[anchorR][anchorC]
        : [];
      if (cellParas && match.paragraphIndex >= 0 && match.paragraphIndex < cellParas.length) {
        let cellContentH = 0;
        for (let pIdx = 0; pIdx < cellParas.length; pIdx++) {
          const para = cellParas[pIdx];
          cellContentH += Math.max(0, para.before || 0);
          if (para.image && para.imageWidth && para.imageHeight && para.imageWidth > 0 && para.imageHeight > 0) {
            const fitW = Math.min(availW, para.imageWidth);
            const fitH = para.imageHeight * (fitW / para.imageWidth);
            cellContentH += fitH;
          } else if (ctx) {
            const lines = CanvasElementDrawer.layoutParagraph(ctx, para, availW, true);
            for (let lIdx = 0; lIdx < lines.length; lIdx++) {
              cellContentH += lines[lIdx].height;
            }
          } else {
            cellContentH += 16;
          }
          cellContentH += Math.max(0, para.after || 0);
        }
        const vOffset = CanvasElementDrawer.resolveCellVerticalOffset(element, anchorR, anchorC, cellH, cellContentH);
        let paraY = cellY + vOffset;
        for (let pIdx = 0; pIdx < cellParas.length; pIdx++) {
          const para = cellParas[pIdx];
          paraY += Math.max(0, para.before || 0);
          if (pIdx === match.paragraphIndex) {
            const pRects = CanvasElementDrawer.computeParagraphHighlightRects(
              ctx,
              para,
              match.startChar,
              match.endChar,
              x1 + 5,
              paraY,
              availW,
              true
            );
            rawRects.push(...pRects);
            break;
          }
          if (ctx) {
            const lines = CanvasElementDrawer.layoutParagraph(ctx, para, availW, true);
            for (let lIdx = 0; lIdx < lines.length; lIdx++) {
              paraY += lines[lIdx].height;
            }
          } else {
            paraY += 16;
          }
          paraY += Math.max(0, para.after || 0);
        }
      }
    } else if (element.paragraphs && element.paragraphs.length > 0) {
      if (match.paragraphIndex >= 0 && match.paragraphIndex < element.paragraphs.length) {
        const padding = Math.max(0, element.padding ?? 4);
        const availableWidth = Math.max(1, element.width - padding * 2);
        const wrap = element.textWrap !== false;

        let totalTextHeight = 0;
        const paraHeights: number[] = [];
        for (const para of element.paragraphs) {
          let h = Math.max(0, para.before || 0);
          if (ctx) {
            const lines = CanvasElementDrawer.layoutParagraph(ctx, para, availableWidth, wrap);
            for (const l of lines) {
              h += l.height;
            }
          } else {
            h += 16;
          }
          h += Math.max(0, para.after || 0);
          paraHeights.push(h);
          totalTextHeight += h;
        }

        let offsetY = padding;
        const remaining = Math.max(0, element.height - padding * 2 - totalTextHeight);
        if (element.verticalAlignment === 'CENTER') {
          offsetY += remaining / 2;
        } else if (element.verticalAlignment === 'BOTTOM') {
          offsetY += remaining;
        }

        for (let i = 0; i < element.paragraphs.length; i++) {
          const para = element.paragraphs[i];
          offsetY += Math.max(0, para.before || 0);
          if (i === match.paragraphIndex) {
            const pRects = CanvasElementDrawer.computeParagraphHighlightRects(
              ctx,
              para,
              match.startChar,
              match.endChar,
              padding,
              offsetY,
              availableWidth,
              wrap
            );
            rawRects.push(...pRects);
            break;
          }
          offsetY += (paraHeights[i] - Math.max(0, para.before || 0));
        }
      }
    }

    if (element.transform && element.transform.length >= 6) {
      return rawRects.map((r: OfficeRect): OfficeRect => CanvasElementDrawer.applyAffineTransform(r, element.transform));
    } else if (element.x !== 0 || element.y !== 0) {
      return rawRects.map((r: OfficeRect): OfficeRect => {
        const shifted: OfficeRect = {
          x: r.x + element.x,
          y: r.y + element.y,
          width: r.width,
          height: r.height
        };
        return shifted;
      });
    }
    return rawRects;
  }

  public static applyAffineTransform(
    rect: OfficeRect,
    m: [number, number, number, number, number, number]
  ): OfficeRect {
    const x1 = rect.x;
    const y1 = rect.y;
    const x2 = rect.x + rect.width;
    const y2 = rect.y + rect.height;

    const p1x = m[0] * x1 + m[2] * y1 + m[4];
    const p1y = m[1] * x1 + m[3] * y1 + m[5];

    const p2x = m[0] * x2 + m[2] * y1 + m[4];
    const p2y = m[1] * x2 + m[3] * y1 + m[5];

    const p3x = m[0] * x1 + m[2] * y2 + m[4];
    const p3y = m[1] * x1 + m[3] * y2 + m[5];

    const p4x = m[0] * x2 + m[2] * y2 + m[4];
    const p4y = m[1] * x2 + m[3] * y2 + m[5];

    const minX = Math.min(p1x, p2x, p3x, p4x);
    const maxX = Math.max(p1x, p2x, p3x, p4x);
    const minY = Math.min(p1y, p2y, p3y, p4y);
    const maxY = Math.max(p1y, p2y, p3y, p4y);

    return {
      x: minX,
      y: minY,
      width: Math.max(1, maxX - minX),
      height: Math.max(1, maxY - minY)
    };
  }

  // MARK: - 选区文本度量与文本块构建

  /** 段落纯文本：与 layoutParagraphInternal 的 run 拼接顺序一致（bullet 优先，跳过空 run） */
  public static paragraphPlainText(para: model.Paragraph): string {
    let text = '';
    if (para.bullet && para.bullet.length > 0) {
      text += para.bullet;
    }
    if (para.runs) {
      for (const run of para.runs) {
        if (run.text && run.text.length > 0) {
          text += run.text;
        }
      }
    }
    return text;
  }

  /** 段落是否含可选文本（runs 与 bullet 均为空视为空段落） */
  private static isParagraphBlank(para: model.Paragraph): boolean {
    return CanvasElementDrawer.paragraphPlainText(para).length === 0;
  }

  /**
   * 构建段落数组的行度量与拼接纯文本。
   *
   * 坐标规则与 drawParagraphs / drawParagraphLines 完全一致：
   * 段落 before/after 累加、元素 verticalAlignment 决定整体纵向偏移、
   * 行的左/右缩进与居中/右对齐/两端对齐在此结算，且折行结果直接命中
   * `CanvasElementDrawer.paragraphCache` 中与绘制同一份缓存，避免重复测量。
   *
   * 空段落（runs 与 bullet 均为空）只保留行高参与纵向排版，不写入占位字符；
   * 段落之间统一以 "\n" 分隔。段内 `<w:br/>` 产生的显式换行会拆成多行，
   * 其 "\n" 字符偏移由 `advancePlainCursor` 正确跳过，保证 charStart/charEnd 精确。
   */
  public static buildParagraphsBlockLines(
    ctx: OfficeCanvasContext,
    paragraphs: model.Paragraph[],
    padding: number,
    availableWidth: number,
    blockHeight: number,
    verticalAlignment: model.VerticalAlignment,
    wrap: boolean,
    obstacles?: WrapObstacle[],
    baseY: number = 0,
    originX: number = 0
  ): CanvasParagraphsLayout {
    const textParts: string[] = [];
    const lines: CanvasTextLineMetrics[] = [];
    let totalTextHeight = 0;
    // 已写入 fullText 的字符总数与段落数，用于精确推进 paraBaseOffset
    let joinedChars = 0;
    let joinedParts = 0;

    for (let pIdx = 0; pIdx < paragraphs.length; pIdx++) {
      const para = paragraphs[pIdx];
      // 与 drawParagraphs 完全一致：先累计 before，再以「已用高度」作为折行基准 Y
      totalTextHeight += Math.max(0, para.before || 0);
      const wrapped = CanvasElementDrawer.layoutParagraph(
        ctx,
        para,
        availableWidth,
        wrap,
        obstacles,
        baseY + padding + totalTextHeight,
        originX + padding
      );
      const plain = CanvasElementDrawer.paragraphPlainText(para);
      const hasText = plain.length > 0;
      // 该段落在 fullText 中的基准偏移：前序段落长度之和 + 段落分隔符个数
      const paraBaseOffset = joinedChars + joinedParts;
      let lineTop = padding + totalTextHeight;
      let plainCursor = 0;

      for (let lIdx = 0; lIdx < wrapped.length; lIdx++) {
        const line = wrapped[lIdx];
        let lineLen = 0;
        for (const seg of line.segments) {
          lineLen += seg.text.length;
        }

        if (hasText) {
          const lineAvailWidth = Math.max(1, availableWidth - line.leftIndent - line.rightIndent);
          let lineX = padding + line.leftIndent;
          if (para.alignment === 1) {
            lineX += (lineAvailWidth - line.width) / 2;
          } else if (para.alignment === 2) {
            lineX += lineAvailWidth - line.width;
          }
          // 与 drawParagraphLines / computeParagraphHighlightRects 一致：段落末行不参与两端对齐拉伸
          const justifyStarts = para.alignment === 3 && lIdx < wrapped.length - 1
            ? CanvasElementDrawer.justifiedLineStarts(ctx, line, lineAvailWidth)
            : null;

          // 跳过段内显式换行符，避免把 "\n" 计入可命中字符
          plainCursor = CanvasElementDrawer.advancePlainCursor(plain, plainCursor);
          const charStart = paraBaseOffset + plainCursor;
          const charEnd = charStart + lineLen;
          const lineWidth = justifyStarts !== null ? lineAvailWidth : Math.max(1, line.width);
          lines.push(new CanvasTextLineMetrics(
            ctx,
            lineX,
            lineTop,
            lineX + lineWidth,
            lineTop + line.height,
            lineX,
            charStart,
            charEnd,
            paraBaseOffset,
            line.segments,
            justifyStarts
          ));
          plainCursor += lineLen;
        }
        lineTop += line.height;
        totalTextHeight += line.height;
      }

      totalTextHeight += Math.max(0, para.after || 0);
      if (hasText) {
        textParts.push(plain);
        joinedChars += plain.length;
        joinedParts++;
      } else {
        // 空段落不计入 fullText，也不产生段落分隔符
        // 但需与后续段落的偏移保持一致，故此处不做任何累计
      }
    }

    // verticalAlignment 只影响行在块内的纵向位置，remaining 计算与 drawParagraphs 完全一致
    let alignmentOffset = 0;
    const remaining = Math.max(0, blockHeight - padding * 2 - totalTextHeight);
    if (verticalAlignment === 'CENTER') {
      alignmentOffset = remaining / 2;
    } else if (verticalAlignment === 'BOTTOM') {
      alignmentOffset = remaining;
    }
    const resultLines: CanvasTextLineMetrics[] = [];
    for (const line of lines) {
      resultLines.push(alignmentOffset !== 0 ? line.shiftedBy(alignmentOffset) : line);
    }

    const result: CanvasParagraphsLayout = {
      fullText: textParts.join('\n'),
      lines: resultLines
    };
    return result;
  }

  /** 跳过 plain 中从 cursor 起连续的换行符（段内 `<w:br/>` 产生的显式换行） */
  private static advancePlainCursor(plain: string, cursor: number): number {
    let index = cursor;
    while (index < plain.length) {
      const ch = plain.charAt(index);
      if (ch === '\n' || ch === '\r') {
        index++;
      } else {
        break;
      }
    }
    return index;
  }

  /** 计算单元格内文字内容高度，与 drawTable / computeTableGeometry 的 cellContentH 完全一致 */
  private static measureCellContentHeight(
    ctx: OfficeCanvasContext | null,
    cellParas: model.Paragraph[],
    availWidth: number
  ): number {
    let contentHeight = 0;
    for (let pIdx = 0; pIdx < cellParas.length; pIdx++) {
      const para = cellParas[pIdx];
      contentHeight += Math.max(0, para.before || 0);
      if (para.image && para.imageWidth && para.imageHeight && para.imageWidth > 0 && para.imageHeight > 0) {
        const fitW = Math.min(availWidth, para.imageWidth);
        const fitH = para.imageHeight * (fitW / para.imageWidth);
        contentHeight += fitH;
      } else if (ctx) {
        const lines = CanvasElementDrawer.layoutParagraph(ctx, para, availWidth, true);
        for (let lIdx = 0; lIdx < lines.length; lIdx++) {
          contentHeight += lines[lIdx].height;
        }
      } else {
        contentHeight += 16;
      }
      contentHeight += Math.max(0, para.after || 0);
    }
    return contentHeight;
  }

  /**
   * 为单个元素构建 TextBlockLayout 列表。
   *
   * - TABLE 且含 rows：列宽、行高与垂直居中 vOffset 与 computeTableGeometry / drawTable 保持 100% 一致；
   *   合并单元格只在锚点单元格建块（与 drawTable 的文字绘制位置对齐）；
   *   每个含文本的单元格独立成块，按行优先顺序分配 blockIndex。
   * - 含 paragraphs：生成单个 TextBlockLayout，行度量与 drawParagraphs 同一套坐标规则。
   */
  public static buildElementTextBlocks(
    ctx: OfficeCanvasContext,
    element: model.Element,
    baseBlockIndex: number,
    pageIndex: number,
    obstacles?: WrapObstacle[],
    baseY: number = 0,
    originX: number = 0,
    pageOffsetY: number = 0
  ): TextBlockLayout[] {
    const result: TextBlockLayout[] = [];
    const rows = element.rows ?? [];
    const hasTable = element.type === 'TABLE' && rows.length > 0;

    // 元素局部 -> 文档全局的仿射变换；无 transform 时退化为元素原点平移
    const elementTransform: number[] = [];
    if (element.transform && element.transform.length >= 6) {
      for (let i = 0; i < 6; i++) {
        elementTransform.push(element.transform[i]);
      }
    } else {
      elementTransform.push(1, 0, 0, 1, element.x, element.y);
    }
    if (pageOffsetY !== 0) {
      elementTransform[5] += pageOffsetY;
    }

    if (hasTable) {
      const geom = CanvasElementDrawer.computeTableGeometry(ctx, element);
      const cols = geom.cols;
      const numRows = rows.length;
      if (cols === 0 || numRows === 0) {
        return result;
      }
      const colX = geom.colX;
      const rowTops = geom.rowTops;
      let blockIndex = baseBlockIndex;

      for (let r = 0; r < numRows; r++) {
        const row = rows[r];
        for (let c = 0; c < cols; c++) {
          const merge = CanvasElementDrawer.findMerge(element.merges, r, c);
          // 合并区域内的非锚点单元格跳过，与 drawTable 的 continue 分支完全一致
          if (merge && (merge.startRow !== r || merge.startColumn !== c)) {
            continue;
          }
          const cellParas = c < row.length ? row[c] : [];
          if (!cellParas || cellParas.length === 0) {
            continue;
          }
          let hasText = false;
          for (const para of cellParas) {
            if (!CanvasElementDrawer.isParagraphBlank(para)) {
              hasText = true;
              break;
            }
          }
          if (!hasText) {
            continue;
          }

          const x1 = colX[c];
          const x2 = merge ? colX[Math.min(cols, merge.endColumn + 1)] : colX[c + 1];
          const y1 = rowTops[r];
          const y2 = merge ? rowTops[Math.min(numRows, merge.endRow + 1)] : rowTops[r + 1];
          const cellW = Math.max(1, x2 - x1);
          const cellH = Math.max(1, y2 - y1);
          // drawTable 与 computeElementHighlightRects 使用的单元格可用宽度均为 cellW - 10
          const availW = Math.max(1, cellW - 10);
          const cellContentH = CanvasElementDrawer.measureCellContentHeight(ctx, cellParas, availW);
          // 合并单元格只在锚点建块，垂直对齐查询同样以锚点 (r, c) 为准
          const vOffset = CanvasElementDrawer.resolveCellVerticalOffset(element, r, c, cellH, cellContentH);
          // 单元格文字在元素局部坐标系中的起排原点，与 drawTable 的 (x1 + 5, y1 + vOffset) 一致
          const cellOriginX = x1 + 5;
          const cellOriginY = y1 + vOffset;

          const layout = CanvasElementDrawer.buildParagraphsBlockLines(
            ctx, cellParas, 0, availW, 0, 'TOP', true
          );
          if (layout.fullText.length === 0) {
            continue;
          }

          const cellLines: TextLineMetrics[] = [];
          for (const line of layout.lines) {
            cellLines.push(line.translatedBy(cellOriginX, cellOriginY));
          }
          let cellBottom = cellOriginY;
          for (const line of cellLines) {
            if (line.bottom > cellBottom) {
              cellBottom = line.bottom;
            }
          }
          const cellRect: TextRect = {
            left: cellOriginX,
            top: cellOriginY,
            right: cellOriginX + availW,
            bottom: Math.max(cellOriginY + 1, cellBottom)
          };
          const block = new TextBlockLayout(
            blockIndex,
            pageIndex,
            CanvasElementDrawer.transformRectByMatrix(elementTransform, cellRect),
            elementTransform.slice(0, 6),
            layout.fullText,
            cellLines
          );
          result.push(block);
          blockIndex++;
        }
      }
      return result;
    }

    const paragraphs = element.paragraphs ?? [];
    if (paragraphs.length === 0) {
      return result;
    }
    let hasAnyText = false;
    for (const para of paragraphs) {
      if (!CanvasElementDrawer.isParagraphBlank(para)) {
        hasAnyText = true;
        break;
      }
    }
    if (!hasAnyText) {
      return result;
    }

    const padding = Math.max(0, element.padding ?? 4);
    const availableWidth = Math.max(1, element.width - padding * 2);
    const wrap = element.textWrap !== false;
    // baseY / originX 由调用方按所在容器（绕排组、幻灯片页等）传入；
    // 返回的行度量以容器局部坐标为基准，与 drawParagraphLines 的实际绘制位置一致。
    const layout = CanvasElementDrawer.buildParagraphsBlockLines(
      ctx,
      paragraphs,
      padding,
      availableWidth,
      element.height,
      element.verticalAlignment,
      wrap,
      obstacles,
      baseY,
      originX
    );
    if (layout.fullText.length === 0) {
      return result;
    }

    const blockLines: TextLineMetrics[] = [];
    for (const line of layout.lines) {
      blockLines.push(line.translatedBy(originX, baseY));
    }
    const blockRect: TextRect = {
      left: originX,
      top: baseY,
      right: originX + Math.max(1, element.width),
      bottom: baseY + Math.max(1, element.height)
    };
    const block = new TextBlockLayout(
      baseBlockIndex,
      pageIndex,
      CanvasElementDrawer.transformRectByMatrix(elementTransform, blockRect),
      elementTransform.slice(0, 6),
      layout.fullText,
      blockLines
    );
    result.push(block);
    return result;
  }

  /** 用 6 元仿射矩阵变换矩形并取轴对齐包围框 */
  public static transformRectByMatrix(m: number[], rect: TextRect): TextRect {
    if (m.length < 6) {
      return rect;
    }
    const xs: number[] = [
      m[0] * rect.left + m[2] * rect.top + m[4],
      m[0] * rect.right + m[2] * rect.top + m[4],
      m[0] * rect.left + m[2] * rect.bottom + m[4],
      m[0] * rect.right + m[2] * rect.bottom + m[4]
    ];
    const ys: number[] = [
      m[1] * rect.left + m[3] * rect.top + m[5],
      m[1] * rect.right + m[3] * rect.top + m[5],
      m[1] * rect.left + m[3] * rect.bottom + m[5],
      m[1] * rect.right + m[3] * rect.bottom + m[5]
    ];
    let minX = xs[0];
    let maxX = xs[0];
    let minY = ys[0];
    let maxY = ys[0];
    for (let i = 1; i < xs.length; i++) {
      if (xs[i] < minX) {
        minX = xs[i];
      }
      if (xs[i] > maxX) {
        maxX = xs[i];
      }
      if (ys[i] < minY) {
        minY = ys[i];
      }
      if (ys[i] > maxY) {
        maxY = ys[i];
      }
    }
    const bounds: TextRect = { left: minX, top: minY, right: maxX, bottom: maxY };
    return bounds;
  }

  /**
   * 按元素/表格单元格提取纯文本（O(字符数)，不触发 Canvas measureText）。
   * 供长 DOCX 与未访问 PPTX 幻灯片构建轻量占位索引时快速获得全文。
   * 返回语义：普通元素最多 1 项；表格按行优先为每个非空文本单元格返回一项（空串不返回）。
   */
  public static extractElementFullText(element: model.Element): string[] {
    const result: string[] = [];
    const rows = element.rows ?? [];
    if (element.type === 'TABLE' && rows.length > 0) {
      let cols = 0;
      for (let i = 0; i < rows.length; i++) {
        cols = Math.max(cols, rows[i].length);
      }
      for (let r = 0; r < rows.length; r++) {
        const row = rows[r];
        for (let c = 0; c < cols; c++) {
          const merge = CanvasElementDrawer.findMerge(element.merges, r, c);
          if (merge && (merge.startRow !== r || merge.startColumn !== c)) {
            continue;
          }
          const cellParas = c < row.length ? row[c] : [];
          if (!cellParas || cellParas.length === 0) {
            continue;
          }
          const parts: string[] = [];
          for (const para of cellParas) {
            const plain = CanvasElementDrawer.paragraphPlainText(para);
            if (plain.length > 0) {
              parts.push(plain);
            }
          }
          if (parts.length > 0) {
            result.push(parts.join('\n'));
          }
        }
      }
      return result;
    }

    const paragraphs = element.paragraphs ?? [];
    if (paragraphs.length === 0) {
      return result;
    }
    const parts: string[] = [];
    for (const para of paragraphs) {
      const plain = CanvasElementDrawer.paragraphPlainText(para);
      if (plain.length > 0) {
        parts.push(plain);
      }
    }
    if (parts.length > 0) {
      result.push(parts.join('\n'));
    }
    return result;
  }

  /** 绘制选区高亮矩形（rgba(26, 115, 232, 0.32)，与设计稿一致） */
  public static drawSelectionHighlights(ctx: OfficeCanvasContext, rects: TextRect[]): void {
    if (rects.length === 0) {
      return;
    }
    ctx.save();
    ctx.fillStyle = 'rgba(26, 115, 232, 0.32)';
    for (const rect of rects) {
      const width = rect.right - rect.left;
      const height = rect.bottom - rect.top;
      if (width > 0 && height > 0) {
        ctx.fillRect(rect.left, rect.top, width, height);
      }
    }
    ctx.restore();
  }
}
