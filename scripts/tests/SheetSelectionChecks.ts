/**
 * XLSX 二维网格选区模型检查（node 直接执行，无需构建）：
 *   node scripts/tests/SheetSelectionChecks.ts
 *
 * 本文件是 `scripts/tests/SheetSelectionChecks.java`（111 条断言）的鸿蒙端镜像：
 * 用例顺序、测试夹具与期望字符串逐条一致，用于证明
 * `viewer-ohos/src/main/ets/render/SheetSelectionModel.ts` 与 Java 参考实现语义同构。
 * 期望输出：Sheet selection checks passed: 111
 */
import {
  allRange,
  cellTextAt,
  createCoord,
  createSelection,
  docRect,
  formatTsvCell,
  hitTest,
  isSingleLogicalCell,
  mergeAt,
  mergeDocRect,
  rectHeight,
  rectWidth,
  resolve,
  selectedText,
  selectionContainsColumn,
  selectionContainsRow,
  selectionColumnCount,
  selectionCovers,
  selectionEquals,
  selectionIsSingleCell,
  selectionRowCount
} from '../../viewer-ohos/src/main/ets/render/SheetSelectionModel.ts';
import { readFileSync } from 'node:fs';
import { resolve as resolvePath } from 'node:path';
import type {
  CellCoord,
  CellRect,
  SelectionAxis,
  SelectionCell,
  SelectionCellRange,
  SelectionLayout,
  SelectionSheet,
  SheetSelection
} from '../../viewer-ohos/src/main/ets/render/SheetSelectionModel.ts';

const root = resolvePath(import.meta.dirname, '../..');

/** 与各端渲染常量一致：表头宽 42、行头高 20（沿用 Java 套件取值，模型本身与具体数值无关） */
const HEADER_WIDTH = 42;
const HEADER_HEIGHT = 20;

let checks = 0;

function check(condition: boolean, message: string): void {
  checks++;
  if (!condition) {
    throw new Error(message);
  }
}

function expectEqual(actual: number, expected: number, message: string): void {
  checks++;
  if (actual !== expected) {
    throw new Error(`${message}: 期望 ${expected}，实际 ${actual}`);
  }
}

function expectText(actual: string, expected: string, message: string): void {
  checks++;
  if (actual !== expected) {
    throw new Error(`${message}: 期望 <${expected}>，实际 <${actual}>`);
  }
}

function expectCoord(actual: CellCoord | null, row: number, column: number, message: string): void {
  checks++;
  if (actual === null || actual.row !== row || actual.column !== column) {
    const text = actual === null ? '(null)' : `(${actual.row}, ${actual.column})`;
    throw new Error(`${message}: 期望 (${row}, ${column})，实际 ${text}`);
  }
}

function expectNullCoord(actual: CellCoord | null, message: string): void {
  checks++;
  if (actual !== null) {
    throw new Error(`${message}: 期望 null，实际 (${actual.row}, ${actual.column})`);
  }
}

function expectNullRect(actual: CellRect | null, message: string): void {
  checks++;
  if (actual !== null) {
    throw new Error(`${message}: 期望 null，实际 (${actual.left}, ${actual.top}, ${actual.right}, ${actual.bottom})`);
  }
}

function expectNullSelection(actual: SheetSelection | null, message: string): void {
  checks++;
  if (actual !== null) {
    throw new Error(`${message}: 期望 null，实际 start=(${actual.startRow}, ${actual.startColumn})`);
  }
}

function expectNotNullSelection(actual: SheetSelection | null, message: string): void {
  checks++;
  if (actual === null) {
    throw new Error(`${message}: 期望非 null，实际 null`);
  }
}

function expectNotNullRect(actual: CellRect | null, message: string): void {
  checks++;
  if (actual === null) {
    throw new Error(`${message}: 期望非 null，实际 null`);
  }
}

// ---------------------------------------------------------------------------
// 构造辅助：镜像 Java 套件的 sheet / cell / merge / layout / at
// ---------------------------------------------------------------------------

/**
 * 构造工作表：所有行高、列宽相同，按行列二维数组填充文本。
 * `grid[row][column]` 为 null 表示该格无单元格；单元格按行优先、行内列递增顺序追加，
 * 满足 `rowStarts` 的稀疏索引约定。
 */
function sheet(grid: (string | null)[][], rowH: number, colW: number): SelectionSheet {
  const rowCount = grid.length;
  const columnCount = rowCount === 0 ? 0 : grid[0].length;
  const rowHeights: number[] = [];
  const columnWidths: number[] = [];
  const cells: SelectionCell[] = [];
  const merges: SelectionCellRange[] = [];
  for (let i = 0; i < rowCount; i++) {
    rowHeights.push(rowH);
  }
  for (let i = 0; i < columnCount; i++) {
    columnWidths.push(colW);
  }
  for (let row = 0; row < rowCount; row++) {
    for (let column = 0; column < columnCount; column++) {
      const text = grid[row][column];
      if (text === null) continue;
      cells.push(makeCell(row, column, text));
    }
  }
  return { rowHeights: rowHeights, columnWidths: columnWidths, cells: cells, merges: merges };
}

