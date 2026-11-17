/**
 * JZOffice 鸿蒙端纯 TypeScript 文本选区模型（零 ArkUI、零 @kit.* 依赖）
 *
 * 与 macOS `TextSelectionModel.swift`、Android `TextSelectionModel.java` 保持完全一致的选区语义：
 * 块级文本顺序索引、逆矩阵点击命中、词界提取、跨块选区矩形与手柄几何、纯文本拼接。
 * 本文件既可由 Node.js（原生 TS type-stripping）直接执行，也可被 ArkTS 严格模式编译，
 * 因此禁止使用 enum、any、动态下标访问非数组对象与无接口类型的对象字面量。
 */

/** 文档文本流中的光标/字符位置 */
export interface TextPosition {
  /** 按文档阅读顺序分配的连续块索引 */
  readonly blockIndex: number;
  /** 在块 fullText 中的 UTF-16 码元偏移（0 .. fullText.length） */
  readonly charIndex: number;
}

/** 选区范围：保留锚点 anchor 与焦点 focus，支持正向与反向拖选 */
export interface TextSelection {
  readonly anchor: TextPosition;
  readonly focus: TextPosition;
}

/** 轴对齐矩形（块局部坐标系或文档全局坐标系） */
export interface TextRect {
  readonly left: number;
  readonly top: number;
  readonly right: number;
  readonly bottom: number;
}

/** 手柄定位点：同时给出文档全局坐标与块局部坐标 */
export interface HandlePoint {
  readonly docX: number;
  readonly docTopY: number;
  readonly docBottomY: number;
  readonly blockIndex: number;
  readonly localX: number;
  readonly localTopY: number;
  readonly localBottomY: number;
}

/** 选区起始/结束手柄 */
export interface SelectionHandles {
  readonly start: HandlePoint;
  readonly end: HandlePoint;
}

/** 单个文本块的高亮矩形（块局部矩形 + 文档全局包围框） */
export interface BlockHighlightRect {
  readonly blockIndex: number;
  readonly transform: number[];
  readonly localRect: TextRect;
  readonly docBounds: TextRect;
}

/**
 * 单行排版几何与字符映射的抽象：由平台层（Canvas 行度量）实现，
 * 纯逻辑层仅依赖本接口即可完成命中测试与高亮计算。
 */
export interface TextLineMetrics {
  /** 行矩形（块局部坐标，left/right 为行内文字实际覆盖范围） */
  readonly left: number;
  readonly top: number;
  readonly right: number;
  readonly bottom: number;
  /** 行内文字的绘制起点 X（已包含缩进与居中对齐偏移） */
  readonly lineX: number;
  /** 行在块 fullText 中的起始偏移 */
  readonly charStart: number;
  /** 行在块 fullText 中的结束偏移（不含） */
  readonly charEnd: number;
  /** 行所属段落在块 fullText 中的基准偏移 */
  readonly paraBaseOffset: number;
  /** 行内某字符（相对行首的局部索引）的相对 X 坐标，相对 lineX */
  horizontalOffset(localCharIndex: number): number;
  /** 按行内 X 坐标（相对 lineX）反查最邻近字符索引 */
  charIndexForX(relativeX: number): number;
}

/** 码元类别：ASCII 词字符（字母/数字/下划线） */
const CODE_CLASS_WORD: number = 1;
/** 码元类别：CJK 及全角字符（连续成段） */
const CODE_CLASS_CJK: number = 2;
/** 码元类别：空白字符（不作为首选词） */
const CODE_CLASS_SPACE: number = 3;
/** 码元类别：其余标点与符号 */
const CODE_CLASS_OTHER: number = 4;

/** 词界扫描结果（内部使用） */
interface CodeSpan {
  start: number;
  end: number;
}

/** 二维点（内部使用，避免借用 TextPosition 承载坐标） */
interface PlanePoint {
  x: number;
  y: number;
}

// MARK: - 基础工具函数

