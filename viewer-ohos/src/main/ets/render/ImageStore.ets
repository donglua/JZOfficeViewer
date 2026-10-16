import { image } from '@kit.ImageKit';
import { NativeCore } from '../core/NativeCore';
import { RenderUtils } from './RenderUtils';

/**
 * 文档内嵌图片仓库：支持异步去重解码、活跃引用保护、LRU 容量淘汰（最多 32 张 / 8M 像素预算）及销毁防泄漏
 */
export class ImageStore {
  private static readonly MAX_CACHED_IMAGES: number = 32;
  private static readonly MAX_TOTAL_PIXELS: number = 8_000_000;

  private readonly filePath: string;
  private readonly pixelMaps: Map<string, image.PixelMap> = new Map();
  private readonly pixelCounts: Map<string, number> = new Map();
  private readonly refCounts: Map<string, number> = new Map();
  private readonly pending: Map<string, Promise<image.PixelMap | null>> = new Map();
  private totalPixels: number = 0;
  private closed: boolean = false;

  constructor(filePath: string) {
    this.filePath = filePath;
  }

  public get cache(): Map<string, image.PixelMap> {
    return this.pixelMaps;
  }

  /**
   * 标记部件正在被可见组件使用，避免在展示期间被 LRU 淘汰释放
   */
  public acquire(part: string): void {
    if (!part || this.closed) return;
    this.refCounts.set(part, (this.refCounts.get(part) ?? 0) + 1);
    this.touch(part);
  }

  /**
   * 解除可见组件对部件的占用，必要时触发冷图片 LRU 回收
   */
  public releasePart(part: string): void {
    if (!part || this.closed) return;
    const count = (this.refCounts.get(part) ?? 0) - 1;
    if (count > 0) {
      this.refCounts.set(part, count);
    } else {
      this.refCounts.delete(part);
      this.trimCache();
    }
  }

  private touch(part: string): void {
    const existing = this.pixelMaps.get(part);
    if (existing) {
      this.pixelMaps.delete(part);
      this.pixelMaps.set(part, existing);
    }
  }

  /**
   * 确保指定部件已加载完成；若加载期间仓库已销毁则立即释放解码出的 PixelMap 防止泄漏
   */
  public async load(part: string): Promise<void> {
    if (this.closed || !this.filePath || !part) return;
    if (this.pixelMaps.has(part)) {
      this.touch(part);
      return;
    }
    let task = this.pending.get(part);
    if (!task) {
      task = this.decode(part);
      this.pending.set(part, task);
    }
    let pixelMap: image.PixelMap | null = null;
    try {
      pixelMap = await task;
    } finally {
      if (this.pending.get(part) === task) {
        this.pending.delete(part);
      }
    }
    if (!pixelMap) return;
    if (this.closed) {
      pixelMap.release();
      return;
    }
    const existing = this.pixelMaps.get(part);
    if (existing) {
      if (existing !== pixelMap) {
        pixelMap.release();
      }
      this.touch(part);
      return;
    }
    let pixels = 0;
    try {
      const info = await pixelMap.getImageInfo();
      pixels = Math.max(0, (info?.size?.width ?? 0) * (info?.size?.height ?? 0));
    } catch (_e) {
      pixels = 0;
    }
    if (this.closed) {
      pixelMap.release();
      return;
    }
    this.pixelMaps.set(part, pixelMap);
    this.pixelCounts.set(part, pixels);
    this.totalPixels += pixels;
    this.trimCache();
  }

  private trimCache(): void {
    if (this.closed) return;
    if (this.pixelMaps.size <= ImageStore.MAX_CACHED_IMAGES && this.totalPixels <= ImageStore.MAX_TOTAL_PIXELS) {
      return;
    }
    const keys: string[] = Array.from(this.pixelMaps.keys());
    for (const key of keys) {
      if (this.pixelMaps.size <= ImageStore.MAX_CACHED_IMAGES && this.totalPixels <= ImageStore.MAX_TOTAL_PIXELS) {
        break;
      }
      if ((this.refCounts.get(key) ?? 0) > 0) {
        continue;
      }
      const evicted = this.pixelMaps.get(key);
      const pixels = this.pixelCounts.get(key) ?? 0;
      this.pixelMaps.delete(key);
      this.pixelCounts.delete(key);
      this.totalPixels = Math.max(0, this.totalPixels - pixels);
      if (evicted) {
        evicted.release();
      }
    }
  }

  private async decode(part: string): Promise<image.PixelMap | null> {
    try {
      const buffer: ArrayBuffer = await NativeCore.readPartAsync(this.filePath, part);
      if (this.closed) return null;
      return await RenderUtils.decodeImageBuffer(buffer);
    } catch (_e) {
      return null;
    }
  }

  public release(): void {
    this.closed = true;
    this.pixelMaps.forEach((pixelMap: image.PixelMap) => {
      pixelMap.release();
    });
    this.pixelMaps.clear();
    this.pixelCounts.clear();
    this.refCounts.clear();
    this.pending.clear();
    this.totalPixels = 0;
  }
}