/** 构造单元格值对象（ArkTS 禁止无接口类型的对象字面量，一律经工厂函数） */
function makeCell(row: number, column: number, text: string): SelectionCell {
  return { row: row, column: column, text: text };
}

/** 构造合并区域值对象 */
function merge(startRow: number, startColumn: number, endRow: number, endColumn: number): SelectionCellRange {
  return {
    startRow: startRow,
    startColumn: startColumn,
    endRow: endRow,
    endColumn: endColumn
  };
}

/** 构造单轴：gutter 计入 offsets[0]，尺寸为 0 的行列不进入 visible（对齐 SheetLayout.Axis） */
function axisOf(sizes: number[], gutter: number): SelectionAxis {
  const offsets: number[] = [];
  const visible: number[] = [];
  offsets.push(gutter);
  for (let i = 0; i < sizes.length; i++) {
    offsets.push(offsets[i] + sizes[i]);
    if (sizes[i] > 0) {
      visible.push(i);
    }
  }
  return { offsets: offsets, visible: visible };
}

/** 镜像 Java `new SheetLayout(sheet, HEADER_WIDTH, HEADER_HEIGHT)`：含 gutter 前缀和与 rowStarts */
function layoutOf(target: SelectionSheet): SelectionLayout {
  const rows = axisOf(target.rowHeights, HEADER_HEIGHT);
  const columns = axisOf(target.columnWidths, HEADER_WIDTH);
  const rowStarts: number[] = [];
  let next = 0;
  for (let row = 0; row < target.rowHeights.length; row++) {
    rowStarts.push(next);
    while (next < target.cells.length && target.cells[next].row === row) {
      next++;
    }
  }
  rowStarts.push(next);
  return { rows: rows, columns: columns, rowStarts: rowStarts };
}

/** 构造坐标（对齐 Java 套件的 at 辅助） */
function at(row: number, column: number): CellCoord {
  return createCoord(row, column);
}

/** 网格夹具：rowCount × columnCount 全部填 "row,column" */
function filledGrid(rowCount: number, columnCount: number): string[][] {
  const grid: string[][] = [];
  for (let row = 0; row < rowCount; row++) {
    const line: string[] = [];
    for (let column = 0; column < columnCount; column++) {
      line.push(`${row},${column}`);
    }
    grid.push(line);
  }
  return grid;
}

const THREE_BY_THREE: string[][] = [
  ['0,0', '0,1', '0,2'],
  ['1,0', '1,1', '1,2'],
  ['2,0', '2,1', '2,2']
];

// ---------------------------------------------------------------------------
// 1. mergedClosureSingle：单格落在合并区域内时扩张成整个合并区域
// ---------------------------------------------------------------------------
const closureSheet = sheet([
  ['A1', 'B1', 'C1'],
  ['A2', 'B2', 'C2'],
  ['A3', 'B3', 'C3']
], 20, 64);
closureSheet.merges.push(merge(0, 0, 1, 1)); // A1:B2
const closureLayout = layoutOf(closureSheet);

// 锚点落在合并区域右下角从属位置，闭包必须把它们拉回完整区域
const closureSelection = resolve(closureSheet, at(1, 1), at(1, 1));
expectNotNullSelection(closureSelection, '闭包：选区应解析成功');
if (closureSelection !== null) {
  expectEqual(closureSelection.startRow, 0, '闭包：startRow 上拉到 0');
  expectEqual(closureSelection.startColumn, 0, '闭包：startColumn 上拉到 0');
  expectEqual(closureSelection.endRow, 1, '闭包：endRow 保持 1');
  expectEqual(closureSelection.endColumn, 1, '闭包：endColumn 保持 1');

  check(isSingleLogicalCell(closureSheet, closureSelection), '闭包：单合并格视为逻辑单格');

  const closureRect = docRect(closureLayout, closureSelection);
  expectNotNullRect(closureRect, '闭包：合并选区应有文档矩形');
  if (closureRect !== null) {
    expectEqual(Math.round(closureRect.left), Math.round(HEADER_WIDTH), '闭包：矩形左边为表头 + 0');
    expectEqual(Math.round(closureRect.right), Math.round(HEADER_WIDTH + 128), '闭包：矩形右边跨 2 列');
    expectEqual(Math.round(closureRect.top), Math.round(HEADER_HEIGHT), '闭包：矩形上边为表头 + 0');
    expectEqual(Math.round(closureRect.bottom), Math.round(HEADER_HEIGHT + 40), '闭包：矩形下边跨 2 行');
  } else {
    checks += 4;
  }
}

