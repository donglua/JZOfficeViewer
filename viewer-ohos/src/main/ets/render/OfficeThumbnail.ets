import { image } from '@kit.ImageKit';
import * as model from '../core/OfficeModel';
import { NativeCore } from '../core/NativeCore';
import { CanvasElementDrawer, WrapObstacle } from './CanvasElementDrawer';
import { ImageStore } from './ImageStore';
import { RenderUtils } from './RenderUtils';

/**
 * 鸿蒙端无界面（Offscreen）Office 文档缩略图/封面生成器
 * 对齐 Android 端 `OfficeThumbnail.decode` / `OfficeThumbnail.load`，
 * 支持脱离 UI 组件直接生成首页/首张幻灯片/首个工作表预览 PixelMap。
 *
 * @param filePath 沙箱内文档绝对路径
 * @param maxTargetWidth 缩略图最大宽度（像素，必须 > 0）
 * @param maxTargetHeight 缩略图最大高度（像素，必须 > 0）
 * @returns 渲染完成的 PixelMap（调用方在使用完毕后负责调用 release()）
 */
export async function renderOfficeThumbnail(
  filePath: string,
  maxTargetWidth: number,
  maxTargetHeight: number
): Promise<image.PixelMap> {
  if (!filePath || filePath.trim().length === 0) {
    throw new Error('File path cannot be empty');
  }
  if (maxTargetWidth <= 0 || maxTargetHeight <= 0) {
    throw new Error(`Target width and height must be positive, got ${maxTargetWidth}x${maxTargetHeight}`);
  }

  // 封面只取首页：走首屏解析，避免为一张缩略图承担整篇文档的解析成本
  const doc: model.OfficeDocument = await NativeCore.parseDocumentFirstViewportAsync(filePath);
  if (doc.kind === 'PPTX') {
    return await renderPptxThumbnail(filePath, doc, maxTargetWidth, maxTargetHeight);
  } else if (doc.kind === 'DOCX') {
    return await renderDocxThumbnail(filePath, doc, maxTargetWidth, maxTargetHeight);
  } else if (doc.kind === 'XLSX') {
    return renderXlsxThumbnail(doc, maxTargetWidth, maxTargetHeight);
  } else {
    throw new Error(`Unsupported document format: ${doc.kind}`);
  }
}

async function renderPptxThumbnail(
  filePath: string,
  doc: model.OfficeDocument,
  maxW: number,
  maxH: number
): Promise<image.PixelMap> {
  if (!doc.pages || doc.pages.length === 0) {
    throw new Error('Presentation has no slides');
  }
  const firstPage = doc.pages[0];
  const slideW = firstPage.width && firstPage.width > 0 ? firstPage.width : 720;
  const slideH = firstPage.height && firstPage.height > 0 ? firstPage.height : 405;

  const scale = Math.min(maxW / slideW, maxH / slideH);
  const outW = Math.max(1, Math.round(slideW * scale));
  const outH = Math.max(1, Math.round(slideH * scale));

  const offscreen = new OffscreenCanvas(outW, outH);
  const ctx = offscreen.getContext('2d', new RenderingContextSettings(true));
  ctx.fillStyle = RenderUtils.argbToCss(firstPage.background) ?? '#ffffff';
  ctx.fillRect(0, 0, outW, outH);

  const imageStore = new ImageStore(filePath);
  try {
    const elements = firstPage.elements ?? [];
    const pixelBudget = Math.max(100_000, Math.min(2_000_000, outW * outH * 2));
    for (const el of elements) {
      if (el.type === 'IMAGE' && el.image) {
        imageStore.acquire(el.image);
        await imageStore.load(el.image, pixelBudget);
      }
    }

    ctx.save();
    ctx.scale(scale, scale);
    for (const el of elements) {
      CanvasElementDrawer.drawElement(ctx, el, imageStore.cache);
    }
    ctx.restore();
    return ctx.getPixelMap(0, 0, outW, outH);
  } finally {
    imageStore.release();
  }
}

