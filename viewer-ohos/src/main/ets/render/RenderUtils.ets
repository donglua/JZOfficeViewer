import { image } from '@kit.ImageKit';
import { util } from '@kit.ArkTS';
import * as model from '../core/OfficeModel';

export interface DecodedImageResult {
  readonly pixelMap: image.PixelMap;
  readonly pixels: number;
  readonly sampled: boolean;
  readonly budget: number;
}

export class RenderUtils {
  private static readonly COLOR_CACHE_MAX = 512;
  private static readonly colorCache: Map<number, string | null> = new Map();
  private static readonly FONT_CACHE_MAX = 128;
  private static readonly fontCache: Map<string, string> = new Map();

  /**
   * 将 Rust 输出的 32 位 ARGB 颜色整数转换为 Canvas / ArkUI 支持的 rgba() 字符串
   * 若 alpha 为 0（透明），返回 null
   */
  public static argbToCss(argb: number): string | null {
    const cached = RenderUtils.colorCache.get(argb);
    if (cached !== undefined) return cached;

    const unsigned = argb >>> 0;
    const a = (unsigned >>> 24) & 0xff;
    let result: string | null = null;
    if (a !== 0) {
      const r = (unsigned >>> 16) & 0xff;
      const g = (unsigned >>> 8) & 0xff;
      const b = unsigned & 0xff;
      result = a === 255 ? `rgb(${r}, ${g}, ${b})` : `rgba(${r}, ${g}, ${b}, ${(a / 255).toFixed(3)})`;
    }

    if (RenderUtils.colorCache.size >= RenderUtils.COLOR_CACHE_MAX) {
      const firstKey = RenderUtils.colorCache.keys().next().value;
      if (firstKey !== undefined) RenderUtils.colorCache.delete(firstKey);
    }
    RenderUtils.colorCache.set(argb, result);
    return result;
  }

  /**
   * 对齐 Android 端 OfficeTextLayout.FontFace 的字体族兼容映射：
   * - Impact -> sans-serif-condensed（并自动补偿加粗）
   * - 思源黑体 CN Light / Source Han Sans CN Light / Source Han Sans SC Light / Noto Sans CJK SC Light -> sans-serif-light
   */
  public static resolveFontFamily(fontFace?: string, quoteCustom: boolean = false): string {
    const key = `${quoteCustom ? 1 : 0}:${fontFace ?? ''}`;
    const cached = RenderUtils.fontCache.get(key);
    if (cached !== undefined) return cached;

    const trimmed = fontFace ? fontFace.trim() : '';
    let result = 'sans-serif';
    if (trimmed.length > 0) {
      if (trimmed.toLowerCase() === 'impact') {
        result = 'sans-serif-condensed, sans-serif';
      } else if (
        trimmed === '思源黑体 CN Light' ||
        trimmed === 'Source Han Sans CN Light' ||
        trimmed === 'Source Han Sans SC Light' ||
        trimmed === 'Noto Sans CJK SC Light'
      ) {
        result = 'sans-serif-light, sans-serif';
      } else {
        result = quoteCustom ? `"${trimmed}", sans-serif` : `${trimmed}, sans-serif`;
      }
    }

    if (RenderUtils.fontCache.size >= RenderUtils.FONT_CACHE_MAX) {
      const firstKey = RenderUtils.fontCache.keys().next().value;
      if (firstKey !== undefined) RenderUtils.fontCache.delete(firstKey);
    }
    RenderUtils.fontCache.set(key, result);
    return result;
  }

  /**
   * 对齐 Android 端 OfficeTextLayout.FontFace：Impact 映射为 sans-serif-condensed 时强制加粗
   */
  public static resolveFontBold(fontFace?: string, bold?: boolean): boolean {
    if (bold) return true;
    return fontFace ? fontFace.trim().toLowerCase() === 'impact' : false;
  }