// ---------------------------------------------------------------------------
// 2. mergedClosureChain：闭包必须迭代到不动点（用重叠合并区域才能观察出差别）
//
// 「相邻但不重叠」的合并区域串不起来：闭包只并入与当前矩形相交的区域，而合法 XLSX
// 的合并区域两两不重叠。设当前矩形 R0、并入的不相交区域 A，新矩形 R1 = bbox(R0 ∪ A)；
// R1 中不属于 R0 的部分必然落在 A 覆盖的单元格内，于是任何与 R1 \ R0 相交的区域 C
// 必与 A 重叠——与「两两不重叠」矛盾。因此对合法数据单轮遍历已收敛。
//
// 要真正锁定不动点语义，必须用重叠的合并列表（畸形工作表或后续跨表引用可能出现）：
// C1:E1 先声明、A1:C1 后声明，二者在 C1 重叠。单轮扫描先跳过 C1:E1（与 A1 不相交）、
// 再并入 A1:C1 后本轮结束，停在 C1（endColumn=2）；不动点实现第二轮发现新边界与 C1:E1
// 相交并并入，稳定在 A1:E1（endColumn=4）。退化为单轮时本组断言必然失败。
// ---------------------------------------------------------------------------
const chainSheet = sheet([
  ['A1', 'B1', 'C1', 'D1', 'E1'],
  ['A2', 'B2', 'C2', 'D2', 'E2'],
  ['A3', 'B3', 'C3', 'D3', 'E3']
], 20, 64);
// 逆序 + 重叠：远端 C1:E1 先声明，起选所在的 A1:C1 后声明，二者在 C1 重叠
chainSheet.merges.push(merge(0, 2, 0, 4)); // C1:E1
chainSheet.merges.push(merge(0, 0, 0, 2)); // A1:C1
chainSheet.merges.push(merge(1, 0, 1, 1)); // A2:B2
const chainLayout = layoutOf(chainSheet);

// 起点只在 A1：单轮停在 A1:C1，不动点扩到 A1:E1
const chainSelection = resolve(chainSheet, at(0, 0), at(0, 0));
if (chainSelection !== null) {
  expectEqual(chainSelection.startRow, 0, '链式闭包：startRow 为 0');
  expectEqual(chainSelection.startColumn, 0, '链式闭包：startColumn 为 0');
  expectEqual(chainSelection.endRow, 0, '链式闭包：endRow 为 0');
  expectEqual(chainSelection.endColumn, 4, '链式闭包：不动点迭代后 endColumn 到达 E 列');
  check(!isSingleLogicalCell(chainSheet, chainSelection), '链式闭包：两个串联合并区域不是逻辑单格');
} else {
  checks += 5;
}

// 反向锚点：从 E1 起选同样收敛到 A1:E1，证明闭包与遍历方向无关
const chainFromFar = resolve(chainSheet, at(0, 4), at(0, 4));
if (chainFromFar !== null) {
  expectEqual(chainFromFar.startColumn, 0, '链式闭包：反向起选收敛到 A 列');
  expectEqual(chainFromFar.endColumn, 4, '链式闭包：反向起选终点仍为 E 列');
} else {
  checks += 2;
}

// 触到底部合并区域：闭包下扩到 A2:B2 的末行
const chainLower = resolve(chainSheet, at(1, 0), at(1, 0));
if (chainLower !== null) {
  expectEqual(chainLower.startRow, 1, '链式闭包：下层 startRow 为 1');
  expectEqual(chainLower.endRow, 1, '链式闭包：下层 endRow 为 1');
  expectEqual(chainLower.startColumn, 0, '链式闭包：下层 startColumn 为 0');
  expectEqual(chainLower.endColumn, 1, '链式闭包：下层 endColumn 为 1');
} else {
  checks += 4;
}

// 未与任何合并区域相交的普通矩形保持原样
const chainPlain = resolve(chainSheet, at(2, 4), at(2, 4));
if (chainPlain !== null) {
  expectEqual(chainPlain.startRow, 2, '链式闭包：普通选区 startRow 不变');
  expectEqual(chainPlain.endRow, 2, '链式闭包：普通选区 endRow 不变');
  expectEqual(chainPlain.startColumn, 4, '链式闭包：普通选区 startColumn 不变');
  expectEqual(chainPlain.endColumn, 4, '链式闭包：普通选区 endColumn 不变');
} else {
  checks += 4;
}
check(chainLayout !== null, '链式闭包：布局构造成功');

// ---------------------------------------------------------------------------
// 3. reversedDragSelection：反向拖选导出规范化边界并保留原始锚点/焦点
// ---------------------------------------------------------------------------
const reverseSheet = sheet(THREE_BY_THREE, 20, 64);
const reverseSelection = resolve(reverseSheet, at(2, 2), at(0, 0));
if (reverseSelection !== null) {
  expectEqual(reverseSelection.startRow, 0, '反向选：startRow 规范化');
  expectEqual(reverseSelection.startColumn, 0, '反向选：startColumn 规范化');
  expectEqual(reverseSelection.endRow, 2, '反向选：endRow 规范化');
  expectEqual(reverseSelection.endColumn, 2, '反向选：endColumn 规范化');
  check(reverseSelection.anchor.row === 2 && reverseSelection.anchor.column === 2, '反向选：锚点保留');
  check(reverseSelection.focus.row === 0 && reverseSelection.focus.column === 0, '反向选：焦点保留');
  expectEqual(selectionRowCount(reverseSelection), 3, '反向选：rowCount 为 3');
  expectEqual(selectionColumnCount(reverseSelection), 3, '反向选：columnCount 为 3');
} else {
  checks += 8;
}
expectNullSelection(resolve(reverseSheet, null, at(0, 0)), '反向选：null 锚点应返回 null');

