import { image } from '@kit.ImageKit';
import { NativeCore } from '../core/NativeCore';
import { RenderUtils } from './RenderUtils';

/**
 * 文档内嵌图片仓库：同一 ZIP 部件（如母版背景图）只读取、解码一次，供所有幻灯片共享
 */
export class ImageStore {
  private readonly filePath: string;
  private readonly pixelMaps: Map<string, image.PixelMap> = new Map();
  private readonly pending: Map<string, Promise<image.PixelMap | null>> = new Map();

  constructor(filePath: string) {
    this.filePath = filePath;
  }

  public get cache(): Map<string, image.PixelMap> {
    return this.pixelMaps;
  }

  /**
   * 确保指定部件已加载完成；失败的图片保持为空（绘制端回退为占位色块）
   */
  public async load(part: string): Promise<void> {
    if (!this.filePath || this.pixelMaps.has(part)) return;
    let task = this.pending.get(part);
    if (!task) {
      task = this.decode(part);
      this.pending.set(part, task);
    }
    const pixelMap = await task;
    if (pixelMap) {
      this.pixelMaps.set(part, pixelMap);
    }
  }

  private async decode(part: string): Promise<image.PixelMap | null> {
    try {
      const buffer: ArrayBuffer = await NativeCore.readPartAsync(this.filePath, part);
      return await RenderUtils.decodeImageBuffer(buffer);
    } catch (_e) {
      return null;
    }
  }

  public release(): void {
    this.pixelMaps.forEach((pixelMap: image.PixelMap) => {
      pixelMap.release();
    });
    this.pixelMaps.clear();
    this.pending.clear();
  }
}
