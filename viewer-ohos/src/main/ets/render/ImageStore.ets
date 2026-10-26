import { image } from '@kit.ImageKit';
import { NativeCore } from '../core/NativeCore';
import { RenderUtils, DecodedImageResult } from './RenderUtils';

/**
 * 文档内嵌图片仓库：受控并发解码（最大 3 并发）、按需动态下采样、LRU 容量淘汰与多实例安全隔离
 */
export class ImageStore {
  private static readonly MAX_CACHED_IMAGES: number = 32;
  private static readonly MAX_TOTAL_PIXELS: number = 8_000_000;
  private static readonly MAX_CONCURRENT_DECODES: number = 3;

  private static readonly activePathRefs: Map<string, number> = new Map();

  private readonly filePath: string;
  private readonly pixelMaps: Map<string, image.PixelMap> = new Map();
  private readonly pixelCounts: Map<string, number> = new Map();
  private readonly refCounts: Map<string, number> = new Map();
  private readonly sampledFlags: Map<string, boolean> = new Map();
  private readonly decodedBudgets: Map<string, number> = new Map();
  private readonly pending: Map<string, Promise<DecodedImageResult | null>> = new Map();
  private readonly failedParts: Set<string> = new Set();

  private totalPixels: number = 0;
  private closed: boolean = false;
  private activeDecodes: number = 0;
  private readonly waitQueue: Array<() => void> = [];
  private pathRegistered: boolean = false;

  constructor(filePath: string) {
    this.filePath = filePath;
    if (this.filePath) {
      const cur = ImageStore.activePathRefs.get(this.filePath) ?? 0;
      ImageStore.activePathRefs.set(this.filePath, cur + 1);
      this.pathRegistered = true;
    }
  }

  public get cache(): Map<string, image.PixelMap> {
    return this.pixelMaps;
  }

  public acquire(part: string): void {
    if (!part || this.closed) return;
    this.refCounts.set(part, (this.refCounts.get(part) ?? 0) + 1);
    this.touch(part);
  }

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

  private async acquireDecodeSlot(): Promise<void> {
    if (this.activeDecodes < ImageStore.MAX_CONCURRENT_DECODES) {
      this.activeDecodes++;
      return;
    }
    return new Promise<void>((resolve) => {
      this.waitQueue.push(() => {
        this.activeDecodes++;
        resolve();
      });
    });
  }

  private releaseDecodeSlot(): void {
    this.activeDecodes--;
    if (this.waitQueue.length > 0) {
      const next = this.waitQueue.shift();
      if (next) next();
    }
  }

  /**
   * 异步加载指定部件图片；若存在高清升级或首次就绪，返回 true
   */
  public async load(part: string, desiredMaxPixels: number = 4_000_000): Promise<boolean> {
    if (this.closed || !this.filePath || !part || this.failedParts.has(part)) {
      return false;
    }

    const cached = this.pixelMaps.get(part);
    const isSampled = this.sampledFlags.get(part) ?? false;
    const currentBudget = this.decodedBudgets.get(part) ?? 0;

    // 若缓存命中且无需高清升级，直接返回
    if (cached) {
      if (!isSampled || desiredMaxPixels <= currentBudget * 1.5) {
        this.touch(part);
        return false;
      }
    }

    let task = this.pending.get(part);
    if (!task) {
      task = this.decodeWithBudget(part, desiredMaxPixels);
      this.pending.set(part, task);
    }

    let result: DecodedImageResult | null = null;
    try {
      result = await task;
    } finally {
      if (this.pending.get(part) === task) {
        this.pending.delete(part);
      }
    }

    if (!result) {
      if (!this.closed && (this.refCounts.get(part) ?? 0) > 0) {
        this.failedParts.add(part);
      }
      return false;
    }

    if (this.closed) {
      result.pixelMap.release();
      return false;
    }

    const oldPixelMap = this.pixelMaps.get(part);
    const oldPixels = this.pixelCounts.get(part) ?? 0;

    // 若已有旧图且当前解码结果像素未增加，保留旧图
    if (oldPixelMap && result.pixelMap === oldPixelMap) {
      this.touch(part);
      return false;
    }

    let pixels = result.pixels;
    if (pixels <= 0) {
      try {
        const info = await result.pixelMap.getImageInfo();
        pixels = Math.max(0, (info?.size?.width ?? 0) * (info?.size?.height ?? 0));
      } catch (_e) {
        pixels = 0;
      }
    }

    if (this.closed) {
      result.pixelMap.release();
      return false;
    }

    // 替换为新 PixelMap，扣减旧像素并释放旧图
    if (oldPixelMap) {
      this.totalPixels = Math.max(0, this.totalPixels - oldPixels);
      oldPixelMap.release();
    }

    this.pixelMaps.set(part, result.pixelMap);
    this.pixelCounts.set(part, pixels);
    this.sampledFlags.set(part, result.sampled);
    this.decodedBudgets.set(part, result.budget);
    this.totalPixels += pixels;
    this.trimCache();
    return true;
  }

  private async decodeWithBudget(part: string, desiredMaxPixels: number): Promise<DecodedImageResult | null> {
    await this.acquireDecodeSlot();
    try {
      // 快速划过优化：若出队后该部件引用已被释放，跳过本次解码
      if (this.closed || (this.refCounts.get(part) ?? 0) <= 0) {
        return null;
      }
      const buffer: ArrayBuffer = await NativeCore.readPartAsync(this.filePath, part);
      if (this.closed || (this.refCounts.get(part) ?? 0) <= 0) {
        return null;
      }
      return await RenderUtils.decodeImageBufferDetailed(buffer, desiredMaxPixels);
    } catch (e) {
      console.warn(`[ImageStore] Failed to read/decode image part ${part}: ${e}`);
      return null;
    } finally {
      this.releaseDecodeSlot();
    }
  }

  private trimCache(): void {
    if (this.closed) return;
    if (this.pixelMaps.size <= ImageStore.MAX_CACHED_IMAGES && this.totalPixels <= ImageStore.MAX_TOTAL_PIXELS) {
      return;
    }
    for (const key of this.pixelMaps.keys()) {
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
      this.sampledFlags.delete(key);
      this.decodedBudgets.delete(key);
      this.totalPixels = Math.max(0, this.totalPixels - pixels);
      if (evicted) {
        evicted.release();
      }
    }
  }

  public release(): void {
    this.closed = true;
    while (this.waitQueue.length > 0) {
      const next = this.waitQueue.shift();
      if (next) next();
    }
    this.pixelMaps.forEach((pixelMap: image.PixelMap) => {
      pixelMap.release();
    });
    this.pixelMaps.clear();
    this.pixelCounts.clear();
    this.sampledFlags.clear();
    this.decodedBudgets.clear();
    this.refCounts.clear();
    this.pending.clear();
    this.failedParts.clear();
    this.totalPixels = 0;

    if (this.pathRegistered && this.filePath) {
      const cur = ImageStore.activePathRefs.get(this.filePath) ?? 1;
      if (cur <= 1) {
        ImageStore.activePathRefs.delete(this.filePath);
        NativeCore.evictCache(this.filePath);
      } else {
        ImageStore.activePathRefs.set(this.filePath, cur - 1);
      }
      this.pathRegistered = false;
    }
  }
}