/** 是否为高代理（0xD800..0xDBFF） */
function isHighSurrogateCode(code: number): boolean {
  return code >= 0xD800 && code <= 0xDBFF;
}

/** 是否为低代理（0xDC00..0xDFFF） */
function isLowSurrogateCode(code: number): boolean {
  return code >= 0xDC00 && code <= 0xDFFF;
}

/** 是否为 ASCII 词字符：字母、数字、下划线 */
function isAsciiWordCode(code: number): boolean {
  if (code >= 0x30 && code <= 0x39) {
    return true;
  }
  if (code >= 0x41 && code <= 0x5A) {
    return true;
  }
  if (code >= 0x61 && code <= 0x7A) {
    return true;
  }
  return code === 0x5F;
}

/** 是否为 CJK 及全角字符（与 CanvasElementDrawer 的字间断行判定保持一致） */
function isCjkCode(code: number): boolean {
  if (code >= 0x2E80 && code <= 0x9FFF) {
    return true;
  }
  if (code >= 0x3040 && code <= 0x30FF) {
    return true;
  }
  if (code >= 0xAC00 && code <= 0xD7AF) {
    return true;
  }
  return code >= 0xF900 && code <= 0xFAFF;
}

/** 是否为空白字符 */
function isSpaceCode(code: number): boolean {
  if (code === 0x20 || code === 0x09 || code === 0x0A || code === 0x0D) {
    return true;
  }
  return code === 0xA0 || code === 0x3000;
}

/** 判定单个 UTF-16 码元的类别 */
function classifyCode(code: number): number {
  if (isAsciiWordCode(code)) {
    return CODE_CLASS_WORD;
  }
  if (isCjkCode(code)) {
    return CODE_CLASS_CJK;
  }
  if (isSpaceCode(code)) {
    return CODE_CLASS_SPACE;
  }
  return CODE_CLASS_OTHER;
}

/** 取 index 处码点的 UTF-16 长度（代理对为 2，其余为 1） */
function codePointStep(text: string, index: number): number {
  if (index < 0 || index >= text.length) {
    return 1;
  }
  const code = text.charCodeAt(index);
  if (isHighSurrogateCode(code) && index + 1 < text.length && isLowSurrogateCode(text.charCodeAt(index + 1))) {
    return 2;
  }
  return 1;
}

/** 比较两个文本位置的逻辑先后顺序：负数表示 a 在 b 之前 */
export function compareTextPositions(a: TextPosition, b: TextPosition): number {
  if (a.blockIndex !== b.blockIndex) {
    return a.blockIndex - b.blockIndex;
  }
  return a.charIndex - b.charIndex;
}

/**
 * 选区起点/终点的内部解析函数。
 * 类内方法与模块级导出函数共用同一实现，避免同名成员方法遮蔽模块函数导致无穷递归。
 */
function resolveSelectionStart(selection: TextSelection): TextPosition {
  return compareTextPositions(selection.anchor, selection.focus) <= 0 ? selection.anchor : selection.focus;
}

function resolveSelectionEnd(selection: TextSelection): TextPosition {
  return compareTextPositions(selection.anchor, selection.focus) <= 0 ? selection.focus : selection.anchor;
}

function resolveSelectionEmpty(selection: TextSelection): boolean {
  return compareTextPositions(selection.anchor, selection.focus) === 0;
}

/** 选区是否为空（锚点与焦点重合） */
export function isSelectionEmpty(selection: TextSelection): boolean {
  return resolveSelectionEmpty(selection);
}

/** 选区的逻辑起点（anchor/focus 中较早者） */
export function selectionStart(selection: TextSelection): TextPosition {
  return resolveSelectionStart(selection);
}

/** 选区的逻辑终点（anchor/focus 中较晚者） */
export function selectionEnd(selection: TextSelection): TextPosition {
  return resolveSelectionEnd(selection);
}/**
 * 将字符索引夹紧到 `0 .. text.length`，并避免落在高/低代理对之间。
 * 落在代理对中间时向后夹紧到该码点之后的合法边界，避免切分 Emoji 或扩展汉字。
 */
