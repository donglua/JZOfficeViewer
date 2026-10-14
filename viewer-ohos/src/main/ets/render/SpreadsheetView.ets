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
  @Prop document: model.OfficeDocument;
  @State currentSheetIndex: number = 0;
  @State offsetX: number = 0;
  @State offsetY: number = 0;
  @State scaleVal: number = 1.0;

  private settings: RenderingContextSettings = new RenderingContextSettings(true);
  private context2D: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings);
  private canvasWidth: number = 0;
  private canvasHeight: number = 0;

  // 手势暂存变量
  private panStartX: number = 0;
  private panStartY: number = 0;
  private pinchStartScale: number = 1.0;

  private get currentSheet(): model.Sheet | undefined {
    if (!this.document.sheets || this.document.sheets.length === 0) return undefined;
    const idx = Math.min(Math.max(0, this.currentSheetIndex), this.document.sheets.length - 1);
    return this.document.sheets[idx];
  }

  private redraw(): void {
    const sheet = this.currentSheet;
    if (!sheet || this.canvasWidth <= 0 || this.canvasHeight <= 0) return;

    const ctx = this.context2D;
    ctx.clearRect(0, 0, this.canvasWidth, this.canvasHeight);

    const s = this.scaleVal;
    const ox = this.offsetX;
    const oy = this.offsetY;

    // 计算行列累加偏移位置
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

    // 1. 绘制表格主体背景与单元格 (受剪裁与视口滚动影响)
    ctx.save();
    ctx.beginPath();
    ctx.rect(HEADER_WIDTH, HEADER_HEIGHT, this.canvasWidth - HEADER_WIDTH, this.canvasHeight - HEADER_HEIGHT);
    ctx.clip();

    // 白色底板
    ctx.fillStyle = '#ffffff';
    ctx.fillRect(HEADER_WIDTH + ox, HEADER_HEIGHT + oy, totalGridWidth, totalGridHeight);

    // 构建合并单元格索引
    const mergedSubordinates = new Set<string>();
    const mergeAnchors = new Map<string, model.CellRange>();
    if (sheet.merges && sheet.merges.length > 0) {
      for (const m of sheet.merges) {
        mergeAnchors.set(`${m.startRow}:${m.startColumn}`, m);
        for (let r = m.startRow; r <= m.endRow; r++) {
          for (let c = m.startColumn; c <= m.endColumn; c++) {
            if (r !== m.startRow || c !== m.startColumn) {
              mergedSubordinates.add(`${r}:${c}`);
            }
          }
        }
      }
    }

    // 绘制单元格内容
    for (const cell of sheet.cells) {
      const c = cell.column;
      const r = cell.row;
      const key = `${r}:${c}`;
      if (mergedSubordinates.has(key)) {
        continue;
      }

      const mergeRange = mergeAnchors.get(key);
      const left = HEADER_WIDTH + ox + (colOffsets[c] ?? 0);
      const top = HEADER_HEIGHT + oy + (rowOffsets[r] ?? 0);
      const colW = mergeRange
        ? (colOffsets[mergeRange.endColumn + 1] ?? left) - (colOffsets[c] ?? left)
        : (colOffsets[c + 1] ?? left) - (colOffsets[c] ?? left);
      const rowH = mergeRange
        ? (rowOffsets[mergeRange.endRow + 1] ?? top) - (rowOffsets[r] ?? top)
        : (rowOffsets[r + 1] ?? top) - (rowOffsets[r] ?? top);

      // 视口外裁剪优化
      if (left + colW < HEADER_WIDTH || left > this.canvasWidth) continue;
      if (top + rowH < HEADER_HEIGHT || top > this.canvasHeight) continue;

      const style = this.document.cellStyles?.[cell.style];

      // 单元格背景填色
      if (style && style.fill !== 0) {
        const fillCss = RenderUtils.argbToCss(style.fill);
        if (fillCss) {
          ctx.fillStyle = fillCss;
          ctx.fillRect(left, top, colW, rowH);
        }
      }

      // 单元格边框
      ctx.strokeStyle = GRID_COLOR;
      ctx.lineWidth = 0.5;
      ctx.strokeRect(left, top, colW, rowH);

      // 单元格文字
      if (cell.text) {
        const fontSize = Math.max(9, (style?.fontSize ?? 11) * s);
        const bold = style?.bold ? 'bold ' : '';
        const italic = style?.italic ? 'italic ' : '';
        ctx.font = `${italic}${bold}${fontSize}px sans-serif`;
        ctx.fillStyle = style?.color ? (RenderUtils.argbToCss(style.color) ?? '#202124') : '#202124';

        const textMetrics = ctx.measureText(cell.text);
        const textW = textMetrics.width;

        // 对齐方式 (数字靠右，普通文字默认靠左)
        let textX = left + 4;
        if (cell.numeric || style?.alignment === 3) {
          textX = Math.max(left + 4, left + colW - textW - 4);
        } else if (style?.alignment === 2) {
          textX = left + (colW - textW) / 2;
        }

        const textY = top + (rowH + fontSize * 0.7) / 2;
        ctx.fillText(cell.text, textX, textY);
      }
    }

    ctx.restore();

    // 2. 绘制顶部列头 (A, B, C...) 随 X 滚动，Y 固定
    ctx.save();
    ctx.beginPath();
    ctx.rect(HEADER_WIDTH, 0, this.canvasWidth - HEADER_WIDTH, HEADER_HEIGHT);
    ctx.clip();
    ctx.fillStyle = HEADER_BG;
    ctx.fillRect(HEADER_WIDTH, 0, this.canvasWidth - HEADER_WIDTH, HEADER_HEIGHT);

    ctx.strokeStyle = GRID_COLOR;
    ctx.lineWidth = 0.5;
    ctx.fillStyle = HEADER_TEXT;
    ctx.font = '10px sans-serif';

    for (let c = 0; c < sheet.columnWidths.length; c++) {
      const left = HEADER_WIDTH + ox + (colOffsets[c] ?? 0);
      const colW = (colOffsets[c + 1] ?? left) - (colOffsets[c] ?? left);
      if (left + colW < HEADER_WIDTH || left > this.canvasWidth) continue;

      ctx.strokeRect(left, 0, colW, HEADER_HEIGHT);
      const colLetter = this.indexToColumnLetter(c);
      const tw = ctx.measureText(colLetter).width;
      ctx.fillText(colLetter, left + (colW - tw) / 2, 14);
    }
    ctx.restore();

    // 3. 绘制左侧行头 (1, 2, 3...) 随 Y 滚动，X 固定
    ctx.save();
    ctx.beginPath();
    ctx.rect(0, HEADER_HEIGHT, HEADER_WIDTH, this.canvasHeight - HEADER_HEIGHT);
    ctx.clip();
    ctx.fillStyle = HEADER_BG;
    ctx.fillRect(0, HEADER_HEIGHT, HEADER_WIDTH, this.canvasHeight - HEADER_HEIGHT);

    ctx.strokeStyle = GRID_COLOR;
    ctx.lineWidth = 0.5;
    ctx.fillStyle = HEADER_TEXT;
    ctx.font = '10px sans-serif';

    for (let r = 0; r < sheet.rowHeights.length; r++) {
      const top = HEADER_HEIGHT + oy + (rowOffsets[r] ?? 0);
      const rowH = (rowOffsets[r + 1] ?? top) - (rowOffsets[r] ?? top);
      if (top + rowH < HEADER_HEIGHT || top > this.canvasHeight) continue;

      ctx.strokeRect(0, top, HEADER_WIDTH, rowH);
      const rowNum = (r + 1).toString();
      const tw = ctx.measureText(rowNum).width;
      ctx.fillText(rowNum, (HEADER_WIDTH - tw) / 2, top + (rowH + 7) / 2);
    }
    ctx.restore();

    // 4. 左上角空白交叉块 (固定不动)
    ctx.fillStyle = HEADER_BG;
    ctx.fillRect(0, 0, HEADER_WIDTH, HEADER_HEIGHT);
    ctx.strokeStyle = GRID_COLOR;
    ctx.lineWidth = 0.5;
    ctx.strokeRect(0, 0, HEADER_WIDTH, HEADER_HEIGHT);
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
      // 1. 表格主视图 Canvas (支持手势滚动与缩放)
      Canvas(this.context2D)
        .width('100%')
        .layoutWeight(1)
        .onReady(() => {
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
            // 缩放手势
            PinchGesture({ fingers: 2 })
              .onActionStart(() => {
                this.pinchStartScale = this.scaleVal;
              })
              .onActionUpdate((event: GestureEvent) => {
                this.scaleVal = Math.min(3.0, Math.max(0.5, this.pinchStartScale * event.scale));
                this.redraw();
              }),
            // 平移拖拽手势
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

      // 2. 底部工作表 (Sheet) 切换标签栏
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
            })
          }
          .padding({ left: 12, right: 12, top: 6, bottom: 6 })
        }
        .scrollable(ScrollDirection.Horizontal)
        .width('100%')
        .backgroundColor('#ffffff')
        .border({ width: { top: 0.5 }, color: '#e0e0e0' })
      }
    }
    .width('100%')
    .height('100%')
  }
}
