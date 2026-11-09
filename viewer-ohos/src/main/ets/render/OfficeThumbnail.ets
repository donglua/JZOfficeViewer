import { image } from '@kit.ImageKit';
import * as model from '../core/OfficeModel';
import { NativeCore } from '../core/NativeCore';
import { CanvasElementDrawer } from './CanvasElementDrawer';
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

  const doc: model.OfficeDocument = await NativeCore.parseDocumentAsync(filePath);
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
      }
    }

    ctx.save();
    ctx.scale(scale, scale);
    const marginX = 24;
    const availW = Math.max(100, docW - marginX * 2);
    let curY = 24;

    for (const block of allBlocks) {
      if (curY >= docH - 16) break;
      const elW = block.width && block.width > 0 ? Math.min(availW, block.width) : availW;
      let elH = block.height && block.height > 0 ? block.height : 0;
      if (elH <= 0 && block.type === 'TABLE' && block.rows && block.rows.length > 0) {
        elH = CanvasElementDrawer.measureTableHeight(block, elW, ctx);
      } else if (elH <= 0 && block.paragraphs && block.paragraphs.length > 0) {
        elH = CanvasElementDrawer.measureParagraphsHeight(ctx, block.paragraphs, elW, true) + 8;
      } else if (elH <= 0) {
        elH = 80;
      }

      const positioned: model.Element = {
        type: block.type,
        x: marginX,
        y: curY,
        width: elW,
        height: elH,
        transform: [1, 0, 0, 1, marginX, curY],
        padding: block.padding ?? 4,
        fill: block.fill,
        stroke: block.stroke,
        strokeWidth: block.strokeWidth,
        image: block.image,
        imageBounds: block.imageBounds,
        verticalAlignment: block.verticalAlignment,
        textWrap: true,
        paragraphs: block.paragraphs,
        rows: block.rows,
        columnWidths: block.columnWidths,
        cellFills: block.cellFills,
        paths: block.paths,
        fillGradient: block.fillGradient,
        merges: block.merges
      };
      CanvasElementDrawer.drawElement(ctx, positioned, imageStore.cache);
      curY += elH + 8;
    }
    ctx.restore();
    return ctx.getPixelMap(0, 0, outW, outH);
  } finally {
    imageStore.release();
  }
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