export function clampToCodePointBoundary(text: string, charIndex: number): number {
  const finite = Number.isFinite(charIndex) ? Math.round(charIndex) : 0;
  const clamped = Math.max(0, Math.min(text.length, finite));
  if (clamped <= 0 || clamped >= text.length) {
    return clamped;
  }
  if (isLowSurrogateCode(text.charCodeAt(clamped)) && isHighSurrogateCode(text.charCodeAt(clamped - 1))) {
    return clamped + 1;
  }
  return clamped;
}

/** 构造一个文本位置（供视图层复用，避免出现无接口类型的对象字面量） */
export function makeTextPosition(blockIndex: number, charIndex: number): TextPosition {
  const position: TextPosition = { blockIndex: blockIndex, charIndex: charIndex };
  return position;
}

/** 构造一个矩形（供视图层复用） */
export function makeTextRect(left: number, top: number, right: number, bottom: number): TextRect {
  const rect: TextRect = { left: left, top: top, right: right, bottom: bottom };
  return rect;
}

/** 构造一个选区（供视图层复用） */
export function makeTextSelection(anchor: TextPosition, focus: TextPosition): TextSelection {
  const selection: TextSelection = { anchor: anchor, focus: focus };
  return selection;
}

// MARK: - 仿射变换工具

/** 用仿射矩阵 [a, b, c, d, tx, ty] 变换一个点 */
function applyAffineToPoint(m: number[], x: number, y: number): PlanePoint {
  if (m.length < 6) {
    const passthrough: PlanePoint = { x: x, y: y };
    return passthrough;
  }
  const point: PlanePoint = {
    x: m[0] * x + m[2] * y + m[4],
    y: m[1] * x + m[3] * y + m[5]
  };
  return point;
}

/** 求仿射矩阵 [a, b, c, d, tx, ty] 的逆矩阵；矩阵不可逆时返回 null */
function invertAffine(m: number[]): number[] | null {
  if (m.length < 6) {
    return null;
  }
  const a = m[0];
  const b = m[1];
  const c = m[2];
  const d = m[3];
  const tx = m[4];
  const ty = m[5];
  const det = a * d - b * c;
  if (!Number.isFinite(det) || Math.abs(det) < 1e-9) {
    return null;
  }
  const ia = d / det;
  const ib = -b / det;
  const ic = -c / det;
  const id = a / det;
  const itx = -(ia * tx + ic * ty);
  const ity = -(ib * tx + id * ty);
  const result: number[] = [ia, ib, ic, id, itx, ity];
  return result;
}

/** 计算矩形经仿射变换后的轴对齐包围框 */
export function transformTextRect(m: number[], rect: TextRect): TextRect {
  if (m.length < 6) {
    return rect;
  }
  const xs: number[] = [
    m[0] * rect.left + m[2] * rect.top + m[4],
    m[0] * rect.right + m[2] * rect.top + m[4],
    m[0] * rect.left + m[2] * rect.bottom + m[4],
    m[0] * rect.right + m[2] * rect.bottom + m[4]
  ];
  const ys: number[] = [
    m[1] * rect.left + m[3] * rect.top + m[5],
    m[1] * rect.right + m[3] * rect.top + m[5],
    m[1] * rect.left + m[3] * rect.bottom + m[5],
    m[1] * rect.right + m[3] * rect.bottom + m[5]
  ];
  let minX = xs[0];
  let maxX = xs[0];
  let minY = ys[0];
  let maxY = ys[0];
  for (let i = 1; i < xs.length; i++) {
    if (xs[i] < minX) {
      minX = xs[i];
    }
    if (xs[i] > maxX) {
      maxX = xs[i];
    }
    if (ys[i] < minY) {
      minY = ys[i];
    }
    if (ys[i] > maxY) {
      maxY = ys[i];
    }
  }
  return makeTextRect(minX, minY, maxX, maxY);
}

