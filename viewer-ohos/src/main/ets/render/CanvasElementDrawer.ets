import { image } from '@kit.ImageKit';
import * as model from '../core/OfficeModel';
import { RenderUtils } from './RenderUtils';

interface TextSegment {
  text: string;
  font: string;
  fontSize: number;
  color: string;
  underline: boolean;
  width: number;
}

interface WrappedLine {
  segments: TextSegment[];
  width: number;
  height: number;
  maxFontSize: number;
}

export class CanvasElementDrawer {
  // 缓存已构建的 Path2D，避免滑动时每帧重复解析成百上千条矢量指令
  private static readonly pathCache: WeakMap<model.Path, Path2D> = new WeakMap();

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
          ctx.stroke(path2d);
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
      }
    }

    // 4. 绘制图片 (IMAGE)
    if (element.type === 'IMAGE') {
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
    }

    // 5. 绘制表格 (TABLE)
    if (element.type === 'TABLE' && element.rows && element.rows.length > 0) {
      CanvasElementDrawer.drawTable(ctx, element);
    }

    // 6. 绘制文本段落 (TEXT 或形状内文字)
    if (element.paragraphs && element.paragraphs.length > 0) {
      CanvasElementDrawer.drawParagraphs(ctx, element);
    }

    ctx.restore();
  }

  private static resolveFillStyle(
    ctx: CanvasRenderingContext2D,
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

  private static drawTable(ctx: CanvasRenderingContext2D, element: model.Element): void {
    const rows = element.rows ?? [];
    let cols = 0;
    for (const r of rows) {
      cols = Math.max(cols, r.length);
    }
    if (cols === 0) return;

    const colWidths = element.columnWidths ?? [];
    let totalWeight = 0;
    for (const cw of colWidths) {
      totalWeight += Math.max(1, cw);
    }

    const cellFills = element.cellFills ?? [];
    let currentY = 0;

    for (let r = 0; r < rows.length; r++) {
      const row = rows[r];
      // 先计算每列宽度并预排版测量当前行最大高度（列宽已由 Rust core 归一化为 point，同时保留兜底）
      const computedColWidths: number[] = [];
      let rowHeight = 20;
      for (let c = 0; c < cols; c++) {
        const colW =
          colWidths.length === cols && totalWeight > 0
            ? (Math.abs(totalWeight - element.width) < 0.5
                ? Math.max(1, colWidths[c])
                : (element.width * Math.max(1, colWidths[c])) / totalWeight)
            : element.width / cols;
        computedColWidths.push(colW);
        const cellParas = c < row.length ? row[c] : [];
        if (cellParas && cellParas.length > 0) {
          const h = CanvasElementDrawer.measureParagraphsHeight(ctx, cellParas, Math.max(1, colW - 10), true);
          rowHeight = Math.max(rowHeight, h + 10);
        }
      }

      let currentX = 0;
      for (let c = 0; c < cols; c++) {
        const colW = computedColWidths[c];
        const fillInt = cellFills[r]?.[c] ?? 0;
        const fillCss = RenderUtils.argbToCss(fillInt);
        if (fillCss) {
          ctx.fillStyle = fillCss;
          ctx.fillRect(currentX, currentY, colW, rowHeight);
        }

        ctx.strokeStyle = '#b7bec7';
        ctx.lineWidth = 0.6;
        ctx.strokeRect(currentX, currentY, colW, rowHeight);

        const cellParas = c < row.length ? row[c] : [];
        if (cellParas && cellParas.length > 0) {
          ctx.save();
          ctx.beginPath();
          ctx.rect(currentX, currentY, colW, rowHeight);
          ctx.clip();
          let paraY = currentY + 5;
          for (const para of cellParas) {
            paraY += Math.max(0, para.before || 0);
            const lines = CanvasElementDrawer.layoutParagraph(ctx, para, Math.max(1, colW - 10), true);
            const h = CanvasElementDrawer.drawParagraphLines(
              ctx,
              para,
              lines,
              currentX + 5,
              paraY,
              Math.max(1, colW - 10)
            );
            paraY += h + Math.max(0, para.after || 0);
          }
          ctx.restore();
        }
        currentX += colW;
      }
      currentY += rowHeight;
    }
  }

  private static drawParagraphs(ctx: CanvasRenderingContext2D, element: model.Element): void {
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
      const lines = CanvasElementDrawer.layoutParagraph(ctx, para, availableWidth, wrap);
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
    ctx: CanvasRenderingContext2D,
    paragraphs: model.Paragraph[],
    availableWidth: number,
    wrap: boolean
  ): number {
    let total = 0;
    for (const para of paragraphs) {
      total += Math.max(0, para.before || 0);
      const lines = CanvasElementDrawer.layoutParagraph(ctx, para, availableWidth, wrap);
      for (const line of lines) {
        total += line.height;
      }
      total += Math.max(0, para.after || 0);
    }
    return total;
  }

  private static drawParagraphLines(
    ctx: CanvasRenderingContext2D,
    para: model.Paragraph,
    lines: WrappedLine[],
    startX: number,
    startY: number,
    availableWidth: number
  ): number {
    const rightIndent = Math.max(0, para.rightIndent || 0);
    const baseIndent = Math.max(0, para.indent || 0);
    const firstIndent = Math.max(0, baseIndent + (para.firstLineIndent || 0));

    ctx.textBaseline = 'alphabetic';
    ctx.textAlign = 'left';

    let curY = startY;
    for (let i = 0; i < lines.length; i++) {
      const line = lines[i];
      const leftIndent = i === 0 ? firstIndent : baseIndent;
      const lineAvailWidth = Math.max(1, availableWidth - leftIndent - rightIndent);

      let lineX = startX + leftIndent;
      if (para.alignment === 1) {
        lineX += (lineAvailWidth - line.width) / 2;
      } else if (para.alignment === 2) {
        lineX += lineAvailWidth - line.width;
      }

      const baselineY = curY + line.height - (line.height - line.maxFontSize) / 2 - line.maxFontSize * 0.15;
      let segX = lineX;
      for (const seg of line.segments) {
        ctx.font = seg.font;
        ctx.fillStyle = seg.color;
        // 整段一次性绘制，不再逐字调用 fillText
        ctx.fillText(seg.text, segX, baselineY);
        if (seg.underline && seg.width > 0) {
          ctx.strokeStyle = seg.color;
          ctx.lineWidth = Math.max(0.75, seg.fontSize * 0.06);
          ctx.beginPath();
          ctx.moveTo(segX, baselineY + seg.fontSize * 0.12);
          ctx.lineTo(segX + seg.width, baselineY + seg.fontSize * 0.12);
          ctx.stroke();
        }
        segX += seg.width;
      }
      curY += line.height;
    }
    return curY - startY;
  }

  /**
   * 高性能段落折行：整段测量优先，仅在超出宽度时按需切分，使用 vp 字号单位对齐画布坐标系
   */
  private static layoutParagraph(
    ctx: CanvasRenderingContext2D,
    para: model.Paragraph,
    availableWidth: number,
    wrap: boolean
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
    if (runs.length === 0) {
      const defaultSize = para.runs && para.runs.length > 0 ? Math.max(1, para.runs[0].size) : 12;
      return [{
        segments: [],
        width: 0,
        height: CanvasElementDrawer.computeLineHeight(para, defaultSize),
        maxFontSize: defaultSize,
      }];
    }

    const rawLines: TextSegment[][] = [[]];
    let currentLineWidth = 0;
    const maxLineW = (lineIdx: number): number => {
      if (!wrap) return 1000000;
      const indent = lineIdx === 0 ? firstIndent : baseIndent;
      return Math.max(1, availableWidth - indent - rightIndent);
    };

    for (const run of runs) {
      const fontSize = Math.max(1, run.size || 12);
      const fontStyle = run.italic ? 'italic ' : '';
      const fontWeight = RenderUtils.resolveFontBold(run.fontFace, run.bold) ? 'bold ' : '';
      // 使用 vp 作为字号单位，并对齐 Android 的 Impact / 思源黑体 Light 字体兼容映射
      const fontFace = RenderUtils.resolveFontFamily(run.fontFace, true);
      const fontStr = `${fontStyle}${fontWeight}${fontSize}vp ${fontFace}`;
      const colorCss = RenderUtils.argbToCss(run.color) ?? '#202124';
      ctx.font = fontStr;

      const subParts = run.text.split('\n');
      for (let p = 0; p < subParts.length; p++) {
        if (p > 0) {
          rawLines.push([]);
          currentLineWidth = 0;
        }
        let remainingText = subParts[p];
        if (remainingText.length === 0) continue;

        while (remainingText.length > 0) {
          const limit = maxLineW(rawLines.length - 1);
          const fullW = ctx.measureText(remainingText).width;

          // 快路径：如果整段文字直接放得下，0 拆分直接入列！
          if (!wrap || currentLineWidth + fullW <= limit) {
            rawLines[rawLines.length - 1].push({
              text: remainingText,
              font: fontStr,
              fontSize,
              color: colorCss,
              underline: run.underline,
              width: fullW,
            });
            currentLineWidth += fullW;
            break;
          }

          // 若当前行已有内容且放不下，先换新行再试
          const availInLine = limit - currentLineWidth;
          if (availInLine <= fontSize * 0.5 && currentLineWidth > 0) {
            rawLines.push([]);
            currentLineWidth = 0;
            continue;
          }

          // 二分查找当前行能容纳的最大字符数，避免逐字遍历测量
          let low = 1;
          let high = remainingText.length;
          let bestCount = 1;
          let bestWidth = ctx.measureText(remainingText.substring(0, 1)).width;

          while (low <= high) {
            const mid = (low + high) >>> 1;
            const sub = remainingText.substring(0, mid);
            const w = ctx.measureText(sub).width;
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
            bestWidth = ctx.measureText(remainingText.substring(0, bestCount)).width;
          }

          // 英文按词折行保护：若截断处在单词中间且前部有空格，优先在空格处断行
          if (bestCount < remainingText.length && !/\s/.test(remainingText.charAt(bestCount))) {
            const candidate = remainingText.substring(0, bestCount);
            const lastSpace = candidate.lastIndexOf(' ');
            if (lastSpace > 0 && lastSpace >= bestCount * 0.4) {
              bestCount = lastSpace + 1;
              bestWidth = ctx.measureText(remainingText.substring(0, bestCount)).width;
            }
          }

          if (bestCount === 1 && currentLineWidth > 0 && bestWidth > availInLine) {
            rawLines.push([]);
            currentLineWidth = 0;
            continue;
          }

          const fitText = remainingText.substring(0, bestCount);
          rawLines[rawLines.length - 1].push({
            text: fitText,
            font: fontStr,
            fontSize,
            color: colorCss,
            underline: run.underline,
            width: bestWidth,
          });
          remainingText = remainingText.substring(bestCount);
          if (remainingText.length > 0) {
            rawLines.push([]);
            currentLineWidth = 0;
          } else {
            currentLineWidth += bestWidth;
          }
        }
      }
    }

    return rawLines.map((segs): WrappedLine => {
      let w = 0;
      let maxFs = runs[0].size || 12;
      for (const s of segs) {
        w += s.width;
        if (s.fontSize > maxFs) maxFs = s.fontSize;
      }
      return {
        segments: segs,
        width: w,
        height: CanvasElementDrawer.computeLineHeight(para, maxFs),
        maxFontSize: maxFs,
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
}
