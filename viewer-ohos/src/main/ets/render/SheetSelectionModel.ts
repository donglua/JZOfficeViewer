/**
 * XLSX 二维网格选区模型（HarmonyOS）：纯 TypeScript 逻辑，零 ArkUI、零 @kit.*、零 import 依赖。
 *
 * 本模块是设计文档 `docs/superpowers/specs/2026-11-18-xlsx-selection-copy-design.md`
 * §3.1 的鸿蒙端实现，与 Android `SheetSelectionModel.java`、macOS `SheetSelectionModel.swift`
 * 逐条语义一致，并由 `scripts/tests/SheetSelectionChecks.ts` 用 node 原生 TS 直接执行验证
 * （因此本文件不得出现任何 `import`，也不得引用只有 `.ets` 才能提供的类型）。
 *
 * 覆盖的能力：
 * 1. 坐标 {@link CellCoord} 与选区 {@link SheetSelection}：保留锚点/焦点，导出规范化边界；
 * 2. 合并单元格不动点闭包扩张 {@link resolve}：选区与任何合并区域相交即并入其完整范围；
 * 3. 冻结窗格命中测试 {@link hitTest}：按冻结边界消解滚动偏移，锁定轴不叠加滚动量；
 * 4. 全选范围 {@link allRange}：仅当工作表存在非空文本单元格时给出首个到末个可见单元格；
 * 5. TSV 格式化 {@link selectedText}：跳过隐藏行列、合并从属位置留空、按 RFC 4180 转义。
 *
 * <p><b>坐标约定</b>：轴前缀和 {@link SelectionAxis.offsets} 已把外围标头（gutter）计入
 * `offsets[0]`，因此 {@link docRect} 返回的矩形含标头偏移，{@link hitTest} 也以
 * 「含标头原点的视图数据坐标」为输入。鸿蒙端 `SheetLayoutData` 的前缀和本身不含 gutter，
 * 视图层需自带 gutter 偏移后再喂给本模型（见 `SpreadsheetView.selectionLayoutOf`）。
 *
 * <p><b>命中测试的单位约定</b>：{@link hitTest} 的全部浮点入参处于同一套「视图数据坐标」——
 * 调用方已把屏幕坐标除以当前缩放（scale），使 1 单位等于 1 个文档单位。因此模型层
 * 无需知道缩放值，也不会因缩放引入舍入偏差。表头宽度/高度直接从
 * `layout.columns.offsets[0]` 与 `layout.rows.offsets[0]` 取得，与各端的
 * HEADER_WIDTH / HEADER_HEIGHT 常量天然同步（鸿蒙与 macOS 为 42/22，Android 为 42/20）。
 */

/** 拖拽到表格外缘继续扩选时的钳位留白，避免落在末列/末行的开区间边界上 */
export const EDGE_EPSILON = 0.01;

/** TSV 单元格转义时需要用双引号包裹的字符集合判定 */
export const TSV_ESCAPE_CHARS = '\t\n\r"';

// ---------------------------------------------------------------------------
// 视觉常量（设计文档 §3.2.1）：与渲染层共享，避免同一套色值在两处漂移
// ---------------------------------------------------------------------------

/** 选区填充：15% 透明度 Google Blue，叠在单元格文本之上仍可辨认 */
export const SELECTION_FILL_COLOR = '#261A73E8';

/** 选区描边：不透明 Google Blue，线宽按缩放换算以保持固定物理观感 */
export const SELECTION_STROKE_COLOR = '#FF1A73E8';

/** 选区描边物理线宽（vp）：绘制时除以缩放，各缩放级别视觉粗细恒定（Android 为 1.5f / scale） */
export const SELECTION_STROKE_WIDTH = 1.5;

/** 命中选区的列标/行号标头背景色 */
export const HEADER_SELECTED_COLOR = '#D2E3FC';

/** 命中选区的列标/行号标头文字色，配合加粗形成联动反馈 */
export const HEADER_SELECTED_TEXT_COLOR = '#174EA6';

/** 对角拖拽手柄半径（vp，固定物理尺寸，不随缩放变化） */
export const SELECTION_HANDLE_RADIUS = 6;

/** 对角拖拽手柄的触控热区半径（vp），略大于视觉半径以便手指按住 */
export const SELECTION_HANDLE_TOUCH_RADIUS = 24;

/** 对角拖拽手柄的白色描边宽度（vp） */
export const SELECTION_HANDLE_STROKE_WIDTH = 1.5;