/** 点到矩形的欧氏距离（点在矩形内为 0） */
function distanceToRect(x: number, y: number, rect: TextRect): number {
  const dx = Math.max(rect.left - x, 0, x - rect.right);
  const dy = Math.max(rect.top - y, 0, y - rect.bottom);
  return Math.sqrt(dx * dx + dy * dy);
}

// MARK: - 数组行度量（纯逻辑默认实现，供 Node.js / 纯 JVM 测试使用）

/**
 * 基于单调递增字符偏移数组的行度量实现。
 * `charOffsets` 长度为「行内字符数 + 1」，代理对的两个 UTF-16 单元共用同一起点。
 */
export class ArrayLineMetrics implements TextLineMetrics {
  readonly left: number;
  readonly top: number;
  readonly right: number;
  readonly bottom: number;
  readonly lineX: number;
  readonly charStart: number;
  readonly charEnd: number;
  readonly paraBaseOffset: number;
  private readonly charOffsets: number[];

  constructor(
    left: number,
    top: number,
    right: number,
    bottom: number,
    lineX: number,
    charStart: number,
    charEnd: number,
    paraBaseOffset: number,
    charOffsets: number[]
  ) {
    this.left = left;
    this.top = top;
    this.right = right;
    this.bottom = bottom;
    this.lineX = lineX;
    this.charStart = charStart;
    this.charEnd = charEnd;
    this.paraBaseOffset = paraBaseOffset;
    this.charOffsets = charOffsets;
  }

  horizontalOffset(localCharIndex: number): number {
    const offsets = this.charOffsets;
    if (offsets.length === 0) {
      return 0;
    }
    const last = offsets.length - 1;
    const index = Math.max(0, Math.min(last, Math.round(localCharIndex)));
    return offsets[index];
  }

  charIndexForX(relativeX: number): number {
    const offsets = this.charOffsets;
    const last = offsets.length - 1;
    if (last <= 0) {
      return 0;
    }
    if (relativeX <= offsets[0]) {
      return 0;
    }
    // 按字形中点四舍五入：越过中点即视为落在下一个字符边界，光标更贴近点击侧
    for (let i = 0; i < last; i++) {
      const start = offsets[i];
      const end = offsets[i + 1];
      if (end <= start) {
        // 零宽度单元（代理对的低代理位或组合符）不参与命中，避免切分码点
        continue;
      }
      if (relativeX < (start + end) / 2) {
        return i;
      }
    }
    return last;
  }
}

// MARK: - 文本块与全文档索引

/** 一个文本块：DOCX 中的正文段落块/表格单元格，或 PPTX 中的一个文本形状 */
export class TextBlockLayout {
  readonly blockIndex: number;
  /** 块所属页面索引（DOCX 固定为 0，PPTX 为 0-based 幻灯片页码） */
  readonly pageIndex: number;
  /** 块在文档全局坐标系下的外接矩形 */
  bounds: TextRect;
  /** 局部坐标映射到文档全局坐标的仿射变换 [a, b, c, d, tx, ty] */
  transform: number[];
  /** 完整拼接后的纯文本（段落之间以换行符分隔） */
  readonly fullText: string;
  /** 内部所有排版行（允许按需懒填充） */
  lines: TextLineMetrics[];

  constructor(
    blockIndex: number,
    pageIndex: number,
    bounds: TextRect,
    transform: number[],
    fullText: string,
    lines: TextLineMetrics[]
  ) {
    this.blockIndex = blockIndex;
    this.pageIndex = pageIndex;
    this.bounds = bounds;
    this.transform = transform;
    this.fullText = fullText;
    this.lines = lines;
  }

