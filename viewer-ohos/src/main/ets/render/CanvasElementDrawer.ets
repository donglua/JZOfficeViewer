import { image } from '@kit.ImageKit';
import * as model from '../core/OfficeModel';
import { RenderUtils } from './RenderUtils';

/**
 * 共享图元绘制器：在 CanvasRenderingContext2D 上绘制单个 model.Element
 * 适用于 PPTX 幻灯片矢量画布渲染与通用 Canvas 图元绘制
 */
export class CanvasElementDrawer {
  /**
   * 绘制单个 Element
   * @param ctx 鸿蒙 2D 绘图上下文
   * @param element 待绘制的图元模型
   * @param imageCache 可选的 PixelMap 图片缓存
   */
  public static drawElement(
    ctx: CanvasRenderingContext2D,
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

    // 2. 绘制 PATH 复杂几何路径
    if (element.type === 'PATH' && element.paths && element.paths.length > 0) {
      for (const p of element.paths) {
        if (!p.commands || p.commands.length === 0) continue;
        const path2d = RenderUtils.buildPath2D(p.commands);

        // 填充
        if (p.fill && CanvasElementDrawer.applyFill(ctx, element, w, h)) {
          ctx.fill(path2d);
        }

        // 描边
        if (p.stroke && element.stroke !== 0) {
          const strokeCss = RenderUtils.argbToCss(element.stroke);
          if (strokeCss) {
            ctx.strokeStyle = strokeCss;
            ctx.lineWidth = Math.max(0.5, element.strokeWidth || 1);
            ctx.stroke(path2d);
          }
        }
      }
    } else {
      // 3. 基础几何图形 (RECT / ELLIPSE / LINE)
      if (element.type !== 'LINE' && CanvasElementDrawer.applyFill(ctx, element, w, h)) {
        if (element.type === 'ELLIPSE') {
          ctx.beginPath();
          ctx.ellipse(w / 2, h / 2, w / 2, h / 2, 0, 0, Math.PI * 2);
          ctx.fill();
        } else {
          ctx.fillRect(0, 0, w, h);
        }
      }

      const strokeCss = RenderUtils.argbToCss(element.stroke);
      if (strokeCss) {
        ctx.strokeStyle = strokeCss;
        ctx.lineWidth = Math.max(0.5, element.strokeWidth || 1);
        if (element.type === 'ELLIPSE') {
          ctx.beginPath();
          ctx.ellipse(w / 2, h / 2, w / 2, h / 2, 0, 0, Math.PI * 2);
          ctx.stroke();
        } else if (element.type === 'LINE') {
          ctx.beginPath();
          ctx.moveTo(0, 0);
          ctx.lineTo(w, h);
          ctx.stroke();
        } else if (element.stroke !== 0) {
          ctx.strokeRect(0, 0, w, h);
        }
      }
    }

    // 4. 绘制图片 (IMAGE)
    if (element.type === 'IMAGE') {
      let pixelMap: image.PixelMap | undefined;
      if (element.image && imageCache) {
        pixelMap = imageCache.get(element.image);
      }
      if (pixelMap) {
        if (element.imageBounds && element.imageBounds.length >= 4) {
          const ib = element.imageBounds;
          ctx.drawImage(pixelMap, ib[0], ib[1], ib[2] - ib[0], ib[3] - ib[1]);
        } else {
          ctx.drawImage(pixelMap, 0, 0, w, h);
        }
      } else {
        // 图片加载中或未命中缓存时的占位灰框
        ctx.fillStyle = '#e8eaed';
        ctx.fillRect(0, 0, w, h);
      }
    }

    // 5. 绘制表格 (TABLE)
    if (element.type === 'TABLE' && element.rows && element.rows.length > 0) {
      CanvasElementDrawer.drawTable(ctx, element);
    }

    // 6. 绘制文本段落 (TEXT 或 形状内文字)
    if (element.paragraphs && element.paragraphs.length > 0) {
      CanvasElementDrawer.drawParagraphs(ctx, element);
    }

    ctx.restore();
  }