// ---------------------------------------------------------------------------
// 结构输入类型
// ---------------------------------------------------------------------------

/**
 * 工作表单元格的最小结构形状。
 * 用结构类型而非直接引用 `OfficeModel.Cell`：`OfficeModel.ets` 是 `.ets` 文件，
 * 纯 TS 模型若依赖它就无法被 node 直接执行做纯逻辑回归；结构类型同时保证
 * `model.Sheet` 的对象可以直接赋值进来。
 */
export interface SelectionCell {
  row: number;
  column: number;
  text: string;
}

/** 合并单元格区域的最小结构形状（对齐 `OfficeModel.CellRange`） */
export interface SelectionCellRange {
  startRow: number;
  startColumn: number;
  endRow: number;
  endColumn: number;
}

/**
 * 工作表的最小结构形状：`model.Sheet` 可直接赋值给本接口（结构兼容），
 * 但本文件不感知 `geometry` / `frozenRows` 等与本模型无关的字段。
 */
export interface SelectionSheet {
  rowHeights: number[];
  columnWidths: number[];
  cells: SelectionCell[];
  merges: SelectionCellRange[];
}

/** 单轴前缀和与可见索引（对齐 Java `SheetLayout.Axis`，offsets[0] 已含标头 gutter） */
export interface SelectionAxis {
  offsets: number[];
  visible: number[];
}

/**
 * 工作表布局的最小结构形状：`rowStarts` 为按行分段的稀疏单元格索引起始位置，
 * 允许 `number[]` 或 `Int32Array`（鸿蒙端 `SheetLayoutData` 用后者避免大表内存占用）。
 */
export interface SelectionLayout {
  rows: SelectionAxis;
  columns: SelectionAxis;
  rowStarts: number[] | Int32Array;
}

// ---------------------------------------------------------------------------
// 基础值类型
// ---------------------------------------------------------------------------

/** 工作表单元格坐标：`row` 与 `column` 均为 0 基 */
export interface CellCoord {
  row: number;
  column: number;
}

/**
 * 矩形选区：保留用户按下的锚点与浮动的焦点，支持反向拖选（焦点可以越过锚点）。
 *
 * `startRow` / `startColumn` / `endRow` / `endColumn` 为 anchor 与 focus 张成的
 * 规范化闭区间边界，且已并入所有相交合并区域，因此可直接用于高亮绘制与 TSV 遍历，
 * 无需再次计算。
 */
export interface SheetSelection {
  anchor: CellCoord;
  focus: CellCoord;
  startRow: number;
  startColumn: number;
  endRow: number;
  endColumn: number;
}

/** 文档坐标下的矩形（含外围标头偏移），左闭右开 */
export interface CellRect {
  left: number;
  top: number;
  right: number;
  bottom: number;
}

/** 构造坐标：负数按 0 处理，与 Java `CellCoord` 构造器的钳位行为一致 */
export function createCoord(row: number, column: number): CellCoord {
  return { row: Math.max(0, row), column: Math.max(0, column) };
}

/**
 * 构造选区：`start*` / `end*` 一并做 min/max 规范化，`anchor` 为空时退化为 (0,0)、
 * `focus` 为空时退化为 `anchor`，与 Java `SheetSelection` 两个构造器的合并语义一致。
 */
export function createSelection(
  anchor: CellCoord | null,
  focus: CellCoord | null,
  startRow: number,
  startColumn: number,
  endRow: number,
  endColumn: number
): SheetSelection {
  const safeAnchor: CellCoord = anchor === null ? createCoord(0, 0) : anchor;
  const safeFocus: CellCoord = focus === null ? safeAnchor : focus;
  return {
    anchor: safeAnchor,
    focus: safeFocus,
    startRow: Math.min(startRow, endRow),
    startColumn: Math.min(startColumn, endColumn),
    endRow: Math.max(startRow, endRow),
    endColumn: Math.max(startColumn, endColumn)
  };
}

/** 由单个坐标构造单格选区（对齐 Java `SheetSelection(CellCoord)` 构造器） */
export function createSingleCellSelection(coord: CellCoord): SheetSelection {
  return createSelection(coord, coord, coord.row, coord.column, coord.row, coord.column);
}

/** 两个坐标是否指向同一单元格（替代 Java 的 `CellCoord.equals`） */
export function coordEquals(a: CellCoord | null, b: CellCoord | null): boolean {
  if (a === null || b === null) return a === b;
  return a.row === b.row && a.column === b.column;
}