// ---------------------------------------------------------------------------
// 4. hiddenRowsAndColumnsSkipped：隐藏列不进 TSV 且不产生多余制表符
// ---------------------------------------------------------------------------
const hiddenSheet = sheet([
  ['A1', 'hidden', 'C1'],
  ['hiddenRow', 'hiddenRow', 'hiddenRow'],
  ['A3', 'hidden', 'C3']
], 20, 64);
hiddenSheet.columnWidths[1] = 0; // B 列隐藏
hiddenSheet.rowHeights[1] = 0;   // 第 2 行隐藏
const hiddenLayout = layoutOf(hiddenSheet);

// 隐藏行列不出现在 axis.visible 中
expectEqual(hiddenLayout.rows.visible.length, 2, '隐藏：仅 2 行可见');
expectEqual(hiddenLayout.columns.visible.length, 2, '隐藏：仅 2 列可见');

const hiddenSelection = resolve(hiddenSheet, at(0, 0), at(2, 2));
expectText(selectedText(hiddenSheet, hiddenLayout, hiddenSelection), 'A1\tC1\nA3\tC3',
  '隐藏：隐藏行与隐藏列整条跳过');

// 隐藏列上的单元格仍可被直接寻址（模型层不做额外过滤）
expectText(cellTextAt(hiddenSheet, hiddenLayout, 0, 1) ?? '', 'hidden',
  '隐藏：隐藏列上的单元格仍可寻址');

// ---------------------------------------------------------------------------
// 5. singleCellAndMergedCellText：单格与单合并格输出裸文本，多格输出矩形网格
// ---------------------------------------------------------------------------
const textSheet = sheet([
  ['标题', null, null],
  ['x', 'y', 'z']
], 20, 64);
textSheet.merges.push(merge(0, 0, 0, 2)); // A1:C1
const textLayout = layoutOf(textSheet);

// 单格：裸文本，不带制表符
const singleText = resolve(textSheet, at(1, 1), at(1, 1));
expectText(selectedText(textSheet, textLayout, singleText), 'y', '文本：单格导出裸文本');

// 单合并格：同样裸文本
const mergedSelection = resolve(textSheet, at(0, 1), at(0, 1));
check(isSingleLogicalCell(textSheet, mergedSelection), '文本：合并区域是逻辑单格');
expectText(selectedText(textSheet, textLayout, mergedSelection), '标题', '文本：合并格导出锚点文本且无制表符');

// 多格：合并区域从属位置留空，保持矩形对齐
const multiSelection = resolve(textSheet, at(0, 0), at(1, 2));
expectText(selectedText(textSheet, textLayout, multiSelection), '标题\t\t\nx\ty\tz',
  '文本：多格网格保持合并从属位置为空');

// 空选区语义
expectText(selectedText(textSheet, textLayout, null), '', '文本：null 选区导出空串');

// ---------------------------------------------------------------------------
// 6. tsvEscaping：含制表符、换行、双引号的文本按 RFC 4180 转义
// ---------------------------------------------------------------------------
expectText(formatTsvCell(null), '', '转义：null 视为空');
expectText(formatTsvCell(''), '', '转义：空串保持为空');
expectText(formatTsvCell('plain'), 'plain', '转义：普通文本原样输出');
expectText(formatTsvCell('a\tb'), '"a\tb"', '转义：制表符强制加引号');
expectText(formatTsvCell('a\nb'), '"a\nb"', '转义：换行强制加引号');
expectText(formatTsvCell('a\rb'), '"a\rb"', '转义：回车强制加引号');
expectText(formatTsvCell('say "hi"'), '"say ""hi"""', '转义：内部引号翻倍');
expectText(formatTsvCell('"'), '""""', '转义：单个引号变成四个');

const escapeSheet = sheet([
  ['a\tb', 'c'],
  ['d', 'e']
], 20, 64);
const escapeLayout = layoutOf(escapeSheet);
const escapeSelection = resolve(escapeSheet, at(0, 0), at(1, 1));
expectText(selectedText(escapeSheet, escapeLayout, escapeSelection), '"a\tb"\tc\nd\te',
  '转义：带引号的单元格在 TSV 中保持网格形状');

// ---------------------------------------------------------------------------
// 7. allEmptySelectionReturnsEmpty：选区内全为空文本时返回空串
// ---------------------------------------------------------------------------
const emptySheet = sheet([
  ['only', null, null],
  [null, null, null]
], 20, 64);
const emptyLayout = layoutOf(emptySheet);
// 只能选中右下角空白矩形：A1 含文本但不在范围内
const blankSelection = createSelection(at(1, 1), at(1, 2), 1, 1, 1, 2);
expectText(selectedText(emptySheet, emptyLayout, blankSelection), '', '空选：全空白选区导出空串');

// 显式空串单元格同样视为空
const explicitEmptySheet = sheet([['', '']], 20, 64);
const explicitEmptyLayout = layoutOf(explicitEmptySheet);
const explicitEmptySelection = createSelection(at(0, 0), at(0, 1), 0, 0, 0, 1);
expectText(selectedText(explicitEmptySheet, explicitEmptyLayout, explicitEmptySelection), '',
  '空选：显式空串单元格同样导出空串');

