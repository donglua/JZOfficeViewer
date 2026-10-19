import { image } from '@kit.ImageKit';
import { util } from '@kit.ArkTS';
import * as model from '../core/OfficeModel';

export class RenderUtils {
  /**
   * 将 Rust 输出的 32 位 ARGB 颜色整数转换为 Canvas / ArkUI 支持的 rgba() 字符串
   * 若 alpha 为 0（透明），返回 null
   */
  public static argbToCss(argb: number): string | null {
    const unsigned = argb >>> 0;
    const a = (unsigned >>> 24) & 0xff;
    if (a === 0) {
      return null;
    }
    const r = (unsigned >>> 16) & 0xff;
    const g = (unsigned >>> 8) & 0xff;
    const b = unsigned & 0xff;
    if (a === 255) {
      return `rgb(${r}, ${g}, ${b})`;
    }
    return `rgba(${r}, ${g}, ${b}, ${(a / 255).toFixed(3)})`;
  }

  /**
   * 对齐 Android 端 OfficeTextLayout.FontFace 的字体族兼容映射：
   * - Impact -> sans-serif-condensed（并自动补偿加粗）
   * - 思源黑体 CN Light / Source Han Sans CN Light / Source Han Sans SC Light / Noto Sans CJK SC Light -> sans-serif-light
   */
  public static resolveFontFamily(fontFace?: string, quoteCustom: boolean = false): string {
    const trimmed = fontFace ? fontFace.trim() : '';
    if (trimmed.length === 0) {
      return 'sans-serif';
    }
    if (trimmed.toLowerCase() === 'impact') {
      return 'sans-serif-condensed, sans-serif';
    }
    if (
      trimmed === '思源黑体 CN Light' ||
      trimmed === 'Source Han Sans CN Light' ||
      trimmed === 'Source Han Sans SC Light' ||
      trimmed === 'Noto Sans CJK SC Light'
    ) {
      return 'sans-serif-light, sans-serif';
    }
    return quoteCustom ? `"${trimmed}", sans-serif` : `${trimmed}, sans-serif`;
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

  private static async createSampledPixelMap(
    imageSource: image.ImageSource,
    maxPixels: number = RenderUtils.DEFAULT_MAX_PIXELS
  ): Promise<image.PixelMap> {
    let srcW = 0;
    let srcH = 0;
    try {
      const info: image.ImageInfo = await imageSource.getImageInfo();
      srcW = info?.size?.width ?? 0;
      srcH = info?.size?.height ?? 0;
    } catch (_infoErr) {
      return await RenderUtils.decodePixelMapFallback(imageSource);
    }

    if (srcW <= 0 || srcH <= 0) {
      return await RenderUtils.decodePixelMapFallback(imageSource);
    }

    let sampleSize = 1;
    while (
      Math.ceil(srcW / sampleSize) * Math.ceil(srcH / sampleSize) > maxPixels ||
      Math.ceil(srcW / sampleSize) > RenderUtils.MAX_IMAGE_DIMENSION ||
      Math.ceil(srcH / sampleSize) > RenderUtils.MAX_IMAGE_DIMENSION
    ) {
      sampleSize *= 2;
    }

    // 若无需降采样，直接兜底解码（显式指定 RGBA_8888 确保调色板索引图正确映射为 32 位真彩色）
    if (sampleSize <= 1) {
      return await RenderUtils.decodePixelMapFallback(imageSource);
    }

    const targetW = Math.max(1, Math.floor(srcW / sampleSize));
    const targetH = Math.max(1, Math.floor(srcH / sampleSize));

    // 尝试一：通过 desiredSize + RGBA_8888 一步完成下采样解码
    try {
      return await imageSource.createPixelMap({
        editable: false,
        desiredSize: {
          width: targetW,
          height: targetH
        },
        desiredPixelFormat: image.PixelMapFormat.RGBA_8888
      });
    } catch (_err1) {
      // 某些底层解码器（如处理调色板 Indexed PNG 时）可能不支持 desiredSize + 格式转换联合调用
    }

    // 尝试二：尝试仅 desiredSize 下采样
    try {
      return await imageSource.createPixelMap({
        editable: false,
        desiredSize: {
          width: targetW,
          height: targetH
        }
      });
    } catch (_err2) {
      // desiredSize 失败
    }

    // 尝试三：全尺寸解码为 RGBA_8888 后，调用 pixelMap.scale 进行缩放
    try {
      const pixelMap = await imageSource.createPixelMap({
        editable: true,
        desiredPixelFormat: image.PixelMapFormat.RGBA_8888
      });
      if (pixelMap) {
        try {
          await pixelMap.scale(targetW / srcW, targetH / srcH);
        } catch (_scaleErr) {
          // 若 scale 失败，仍返回已解码的原尺寸 PixelMap，保证图片正常呈现
        }
        return pixelMap;
      }
    } catch (_err3) {
      // 原图 RGBA 解码失败
    }

    // 终极兜底：无参数默认解码
    return await RenderUtils.decodePixelMapFallback(imageSource);
  }

  private static async decodePixelMapFallback(imageSource: image.ImageSource): Promise<image.PixelMap> {
    try {
      return await imageSource.createPixelMap({
        editable: false,
        desiredPixelFormat: image.PixelMapFormat.RGBA_8888
      });
    } catch (_e1) {
      return await imageSource.createPixelMap({ editable: false });
    }
  }

  /**
   * 将 Element.image 中的 Base64 字符串解码为鸿蒙 PixelMap
   */
  public static async decodeBase64Image(base64Str: string): Promise<image.PixelMap | null> {
    let imageSource: image.ImageSource | null = null;
    try {
      // 剥离可能存在的 data:image/png;base64, 前缀
      const commaIdx = base64Str.indexOf(',');
      const pureBase64 = commaIdx >= 0 ? base64Str.substring(commaIdx + 1) : base64Str;

      const helper = new util.Base64Helper();
      const uint8: Uint8Array = helper.decodeSync(pureBase64);
      const buffer: ArrayBuffer = RenderUtils.toArrayBuffer(uint8);

      imageSource = image.createImageSource(buffer);
      return await RenderUtils.createSampledPixelMap(imageSource);
    } catch (e) {
      console.warn(`[RenderUtils] decodeBase64Image failed: ${e}`);
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
    let imageSource: image.ImageSource | null = null;
    try {
      const cleanBuffer = RenderUtils.toArrayBuffer(buffer);
      imageSource = image.createImageSource(cleanBuffer);
      return await RenderUtils.createSampledPixelMap(imageSource, maxPixels);
    } catch (e) {
      console.warn(`[RenderUtils] decodeImageBuffer failed: ${e}`);
      return null;
    } finally {
      if (imageSource) {
        await imageSource.release();
      }
    }
  }
}