  /**
   * 将 model.PathCommand[] 转换为鸿蒙 Canvas 的 Path2D 对象
   */
  public static buildPath2D(commands: model.PathCommand[]): Path2D {
    const path2d = new Path2D();
    for (const cmd of commands) {
      const pts = cmd.points ?? [];
      switch (cmd.op) {
        case 'MOVE':
          if (pts.length >= 2) path2d.moveTo(pts[0], pts[1]);
          break;
        case 'LINE':
          if (pts.length >= 2) path2d.lineTo(pts[0], pts[1]);
          break;
        case 'QUAD':
          if (pts.length >= 4) path2d.quadraticCurveTo(pts[0], pts[1], pts[2], pts[3]);
          break;
        case 'CUBIC':
          if (pts.length >= 6) path2d.bezierCurveTo(pts[0], pts[1], pts[2], pts[3], pts[4], pts[5]);
          break;
        case 'CLOSE':
          path2d.closePath();
          break;
      }
    }
    return path2d;
  }

  private static readonly MAX_IMAGE_DIMENSION: number = 4096;
  private static readonly DEFAULT_MAX_PIXELS: number = 4_000_000;

  /**
   * 确保入参统一转换为标准的 ArrayBuffer（兼容 Uint8Array / Buffer 视图切片）
   */
  public static toArrayBuffer(buffer: ArrayBuffer | Uint8Array): ArrayBuffer {
    if (buffer instanceof Uint8Array) {
      return buffer.buffer.slice(buffer.byteOffset, buffer.byteOffset + buffer.byteLength);
    }
    return buffer as ArrayBuffer;
  }

  private static async createSampledPixelMapWithMeta(
    imageSource: image.ImageSource,
    maxPixels: number = RenderUtils.DEFAULT_MAX_PIXELS
  ): Promise<DecodedImageResult | null> {
    let srcW = 0;
    let srcH = 0;
    try {
      const info: image.ImageInfo = await imageSource.getImageInfo();
      srcW = info?.size?.width ?? 0;
      srcH = info?.size?.height ?? 0;
    } catch (_infoErr) {
      const fallback = await RenderUtils.decodePixelMapFallback(imageSource);
      return fallback ? RenderUtils.wrapPixelMapResult(fallback, maxPixels, false) : null;
    }

    if (srcW <= 0 || srcH <= 0) {
      const fallback = await RenderUtils.decodePixelMapFallback(imageSource);
      return fallback ? RenderUtils.wrapPixelMapResult(fallback, maxPixels, false) : null;
    }

    let sampleSize = 1;
    while (
      Math.ceil(srcW / sampleSize) * Math.ceil(srcH / sampleSize) > maxPixels ||
      Math.ceil(srcW / sampleSize) > RenderUtils.MAX_IMAGE_DIMENSION ||
      Math.ceil(srcH / sampleSize) > RenderUtils.MAX_IMAGE_DIMENSION
    ) {
      sampleSize *= 2;
    }

    const isSampled = sampleSize > 1;
    if (!isSampled) {
      const fallback = await RenderUtils.decodePixelMapFallback(imageSource);
      return fallback ? RenderUtils.wrapPixelMapResult(fallback, maxPixels, false) : null;
    }

    const targetW = Math.max(1, Math.floor(srcW / sampleSize));
    const targetH = Math.max(1, Math.floor(srcH / sampleSize));

    try {
      const pm = await imageSource.createPixelMap({
        editable: false,
        desiredSize: { width: targetW, height: targetH },
        desiredPixelFormat: image.PixelMapFormat.RGBA_8888
      });
      if (pm) return RenderUtils.wrapPixelMapResult(pm, maxPixels, true);
    } catch (_err1) {}

    try {
      const pm = await imageSource.createPixelMap({
        editable: false,
        desiredSize: { width: targetW, height: targetH }
      });
      if (pm) return RenderUtils.wrapPixelMapResult(pm, maxPixels, true);
    } catch (_err2) {}

    try {
      const pm = await imageSource.createPixelMap({
        editable: true,
        desiredPixelFormat: image.PixelMapFormat.RGBA_8888
      });
      if (pm) {
        try {
          await pm.scale(targetW / srcW, targetH / srcH);
        } catch (_scaleErr) {}
        return RenderUtils.wrapPixelMapResult(pm, maxPixels, true);
      }
    } catch (_err3) {}

    const fallback = await RenderUtils.decodePixelMapFallback(imageSource);
    return fallback ? RenderUtils.wrapPixelMapResult(fallback, maxPixels, false) : null;
  }