  /**
   * 绘制表格单元格与文字
   */
  private static drawTable(ctx: CanvasRenderingContext2D, element: model.Element): void {
    const rows = element.rows;
    const colWidths = element.columnWidths ?? [];
    const cellFills = element.cellFills ?? [];

    let currentY = 0;
    // 粗略按行数均分行高
    const rowHeight = element.height > 0 ? element.height / rows.length : 24;

    for (let r = 0; r < rows.length; r++) {
      const row = rows[r];
      let currentX = 0;

      for (let c = 0; c < row.length; c++) {
        const colW = colWidths[c] ?? (element.width / row.length);
        const cellParas = row[c];

        // 单元格背景填充
        const fillInt = cellFills[r]?.[c] ?? 0;
        const fillCss = RenderUtils.argbToCss(fillInt);
        if (fillCss) {
          ctx.fillStyle = fillCss;
          ctx.fillRect(currentX, currentY, colW, rowHeight);
        }

        // 单元格边框
        ctx.strokeStyle = '#b7bec7';
        ctx.lineWidth = 0.5;
        ctx.strokeRect(currentX, currentY, colW, rowHeight);

        // 绘制单元格内文字
        if (cellParas && cellParas.length > 0) {
          ctx.save();
          ctx.translate(currentX + 2, currentY + 2);
          for (const para of cellParas) {
            CanvasElementDrawer.drawSingleParagraph(ctx, para, colW - 4);
          }
          ctx.restore();
        }

        currentX += colW;
      }
      currentY += rowHeight;
    }
  }

  /**
   * 绘制段落文字
   */
  private static drawParagraphs(ctx: CanvasRenderingContext2D, element: model.Element): void {
    const padding = Math.max(0, element.padding || 4);
    let offsetY = padding;
    const availableWidth = Math.max(1, element.width - padding * 2);

    for (const para of element.paragraphs) {
      const lineHeight = CanvasElementDrawer.drawSingleParagraph(ctx, para, availableWidth, padding, offsetY);
      offsetY += lineHeight + (para.after || 2);
    }
  }

  /**
   * 绘制单条段落（支持粗斜体、颜色、字号与自动换行折叠）
   */
  private static drawSingleParagraph(
    ctx: CanvasRenderingContext2D,
    para: model.Paragraph,
    availableWidth: number,
    startX: number = 0,
    startY: number = 0
  ): number {
    let curX = startX + (para.firstLineIndent || 0);
    let curY = startY;
    let maxRunHeight = 14;

    for (const run of para.runs) {
      const fontSize = Math.max(8, run.size || 12);
      maxRunHeight = Math.max(maxRunHeight, fontSize * (para.lineSpacing || 1.2));

      const fontStyle = run.italic ? 'italic' : 'normal';
      const fontWeight = run.bold ? 'bold' : 'normal';
      ctx.font = `${fontStyle} ${fontWeight} ${fontSize}px sans-serif`;

      const colorCss = RenderUtils.argbToCss(run.color) ?? '#202124';
      ctx.fillStyle = colorCss;

      // 简单断词换行
      const words = run.text.split('');
      for (const char of words) {
        const metrics = ctx.measureText(char);
        const charW = metrics.width;

        if (curX + charW > startX + availableWidth && curX > startX) {
          curX = startX;
          curY += maxRunHeight;
        }

        ctx.fillText(char, curX, curY + fontSize);
        curX += charW;
      }
    }

    return (curY - startY) + maxRunHeight;
  }

  /**
   * 应用图元的背景填充（优先处理线性渐变 fillGradient，回退至纯色 ARGB）
   */
  private static applyFill(
    ctx: CanvasRenderingContext2D,
    element: model.Element,
    w: number,
    h: number
  ): boolean {
    if (element.fillGradient && element.fillGradient.stops && element.fillGradient.stops.length > 0) {
      const pts = RenderUtils.gradientPoints(element.fillGradient, w, h);
      const grad = ctx.createLinearGradient(pts[0], pts[1], pts[2], pts[3]);
      for (const stop of element.fillGradient.stops) {
        const css = RenderUtils.argbToCss(stop.color) ?? '#ffffff';
        grad.addColorStop(Math.min(1, Math.max(0, stop.position)), css);
      }
      ctx.fillStyle = grad;
      return true;
    }
    if (element.fill !== 0) {
      const fillCss = RenderUtils.argbToCss(element.fill);
      if (fillCss) {
        ctx.fillStyle = fillCss;
        return true;
      }
    }
    return false;
  }
}