  /** 懒填充行几何：占位块在页面进入视口后补齐精确排版结果，块索引保持不变 */
  setLayoutData(bounds: TextRect, transform: number[], lines: TextLineMetrics[]): void {
    this.bounds = bounds;
    this.transform = transform;
    this.lines = lines;
  }

  /** 行几何是否已就绪 */
  hasMeasuredLines(): boolean {
    return this.lines.length > 0;
  }
}

/** 全文档文本空间索引与选区计算引擎 */
export class DocumentTextLayout {
  readonly blocks: TextBlockLayout[];

  constructor(blocks: TextBlockLayout[]) {
    this.blocks = blocks;
  }

  /** 按块索引查找文本块 */
  blockAt(blockIndex: number): TextBlockLayout | null {
    for (const block of this.blocks) {
      if (block.blockIndex === blockIndex) {
        return block;
      }
    }
    return null;
  }

  /** 文本块数量 */
  blockCount(): number {
    return this.blocks.length;
  }

  /** 是否存在可选文本（任一非空 fullText） */
  hasText(): boolean {
    for (const block of this.blocks) {
      if (block.fullText.length > 0) {
        return true;
      }
    }
    return false;
  }

  /**
   * 将文档全局坐标映射为最贴近的字符位置。
   * 优先选中局部扩展包围盒（dx = 8, dy = 4）包含该点的块；
   * 未直接命中时按到各块外接矩形的距离取最近块，保证跨行空白间隙拖选连续不跳断。
   */
  hitTest(docX: number, docY: number): TextPosition | null {
    if (this.blocks.length === 0) {
      return null;
    }
    let bestBlock: TextBlockLayout | null = null;
    let minDistance = Number.POSITIVE_INFINITY;
    for (const block of this.blocks) {
      const localPoint = this.toLocalPoint(block, docX, docY);
      const localLeft = this.localLeft(block);
      const localTop = this.localTop(block);
      const localRight = this.localRight(block);
      const localBottom = this.localBottom(block);
      if (localPoint.x >= localLeft - 8 && localPoint.x <= localRight + 8 &&
        localPoint.y >= localTop - 4 && localPoint.y <= localBottom + 4) {
        bestBlock = block;
        break;
      }
      const dist = distanceToRect(docX, docY, block.bounds);
      if (dist < minDistance) {
        minDistance = dist;
        bestBlock = block;
      }
    }
    if (bestBlock === null || bestBlock.lines.length === 0) {
      return null;
    }
    const localPoint = this.toLocalPoint(bestBlock, docX, docY);
    const localX = localPoint.x;
    const localY = localPoint.y;
    const line = this.resolveNearestLine(bestBlock, localY);
    const relativeX = localX - line.lineX;
    let charIndex = line.charStart + line.charIndexForX(relativeX);
    charIndex = Math.max(line.charStart, Math.min(line.charEnd, charIndex));
    charIndex = clampToCodePointBoundary(bestBlock.fullText, charIndex);
    return makeTextPosition(bestBlock.blockIndex, charIndex);
  }

  /** 长按默认选词：ASCII 字母/数字/下划线连续成词，CJK 连续成段，空白不作为首选词 */
  wordRange(position: TextPosition): TextSelection | null {
    const block = this.blockAt(position.blockIndex);
    if (block === null) {
      return null;
    }
    const text = block.fullText;
    if (text.length === 0) {
      return null;
    }
    let target = Math.max(0, Math.min(position.charIndex, text.length - 1));
    if (target > 0 && isLowSurrogateCode(text.charCodeAt(target)) && isHighSurrogateCode(text.charCodeAt(target - 1))) {
      target -= 1;
    }
    let cls = classifyCode(text.charCodeAt(target));
    if (cls === CODE_CLASS_SPACE) {
      // 空白不作为首选词：优先向前、其次向后寻找最近的词字符
      let found = -1;
      for (let i = target - 1; i >= 0; i--) {
        if (classifyCode(text.charCodeAt(i)) !== CODE_CLASS_SPACE) {
          found = i;
          break;
        }
      }
      if (found < 0) {
        for (let i = target + 1; i < text.length; i++) {
          if (classifyCode(text.charCodeAt(i)) !== CODE_CLASS_SPACE) {
            found = i;
            break;
          }
        }
      }
      if (found < 0) {
        // 整行空白：退化为单个码点选区
        const step = codePointStep(text, target);
        return makeTextSelection(
          makeTextPosition(block.blockIndex, target),
          makeTextPosition(block.blockIndex, Math.min(text.length, target + step))
        );
      }
      target = found;
      cls = classifyCode(text.charCodeAt(target));
    }
    const span = resolveCodeSpan(text, target, cls);
    return makeTextSelection(
      makeTextPosition(block.blockIndex, span.start),
      makeTextPosition(block.blockIndex, span.end)
    );
  }

