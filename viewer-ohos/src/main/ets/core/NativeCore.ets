import { parse, parseAsync, readPart, readPartAsync, clearCache, evictCache, AbortSignal } from 'libjz_office_ohos.so';
import { OfficeDocument } from './OfficeModel';

export class NativeCore {
  /**
   * 异步解析本地沙箱路径下的 Office 文档（通过底层 Worker 线程池，不阻塞 ArkUI 渲染主线程）
   * @param path 沙箱中的本地文件路径
   * @param signal 可选的中断信号
   */
  public static async parseDocumentAsync(
    path: string,
    signal?: AbortSignal
  ): Promise<OfficeDocument> {
    const rawJson: string = await parseAsync(path, signal);
    const doc = JSON.parse(rawJson) as OfficeDocument;
    if (doc.schemaVersion !== 9) {
      throw new Error(`Unsupported core model version: ${doc.schemaVersion}`);
    }
    return doc;
  }

  /**
   * 同步解析本地沙箱路径下的 Office 文档（建议仅在 TaskPool 子线程或确认极小文件时调用）
   * @param path 沙箱中的本地文件路径
   */
  public static parseDocumentSync(path: string): OfficeDocument {
    const rawJson: string = parse(path);
    const doc = JSON.parse(rawJson) as OfficeDocument;
    if (doc.schemaVersion !== 9) {
      throw new Error(`Unsupported core model version: ${doc.schemaVersion}`);
    }
    return doc;
  }

  /**
   * 异步读取文档 ZIP 包内指定部件字节流（主要用于按需提取内嵌图片）
   * @param path 沙箱中的本地文件路径
   * @param part ZIP 包内的相对路径（如 word/media/image1.png）
   * @param signal 可选的中断信号
   */
  public static async readPartAsync(
    path: string,
    part: string,
    signal?: AbortSignal
  ): Promise<ArrayBuffer> {
    return await readPartAsync(path, part, signal);
  }

  /**
   * 同步读取文档 ZIP 包内指定部件字节流
   * @param path 沙箱中的本地文件路径
   * @param part ZIP 包内的相对路径
   */
  public static readPartSync(path: string, part: string): ArrayBuffer {
    return readPart(path, part);
  }

  /**
   * 清除 Native 底层缓存的文档包文件句柄与 ZIP 索引
   */
  public static clearCache(): void {
    clearCache();
  }

  /**
   * 精准清除指定文档路径在 Native 底层缓存的文件句柄与 ZIP 索引
   * @param path 沙箱中的本地文件路径
   */
  public static evictCache(path: string): void {
    if (path) {
      evictCache(path);
    }
  }
}