/** 两个选区的规范化边界是否一致（替代 Java 的 `SheetSelection.equals`，供「是否已全选」判定） */
export function selectionEquals(a: SheetSelection | null, b: SheetSelection | null): boolean {
  if (a === null || b === null) return a === b;
  return a.startRow === b.startRow && a.startColumn === b.startColumn
    && a.endRow === b.endRow && a.endColumn === b.endColumn;
}

/** 选区覆盖的行数 */
export function selectionRowCount(selection: SheetSelection): number {
  return selection.endRow - selection.startRow + 1;
}

/** 选区覆盖的列数 */
export function selectionColumnCount(selection: SheetSelection): number {
  return selection.endColumn - selection.startColumn + 1;
}

/** 是否恰好覆盖单个坐标（尚未做合并闭包扩张的原始判定） */
export function selectionIsSingleCell(selection: SheetSelection): boolean {
  return selection.startRow === selection.endRow && selection.startColumn === selection.endColumn;
}

/** 选区是否覆盖指定单元格 */
export function selectionCovers(selection: SheetSelection, row: number, column: number): boolean {
  return row >= selection.startRow && row <= selection.endRow
    && column >= selection.startColumn && column <= selection.endColumn;
}

/** 行索引是否落在选区行范围内，供外围行号标头联动高亮 */
export function selectionContainsRow(selection: SheetSelection, row: number): boolean {
  return row >= selection.startRow && row <= selection.endRow;
}

/** 列索引是否落在选区列范围内，供外围列标（A/B/C）联动高亮 */
export function selectionContainsColumn(selection: SheetSelection, column: number): boolean {
  return column >= selection.startColumn && column <= selection.endColumn;
}

/**
 * 选区是否为空：规范化后的选区至少覆盖一个单元格，因此仅在无选区（null）时为真。
 * 视图层用它把「无选区」与「有选区」两条绘制分支统一成一次判定。
 */
export function selectionIsEmpty(selection: SheetSelection | null): boolean {
  return selection === null;
}

/** 文档矩形宽度 */
export function rectWidth(rect: CellRect): number {
  return rect.right - rect.left;
}

/** 文档矩形高度 */
export function rectHeight(rect: CellRect): number {
  return rect.bottom - rect.top;
}

/** 文档矩形是否退化为零面积（右/下边界不大于左/上边界） */
export function rectIsEmpty(rect: CellRect): boolean {
  return rect.right <= rect.left || rect.bottom <= rect.top;
}

// ---------------------------------------------------------------------------
// 合并单元格不动点闭包扩张
// ---------------------------------------------------------------------------

/**
 * 由锚点与焦点解析出选区，并把所有与选区相交的合并区域并入边界，直到一轮遍历不再变化。
 *
 * 这是「不动点闭包」的关键：合并区域之间的相邻关系可能串联（A 并入 B 后 B 又与新并入的
 * 区域相交），因此必须循环到稳定为止，单轮遍历只能覆盖一层（设计文档 §3.1.1）。
 * 闭包保证选区内不存在被合并区域「切开」的残缺单元格，高亮矩形与 TSV 网格才是
 * 用户看到的完整形状。
 *
 * @param sheet  工作表；`merges` 为空时退化为普通矩形选区
 * @param anchor 按下时的单元格
 * @param focus  当前浮动端单元格
 * @returns 已扩张到不动点的选区；`anchor` 或 `focus` 为 null 时返回 null
 */
export function resolve(
  sheet: SelectionSheet | null,
  anchor: CellCoord | null,
  focus: CellCoord | null
): SheetSelection | null {
  if (anchor === null || focus === null) return null;
  let startRow = Math.min(anchor.row, focus.row);
  let endRow = Math.max(anchor.row, focus.row);
  let startColumn = Math.min(anchor.column, focus.column);
  let endColumn = Math.max(anchor.column, focus.column);
  if (sheet !== null && sheet.merges.length > 0) {
    const merges: SelectionCellRange[] = sheet.merges;
    let changed = true;
    while (changed) {
      changed = false;
      for (let i = 0; i < merges.length; i++) {
        const merge: SelectionCellRange = merges[i];
        // 与当前矩形不相交则跳过（闭区间相交判定）
        if (merge.startRow > endRow || merge.endRow < startRow
          || merge.startColumn > endColumn || merge.endColumn < startColumn) continue;
        const nextStartRow = Math.min(startRow, merge.startRow);
        const nextEndRow = Math.max(endRow, merge.endRow);
        const nextStartColumn = Math.min(startColumn, merge.startColumn);
        const nextEndColumn = Math.max(endColumn, merge.endColumn);
        if (nextStartRow !== startRow || nextEndRow !== endRow
          || nextStartColumn !== startColumn || nextEndColumn !== endColumn) {
          startRow = nextStartRow;
          endRow = nextEndRow;
          startColumn = nextStartColumn;
          endColumn = nextEndColumn;
          changed = true;
        }
      }
    }
  }
  return createSelection(anchor, focus, startRow, startColumn, endRow, endColumn);
}