async function renderDocxThumbnail(
  filePath: string,
  doc: model.OfficeDocument,
  maxW: number,
  maxH: number
): Promise<image.PixelMap> {
  const docW = doc.width && doc.width > 0 ? doc.width : 595;
  const docH = docW * 1.414;

  const scale = Math.min(maxW / docW, maxH / docH);
  const outW = Math.max(1, Math.round(docW * scale));
  const outH = Math.max(1, Math.round(docH * scale));

  const offscreen = new OffscreenCanvas(outW, outH);
  const ctx = offscreen.getContext('2d', new RenderingContextSettings(true));
  ctx.fillStyle = '#ffffff';
  ctx.fillRect(0, 0, outW, outH);

  const allBlocks: model.Element[] = [
    ...(doc.headerBlocks ?? []),
    ...(doc.blocks ?? []),
    ...(doc.footerBlocks ?? [])
  ];

  const imageStore = new ImageStore(filePath);
  try {
    const pixelBudget = Math.max(100_000, Math.min(2_000_000, outW * outH * 2));
    for (const block of allBlocks) {
      if (block.type === 'IMAGE' && block.image) {
        imageStore.acquire(block.image);
        await imageStore.load(block.image, pixelBudget);
      } else if (block.type === 'TABLE' && block.rows) {
        for (const row of block.rows) {
          for (const cell of row) {
            for (const p of cell) {
              if (p.image) {
                imageStore.acquire(p.image);
                await imageStore.load(p.image, pixelBudget);
              }
            }
          }
        }
      }
    }

    ctx.save();
    ctx.scale(scale, scale);
    const marginX = 24;
    const availW = Math.max(100, docW - marginX * 2);
    const coreMarginL = doc.marginLeft && doc.marginLeft > 0 ? doc.marginLeft : 72;
    const coreMarginR = doc.marginRight && doc.marginRight > 0 ? doc.marginRight : 72;
    const coreContentW = Math.max(1, docW - coreMarginL - coreMarginR);
    const behindItems: ThumbnailDrawItem[] = [];
    const flowItems: ThumbnailDrawItem[] = [];
    const frontItems: ThumbnailDrawItem[] = [];
    const activeObstacles: WrapObstacle[] = [];
    let curY = 24;

    const sections: model.Element[][] = [
      doc.headerBlocks ?? [],
      doc.blocks ?? [],
      doc.footerBlocks ?? []
    ];
    for (const sec of sections) {
      for (const block of sec) {
        if (curY >= docH - 16) break;
        const floating = block.wrapMode !== undefined && block.wrapMode !== 'INLINE';
        if (!floating) {
          pruneThumbObstacles(activeObstacles, curY);
          if (block.type === 'TABLE' && activeObstacles.length > 0) {
            curY = Math.max(curY, maxThumbObstacleBottom(activeObstacles) + 6);
            activeObstacles.length = 0;
          }
        }
        const isFixedShape = block.type !== 'TEXT' && block.type !== 'IMAGE' && block.type !== 'TABLE';
        const elW = block.width && block.width > 0
          ? (floating && block.type === 'IMAGE' ? block.width : Math.min(availW, block.width))
          : availW;
        let elH = block.height && block.height > 0 ? block.height : 0;

        if (floating) {
          if (elH <= 0) {
            elH = block.type === 'IMAGE' ? 100 : 80;
          }
          const align = block.horizontalAlign ?? 0;
          let fx = marginX;
          if (align === 1) {
            fx = marginX;
          } else if (align === 2) {
            fx = Math.max(0, marginX + (availW - elW) / 2);
          } else if (align === 3) {
            fx = Math.max(0, marginX + availW - elW);
          } else {
            const scaled = marginX + (block.x - coreMarginL) * (availW / coreContentW);
            fx = Math.max(0, Math.min(Math.max(0, docW - elW), scaled));
          }
          let fy = Math.max(24, curY + (block.y || 0));
          if (block.wrapMode === 'TOP_AND_BOTTOM') {
            const clearBot = maxThumbObstacleBottom(activeObstacles);
            fy = Math.max(fy, Math.max(curY, clearBot) + Math.max(0, block.distTop || 0));
            curY = Math.max(curY, fy + elH + Math.max(0, block.distBottom || 0) + 8);
            pruneThumbObstacles(activeObstacles, curY);
          } else if (block.wrapMode !== 'NONE') {
            const obsLeft = fx - Math.max(0, block.distLeft || 0);
            const obsRight = fx + elW + Math.max(0, block.distRight || 0);
            const obsTop = fy - Math.max(0, block.distTop || 0);
            const obsBot = fy + elH + Math.max(0, block.distBottom || 0);
            const side: 'left' | 'right' = align === 1
              ? 'left'
              : (align === 3 ? 'right' : (fx + elW * 0.5 <= marginX + availW * 0.5 ? 'left' : 'right'));
            if (obsLeft <= marginX + 36 && obsRight >= marginX + availW - 36) {
              curY = Math.max(curY, obsBot + 6);
              pruneThumbObstacles(activeObstacles, curY);
            } else {
              activeObstacles.push({ top: obsTop, bottom: obsBot, left: obsLeft, right: obsRight, side });
            }
          }
          const positioned = buildThumbnailElement(block, elW, elH);
          const item: ThumbnailDrawItem = { element: positioned, x: fx, y: fy, isParagraphFlow: false };
          if (block.behindDoc) {
            behindItems.push(item);
          } else {
            frontItems.push(item);
          }
          continue;
        }

        const drawX = marginX;
        if (!isFixedShape && block.type !== 'TEXT' && activeObstacles.length > 0) {
          let clearY = curY;
          for (const obs of activeObstacles) {
            if (drawX < obs.right && drawX + elW > obs.left) {
              clearY = Math.max(clearY, obs.bottom + 6);
            }
          }
          if (clearY > curY) {
            curY = clearY;
            pruneThumbObstacles(activeObstacles, curY);
          }
        }
        const obsSnapshot = block.type === 'TEXT' && activeObstacles.length > 0
          ? activeObstacles.slice()
          : undefined;
        if (elH <= 0 && block.type === 'TABLE' && block.rows && block.rows.length > 0) {
          elH = CanvasElementDrawer.measureTableHeight(block, elW, ctx);
        } else if (elH <= 0 && block.paragraphs && block.paragraphs.length > 0) {
          elH = CanvasElementDrawer.measureParagraphsHeight(ctx, block.paragraphs, elW, true, obsSnapshot, curY, drawX) + 8;
        } else if (elH <= 0) {
          elH = 80;
        }

        const positioned = buildThumbnailElement(block, elW, elH);
        const isParaFlow = block.type === 'TEXT' && !!(block.paragraphs && block.paragraphs.length > 0);
        if (isParaFlow) {
          positioned.padding = 0;
        }
        flowItems.push({ element: positioned, x: drawX, y: curY, obstacles: obsSnapshot, isParagraphFlow: isParaFlow });
        curY += elH + 8;
      }
      if (activeObstacles.length > 0) {
        curY = Math.max(curY, maxThumbObstacleBottom(activeObstacles) + 6);
        activeObstacles.length = 0;
      }
    }

    const drawItem = (item: ThumbnailDrawItem): void => {
      ctx.save();
      ctx.translate(item.x, item.y);
      if (item.isParagraphFlow) {
        CanvasElementDrawer.drawParagraphs(ctx, item.element, item.obstacles, item.y, item.x);
      } else {
        CanvasElementDrawer.drawElement(ctx, item.element, imageStore.cache);
      }
      ctx.restore();
    };
    for (const item of behindItems) drawItem(item);
    for (const item of flowItems) drawItem(item);
    for (const item of frontItems) drawItem(item);
    ctx.restore();
    return ctx.getPixelMap(0, 0, outW, outH);
  } finally {
    imageStore.release();
  }
}

