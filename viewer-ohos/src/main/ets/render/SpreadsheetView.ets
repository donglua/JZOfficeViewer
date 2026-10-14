import * as model from '../core/OfficeModel';
import { RenderUtils } from './RenderUtils';

const HEADER_WIDTH = 42;
const HEADER_HEIGHT = 22;
const GRID_COLOR = '#dce1e5';
const HEADER_BG = '#f3f5f7';
const HEADER_TEXT = '#52606d';

/**
 * XLSX 电子表格原生渲染组件：支持多工作表 Sheet 切换、手势缩放和平移，以及二维 Canvas 视口裁剪
 */
@Component
export struct SpreadsheetView {
  @Watch('onDocumentUpdated') @Prop document: model.OfficeDocument;
  @State currentSheetIndex: number = 0;
  @State offsetX: number = 0;
  @State offsetY: number = 0;
  @State scaleVal: number = 1.0;

  private settings: RenderingContextSettings = new RenderingContextSettings(true);
  private context2D: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings);
  private canvasWidth: number = 0;
  private canvasHeight: number = 0;

  private panStartX: number = 0;
  private panStartY: number = 0;
  private pinchStartScale: number = 1.0;

  onDocumentUpdated(): void {
    this.currentSheetIndex = 0;
    this.offsetX = 0;
    this.offsetY = 0;
    this.scaleVal = 1.0;
    this.redraw();
  }

  private get currentSheet(): model.Sheet | undefined {
    if (!this.document || !this.document.sheets || this.document.sheets.length === 0) {
      return undefined;
    }
    const idx = Math.min(Math.max(0, this.currentSheetIndex), this.document.sheets.length - 1);
    return this.document.sheets[idx];
  }

  private redraw(): void {
    const sheet = this.currentSheet;
    const ctx = this.context2D;
    if (this.canvasWidth <= 0 && ctx.width > 0) {
      this.canvasWidth = ctx.width;
    }
    if (this.canvasHeight <= 0 && ctx.height > 0) {
      this.canvasHeight = ctx.height;
    }
    if (!sheet || this.canvasWidth <= 0 || this.canvasHeight <= 0) return;

    ctx.clearRect(0, 0, this.canvasWidth, this.canvasHeight);
    ctx.fillStyle = '#e9ecef';
    ctx.fillRect(0, 0, this.canvasWidth, this.canvasHeight);

    const s = this.scaleVal;
    const colOffsets: number[] = [0];
    for (let c = 0; c < sheet.columnWidths.length; c++) {
      colOffsets.push(colOffsets[c] + sheet.columnWidths[c] * s);
    }
    const rowOffsets: number[] = [0];
    for (let r = 0; r < sheet.rowHeights.length; r++) {
      rowOffsets.push(rowOffsets[r] + sheet.rowHeights[r] * s);
    }

    const totalGridWidth = colOffsets[colOffsets.length - 1] ?? 0;
    const totalGridHeight = rowOffsets[rowOffsets.length - 1] ?? 0;

    // 限制滚动边界，避免拖出左上角空白
    const minOx = Math.min(0, this.canvasWidth - HEADER_WIDTH - totalGridWidth);
    const minOy = Math.min(0, this.canvasHeight - HEADER_HEIGHT - totalGridHeight);
    const ox = Math.min(0, Math.max(minOx, this.offsetX));
    const oy = Math.min(0, Math.max(minOy, this.offsetY));

    const bodyRight = Math.min(this.canvasWidth, HEADER_WIDTH + ox + totalGridWidth);
    const bodyBottom = Math.min(this.canvasHeight, HEADER_HEIGHT + oy + totalGridHeight);

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

      // 1.2 建立合并单元格锚点映射，避免合并区域内子单元格重复绘制
      const mergedSkip = new Set<string>();
      const anchorCellMap = new Map<string, model.Cell>();
      for (const cell of sheet.cells) {
        anchorCellMap.set(`${cell.row}:${cell.column}`, cell);
      }
      if (sheet.merges) {
        for (const m of sheet.merges) {
          for (let r = m.startRow; r <= m.endRow; r++) {
            for (let c = m.startColumn; c <= m.endColumn; c++) {
              mergedSkip.add(`${r}:${c}`);
            }
          }
        }
      }

      // 1.3 绘制普通非合并单元格填充与文本
      for (const cell of sheet.cells) {
        if (mergedSkip.has(`${cell.row}:${cell.column}`)) continue;
        if (sheet.columnWidths[cell.column] === 0 || sheet.rowHeights[cell.row] === 0) continue;
        const left = HEADER_WIDTH + ox + colOffsets[cell.column];
        const top = HEADER_HEIGHT + oy + rowOffsets[cell.row];
        const colW = colOffsets[cell.column + 1] - colOffsets[cell.column];
        const rowH = rowOffsets[cell.row + 1] - rowOffsets[cell.row];
        if (left + colW < HEADER_WIDTH || left > bodyRight) continue;
        if (top + rowH < HEADER_HEIGHT || top > bodyBottom) continue;

        this.drawSingleCell(ctx, cell, left, top, colW, rowH, s);
      }

      // 1.4 绘制整表网格线（包括空白单元格）
      ctx.strokeStyle = GRID_COLOR;
      ctx.lineWidth = 0.5;
      ctx.beginPath();
      for (let r = 0; r < sheet.rowHeights.length; r++) {
        if (sheet.rowHeights[r] <= 0) continue;
        const y = HEADER_HEIGHT + oy + rowOffsets[r + 1];
        if (y < HEADER_HEIGHT) continue;
        if (y > bodyBottom) break;
        ctx.moveTo(HEADER_WIDTH, y);
        ctx.lineTo(bodyRight, y);
      }
      for (let c = 0; c < sheet.columnWidths.length; c++) {
        if (sheet.columnWidths[c] <= 0) continue;
        const x = HEADER_WIDTH + ox + colOffsets[c + 1];
        if (x < HEADER_WIDTH) continue;
        if (x > bodyRight) break;
        ctx.moveTo(x, HEADER_HEIGHT);
        ctx.lineTo(x, bodyBottom);
      }
      ctx.stroke();

      // 1.5 绘制合并单元格（覆盖内部网格线并绘制锚点文本）
      if (sheet.merges) {
        for (const m of sheet.merges) {
          const left = HEADER_WIDTH + ox + colOffsets[m.startColumn];
          const top = HEADER_HEIGHT + oy + rowOffsets[m.startRow];
          const right = HEADER_WIDTH + ox + colOffsets[m.endColumn + 1];
          const bottom = HEADER_HEIGHT + oy + rowOffsets[m.endRow + 1];
          const w = right - left;
          const h = bottom - top;
          if (w <= 0 || h <= 0 || right < HEADER_WIDTH || left > bodyRight || bottom < HEADER_HEIGHT || top > bodyBottom) {
            continue;
          }
          ctx.fillStyle = '#ffffff';
          ctx.fillRect(left, top, w, h);
          const anchor = anchorCellMap.get(`${m.startRow}:${m.startColumn}`);
          if (anchor) {
            this.drawSingleCell(ctx, anchor, left, top, w, h, s);
          }
          ctx.strokeStyle = GRID_COLOR;
          ctx.lineWidth = 0.5;
          ctx.strokeRect(left, top, w, h);
        }
      }

      // 1.6 绘制自定义单元格四周边框 (style.borders)
      for (const cell of sheet.cells) {
        if (mergedSkip.has(`${cell.row}:${cell.column}`)) continue;
        const style = this.document.cellStyles?.[cell.style];
        if (!style || !style.borders) continue;
        const left = HEADER_WIDTH + ox + colOffsets[cell.column];
        const top = HEADER_HEIGHT + oy + rowOffsets[cell.row];
        const colW = colOffsets[cell.column + 1] - colOffsets[cell.column];
        const rowH = rowOffsets[cell.row + 1] - rowOffsets[cell.row];
        if (left + colW < HEADER_WIDTH || left > bodyRight || top + rowH < HEADER_HEIGHT || top > bodyBottom) continue;
        this.drawCellBorders(ctx, left, top, left + colW, top + rowH, style);
      }
      if (sheet.merges) {
        for (const m of sheet.merges) {
          const anchor = anchorCellMap.get(`${m.startRow}:${m.startColumn}`);
          const style = anchor ? this.document.cellStyles?.[anchor.style] : undefined;
          if (!style || !style.borders) continue;
          const left = HEADER_WIDTH + ox + colOffsets[m.startColumn];
          const top = HEADER_HEIGHT + oy + rowOffsets[m.startRow];
          const right = HEADER_WIDTH + ox + colOffsets[m.endColumn + 1];
          const bottom = HEADER_HEIGHT + oy + rowOffsets[m.endRow + 1];
          this.drawCellBorders(ctx, left, top, right, bottom, style);
        }
      }

      ctx.restore();
    }

    // 2. 顶部列头 (A, B, C...)
    ctx.save();
    ctx.beginPath();
    ctx.rect(HEADER_WIDTH, 0, this.canvasWidth - HEADER_WIDTH, HEADER_HEIGHT);
    ctx.clip();
    ctx.fillStyle = HEADER_BG;
    ctx.fillRect(HEADER_WIDTH, 0, this.canvasWidth - HEADER_WIDTH, HEADER_HEIGHT);
    ctx.strokeStyle = GRID_COLOR;
    ctx.lineWidth = 0.5;
    ctx.fillStyle = HEADER_TEXT;
    ctx.font = '10vp sans-serif';
    ctx.textBaseline = 'middle';
    ctx.textAlign = 'center';

    for (let c = 0; c < sheet.columnWidths.length; c++) {
      if (sheet.columnWidths[c] <= 0) continue;
      const left = HEADER_WIDTH + ox + colOffsets[c];
      const colW = colOffsets[c + 1] - colOffsets[c];
      if (left + colW < HEADER_WIDTH) continue;
      if (left > this.canvasWidth) break;

      ctx.strokeRect(left, 0, colW, HEADER_HEIGHT);
      ctx.fillText(this.indexToColumnLetter(c), left + colW / 2, HEADER_HEIGHT / 2);
    }
    ctx.restore();

    // 3. 左侧行头 (1, 2, 3...)
    ctx.save();
    ctx.beginPath();
    ctx.rect(0, HEADER_HEIGHT, HEADER_WIDTH, this.canvasHeight - HEADER_HEIGHT);
    ctx.clip();
    ctx.fillStyle = HEADER_BG;
    ctx.fillRect(0, HEADER_HEIGHT, HEADER_WIDTH, this.canvasHeight - HEADER_HEIGHT);
    ctx.strokeStyle = GRID_COLOR;
    ctx.lineWidth = 0.5;
    ctx.fillStyle = HEADER_TEXT;
    ctx.font = '10vp sans-serif';
    ctx.textBaseline = 'middle';
    ctx.textAlign = 'right';

    for (let r = 0; r < sheet.rowHeights.length; r++) {
      if (sheet.rowHeights[r] <= 0) continue;
      const top = HEADER_HEIGHT + oy + rowOffsets[r];
      const rowH = rowOffsets[r + 1] - rowOffsets[r];
      if (top + rowH < HEADER_HEIGHT) continue;
      if (top > this.canvasHeight) break;

      ctx.strokeRect(0, top, HEADER_WIDTH, rowH);
      ctx.fillText(`${r + 1}`, HEADER_WIDTH - 6, top + rowH / 2);
    }
    ctx.restore();

    // 4. 左上角交叉块与表头分隔线
    ctx.fillStyle = HEADER_BG;
    ctx.fillRect(0, 0, HEADER_WIDTH, HEADER_HEIGHT);
    ctx.strokeStyle = '#bfc7cd';
    ctx.lineWidth = 0.75;
    ctx.beginPath();
    ctx.moveTo(HEADER_WIDTH, 0);
    ctx.lineTo(HEADER_WIDTH, this.canvasHeight);
    ctx.moveTo(0, HEADER_HEIGHT);
    ctx.lineTo(this.canvasWidth, HEADER_HEIGHT);
    ctx.stroke();
  }

  private drawSingleCell(
    ctx: CanvasRenderingContext2D,
    cell: model.Cell,
    left: number,
    top: number,
    colW: number,
    rowH: number,
    scale: number
  ): void {
    const style = this.document.cellStyles?.[cell.style];
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
    // 关键修复：使用 vp 单位而非 px
    ctx.font = `${italic}${bold}${fontSize}vp sans-serif`;
    ctx.fillStyle = style?.color ? (RenderUtils.argbToCss(style.color) ?? '#202124') : '#202124';
    ctx.textBaseline = 'middle';
    ctx.textAlign = 'left';

    const align = style?.alignment === 3 ? (cell.numeric ? 2 : 0) : (style?.alignment ?? 0);
    const textW = ctx.measureText(cell.text).width;
    const availW = colW - 4;

    let textX = left + 2;
    if (align === 1) {
      textX += (availW - textW) / 2;
    } else if (align === 2) {
      textX += availW - textW;
    }

    let textY = top + rowH / 2;
    if (style?.verticalAlignment === 'TOP') {
      textY = top + 2 + fontSize * 0.6;
    } else if (style?.verticalAlignment === 'BOTTOM') {
      textY = top + rowH - 2 - fontSize * 0.5;
    }

    ctx.save();
    ctx.beginPath();
    ctx.rect(left + 2, top + 1, Math.max(0, colW - 4), Math.max(0, rowH - 2));
    ctx.clip();
    ctx.fillText(cell.text, textX, textY);
    if (style?.underline && textW > 0) {
      ctx.strokeStyle = ctx.fillStyle;
      ctx.lineWidth = Math.max(0.75, fontSize * 0.06);
      ctx.beginPath();
      ctx.moveTo(textX, textY + fontSize * 0.45);
      ctx.lineTo(textX + textW, textY + fontSize * 0.45);
      ctx.stroke();
    }
    ctx.restore();
  }

  private drawCellBorders(
    ctx: CanvasRenderingContext2D,
    left: number,
    top: number,
    right: number,
    bottom: number,
    style: model.CellStyle
  ): void {
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
    let letter = '';
    let temp = index;
    while (temp >= 0) {
      letter = String.fromCharCode((temp % 26) + 65) + letter;
      temp = Math.floor(temp / 26) - 1;
    }
    return letter;
  }

  build() {
    Column() {
      Canvas(this.context2D)
        .width('100%')
        .layoutWeight(1)
        .onReady(() => {
          this.canvasWidth = this.context2D.width;
          this.canvasHeight = this.context2D.height;
          this.redraw();
        })
        .onAreaChange((_oldArea, newArea) => {
          this.canvasWidth = Number(newArea.width);
          this.canvasHeight = Number(newArea.height);
          this.redraw();
        })
        .gesture(
          GestureGroup(
            GestureMode.Parallel,
            PinchGesture({ fingers: 2 })
              .onActionStart(() => {
                this.pinchStartScale = this.scaleVal;
              })
              .onActionUpdate((event: GestureEvent) => {
                this.scaleVal = Math.min(3.0, Math.max(0.5, this.pinchStartScale * event.scale));
                this.redraw();
              }),
            PanGesture()
              .onActionStart(() => {
                this.panStartX = this.offsetX;
                this.panStartY = this.offsetY;
              })
              .onActionUpdate((event: GestureEvent) => {
                this.offsetX = this.panStartX + event.offsetX;
                this.offsetY = this.panStartY + event.offsetY;
                this.redraw();
              })
          )
        )

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
                  this.currentSheetIndex = idx;
                  this.offsetX = 0;
                  this.offsetY = 0;
                  this.redraw();
                })
            }, (_sheet: model.Sheet, idx: number) => `sheet-${idx}`)
          }
          .padding({ left: 12, right: 12 })
          .alignItems(VerticalAlign.Center)
        }
        .scrollable(ScrollDirection.Horizontal)
        .width('100%')
        .height(44) // 关键修复：固定底部页签栏高度，防止 Scroll 默认占满 100% 高度挤压 Canvas
        .backgroundColor('#ffffff')
        .border({ width: { top: 0.5 }, color: '#e0e0e0' })
      }
    }
    .width('100%')
    .height('100%')
  }
}