/**
 * 选区是否恰好等于一个逻辑单元格：单格，或与某个合并区域完全重合。
 *
 * 逻辑单格直接输出单元格文本（不输出网格），这样复制一个合并单元格得到的是
 * 一行文本而不是带尾随制表符的网格（设计文档 §3.1.3）。
 */
export function isSingleLogicalCell(sheet: SelectionSheet | null, selection: SheetSelection | null): boolean {
  if (selection === null) return false;
  if (selectionIsSingleCell(selection)) return true;
  if (sheet === null) return false;
  const merges: SelectionCellRange[] = sheet.merges;
  for (let i = 0; i < merges.length; i++) {
    const merge: SelectionCellRange = merges[i];
    if (merge.startRow === selection.startRow && merge.endRow === selection.endRow
      && merge.startColumn === selection.startColumn && merge.endColumn === selection.endColumn) {
      return true;
    }
  }
  return false;
}

/**
 * 覆盖给定坐标的合并区域。
 *
 * @returns 未被任何合并区域覆盖时返回 null
 */
export function mergeAt(sheet: SelectionSheet | null, row: number, column: number): SelectionCellRange | null {
  if (sheet === null) return null;
  const merges: SelectionCellRange[] = sheet.merges;
  for (let i = 0; i < merges.length; i++) {
    const merge: SelectionCellRange = merges[i];
    if (row >= merge.startRow && row <= merge.endRow
      && column >= merge.startColumn && column <= merge.endColumn) {
      return merge;
    }
  }
  return null;
}

// ---------------------------------------------------------------------------
// 冻结窗格命中测试
// ---------------------------------------------------------------------------

/**
 * 读取 `rowStarts` 的单个元素：统一 `number[]` 与 `Int32Array` 两种承载方式。
 * 用 `instanceof` 收窄联合类型（与 `RenderUtils` 判断 `Uint8Array` 的写法一致），
 * 两个分支各自是具体数组类型，可安全取下标。
 */
function readStart(starts: number[] | Int32Array, index: number): number {
  if (index < 0 || index >= starts.length) return -1;
  if (starts instanceof Int32Array) {
    return starts[index];
  }
  const list: number[] = starts;
  return list[index];
}

/** 单个轴的数据总长（不含表头 gutter），对齐 Java `dataExtent` */
function dataExtent(axis: SelectionAxis): number {
  if (axis.offsets.length === 0) return 0;
  const last = axis.offsets[axis.offsets.length - 1];
  const first = axis.offsets[0];
  return Math.max(0, last - first);
}

/**
 * 在轴上二分定位 `position` 所属的可见段下标（对齐 Java `SheetLayout.Axis.first`）：
 * 找到第一个使 `offsets[visible[i] + 1] > position` 的 i，返回 i 本身（可能等于可见段数）。
 */
function axisFirst(axis: SelectionAxis, position: number): number {
  let low = 0;
  let high = axis.visible.length;
  while (low < high) {
    const middle = (low + high) >>> 1;
    const visibleIndex = axis.visible[middle];
    const edge = axis.offsets[visibleIndex + 1];
    if (edge <= position) {
      low = middle + 1;
    } else {
      high = middle;
    }
  }
  return low;
}

/**
 * 在轴上二分定位 `data` 偏移对应的行列索引。
 *
 * 先把「数据偏移」还原成轴偏移（补回表头 gutter），再复用二分实现；超出可见范围时
 * 钳位到首/末可见索引，保证拖出边缘仍有稳定命中结果（设计文档 §3.1.2 第 3 条）。
 */