interface ThumbnailDrawItem {
  element: model.Element;
  x: number;
  y: number;
  obstacles?: WrapObstacle[];
  isParagraphFlow: boolean;
}

function buildThumbnailElement(block: model.Element, width: number, height: number): model.Element {
  return {
    type: block.type,
    x: 0,
    y: 0,
    width,
    height,
    transform: block.transform,
    padding: block.padding ?? 4,
    fill: block.fill,
    stroke: block.stroke,
    strokeWidth: block.strokeWidth,
    image: block.image,
    imageBounds: block.imageBounds,
    verticalAlignment: block.verticalAlignment,
    textWrap: block.textWrap !== false,
    paragraphs: block.paragraphs,
    rows: block.rows,
    columnWidths: block.columnWidths,
    cellFills: block.cellFills,
    paths: block.paths,
    fillGradient: block.fillGradient,
    merges: block.merges
  };
}

function pruneThumbObstacles(obstacles: WrapObstacle[], y: number): void {
  for (let i = obstacles.length - 1; i >= 0; i--) {
    if (obstacles[i].bottom <= y) {
      obstacles.splice(i, 1);
    }
  }
}

function maxThumbObstacleBottom(obstacles: WrapObstacle[]): number {
  let max = 0;
  for (const obs of obstacles) {
    if (obs.bottom > max) max = obs.bottom;
  }
  return max;
}