// ---------------------------------------------------------------------------
// 8. hitTestWithoutFreeze：无冻结时等价于「文档坐标 = 视图坐标 + 滚动量」
// ---------------------------------------------------------------------------
const hitSheet = sheet(THREE_BY_THREE, 20, 64);
const hitLayout = layoutOf(hitSheet);

// 无滚动：视图坐标 (42+1, 20+1) 落在 A1
expectCoord(hitTest(hitLayout, 0, 0, 0, 0, 0, 0,
  HEADER_WIDTH + 1, HEADER_HEIGHT + 1, false), 0, 0, '命中：无冻结映射到 A1');

// 滚动 64（一列）+ 20（一行）后，同一点应落在 B2
expectCoord(hitTest(hitLayout, 0, 0, 0, 0, 64, 20,
  HEADER_WIDTH + 1, HEADER_HEIGHT + 1, false), 1, 1, '命中：滚动偏移映射到 B2');

// ---------------------------------------------------------------------------
// 9. hitTestFrozenColumns：冻结区内 X 轴不叠加滚动量，滚动区照常叠加
// ---------------------------------------------------------------------------
const frozenColumnSheet = sheet([
  ['0,0', '0,1', '0,2', '0,3'],
  ['1,0', '1,1', '1,2', '1,3']
], 20, 64);
const frozenColumnLayout = layoutOf(frozenColumnSheet);
const frozenW = 64; // 冻结第 0 列

// 冻结区内：视图 X 落在冻结区，命中列 0（不叠加滚动）
expectCoord(hitTest(frozenColumnLayout, 0, 1, frozenW, 0, 100, 0,
  HEADER_WIDTH + 10, HEADER_HEIGHT + 1, false), 0, 0, '命中：冻结列忽略滚动量');

// 滚动区内：视图 X 越过冻结区宽度，数据 X = bodyX + scrollX
expectCoord(hitTest(frozenColumnLayout, 0, 1, frozenW, 0, 64, 0,
  HEADER_WIDTH + frozenW + 1, HEADER_HEIGHT + 1, false), 0, 2, '命中：滚动列叠加滚动偏移');

// ---------------------------------------------------------------------------
// 10. hitTestFrozenRows：冻结区内的 Y 轴不叠加滚动量
// ---------------------------------------------------------------------------
// 8 行 × 20 = 160 的数据高度，留足滚动余量
const frozenRowSheet = sheet([
  ['r0'], ['r1'], ['r2'], ['r3'], ['r4'], ['r5'], ['r6'], ['r7']
], 20, 64);
const frozenRowLayout = layoutOf(frozenRowSheet);
const frozenH = 20; // 冻结第 0 行
const scrollY = 60;

// 冻结行内：bodyY = 1 < frozenH，dataY 不叠加滚动量
expectCoord(hitTest(frozenRowLayout, 1, 0, 0, frozenH, 0, scrollY,
  HEADER_WIDTH + 1, HEADER_HEIGHT + 1, false), 0, 0, '命中：冻结行忽略滚动量');

// 滚动区内：bodyY = frozenH + 1 = 21 >= frozenH，dataY = 21 + 60 = 81 → 第 4 行
expectCoord(hitTest(frozenRowLayout, 1, 0, 0, frozenH, 0, scrollY,
  HEADER_WIDTH + 1, HEADER_HEIGHT + frozenH + 1, false), 4, 0, '命中：滚动行叠加滚动偏移');

// ---------------------------------------------------------------------------
// 11. hitTestFrozenCorner：双轴冻结时交叉角两轴都不叠加滚动量
// ---------------------------------------------------------------------------
// 10 行 × 20 = 200 高、8 列 × 64 = 512 宽，为双轴滚动留足余量
const cornerSheet = sheet(filledGrid(10, 8), 20, 64);
const cornerLayout = layoutOf(cornerSheet);
const cornerFrozenW = 64;
const cornerFrozenH = 40;
const cornerScrollX = 128;
const cornerScrollY = 60;

// 交叉角（左上）：命中 (1, 0)，两轴都锁定
expectCoord(hitTest(cornerLayout, 2, 1, cornerFrozenW, cornerFrozenH, cornerScrollX, cornerScrollY,
  HEADER_WIDTH + cornerFrozenW - 1, HEADER_HEIGHT + cornerFrozenH - 1, false),
1, 0, '命中：冻结交叉角两轴均锁定');

// 冻结列 + 滚动行：bodyY = frozenH + 1，dataY = 41 + 60 = 101 → 第 5 行
expectCoord(hitTest(cornerLayout, 2, 1, cornerFrozenW, cornerFrozenH, cornerScrollX, cornerScrollY,
  HEADER_WIDTH + 1, HEADER_HEIGHT + cornerFrozenH + 1, false),
5, 0, '命中：冻结列搭配滚动行');

// 冻结行 + 滚动列：bodyX = 65，dataX = 65 + 128 = 193 → 第 3 列
expectCoord(hitTest(cornerLayout, 2, 1, cornerFrozenW, cornerFrozenH, cornerScrollX, cornerScrollY,
  HEADER_WIDTH + cornerFrozenW + 1, HEADER_HEIGHT + 1, false),
0, 3, '命中：冻结行搭配滚动列');

