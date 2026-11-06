import { NativeCore } from './NativeCore';
import * as model from './OfficeModel';

/**
 * 文档元数据模型（与平台独立，不依赖 UI 渲染层）
 */
export interface OfficeMetadataInfo {
  readonly format: model.Kind;
  readonly pageCount: number;
  readonly sheetNames: string[];
  readonly warnings: string[];
  readonly width: number;
  readonly height: number;
}

/**
 * 异步速读指定沙箱路径 Office 文档的元数据（格式、页数、Sheet 列表、尺寸与告警）。
 * 无需初始化 UI 视图组件。
 */
export async function readOfficeMetadata(filePath: string): Promise<OfficeMetadataInfo> {
  const doc: model.OfficeDocument = await NativeCore.parseDocumentAsync(filePath);
  const isXlsx = doc.kind === 'XLSX';
  const isPptx = doc.kind === 'PPTX';
  const pageCount = isXlsx ? (doc.sheets ? doc.sheets.length : 0)
    : isPptx ? (doc.pages ? doc.pages.length : 0) : 1;
  const sheetNames = isXlsx && doc.sheets ? doc.sheets.map((s: model.Sheet) => s.name) : [];
  let docHeight = 0;
  if (isPptx && doc.pages && doc.pages.length > 0) {
    docHeight = doc.pages[0].height;
  }
  return {
    format: doc.kind,
    pageCount: pageCount,
    sheetNames: sheetNames,
    warnings: doc.warnings ? doc.warnings.slice() : [],
    width: doc.width || 0,
    height: docHeight
  };
}