  /** 整行选区（按行几何边界） */
  lineRange(position: TextPosition): TextSelection | null {
    const block = this.blockAt(position.blockIndex);
    if (block === null) {
      return null;
    }
    for (const line of block.lines) {
      if (position.charIndex >= line.charStart && position.charIndex <= line.charEnd) {
        return makeTextSelection(
          makeTextPosition(block.blockIndex, line.charStart),
          makeTextPosition(block.blockIndex, line.charEnd)
        );
      }
    }
    return null;
  }

  /** 全选范围：首块起始位置到末块末尾位置 */
  allTextRange(): TextSelection | null {
    if (this.blocks.length === 0) {
      return null;
    }
    const first = this.blocks[0];
    const last = this.blocks[this.blocks.length - 1];
    return makeTextSelection(
      makeTextPosition(first.blockIndex, 0),
      makeTextPosition(last.blockIndex, last.fullText.length)
    );
  }

  /** 选区在文档全局坐标系下的所有高亮矩形（按块聚合） */
  selectionRects(selection: TextSelection): BlockHighlightRect[] {
    const result: BlockHighlightRect[] = [];
    if (resolveSelectionEmpty(selection)) {
      return result;
    }
    const start = resolveSelectionStart(selection);
    const end = resolveSelectionEnd(selection);
    for (const block of this.blocks) {
      if (block.blockIndex < start.blockIndex || block.blockIndex > end.blockIndex) {
        continue;
      }
      const startChar = block.blockIndex === start.blockIndex ? start.charIndex : 0;
      const endChar = block.blockIndex === end.blockIndex ? end.charIndex : block.fullText.length;
      this.appendBlockRects(block, startChar, endChar, result);
    }
    return result;
  }

  /** 仅计算指定块内的高亮矩形（供 LazyForEach 子组件只处理自身块） */
  selectionRectsForBlock(selection: TextSelection, blockIndex: number): BlockHighlightRect[] {
    const result: BlockHighlightRect[] = [];
    if (resolveSelectionEmpty(selection)) {
      return result;
    }
    const block = this.blockAt(blockIndex);
    if (block === null) {
      return result;
    }
    const start = resolveSelectionStart(selection);
    const end = resolveSelectionEnd(selection);
    if (blockIndex < start.blockIndex || blockIndex > end.blockIndex) {
      return result;
    }
    const startChar = blockIndex === start.blockIndex ? start.charIndex : 0;
    const endChar = blockIndex === end.blockIndex ? end.charIndex : block.fullText.length;
    this.appendBlockRects(block, startChar, endChar, result);
    return result;
  }

  /** 指定块内的选区高亮矩形（块局部坐标，供子组件 Canvas 直接绘制） */
  blockSelectionRects(selection: TextSelection, blockIndex: number): TextRect[] {
    const result: TextRect[] = [];
    const highlights = this.selectionRectsForBlock(selection, blockIndex);
    for (const highlight of highlights) {
      result.push(highlight.localRect);
    }
    return result;
  }