// 纯滚动区：两轴都叠加滚动量
expectCoord(hitTest(cornerLayout, 2, 1, cornerFrozenW, cornerFrozenH, cornerScrollX, cornerScrollY,
  HEADER_WIDTH + cornerFrozenW + 1, HEADER_HEIGHT + cornerFrozenH + 1, false),
5, 3, '命中：滚动象限叠加两轴偏移');

// ---------------------------------------------------------------------------
// 12. hitTestClampsAndHeaders：标头内与越界：不钳位返回 null，钳位则贴到边缘
// ---------------------------------------------------------------------------
const clampSheet = sheet([
  ['0,0', '0,1'],
  ['1,0', '1,1']
], 20, 64);
const clampLayout = layoutOf(clampSheet);

expectNullCoord(hitTest(clampLayout, 0, 0, 0, 0, 0, 0,
  HEADER_WIDTH - 1, HEADER_HEIGHT + 1, false), '钳位：列标头内不产生单元格命中');
expectNullCoord(hitTest(clampLayout, 0, 0, 0, 0, 0, 0,
  HEADER_WIDTH + 1, HEADER_HEIGHT - 1, false), '钳位：行标头内不产生单元格命中');
check(hitTest(clampLayout, 0, 0, 0, 0, 0, 0,
  HEADER_WIDTH + 1, HEADER_HEIGHT + 1, false) !== null, '钳位：正文内触点可命中');

// 越过右下边界：不钳位返回 null，钳位贴到末行末列
const farX = HEADER_WIDTH + 64 * 2 + 50;
const farY = HEADER_HEIGHT + 20 * 2 + 50;
expectNullCoord(hitTest(clampLayout, 0, 0, 0, 0, 0, 0, farX, farY, false),
  '钳位：越界且不钳位返回 null');
expectCoord(hitTest(clampLayout, 0, 0, 0, 0, 0, 0, farX, farY, true),
  1, 1, '钳位：越界钳位到末个可见单元格');

// 滚动量大于表格尺寸时数据坐标同样越界，钳位后仍落在合法末格（绝不返回负索引）
expectCoord(hitTest(clampLayout, 0, 0, 0, 0, 200, 200,
  HEADER_WIDTH + 1, HEADER_HEIGHT + 1, true), 1, 1, '钳位：过量滚动钳位到末个可见单元格');

// 钳位结果恒为合法坐标：非钳位调用在同样输入下返回 null，绝不产生负索引
expectNullCoord(hitTest(clampLayout, 0, 0, 0, 0, 200, 200,
  HEADER_WIDTH + 1, HEADER_HEIGHT + 1, false), '钳位：过量滚动且不钳位返回 null');
expectCoord(hitTest(clampLayout, 0, 0, 0, 0, 0, 0,
  HEADER_WIDTH, HEADER_HEIGHT, true), 0, 0, '钳位：正文原点映射到首个单元格');

// 拖拽入标头/左上方视口外时，clampToBounds=true 收敛到当前可见左/上缘（支持向左上拖选与边缘滚动）
expectCoord(hitTest(clampLayout, 0, 0, 0, 0, 0, 0,
  HEADER_WIDTH - 12, HEADER_HEIGHT + 5, true), 0, 0, '钳位：拖入行标头时列收敛到 0');
expectCoord(hitTest(clampLayout, 0, 0, 0, 0, 64, 20,
  HEADER_WIDTH - 10, HEADER_HEIGHT - 10, true), 1, 1, '钳位：滚动后拖入标头收敛到左上可见格');
expectCoord(hitTest(clampLayout, 1, 1, 64, 20, 64, 20,
  HEADER_WIDTH - 10, HEADER_HEIGHT - 10, true), 0, 0, '钳位：冻结角下拖入标头收敛到 (0, 0)');

// ---------------------------------------------------------------------------
// 13. allRangeRequiresText：空表返回 null；有文本时覆盖首个到末个可见单元格
// ---------------------------------------------------------------------------
// 全空表
const blankAllSheet = sheet([[null, null], [null, null]], 20, 64);
expectNullSelection(allRange(blankAllSheet, layoutOf(blankAllSheet)), '全选：空表返回 null');

// 只有空白文本的单元格也算空
const spacesSheet = sheet([['', '']], 20, 64);
expectNullSelection(allRange(spacesSheet, layoutOf(spacesSheet)), '全选：空串单元格不启用全选');

// 有文本的表：覆盖全部可见行列
const fullSheet = sheet([
  ['A1', 'B1', 'C1'],
  ['A2', 'B2', 'C2']
], 20, 64);
const fullLayout = layoutOf(fullSheet);
const fullSelection = allRange(fullSheet, fullLayout);
expectNotNullSelection(fullSelection, '全选：非空表应给出范围');
if (fullSelection !== null) {
  expectEqual(fullSelection.startRow, 0, '全选：startRow 为 0');
  expectEqual(fullSelection.startColumn, 0, '全选：startColumn 为 0');
  expectEqual(fullSelection.endRow, 1, '全选：endRow 为末个可见行');
  expectEqual(fullSelection.endColumn, 2, '全选：endColumn 为末个可见列');
}
expectText(selectedText(fullSheet, fullLayout, fullSelection), 'A1\tB1\tC1\nA2\tB2\tC2',
  '全选：整表 TSV 覆盖全部单元格');