function renderXlsxThumbnail(
  doc: model.OfficeDocument,
  maxW: number,
  maxH: number
): image.PixelMap {
  if (!doc.sheets || doc.sheets.length === 0) {
    throw new Error('Spreadsheet has no sheets');
  }
  const sheet = doc.sheets[0];
  const headerW = 42;
  const headerH = 22;

  const colOffsets: number[] = [headerW];
  for (const w of sheet.columnWidths ?? []) {
    colOffsets.push(colOffsets[colOffsets.length - 1] + Math.max(0, w));
  }
  const rowOffsets: number[] = [headerH];
  for (const h of sheet.rowHeights ?? []) {
    rowOffsets.push(rowOffsets[rowOffsets.length - 1] + Math.max(0, h));
  }

  const totalW = colOffsets[colOffsets.length - 1];
  const totalH = rowOffsets[rowOffsets.length - 1];
  const previewW = Math.max(200, Math.min(totalW > headerW ? totalW : 400, 800));
  const previewH = Math.max(150, Math.min(totalH > headerH ? totalH : 300, 600));

  const scale = Math.min(maxW / previewW, maxH / previewH);
  const outW = Math.max(1, Math.round(previewW * scale));
  const outH = Math.max(1, Math.round(previewH * scale));

  const offscreen = new OffscreenCanvas(outW, outH);
  const ctx = offscreen.getContext('2d', new RenderingContextSettings(true));
  ctx.fillStyle = '#ffffff';
  ctx.fillRect(0, 0, outW, outH);

  ctx.save();
  ctx.scale(scale, scale);

  // 绘制表头背景
  ctx.fillStyle = '#f3f5f7';
  ctx.fillRect(0, 0, previewW, headerH);
  ctx.fillRect(0, 0, headerW, previewH);

  const styles = doc.cellStyles ?? [];
  for (const cell of sheet.cells ?? []) {
    if (cell.row < 0 || cell.row + 1 >= rowOffsets.length) continue;
    if (cell.column < 0 || cell.column + 1 >= colOffsets.length) continue;
    const left = colOffsets[cell.column];
    const top = rowOffsets[cell.row];
    if (left >= previewW || top >= previewH) continue;
    const right = colOffsets[cell.column + 1];
    const bottom = rowOffsets[cell.row + 1];
    const w = right - left;
    const h = bottom - top;
    if (w <= 0 || h <= 0) continue;

    const style = cell.style >= 0 && cell.style < styles.length ? styles[cell.style] : undefined;
    const fillCss = style ? RenderUtils.argbToCss(style.fill) : null;
    if (fillCss) {
      ctx.fillStyle = fillCss;
      ctx.fillRect(left, top, w, h);
    }

    if (cell.text) {
      ctx.save();
      ctx.beginPath();
      ctx.rect(left + 2, top + 1, Math.max(0, w - 4), Math.max(0, h - 2));
      ctx.clip();
      const fontSize = style && style.fontSize > 0 ? style.fontSize : 11;
      const bold = style?.bold ? 'bold ' : '';
      ctx.font = `${bold}${fontSize}vp sans-serif`;
      ctx.fillStyle = (style ? RenderUtils.argbToCss(style.color) : null) ?? '#202124';
      ctx.textBaseline = 'middle';
      ctx.fillText(cell.text, left + 4, top + h / 2);
      ctx.restore();
    }
  }

  // 绘制网格线
  ctx.strokeStyle = '#dce1e5';
  ctx.lineWidth = 0.5;
  ctx.beginPath();
  for (const x of colOffsets) {
    if (x > previewW) break;
    ctx.moveTo(x, 0);
    ctx.lineTo(x, previewH);
  }
  for (const y of rowOffsets) {
    if (y > previewH) break;
    ctx.moveTo(0, y);
    ctx.lineTo(previewW, y);
  }
  ctx.stroke();

  ctx.restore();
  return ctx.getPixelMap(0, 0, outW, outH);
}
