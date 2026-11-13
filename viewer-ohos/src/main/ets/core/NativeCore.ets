import { parse, parseAsync, parseFirstViewportAsync, readMetadataAsync as readMetadataAsyncNative, prewarmSearchIndexAsync, search, searchAsync, readPart, readPartAsync, clearCache, evictCache, AbortSignal } from 'libjz_office_ohos.so';
import { MetadataInfo } from './OfficeModel';
import { OfficeDocument, SearchMatch } from './OfficeModel';

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
   * 异步首屏解析本地沙箱路径下的 Office 文档（仅供封面缩略图使用）。
   *
   * PPTX 只渲染首张幻灯片，XLSX 只解析首个工作表，DOCX 只解析首屏正文块；
   * 封面只需要首页内容，因此无需承担整篇文档的解析成本。
   * @param path 沙箱中的本地文件路径
   * @param signal 可选的中断信号
   */
  public static async parseDocumentFirstViewportAsync(
    path: string,
    signal?: AbortSignal
  ): Promise<OfficeDocument> {
    const rawJson: string = await parseFirstViewportAsync(path, signal);
    const doc = JSON.parse(rawJson) as OfficeDocument;
    if (doc.schemaVersion !== 9) {
      throw new Error(`Unsupported core model version: ${doc.schemaVersion}`);
    }
    return doc;
  }

  /**
   * 异步轻量速读本地沙箱路径下 Office 文档的元数据。
   *
   * 只读取判定格式与页数所需的少量部件，不构建正文、样式与几何模型。
   * 返回值为独立的元数据协议，不含可绘制内容。
   * @param path 沙箱中的本地文件路径
   * @param signal 可选的中断信号
   */
  public static async readMetadataAsync(
    path: string,
    signal?: AbortSignal
  ): Promise<MetadataInfo> {
    const rawJson: string = await readMetadataAsyncNative(path, signal);
    const info = JSON.parse(rawJson) as MetadataInfo;
    if (info.schemaVersion !== 9) {
      throw new Error(`Unsupported core model version: ${info.schemaVersion}`);
    }
    return info;
  }

  /**
   * 可选地在后台预热指定文档的全文检索索引。
   * 默认解析不会调用；只有预期立即搜索时才应使用。
   * @param path 沙箱中的本地文件路径
   * @param signal 可选的中断信号
   */
  public static async prewarmSearchIndexAsync(
    path: string,
    signal?: AbortSignal
  ): Promise<void> {
    await prewarmSearchIndexAsync(path, signal);
  }

  /**
   * 异步在指定沙箱路径的 Office 文档中执行全文检索（忽略大小写，复用底层轻量文本索引缓存）
   * @param path 沙箱中的本地文件路径
   * @param query 检索关键词
   * @param signal 可选的中断信号
   */
  public static async searchDocumentAsync(
    path: string,
    query: string,
    signal?: AbortSignal
  ): Promise<SearchMatch[]> {
    if (!query) {
      return [];
    }
    const rawJson: string = await searchAsync(path, query, signal);
    return JSON.parse(rawJson) as SearchMatch[];
  }

  /**
   * 同步在指定沙箱路径的 Office 文档中执行全文检索（忽略大小写）
   * @param path 沙箱中的本地文件路径
   * @param query 检索关键词
   */
  public static searchDocumentSync(path: string, query: string): SearchMatch[] {
    if (!query) {
      return [];
    }
    const rawJson: string = search(path, query);
    return JSON.parse(rawJson) as SearchMatch[];
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

