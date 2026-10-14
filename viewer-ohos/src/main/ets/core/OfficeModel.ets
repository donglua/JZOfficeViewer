/**
 * JZOffice 跨平台文档排版模型定义 (对齐 core/src/model.rs 与 core/src/spreadsheet.rs)
 * 坐标、尺寸与字号统一使用 point (磅)。
 */

export type Kind = 'DOCX' | 'PPTX' | 'XLSX';

export type ElementType = 'TEXT' | 'IMAGE' | 'RECT' | 'ELLIPSE' | 'LINE' | 'TABLE' | 'PATH';

export type VerticalAlignment = 'TOP' | 'CENTER' | 'BOTTOM';

export type LineSpacingRule = 'AUTO' | 'EXACT' | 'AT_LEAST';

export type PathCommandOp = 'MOVE' | 'LINE' | 'QUAD' | 'CUBIC' | 'CLOSE';

export interface PathCommand {
  op: PathCommandOp;
  points?: number[];
}

export interface Path {
  fill: boolean;
  stroke: boolean;
  commands: PathCommand[];
}

export interface GradientFill {
  colors: number[];
  positions: number[];
  points: [number, number, number, number];
  transform?: [number, number, number, number, number, number];
}

export interface Run {
  text: string;
  fontFace?: string;
  size: number;
  bold: boolean;
  italic: boolean;
  underline: boolean;
  color: number;
}

export interface Paragraph {
  runs: Run[];
  alignment: number;
  before: number;
  after: number;
  indent: number;
  rightIndent: number;
  firstLineIndent: number;
  lineSpacingRule: LineSpacingRule;
  lineSpacing: number;
  bullet: string;
}

export interface Element {
  type: ElementType;
  x: number;
  y: number;
  width: number;
  height: number;
  transform: [number, number, number, number, number, number];
  padding: number;
  fill: number;
  stroke: number;
  strokeWidth: number;
  image?: string;
  imageBounds?: [number, number, number, number];
  verticalAlignment: VerticalAlignment;
  textWrap: boolean;
  paragraphs: Paragraph[];
  rows: Paragraph[][][];
  columnWidths: number[];
  cellFills: number[][];
  paths: Path[];
  fillGradient?: GradientFill;
}

export interface Page {
  width: number;
  height: number;
  background: number;
  elements: Element[];
}

export interface CellRange {
  startRow: number;
  startColumn: number;
  endRow: number;
  endColumn: number;
}

export interface CellStyle {
  fontSize: number;
  bold: boolean;
  italic: boolean;
  underline: boolean;
  color: number;
  fill: number;
  alignment: number;
  verticalAlignment: VerticalAlignment;
  wrap: boolean;
  borders: [number | null, number | null, number | null, number | null];
}

export interface Cell {
  row: number;
  column: number;
  text: string;
  style: number;
  numeric: boolean;
}

export interface Sheet {
  name: string;
  rowHeights: number[];
  columnWidths: number[];
  cells: Cell[];
  merges: CellRange[];
}

export interface OfficeDocument {
  schemaVersion: number;
  kind: Kind;
  width: number;
  pages: Page[];
  blocks: Element[];
  warnings: string[];
  sheets: Sheet[];
  cellStyles: CellStyle[];
}