function axisIndex(axis: SelectionAxis, data: number, gutter: number): number {
  let index = axisFirst(axis, gutter + data);
  if (index < 0) index = 0;
  if (index >= axis.visible.length) index = axis.visible.length - 1;
  return index < 0 ? -1 : axis.visible[index];
}

/**
 * 把视图触点映射为单元格坐标，按冻结边界消解滚动偏移（设计文档 §3.1.2）。
 *
 * 规则：
 * 1. 触点落在外围标头内直接返回 null；
 * 2. 冻结列区内（`bodyX < frozenDataW`）X 轴不叠加滚动量，否则叠加 `scrollDataX`；
 * 3. Y 轴同理；
 * 4. 换算后的数据坐标越界时，按 `clampToBounds` 决定返回 null 还是钳位到表格边缘
 *    （拖拽扩选需要后者持续贴边扩展）。
 *
 * 参数顺序与 Java 参考实现完全一致，视图层调用点因此可以逐字对照。
 *
 * @param layout        当前工作表布局，提供 axes 与表头 gutter
 * @param effFrozenRows 本帧生效的冻结行数（已过视口占比保护）
 * @param effFrozenCols 本帧生效的冻结列数（已过视口占比保护）
 * @param frozenDataW   冻结列区宽度（视图数据坐标，未冻结时传 0）
 * @param frozenDataH   冻结行区高度（视图数据坐标，未冻结时传 0）
 * @param scrollDataX   水平滚动量（视图数据坐标，>= 0）
 * @param scrollDataY   垂直滚动量（视图数据坐标，>= 0）
 * @param viewX         触点 X（视图数据坐标，含标头原点）
 * @param viewY         触点 Y（视图数据坐标，含标头原点）
 * @param clampToBounds 越界时是否钳位到表格边缘
 * @returns 命中的单元格坐标；越界且不钳位、或工作表为空时返回 null
 */
export function hitTest(
  layout: SelectionLayout | null,
  effFrozenRows: number,
  effFrozenCols: number,
  frozenDataW: number,
  frozenDataH: number,
  scrollDataX: number,
  scrollDataY: number,
  viewX: number,
  viewY: number,
  clampToBounds: boolean
): CellCoord | null {
  if (layout === null) return null;
  if (layout.columns.visible.length === 0 || layout.rows.visible.length === 0) return null;
  if (layout.columns.offsets.length === 0 || layout.rows.offsets.length === 0) return null;
  if (Number.isNaN(viewX) || Number.isNaN(viewY)) return null;
  const headerWidth = layout.columns.offsets[0];
  const headerHeight = layout.rows.offsets[0];
  // 触点落在外围行列标头内：不产生单元格命中，交给标头自身的联动高亮处理
  if (viewX < headerWidth || viewY < headerHeight) return null;
  const bodyX = viewX - headerWidth;
  const bodyY = viewY - headerHeight;

  const totalWidth = dataExtent(layout.columns);
  const totalHeight = dataExtent(layout.rows);

  // 冻结区内该轴不叠加滚动量，滚动区照常叠加；两轴独立判断
  let dataX = effFrozenCols > 0 && bodyX < frozenDataW ? bodyX : bodyX + Math.max(0, scrollDataX);
  let dataY = effFrozenRows > 0 && bodyY < frozenDataH ? bodyY : bodyY + Math.max(0, scrollDataY);

  if (dataX < 0 || dataX >= totalWidth || dataY < 0 || dataY >= totalHeight) {
    if (!clampToBounds) return null;
    dataX = Math.min(Math.max(0, dataX), Math.max(0, totalWidth - EDGE_EPSILON));
    dataY = Math.min(Math.max(0, dataY), Math.max(0, totalHeight - EDGE_EPSILON));
  }

  const row = axisIndex(layout.rows, dataY, headerHeight);
  const column = axisIndex(layout.columns, dataX, headerWidth);
  if (row < 0 || column < 0) return null;
  return createCoord(row, column);
}

// ---------------------------------------------------------------------------
// 全选范围
// ---------------------------------------------------------------------------

/** 工作表是否至少存在一个非空文本单元格 */
function hasAnyText(sheet: SelectionSheet): boolean {
  const cells: SelectionCell[] = sheet.cells;
  for (let i = 0; i < cells.length; i++) {
    const cell: SelectionCell = cells[i];
    if (cell.text !== null && cell.text !== undefined && cell.text.length > 0) return true;
  }
  return false;
}