  /** 选区起止手柄几何（同时给出文档全局与块局部坐标） */
  handleGeometry(selection: TextSelection): SelectionHandles | null {
    const start = this.resolveHandlePoint(resolveSelectionStart(selection));
    const end = this.resolveHandlePoint(resolveSelectionEnd(selection));
    if (start === null || end === null) {
      return null;
    }
    const handles: SelectionHandles = { start: start, end: end };
    return handles;
  }

  /** 提取选区覆盖的纯文本（跨段落与跨块以换行符连接） */
  selectedText(selection: TextSelection): string {
    if (resolveSelectionEmpty(selection)) {
      return '';
    }
    const parts: string[] = [];
    const start = resolveSelectionStart(selection);
    const end = resolveSelectionEnd(selection);
    for (const block of this.blocks) {
      if (block.blockIndex < start.blockIndex || block.blockIndex > end.blockIndex) {
        continue;
      }
      const text = block.fullText;
      if (text.length === 0) {
        continue;
      }
      const startChar = Math.max(0, Math.min(text.length, block.blockIndex === start.blockIndex ? start.charIndex : 0));
      const endChar = Math.max(startChar, Math.min(text.length, block.blockIndex === end.blockIndex ? end.charIndex : text.length));
      if (startChar < endChar) {
        parts.push(text.substring(startChar, endChar));
      }
    }
    return parts.join('\n');
  }

  /** 选区逻辑起点 */
  selectionStart(selection: TextSelection): TextPosition {
    return resolveSelectionStart(selection);
  }

  /** 选区逻辑终点 */
  selectionEnd(selection: TextSelection): TextPosition {
    return resolveSelectionEnd(selection);
  }

  /** 选区是否为空 */
  isSelectionEmpty(selection: TextSelection): boolean {
    return resolveSelectionEmpty(selection);
  }

  /** 将任意索引夹紧到代理对安全边界 */
  clampPosition(position: TextPosition): TextPosition {
    const block = this.blockAt(position.blockIndex);
    if (block === null) {
      return position;
    }
    const charIndex = clampToCodePointBoundary(block.fullText, position.charIndex);
    return makeTextPosition(position.blockIndex, charIndex);
  }

  /** 文档坐标 -> 块局部坐标 */
  private toLocalPoint(block: TextBlockLayout, docX: number, docY: number): PlanePoint {
    const inv = invertAffine(block.transform);
    if (inv === null) {
      const passthrough: PlanePoint = { x: docX, y: docY };
      return passthrough;
    }
    return applyAffineToPoint(inv, docX, docY);
  }

  private localLeft(block: TextBlockLayout): number {
    if (block.lines.length === 0) {
      return 0;
    }
    let value = block.lines[0].left;
    for (const line of block.lines) {
      if (line.left < value) {
        value = line.left;
      }
    }
    return value;
  }

  private localTop(block: TextBlockLayout): number {
    if (block.lines.length === 0) {
      return 0;
    }
    let value = block.lines[0].top;
    for (const line of block.lines) {
      if (line.top < value) {
        value = line.top;
      }
    }
    return value;
  }

  private localRight(block: TextBlockLayout): number {
    if (block.lines.length === 0) {
      return 1;
    }
    let value = block.lines[0].right;
    for (const line of block.lines) {
      if (line.right > value) {
        value = line.right;
      }
    }
    return value;
  }

  private localBottom(block: TextBlockLayout): number {
    if (block.lines.length === 0) {
      return 1;
    }
    let value = block.lines[0].bottom;
    for (const line of block.lines) {
      if (line.bottom > value) {
        value = line.bottom;
      }
    }
    return value;
  }

  /** 在块内查找纵向包含或中线距离最近的行 */
  private resolveNearestLine(block: TextBlockLayout, localY: number): TextLineMetrics {
    let bestLine = block.lines[0];
    let bestDistance = Number.POSITIVE_INFINITY;
    for (const line of block.lines) {
      if (localY >= line.top && localY <= line.bottom) {
        return line;
      }
      const dist = Math.abs(localY - (line.top + line.bottom) / 2);
      if (dist < bestDistance) {
        bestDistance = dist;
        bestLine = line;
      }
    }
    return bestLine;
  }

