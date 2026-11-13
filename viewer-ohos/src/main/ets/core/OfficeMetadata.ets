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
  // 只读取格式与页数所需的部件，不构建正文、样式与几何模型
  const info: model.MetadataInfo = await NativeCore.readMetadataAsync(filePath);
  return {
    format: info.kind,
    pageCount: info.pageCount,
    sheetNames: info.sheetNames ? info.sheetNames.slice() : [],
    warnings: info.warnings ? info.warnings.slice() : [],
    width: info.width || 0,
    height: info.height || 0
  };
}