/**
 * 计算工作表的全选范围：首个可见单元格到末个可见单元格（设计文档 §3.1.3 第 1 条）。
 *
 * 只有当工作表至少存在一个非空文本单元格时才可全选；否则 `selectAll()` 应当返回 false，
 * 避免对空白表建立无意义的整表选区。
 *
 * @returns 不可全选或没有可见行列时返回 null
 */
export function allRange(sheet: SelectionSheet | null, layout: SelectionLayout | null): SheetSelection | null {
  if (sheet === null || layout === null) return null;
  if (layout.rows.visible.length === 0 || layout.columns.visible.length === 0) return null;
  if (!hasAnyText(sheet)) return null;
  const firstRow = layout.rows.visible[0];
  const lastRow = layout.rows.visible[layout.rows.visible.length - 1];
  const firstColumn = layout.columns.visible[0];
  const lastColumn = layout.columns.visible[layout.columns.visible.length - 1];
  // 整表范围几乎必然与合并区域相交，同样走闭包扩张以对齐边界语义
  return resolve(sheet, createCoord(firstRow, firstColumn), createCoord(lastRow, lastColumn));
}

// ---------------------------------------------------------------------------
// 选区几何
// ---------------------------------------------------------------------------

/**
 * 选区在文档坐标下的外接矩形（含外围标头偏移），供渲染层绘制填充与描边。
 *
 * 合并闭包已把边界并入完整合并区域，因此矩形天然覆盖被合并的整块，不会切掉一半。
 *
 * @returns 工作表为空或范围越界时返回 null（不抛异常，避免渲染层数组越界）
 */
export function docRect(layout: SelectionLayout | null, selection: SheetSelection | null): CellRect | null {
  if (layout === null || selection === null) return null;
  return resolveRangeRect(layout, selection.startRow, selection.startColumn, selection.endRow, selection.endColumn);
}

/**
 * 合并区域在文档坐标下的外接矩形，供渲染层按合并区域裁剪绘制。
 *
 * @returns 合并区域越界时返回 null
 */
export function mergeDocRect(layout: SelectionLayout | null, merge: SelectionCellRange | null): CellRect | null {
  if (layout === null || merge === null) return null;
  return resolveRangeRect(layout, merge.startRow, merge.startColumn, merge.endRow, merge.endColumn);
}

/** 闭区间行列范围 → 文档矩形的公共实现（选区与合并区域共用同一套坐标） */
function resolveRangeRect(
  layout: SelectionLayout,
  startRow: number,
  startColumn: number,
  endRow: number,
  endColumn: number
): CellRect | null {
  const rowCount = layout.rows.offsets.length - 1;
  const columnCount = layout.columns.offsets.length - 1;
  if (startRow < 0 || endRow >= rowCount || startColumn < 0 || endColumn >= columnCount) {
    return null;
  }
  return {
    left: layout.columns.offsets[startColumn],
    top: layout.rows.offsets[startRow],
    right: layout.columns.offsets[endColumn + 1],
    bottom: layout.rows.offsets[endRow + 1]
  };
}

// ---------------------------------------------------------------------------
// TSV 格式化
// ---------------------------------------------------------------------------

/**
 * 把选区导出为 Tab 分隔文本（TSV）。
 *
 * 输出规则（设计文档 §3.1.3 第 2 条）：
 * 1. 逻辑单格（含单合并格）直接返回该单元格文本，不带任何制表符或换行；
 * 2. 多格区域按行优先拼接：同行可见列之间以 `"\t"` 分隔，行之间以 `"\n"` 分隔；
 * 3. 隐藏行（高度 <= 0）与隐藏列（宽度 <= 0）整条跳过，因此隐藏列不会被复制出空列，
 *    更不会留下多余制表符；
 * 4. 合并区域的非锚点位置输出空串，保持矩形网格的列数对齐；
 * 5. 含制表符、换行或双引号的文本按 RFC 4180 用双引号包裹并把内部引号翻倍；
 * 6. 整个选区没有任何非空文本时返回 `""`，避免复制出纯空白网格。
 *
 * @returns 无选区时返回 `""`
 */