  /** 追加单个块内落在 [startChar, endChar) 的高亮矩形 */
  private appendBlockRects(
    block: TextBlockLayout,
    startChar: number,
    endChar: number,
    result: BlockHighlightRect[]
  ): void {
    if (block.lines.length === 0 || startChar >= endChar) {
      return;
    }
    const textLength = block.fullText.length;
    const clampedStart = Math.max(0, Math.min(textLength, startChar));
    const clampedEnd = Math.max(clampedStart, Math.min(textLength, endChar));
    if (clampedStart >= clampedEnd) {
      return;
    }
    for (const line of block.lines) {
      const selStart = Math.max(clampedStart, line.charStart);
      const selEnd = Math.min(clampedEnd, line.charEnd);
      if (selStart >= selEnd) {
        continue;
      }
      const localStart = selStart - line.charStart;
      const localEnd = selEnd - line.charStart;
      const x1 = line.horizontalOffset(localStart);
      const x2 = line.horizontalOffset(localEnd);
      const left = line.lineX + Math.min(x1, x2);
      const width = Math.max(1.5, Math.abs(x2 - x1));
      const localRect = makeTextRect(left, line.top, left + width, line.bottom);
      const highlight: BlockHighlightRect = {
        blockIndex: block.blockIndex,
        transform: block.transform,
        localRect: localRect,
        docBounds: transformTextRect(block.transform, localRect)
      };
      result.push(highlight);
    }
  }

  /** 计算单个位置的手柄几何 */
  private resolveHandlePoint(position: TextPosition): HandlePoint | null {
    const block = this.blockAt(position.blockIndex);
    if (block === null || block.lines.length === 0) {
      return null;
    }
    let line: TextLineMetrics | null = null;
    for (const candidate of block.lines) {
      if (position.charIndex >= candidate.charStart && position.charIndex <= candidate.charEnd) {
        line = candidate;
        break;
      }
    }
    if (line === null) {
      let bestDistance = Number.POSITIVE_INFINITY;
      for (const candidate of block.lines) {
        const dist = position.charIndex < candidate.charStart
          ? candidate.charStart - position.charIndex
          : position.charIndex - candidate.charEnd;
        if (dist < bestDistance) {
          bestDistance = dist;
          line = candidate;
        }
      }
    }
    if (line === null) {
      return null;
    }
    const localIndex = Math.max(0, Math.min(line.charEnd - line.charStart, position.charIndex - line.charStart));
    const localX = line.lineX + line.horizontalOffset(localIndex);
    const topPoint = applyAffineToPoint(block.transform, localX, line.top);
    const bottomPoint = applyAffineToPoint(block.transform, localX, line.bottom);
    const handle: HandlePoint = {
      docX: topPoint.x,
      docTopY: topPoint.y,
      docBottomY: bottomPoint.y,
      blockIndex: block.blockIndex,
      localX: localX,
      localTopY: line.top,
      localBottomY: line.bottom
    };
    return handle;
  }
}

/** 解析 target 所在码元类别的连续区间 */
function resolveCodeSpan(text: string, target: number, cls: number): CodeSpan {
  let start = target;
  while (start > 0) {
    let prev = start - 1;
    if (prev > 0 && isLowSurrogateCode(text.charCodeAt(prev)) && isHighSurrogateCode(text.charCodeAt(prev - 1))) {
      prev -= 1;
    }
    if (classifyCode(text.charCodeAt(prev)) !== cls) {
      break;
    }
    start = prev;
  }
  let end = target + codePointStep(text, target);
  while (end < text.length) {
    if (classifyCode(text.charCodeAt(end)) !== cls) {
      break;
    }
    end += codePointStep(text, end);
  }
  const span: CodeSpan = { start: start, end: end };
  return span;
}