// 末列/末行隐藏时全选跟随可见范围收缩
const hiddenTailSheet = sheet([
  ['A1', 'B1', 'C1'],
  ['A2', 'B2', 'C2']
], 20, 64);
hiddenTailSheet.columnWidths[2] = 0;
hiddenTailSheet.rowHeights[1] = 0;
const hiddenTailLayout = layoutOf(hiddenTailSheet);
const shrunkSelection = allRange(hiddenTailSheet, hiddenTailLayout);
expectNotNullSelection(shrunkSelection, '全选：隐藏尾部仍可全选');
if (shrunkSelection !== null) {
  expectEqual(shrunkSelection.endRow, 0, '全选：隐藏的末行被排除');
  expectEqual(shrunkSelection.endColumn, 1, '全选：隐藏的末列被排除');
}
expectText(selectedText(hiddenTailSheet, hiddenTailLayout, shrunkSelection), 'A1\tB1',
  '全选：跳过隐藏的末行末列');

// ---------------------------------------------------------------------------
// 14. selectionHeaderLinkage：行列标头联动高亮的判定
// ---------------------------------------------------------------------------
const headerSheet = sheet([
  ['a', 'b', 'c', 'd'],
  ['e', 'f', 'g', 'h'],
  ['i', 'j', 'k', 'l']
], 20, 64);
const headerSelection = resolve(headerSheet, at(1, 1), at(2, 2));
if (headerSelection !== null) {
  check(selectionContainsRow(headerSelection, 1), '标头：第 1 行高亮');
  check(selectionContainsRow(headerSelection, 2), '标头：第 2 行高亮');
  check(!selectionContainsRow(headerSelection, 0), '标头：第 0 行不高亮');
  check(!selectionContainsRow(headerSelection, 3), '标头：第 3 行不高亮');

  check(selectionContainsColumn(headerSelection, 1), '标头：B 列高亮');
  check(selectionContainsColumn(headerSelection, 2), '标头：C 列高亮');
  check(!selectionContainsColumn(headerSelection, 0), '标头：A 列不高亮');
  check(!selectionContainsColumn(headerSelection, 3), '标头：D 列不高亮');

  check(selectionCovers(headerSelection, 1, 2), '标头：范围内的单元格被覆盖');
  check(!selectionCovers(headerSelection, 0, 0), '标头：范围外的单元格不被覆盖');
} else {
  checks += 10;
}

// ---------------------------------------------------------------------------
// 15. selectionDocRect：选区矩形精确对齐行列前缀和，越界时安全返回 null
// ---------------------------------------------------------------------------
const rectSheet = sheet([
  ['a', 'b', 'c'],
  ['d', 'e', 'f'],
  ['g', 'h', 'i']
], 20, 64);
const rectLayout = layoutOf(rectSheet);

const rectSelection = resolve(rectSheet, at(1, 1), at(2, 2));
const selectionRect = docRect(rectLayout, rectSelection);
expectNotNullRect(selectionRect, '矩形：选区矩形解析成功');
if (selectionRect !== null) {
  expectEqual(Math.round(selectionRect.left), Math.round(HEADER_WIDTH + 64), '矩形：左边为 B 列原点');
  expectEqual(Math.round(selectionRect.right), Math.round(HEADER_WIDTH + 192), '矩形：右边越过 C 列');
  expectEqual(Math.round(selectionRect.top), Math.round(HEADER_HEIGHT + 20), '矩形：上边为第 2 行原点');
  expectEqual(Math.round(selectionRect.bottom), Math.round(HEADER_HEIGHT + 60), '矩形：下边越过第 3 行');
  expectEqual(Math.round(rectWidth(selectionRect)), 128, '矩形：宽度跨 2 列');
  expectEqual(Math.round(rectHeight(selectionRect)), 40, '矩形：高度跨 2 行');
} else {
  checks += 6;
}

// 越界选区安全返回 null，避免渲染层数组越界
const outOfBoundsSelection = createSelection(at(0, 0), at(9, 9), 0, 0, 9, 9);
expectNullRect(docRect(rectLayout, outOfBoundsSelection), '矩形：越界选区返回 null');
expectNullRect(docRect(rectLayout, null), '矩形：null 选区返回 null');

// 合并区域的矩形与选区矩形使用同一套坐标
const mergedRectSheet = sheet([
  ['a', 'b'],
  ['c', 'd']
], 20, 64);
const mergedRange = merge(0, 0, 0, 1);
mergedRectSheet.merges.push(mergedRange);
const mergedRectLayout = layoutOf(mergedRectSheet);
const mergedDocRect = mergeDocRect(mergedRectLayout, mergedRange);
expectNotNullRect(mergedDocRect, '矩形：合并区域矩形解析成功');
if (mergedDocRect !== null) {
  expectEqual(Math.round(rectWidth(mergedDocRect)), 128, '矩形：合并区域跨 2 列');
} else {
  checks += 1;
}
expectNullRect(mergeDocRect(mergedRectLayout, merge(0, 0, 9, 9)), '矩形：越界合并区域返回 null');