  private static wrapPixelMapResult(
    pixelMap: image.PixelMap,
    budget: number,
    sampled: boolean
  ): DecodedImageResult {
    let pixels = 0;
    try {
      // 优先同步获取图片像素尺寸，避免异步 Promise 开销
      // @ts-ignore: getImageInfoSync 为 API 12 同步接口
      if (typeof pixelMap.getImageInfoSync === 'function') {
        // @ts-ignore
        const info = pixelMap.getImageInfoSync();
        pixels = Math.max(0, (info?.size?.width ?? 0) * (info?.size?.height ?? 0));
      }
    } catch (_syncErr) {
      pixels = 0;
    }
    return { pixelMap, pixels, sampled, budget };
  }

  private static async decodePixelMapFallback(imageSource: image.ImageSource): Promise<image.PixelMap | null> {
    try {
      return await imageSource.createPixelMap({
        editable: false,
        desiredPixelFormat: image.PixelMapFormat.RGBA_8888
      });
    } catch (_e1) {
      try {
        return await imageSource.createPixelMap({ editable: false });
      } catch (_e2) {
        return null;
      }
    }
  }

  /**
   * 将 Element.image 中的 Base64 字符串解码为鸿蒙 PixelMap
   */
  public static async decodeBase64Image(base64Str: string): Promise<image.PixelMap | null> {
    try {
      // 剥离可能存在的 data:image/png;base64, 前缀
      const commaIdx = base64Str.indexOf(',');
      const pureBase64 = commaIdx >= 0 ? base64Str.substring(commaIdx + 1) : base64Str;

      const helper = new util.Base64Helper();
      const uint8: Uint8Array = helper.decodeSync(pureBase64);
      const buffer: ArrayBuffer = RenderUtils.toArrayBuffer(uint8);

      return await RenderUtils.decodeImageBuffer(buffer);
    } catch (e) {
      console.warn(`[RenderUtils] decodeBase64Image failed: ${e}`);
      return null;
    }
  }

  /**
   * 将 ArrayBuffer 二进制流直接解码为鸿蒙 PixelMap 并返回详细元数据（实际像素数、预算及是否下采样）
   */
  public static async decodeImageBufferDetailed(
    buffer: ArrayBuffer,
    maxPixels: number = RenderUtils.DEFAULT_MAX_PIXELS
  ): Promise<DecodedImageResult | null> {
    let imageSource: image.ImageSource | null = null;
    try {
      const cleanBuffer = RenderUtils.toArrayBuffer(buffer);
      imageSource = image.createImageSource(cleanBuffer);
      return await RenderUtils.createSampledPixelMapWithMeta(imageSource, maxPixels);
    } catch (e) {
      console.warn(`[RenderUtils] decodeImageBufferDetailed failed: ${e}`);
      return null;
    } finally {
      if (imageSource) {
        await imageSource.release();
      }
    }
  }

  /**
   * 将 ArrayBuffer 二进制流直接解码为鸿蒙 PixelMap（自动按预算降采样）
   */
  public static async decodeImageBuffer(
    buffer: ArrayBuffer,
    maxPixels: number = RenderUtils.DEFAULT_MAX_PIXELS
  ): Promise<image.PixelMap | null> {
    const detailed = await RenderUtils.decodeImageBufferDetailed(buffer, maxPixels);
    return detailed ? detailed.pixelMap : null;
  }
}
