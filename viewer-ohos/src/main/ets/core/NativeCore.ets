import { parse, parseAsync, readPart, readPartAsync, AbortSignal } from 'libjz_office_ohos.so';
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
    return JSON.parse(rawJson) as OfficeDocument;
  }

  /**
   * 同步解析本地沙箱路径下的 Office 文档（建议仅在 TaskPool 子线程或确认极小文件时调用）
   * @param path 沙箱中的本地文件路径
   */
  public static parseDocumentSync(path: string): OfficeDocument {
    const rawJson: string = parse(path);
    return JSON.parse(rawJson) as OfficeDocument;
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
}