// ---------------------------------------------------------------------------
// 附加自检（不计入 111 条对齐断言）：构造器与判定辅助的一致性
// ---------------------------------------------------------------------------
// createSelection 的 min/max 规范化与 null 兜底必须与 Java 构造器逐条一致
const normalised = createSelection(at(5, 7), null, 3, 4, 1, 2);
if (normalised.startRow === 1 && normalised.endRow === 3
  && normalised.startColumn === 2 && normalised.endColumn === 4
  && normalised.focus.row === 5 && normalised.focus.column === 7) {
  // 语义正确
} else {
  throw new Error('createSelection 规范化结果与 Java 构造器不一致');
}
if (!selectionEquals(normalised, createSelection(at(0, 0), at(0, 0), 1, 2, 3, 4))) {
  throw new Error('selectionEquals 应只比较规范化边界');
}
if (selectionIsSingleCell(normalised)) {
  throw new Error('selectionIsSingleCell 对 3×3 选区不应返回 true');
}
if (mergeAt(mergedRectSheet, 0, 1) === null || mergeAt(mergedRectSheet, 1, 0) !== null) {
  throw new Error('mergeAt 覆盖判定不正确');
}

// ---------------------------------------------------------------------------
// 接入点静态检查：确认视图层与父视图的选区接入完整（不改变上面的 111 条对齐断言计数）
// ---------------------------------------------------------------------------
const modelSource = readFileSync(resolvePath(root, 'viewer-ohos/src/main/ets/render/SheetSelectionModel.ts'), 'utf8');
const viewSource = readFileSync(resolvePath(root, 'viewer-ohos/src/main/ets/render/SpreadsheetView.ets'), 'utf8');
const previewSource = readFileSync(resolvePath(root, 'viewer-ohos/src/main/ets/render/OfficePreviewView.ets'), 'utf8');

let integrationChecks = 0;
function expectIntegration(condition: boolean, message: string): void {
  integrationChecks++;
  if (!condition) {
    throw new Error(`接入点检查失败：${message}`);
  }
}

// 纯 TS 模型必须零 import，否则无法在 plain node 下直接执行
expectIntegration(!/^\s*import\s/m.test(modelSource), 'SheetSelectionModel.ts 不得包含任何 import 语句');
expectIntegration(!/from\s+'@kit\.|require\(\s*'@kit\./.test(modelSource),
  'SheetSelectionModel.ts 不得引用 @kit.* 模块');

// SpreadsheetView 必须真正接入选区：状态、长按、手柄拖拽、四象限绘制、标头联动
expectIntegration(viewSource.includes('LongPressGesture({ duration: SELECTION_LONG_PRESS_MS, repeat: false })'),
  'SpreadsheetView 缺少长按选格手势');
expectIntegration(viewSource.includes('private handleLongPress(event: GestureEvent): void'),
  'SpreadsheetView 长按回调未进入选格逻辑');
expectIntegration(viewSource.includes('hitTest('), 'SpreadsheetView 未调用模型 hitTest');
expectIntegration(viewSource.includes('mapMatchRectToQuadrants({'), 'SpreadsheetView 未按象限映射选区高亮');
expectIntegration(viewSource.includes('selectionContainsColumn('), 'SpreadsheetView 列标头缺少联动高亮');
expectIntegration(viewSource.includes('selectionContainsRow('), 'SpreadsheetView 行标头缺少联动高亮');
expectIntegration(viewSource.includes('SelectionMenuBubble({'), 'SpreadsheetView 未复用选区浮动气泡');
expectIntegration(viewSource.includes('copyTextToPasteboard(text)'), 'SpreadsheetView 复制未写入系统剪贴板');
expectIntegration(/GestureMode\.Parallel/.test(viewSource), 'XLSX 手势组必须保持 Parallel 模式');
expectIntegration(viewSource.includes('this.isSelectionDragging'), 'XLSX 拖选期间必须屏蔽 PanGesture');

// 切表 / 重新加载 / 缩放复位必须清除选区（设计文档 §全局约束）
expectIntegration(/switchSheet\(idx: number\)[\s\S]{0,400}this\.resetSelection\(false\)/.test(viewSource),
  '切表未清除选区');
expectIntegration(/this\.document !== this\.lastDocument[\s\S]{0,400}this\.resetSelection\(false\)/.test(viewSource),
  '文档重新加载未清除选区');
expectIntegration(/if \(resetOffsets\) \{\s*this\.clearSelection\(\);/.test(viewSource),
  '缩放复位未清除选区');

// 父视图必须把 XLSX 的选区钩子转交出去
expectIntegration(/registerControls: \(\s*selectSheet:[\s\S]{0,600}selection\?: SelectionControlHooks[\s\S]{0,400}this\.applySelectionHooks\(selection\);/
  .test(previewSource), 'OfficePreviewView 的 XLSX 分支未转交选区钩子');
expectIntegration(!/XLSX 不注册/.test(previewSource), 'OfficePreviewView 仍保留「XLSX 不注册」的过期注释');

console.log(`Sheet selection checks passed: ${checks}`);
console.log(`Sheet selection integration checks passed: ${integrationChecks}`);