export function selectedText(
  sheet: SelectionSheet | null,
  layout: SelectionLayout | null,
  selection: SheetSelection | null
): string {
  if (sheet === null || layout === null || selection === null) return '';
  if (isSingleLogicalCell(sheet, selection)) {
    const single = cellTextAt(sheet, layout, selection.startRow, selection.startColumn);
    return single === null ? '' : single;
  }
  const rowCount = sheet.rowHeights.length;
  const columnCount = sheet.columnWidths.length;
  let result = '';
  let hasContent = false;
  let firstRow = true;
  for (let row = selection.startRow; row <= selection.endRow; row++) {
    // 隐藏行整行跳过：既不出文本也不出换行，与 Excel 复制可见区域的行为一致
    if (row < 0 || row >= rowCount || sheet.rowHeights[row] <= 0) continue;
    // 行间换行只在真正输出了一行之后补，避免隐藏行把换行提前推出去
    if (!firstRow) result += '\n';
    let firstColumn = true;
    for (let column = selection.startColumn; column <= selection.endColumn; column++) {
      // 隐藏列整列跳过，且不计入制表符数量
      if (column < 0 || column >= columnCount || sheet.columnWidths[column] <= 0) continue;
      if (!firstColumn) result += '\t';
      firstColumn = false;
      const merge = mergeAt(sheet, row, column);
      if (merge !== null && (row !== merge.startRow || column !== merge.startColumn)) {
        // 合并区域的从属位置留空，保证网格矩形对齐
        continue;
      }
      const text = cellTextAt(sheet, layout, row, column);
      const escaped = formatTsvCell(text);
      if (escaped.length > 0) hasContent = true;
      result += escaped;
    }
    firstRow = false;
  }
  return hasContent ? result : '';
}

/**
 * TSV 单元格转义：仅当文本含制表符、换行、回车或双引号时按 RFC 4180 / Excel 规范包裹。
 *
 * @returns 空文本返回 `""`；null 与 undefined 同样按空文本处理
 */
export function formatTsvCell(text: string | null | undefined): string {
  if (text === null || text === undefined || text.length === 0) return '';
  let escape = false;
  for (let i = 0; i < text.length; i++) {
    if (TSV_ESCAPE_CHARS.indexOf(text.charAt(i)) >= 0) {
      escape = true;
      break;
    }
  }
  if (!escape) return text;
  let quoted = '"';
  for (let i = 0; i < text.length; i++) {
    const value = text.charAt(i);
    if (value === '"') quoted += '"';
    quoted += value;
  }
  return quoted + '"';
}

/**
 * 查找指定坐标的单元格文本。
 *
 * 先按 `rowStarts` 对该行做二分定位，再在该行的稀疏单元格序列中线性扫描列；
 * 单行内的列数远小于整表单元格数，因此整体代价为 O(log R + K)。
 *
 * @returns 该位置没有单元格时返回 null
 */
export function cellTextAt(
  sheet: SelectionSheet | null,
  layout: SelectionLayout | null,
  row: number,
  column: number
): string | null {
  const cell = cellAt(sheet, layout, row, column);
  return cell === null ? null : cell.text;
}

/** 查找指定坐标的单元格对象，未命中返回 null。实现与 Java `cellAt` 逐条一致。 */
export function cellAt(
  sheet: SelectionSheet | null,
  layout: SelectionLayout | null,
  row: number,
  column: number
): SelectionCell | null {
  if (sheet === null || layout === null || row < 0 || column < 0) return null;
  const starts: number[] | Int32Array = layout.rowStarts;
  if (row + 1 >= starts.length) return null;
  const cells: SelectionCell[] = sheet.cells;
  const rowStart = readStart(starts, row);
  const rowEnd = readStart(starts, row + 1);
  if (rowStart < 0 || rowEnd < 0) return null;
  const high = Math.min(rowEnd, cells.length);
  const begin = Math.max(0, firstCellInRow(cells, rowStart, high, column));
  for (let i = begin; i < high; i++) {
    const cell: SelectionCell = cells[i];
    if (cell.column === column) return cell;
    if (cell.column > column) break;
  }
  return null;
}

/**
 * 行内二分：在 `[low, high)` 区间内找到第一个列号 >= `column` 的单元格下标。
 * 与 Java `SheetLayout.firstCell` 完全等价，只是把 `high` 收敛到单元格总数以避免
 * core 字段与单元格数量不一致时的越界读取。
 */
function firstCellInRow(cells: SelectionCell[], low: number, high: number, column: number): number {
  let start = low;
  let end = high;
  while (start < end) {
    const middle = (start + end) >>> 1;
    const cell: SelectionCell = cells[middle];
    if (cell.column < column) {
      start = middle + 1;
    } else {
      end = middle;
    }
  }
  return start;
}
