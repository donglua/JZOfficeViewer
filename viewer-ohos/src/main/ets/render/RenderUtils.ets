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
      const buffer: ArrayBuffer = uint8.buffer.slice(
        uint8.byteOffset,
        uint8.byteOffset + uint8.byteLength
      );

      imageSource = image.createImageSource(buffer);
      return await imageSource.createPixelMap({ editable: false });
    } catch (_e) {
      return null;
    } finally {
      if (imageSource) {
        await imageSource.release();
      }
    }
  }

  /**
   * 将 ArrayBuffer 二进制流直接解码为鸿蒙 PixelMap
   */
  public static async decodeImageBuffer(buffer: ArrayBuffer): Promise<image.PixelMap | null> {
    let imageSource: image.ImageSource | null = null;
    try {
      imageSource = image.createImageSource(buffer);
      return await imageSource.createPixelMap({ editable: false });
    } catch (_e) {
      return null;
    } finally {
      if (imageSource) {
        await imageSource.release();
      }
    }
  }
}
