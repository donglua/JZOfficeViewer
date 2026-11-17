/**
 * 冻结窗格纯逻辑回归检查（node 直接执行）：
 *   node scripts/tests/SheetFreezeChecks.ts
 *
 * 覆盖 viewer-ohos/src/main/ets/render/SheetFreeze.ts 的占比保护、四象限切分、
 * 跨边界合并裁剪、检索高亮象限映射与跳转避让。
 */
import {
  MAX_FROZEN_RATIO,
  FREEZE_LINE_COLOR,
  normalizeFrozen,
  resolveEffectiveFrozen,
  resolveFreezeQuadrants,
  resolveQuadrantDocClip,
  resolveQuadrantMergeRect,
  mapMatchRectToQuadrants,
  resolveScrollToTarget
} from '../../viewer-ohos/src/main/ets/render/SheetFreeze.ts';
import type {
  EffectiveFrozen,
  FreezeDocRect,
  FreezeQuadrant,
  FreezeQuadrantInput,
  FreezeRect,
  MatchQuadrantRect,
  ScrollAvoidInput,
  ScrollTarget
} from '../../viewer-ohos/src/main/ets/render/SheetFreeze.ts';

const HEADER_WIDTH = 42;
const HEADER_HEIGHT = 22;

let checks = 0;

function expectEqual(actual: number, expected: number, message: string): void {
  checks++;
  if (Math.abs(actual - expected) > 1e-6) {
    throw new Error(`${message}: 期望 ${expected}，实际 ${actual}`);
  }
}

function expectText(actual: string, expected: string, message: string): void {
  checks++;
  if (actual !== expected) {
    throw new Error(`${message}: 期望 ${expected}，实际 ${actual}`);
  }
}

function expectBool(actual: boolean, expected: boolean, message: string): void {
  checks++;
  if (actual !== expected) {
    throw new Error(`${message}: 期望 ${expected}，实际 ${actual}`);
  }
}

function expectTrue(actual: boolean, message: string): void {
  checks++;
  if (!actual) {
    throw new Error(`${message}: 期望 true，实际 false`);
  }
}

function expectRect(actual: FreezeRect, x: number, y: number, w: number, h: number, message: string): void {
  checks++;
  const mismatch =
    Math.abs(actual.x - x) > 1e-6 ||
    Math.abs(actual.y - y) > 1e-6 ||
    Math.abs(actual.width - w) > 1e-6 ||
    Math.abs(actual.height - h) > 1e-6;
  if (mismatch) {
    throw new Error(
      `${message}: 期望 {x:${x}, y:${y}, w:${w}, h:${h}}，` +
      `实际 {x:${actual.x}, y:${actual.y}, w:${actual.width}, h:${actual.height}}`
    );
  }
}

function expectRange(actual: FreezeQuadrant, rowStart: number, rowEnd: number,
  colStart: number, colEnd: number, message: string): void {
  checks++;
  if (actual.rowStart !== rowStart || actual.rowEnd !== rowEnd ||
      actual.colStart !== colStart || actual.colEnd !== colEnd) {
    throw new Error(
      `${message}: 期望 rows[${rowStart},${rowEnd}) cols[${colStart},${colEnd})，` +
      `实际 rows[${actual.rowStart},${actual.rowEnd}) cols[${actual.colStart},${actual.colEnd})`
    );
  }
}

function findQuadrant(quadrants: FreezeQuadrant[], kind: string): FreezeQuadrant {
  for (const q of quadrants) {
    if (q.kind === kind) return q;
  }
  throw new Error(`未找到象限 ${kind}，实际象限：${quadrants.map((q) => q.kind).join(',') || '(空)'}`);
}

function hasQuadrant(quadrants: FreezeQuadrant[], kind: string): boolean {
  for (const q of quadrants) {
    if (q.kind === kind) return true;
  }
  return false;
}

function quadrantKinds(quadrants: FreezeQuadrant[]): string {
  return quadrants.map((q) => q.kind).join(',');
}

/** 构造象限入参，缺省值对应“无冻结”的常规视口 */
function quadrantInput(patch: Partial<FreezeQuadrantInput>): FreezeQuadrantInput {
  const base: FreezeQuadrantInput = {
    headerW: HEADER_WIDTH,
    headerH: HEADER_HEIGHT,
    offsetX: 0,
    offsetY: 0,
    frozenDataW: 0,
    frozenDataH: 0,
    bodyRight: 400,
    bodyBottom: 300,
    rowCount: 100,
    colCount: 26,
    effFrozenRows: 0,
    effFrozenCols: 0
  };
  return {
    headerW: patch.headerW ?? base.headerW,
    headerH: patch.headerH ?? base.headerH,
    offsetX: patch.offsetX ?? base.offsetX,
    offsetY: patch.offsetY ?? base.offsetY,
    frozenDataW: patch.frozenDataW ?? base.frozenDataW,
    frozenDataH: patch.frozenDataH ?? base.frozenDataH,
    bodyRight: patch.bodyRight ?? base.bodyRight,
    bodyBottom: patch.bodyBottom ?? base.bodyBottom,
    rowCount: patch.rowCount ?? base.rowCount,
    colCount: patch.colCount ?? base.colCount,
    effFrozenRows: patch.effFrozenRows ?? base.effFrozenRows,
    effFrozenCols: patch.effFrozenCols ?? base.effFrozenCols
  };
}

function effective(patch: Partial<Parameters<typeof resolveEffectiveFrozen>[0]>): EffectiveFrozen {
  const base = {
    frozenRows: 0,
    frozenColumns: 0,
    rowCount: 100,
    colCount: 26,
    availBodyW: 300,
    availBodyH: 200,
    frozenDataW: 0,
    frozenDataH: 0
  };
  return resolveEffectiveFrozen({
    frozenRows: patch.frozenRows ?? base.frozenRows,
    frozenColumns: patch.frozenColumns ?? base.frozenColumns,
    rowCount: patch.rowCount ?? base.rowCount,
    colCount: patch.colCount ?? base.colCount,
    availBodyW: patch.availBodyW ?? base.availBodyW,
    availBodyH: patch.availBodyH ?? base.availBodyH,
    frozenDataW: patch.frozenDataW ?? base.frozenDataW,
    frozenDataH: patch.frozenDataH ?? base.frozenDataH
  });
}

// ---------------------------------------------------------------------------
// 1. normalizeFrozen：缺省 / 负数 / 小数 / 超维度
// ---------------------------------------------------------------------------
expectEqual(MAX_FROZEN_RATIO, 0.75, '占比上限常量为 0.75');
expectEqual(normalizeFrozen(undefined, 10), 0, '缺省值按 0 处理');
expectEqual(normalizeFrozen(null, 10), 0, 'null 按 0 处理');
expectEqual(normalizeFrozen(-3, 10), 0, '负数归一化为 0');
expectEqual(normalizeFrozen(2.9, 10), 2, '小数向下取整');
expectEqual(normalizeFrozen(0.5, 10), 0, '小于 1 的小数归一化为 0');
expectEqual(normalizeFrozen(2, 10), 2, '合法整数原样返回');
expectEqual(normalizeFrozen(30, 10), 10, '超出维度时钳位到上限');
expectEqual(normalizeFrozen(5, -1), 0, '维度非法时钳位到 0');
expectEqual(normalizeFrozen(Number.NaN, 10), 0, 'NaN 归一化为 0');
expectEqual(normalizeFrozen(Number.POSITIVE_INFINITY, 10), 0, 'Infinity 归一化为 0');

// ---------------------------------------------------------------------------
// 2. 视口占比保护：按轴独立降级
// ---------------------------------------------------------------------------
const noFreeze = effective({});
expectEqual(noFreeze.effFrozenRows, 0, '无冻结时有效行数为 0');
expectEqual(noFreeze.effFrozenCols, 0, '无冻结时有效列数为 0');

const standardFreeze = effective({ frozenRows: 2, frozenColumns: 1, frozenDataW: 60, frozenDataH: 40 });
expectEqual(standardFreeze.effFrozenRows, 2, '常规占比下保留冻结行');
expectEqual(standardFreeze.effFrozenCols, 1, '常规占比下保留冻结列');

// 高缩放：仅冻结列超过 75% 视口宽度，冻结行必须继续锁定
const colsOverflow = effective({
  frozenRows: 2,
  frozenColumns: 3,
  availBodyW: 300,
  availBodyH: 200,
  frozenDataW: 240,
  frozenDataH: 40
});
expectEqual(colsOverflow.effFrozenCols, 0, '冻结列超过 75% 宽度时仅列降级');
expectEqual(colsOverflow.effFrozenRows, 2, '列降级不影响行冻结');

// 反向：仅冻结行超过 75% 可用高度
const rowsOverflow = effective({
  frozenRows: 5,
  frozenColumns: 1,
  availBodyW: 300,
  availBodyH: 100,
  frozenDataW: 60,
  frozenDataH: 90
});
expectEqual(rowsOverflow.effFrozenRows, 0, '冻结行超过 75% 高度时仅行降级');
expectEqual(rowsOverflow.effFrozenCols, 1, '行降级不影响列冻结');

// 恰好等于 75% 不降级（严格大于才降级）
const exactRatio = effective({
  frozenRows: 1,
  frozenColumns: 1,
  availBodyW: 200,
  availBodyH: 100,
  frozenDataW: 150,
  frozenDataH: 75
});
expectEqual(exactRatio.effFrozenCols, 1, '恰好 75% 宽度不降级');
expectEqual(exactRatio.effFrozenRows, 1, '恰好 75% 高度不降级');

// 略超 75% 即降级
const justOver = effective({
  frozenRows: 1,
  frozenColumns: 1,
  availBodyW: 200,
  availBodyH: 100,
  frozenDataW: 150.5,
  frozenDataH: 75.5
});
expectEqual(justOver.effFrozenCols, 0, '略超 75% 宽度即降级列');
expectEqual(justOver.effFrozenRows, 0, '略超 75% 高度即降级行');

// 可用区非正
const noSpace = effective({ frozenRows: 2, frozenColumns: 2, availBodyW: 0, availBodyH: 0 });
expectEqual(noSpace.effFrozenCols, 0, '可用宽度为 0 时取消列冻结');
expectEqual(noSpace.effFrozenRows, 0, '可用高度为 0 时取消行冻结');

// 超出表维度时钳位
const clamped = effective({
  frozenRows: 50,
  frozenColumns: 50,
  rowCount: 10,
  colCount: 4,
  frozenDataW: 10,
  frozenDataH: 10
});
expectEqual(clamped.effFrozenRows, 10, '冻结行数钳位到总行数');
expectEqual(clamped.effFrozenCols, 4, '冻结列数钳位到总列数');

// ---------------------------------------------------------------------------
// 3. 四象限切分：区间、裁剪与锁定标记
//    基准视口：400x300，表头 42/22，滚动偏移 (-30, -50)，冻结区文档尺寸 60x40
//    => frozenRight = 102、frozenBottom = 62
// ---------------------------------------------------------------------------
const QUAD_BASE = {
  offsetX: -30,
  offsetY: -50,
  frozenDataW: 60,
  frozenDataH: 40
};

const noFreezeQuads = resolveFreezeQuadrants(quadrantInput({}));
expectEqual(noFreezeQuads.length, 1, '无冻结时只有一个象限');
const plainScroll = noFreezeQuads[0];
expectText(plainScroll.kind, 'scroll', '无冻结时唯一象限是滚动区');
expectRect(plainScroll.clip, HEADER_WIDTH, HEADER_HEIGHT, 400 - HEADER_WIDTH, 300 - HEADER_HEIGHT,
  '无冻结时滚动区裁剪等于整个正文区');
expectRange(plainScroll, 0, 100, 0, 26, '无冻结时滚动区覆盖全部行列');

// 冻结 2 行 1 列：四个象限
const frozen2x1 = resolveFreezeQuadrants(quadrantInput({
  offsetX: QUAD_BASE.offsetX,
  offsetY: QUAD_BASE.offsetY,
  frozenDataW: QUAD_BASE.frozenDataW,
  frozenDataH: QUAD_BASE.frozenDataH,
  effFrozenRows: 2,
  effFrozenCols: 1
}));
expectEqual(frozen2x1.length, 4, '行列交叉冻结时产生四个象限');
expectText(quadrantKinds(frozen2x1), 'scroll,frozenCols,frozenRows,corner', '象限按从底到顶顺序返回');

const scrollQ = findQuadrant(frozen2x1, 'scroll');
expectRect(scrollQ.clip, 102, 62, 298, 238, '滚动区裁剪起点为冻结边界');
expectRange(scrollQ, 2, 100, 1, 26, '滚动区从冻结行列之后开始');
expectTrue(!scrollQ.lockX && !scrollQ.lockY, '滚动区两轴都跟随滚动');
expectEqual(scrollQ.offsetX, -30, '滚动区水平偏移跟随滚动');
expectEqual(scrollQ.offsetY, -50, '滚动区垂直偏移跟随滚动');

const frozenColsQ = findQuadrant(frozen2x1, 'frozenCols');
expectRect(frozenColsQ.clip, 42, 62, 60, 238, '冻结列区裁剪为左侧窄条');
expectRange(frozenColsQ, 2, 100, 0, 1, '冻结列区覆盖未冻结行与冻结列');
expectTrue(frozenColsQ.lockX && !frozenColsQ.lockY, '冻结列区仅锁定 X 轴');
expectEqual(frozenColsQ.offsetX, 0, '冻结列区水平偏移锁定为 0');
expectEqual(frozenColsQ.offsetY, -50, '冻结列区垂直偏移仍跟随滚动');

const frozenRowsQ = findQuadrant(frozen2x1, 'frozenRows');
expectRect(frozenRowsQ.clip, 102, 22, 298, 40, '冻结行区裁剪为顶部横条');
expectRange(frozenRowsQ, 0, 2, 1, 26, '冻结行区覆盖冻结行与未冻结列');
expectTrue(!frozenRowsQ.lockX && frozenRowsQ.lockY, '冻结行区仅锁定 Y 轴');
expectEqual(frozenRowsQ.offsetX, -30, '冻结行区水平偏移仍跟随滚动');
expectEqual(frozenRowsQ.offsetY, 0, '冻结行区垂直偏移锁定为 0');

const cornerQ = findQuadrant(frozen2x1, 'corner');
expectRect(cornerQ.clip, 42, 22, 60, 40, '交叉角裁剪为表头右下的小矩形');
expectRange(cornerQ, 0, 2, 0, 1, '交叉角覆盖冻结行列');
expectTrue(cornerQ.lockX && cornerQ.lockY, '交叉角两轴锁定');
expectTrue(cornerQ.offsetX === 0 && cornerQ.offsetY === 0, '交叉角偏移为 0');

// 象限裁剪互不重叠且拼合出完整正文区
const bodyClipArea = (400 - HEADER_WIDTH) * (300 - HEADER_HEIGHT);
let quadArea = 0;
for (const q of frozen2x1) {
  quadArea += q.clip.width * q.clip.height;
}
expectEqual(quadArea, bodyClipArea, '四象限面积之和等于正文区面积（互不重叠且无空缺）');

// 只冻结列
const onlyCols = resolveFreezeQuadrants(quadrantInput({
  frozenDataW: 60,
  effFrozenCols: 1,
  offsetY: -20
}));
expectEqual(onlyCols.length, 2, '仅冻结列时产生两个象限');
expectText(quadrantKinds(onlyCols), 'scroll,frozenCols', '仅冻结列时只有滚动区与冻结列区');
expectEqual(findQuadrant(onlyCols, 'frozenCols').clip.y, HEADER_HEIGHT, '仅冻结列时冻结列区从正文顶部开始');

// 只冻结行
const onlyRows = resolveFreezeQuadrants(quadrantInput({ frozenDataH: 40, effFrozenRows: 2, offsetX: -20 }));
expectEqual(onlyRows.length, 2, '仅冻结行时产生两个象限');
expectText(quadrantKinds(onlyRows), 'scroll,frozenRows', '仅冻结行时只有滚动区与冻结行区');
expectEqual(findQuadrant(onlyRows, 'frozenRows').clip.x, HEADER_WIDTH, '仅冻结行时冻结行区从正文左侧开始');

// 边界：冻结行数等于总行数（列未全冻结）=> 滚动区与冻结列区消失
const allRowsFrozen = resolveFreezeQuadrants(quadrantInput({
  rowCount: 3,
  colCount: 2,
  frozenDataW: 60,
  frozenDataH: 40,
  effFrozenRows: 3,
  effFrozenCols: 1
}));
expectEqual(allRowsFrozen.length, 2, '行全部冻结时只剩冻结行区与交叉角');
expectText(quadrantKinds(allRowsFrozen), 'frozenRows,corner', '行全部冻结时没有滚动区与冻结列区');
expectRange(findQuadrant(allRowsFrozen, 'frozenRows'), 0, 3, 1, 2, '冻结行区此时覆盖全部行');
expectRange(findQuadrant(allRowsFrozen, 'corner'), 0, 3, 0, 1, '交叉角覆盖全部行与冻结列');

// 边界：冻结列数等于总列数（行未全冻结）=> 滚动区与冻结行区消失
const allColsFrozen = resolveFreezeQuadrants(quadrantInput({
  rowCount: 10,
  colCount: 2,
  frozenDataW: 60,
  effFrozenCols: 2
}));
expectEqual(allColsFrozen.length, 1, '列全部冻结时只剩一个象限');
expectText(quadrantKinds(allColsFrozen), 'frozenCols', '列全部冻结时仅保留冻结列区');
expectRange(findQuadrant(allColsFrozen, 'frozenCols'), 0, 10, 0, 2, '冻结列区此时覆盖全部行列');

// 边界：行列全部冻结 => 只剩交叉角
const allFrozen = resolveFreezeQuadrants(quadrantInput({
  rowCount: 3,
  colCount: 2,
  frozenDataW: 60,
  frozenDataH: 40,
  effFrozenRows: 3,
  effFrozenCols: 2
}));
expectEqual(allFrozen.length, 1, '行列全部冻结时只剩交叉角');
expectText(quadrantKinds(allFrozen), 'corner', '行列全部冻结时仅保留交叉角');
expectRange(findQuadrant(allFrozen, 'corner'), 0, 3, 0, 2, '交叉角覆盖全部行列');

// 正文区被冻结区完全占满（可用区为 0）时不产出象限，避免越界绘制到表头
const squeezed = resolveFreezeQuadrants(quadrantInput({
  bodyRight: HEADER_WIDTH,
  bodyBottom: HEADER_HEIGHT,
  ...QUAD_BASE,
  effFrozenRows: 2,
  effFrozenCols: 1
}));
expectEqual(squeezed.length, 0, '正文区不可见时不产出任何象限');

// 画布比冻结区窄时，象限裁剪收敛到正文可见区域，不越过画布右边界
const narrow = resolveFreezeQuadrants(quadrantInput({
  bodyRight: HEADER_WIDTH + 30,
  bodyBottom: HEADER_HEIGHT + 200,
  ...QUAD_BASE,
  effFrozenRows: 2,
  effFrozenCols: 1
}));
const narrowCorner = findQuadrant(narrow, 'corner');
expectEqual(narrowCorner.clip.width, 30, '画布窄于冻结区时交叉角裁剪收敛到画布右边界');
expectTrue(!hasQuadrant(narrow, 'scroll') && !hasQuadrant(narrow, 'frozenRows'),
  '正文右侧不可见时滚动区与冻结行区被剔除');

// 缩放下冻结边界按 scale 放大
const scaled = resolveFreezeQuadrants(quadrantInput({
  frozenDataW: 120,
  frozenDataH: 80,
  effFrozenRows: 2,
  effFrozenCols: 1
}));
expectRect(findQuadrant(scaled, 'corner').clip, HEADER_WIDTH, HEADER_HEIGHT, 120, 80, '缩放 2 倍后（冻结区屏幕尺寸翻倍）交叉角尺寸翻倍');
expectRect(findQuadrant(scaled, 'scroll').clip, HEADER_WIDTH + 120, HEADER_HEIGHT + 80,
  400 - HEADER_WIDTH - 120, 300 - HEADER_HEIGHT - 80, '缩放 2 倍时滚动区从放大后的冻结边界开始');

// 象限裁剪反算文档坐标
const scrollDocClip = resolveQuadrantDocClip(scrollQ, HEADER_WIDTH, HEADER_HEIGHT, 1);
expectEqual(scrollDocClip.left, 90, '滚动区文档左边界为冻结列宽加上已滚动的 30');
expectEqual(scrollDocClip.top, 90, '滚动区文档上边界为冻结行高加上已滚动的 50');
expectEqual(scrollDocClip.right, 388, '滚动区文档右边界按滚动偏移反算');
expectEqual(scrollDocClip.bottom, 328, '滚动区文档下边界按滚动偏移反算');
const cornerDocClip = resolveQuadrantDocClip(cornerQ, HEADER_WIDTH, HEADER_HEIGHT, 1);
expectRect({ x: cornerDocClip.left, y: cornerDocClip.top, width: cornerDocClip.right - cornerDocClip.left,
  height: cornerDocClip.bottom - cornerDocClip.top }, 0, 0, 60, 40, '锁定轴反算得到冻结区文档范围');

// ---------------------------------------------------------------------------
// 4. 跨冻结边界合并单元格裁剪
// ---------------------------------------------------------------------------
// 横向跨冻结列边界、纵向落在滚动区内的合并
const crossingColMerge: FreezeDocRect = { left: 40, top: 100, right: 200, bottom: 130 };
const mergeInScroll = resolveQuadrantMergeRect(crossingColMerge, scrollQ, HEADER_WIDTH, HEADER_HEIGHT, 1);
expectTrue(mergeInScroll !== null, '跨冻结列边界的合并与滚动区相交');
expectRect(mergeInScroll as FreezeRect, 52, 72, 160, 30, '滚动区合并矩形按滚动偏移平移');

const mergeInFrozenCols = resolveQuadrantMergeRect(crossingColMerge, frozenColsQ, HEADER_WIDTH, HEADER_HEIGHT, 1);
expectTrue(mergeInFrozenCols !== null, '跨冻结列边界的合并与冻结列区相交');
expectRect(mergeInFrozenCols as FreezeRect, 82, 72, 160, 30, '冻结列区合并矩形不随水平滚动平移');
expectTrue((mergeInFrozenCols as FreezeRect).x !== (mergeInScroll as FreezeRect).x,
  '同一合并在冻结区与滚动区的水平位置相差当前滚动量');

expectTrue(resolveQuadrantMergeRect(crossingColMerge, frozenRowsQ, HEADER_WIDTH, HEADER_HEIGHT, 1) === null,
  '合并不触及冻结行区时该象限不绘制');
expectTrue(resolveQuadrantMergeRect(crossingColMerge, cornerQ, HEADER_WIDTH, HEADER_HEIGHT, 1) === null,
  '合并不触及交叉角时该象限不绘制');

// 纵向跨冻结行边界、横向落在滚动区内的合并
const crossingRowMerge: FreezeDocRect = { left: 100, top: 20, right: 160, bottom: 100 };
const rowMergeInFrozenRows = resolveQuadrantMergeRect(crossingRowMerge, frozenRowsQ, HEADER_WIDTH, HEADER_HEIGHT, 1);
expectTrue(rowMergeInFrozenRows !== null, '跨冻结行边界的合并与冻结行区相交');
expectRect(rowMergeInFrozenRows as FreezeRect, 112, 42, 60, 80, '冻结行区合并矩形垂直位置锁定');
const rowMergeInScroll = resolveQuadrantMergeRect(crossingRowMerge, scrollQ, HEADER_WIDTH, HEADER_HEIGHT, 1);
expectTrue(rowMergeInScroll !== null, '同一合并也与滚动区相交');
expectRect(rowMergeInScroll as FreezeRect, 112, -8, 60, 80, '滚动区合并矩形按垂直滚动偏移上移');
expectTrue((rowMergeInScroll as FreezeRect).y < findQuadrant(frozen2x1, 'scroll').clip.y,
  '滚动区合并矩形可超出裁剪区上边界，由象限 clip 裁掉越界部分');

// 完全落在交叉角的合并只在交叉角绘制一次
const cornerMerge: FreezeDocRect = { left: 0, top: 0, right: 50, bottom: 20 };
expectTrue(resolveQuadrantMergeRect(cornerMerge, cornerQ, HEADER_WIDTH, HEADER_HEIGHT, 1) !== null,
  '交叉角内的合并可被绘制');
expectTrue(resolveQuadrantMergeRect(cornerMerge, scrollQ, HEADER_WIDTH, HEADER_HEIGHT, 1) === null,
  '完全位于冻结区的合并不在滚动区重复绘制');
expectTrue(resolveQuadrantMergeRect(cornerMerge, frozenColsQ, HEADER_WIDTH, HEADER_HEIGHT, 1) === null,
  '完全位于冻结行的合并不在冻结列区重复绘制');
expectTrue(resolveQuadrantMergeRect(cornerMerge, frozenRowsQ, HEADER_WIDTH, HEADER_HEIGHT, 1) === null,
  '完全位于冻结列的合并不在冻结行区重复绘制');

// 缩放 2 倍下合并矩形尺寸翻倍
const scaledMerge = resolveQuadrantMergeRect(crossingColMerge, scrollQ, HEADER_WIDTH, HEADER_HEIGHT, 2);
expectTrue(scaledMerge !== null, '缩放后跨边界合并仍与滚动区相交');
expectRect(scaledMerge as FreezeRect, 92, 172, 320, 60, '缩放 2 倍后合并矩形尺寸与偏移同步放大');

// ---------------------------------------------------------------------------
// 5. 检索高亮象限映射
//    基准视口同第 3 节：frozenRight=102、frozenBottom=62，可见文档区
//    滚动区 x[90,388) y[90,328)、冻结列 x[0,60) y[90,328)、冻结行 x[90,388) y[0,40)、交叉角 x[0,60) y[0,40)
// ---------------------------------------------------------------------------
function matchRects(patch: Partial<Parameters<typeof mapMatchRectToQuadrants>[0]>): MatchQuadrantRect[] {
  const base = {
    headerW: HEADER_WIDTH,
    headerH: HEADER_HEIGHT,
    offsetX: -30,
    offsetY: -50,
    scale: 1,
    frozenDocW: 60,
    frozenDocH: 40,
    bodyRight: 400,
    bodyBottom: 300
  };
  return mapMatchRectToQuadrants({
    rect: patch.rect ?? { left: 10, top: 10, right: 50, bottom: 30 },
    headerW: patch.headerW ?? base.headerW,
    headerH: patch.headerH ?? base.headerH,
    offsetX: patch.offsetX ?? base.offsetX,
    offsetY: patch.offsetY ?? base.offsetY,
    scale: patch.scale ?? base.scale,
    frozenDocW: patch.frozenDocW ?? base.frozenDocW,
    frozenDocH: patch.frozenDocH ?? base.frozenDocH,
    bodyRight: patch.bodyRight ?? base.bodyRight,
    bodyBottom: patch.bodyBottom ?? base.bodyBottom
  });
}

// 命中落在交叉角：单块、两轴锁定
const cornerHit = matchRects({ rect: { left: 10, top: 10, right: 50, bottom: 30 } });
expectEqual(cornerHit.length, 1, '交叉角命中只产生一块高亮');
expectRect(cornerHit[0].rect, 52, 32, 40, 20, '交叉角高亮位置两轴锁定');
expectRect(cornerHit[0].clip, HEADER_WIDTH, HEADER_HEIGHT, 60, 40, '交叉角高亮裁剪到交叉角象限');

// 命中落在冻结列（纵向在滚动区）：只锁 X 轴
const frozenColHit = matchRects({ rect: { left: 10, top: 100, right: 50, bottom: 120 } });
expectEqual(frozenColHit.length, 1, '冻结列命中只产生一块高亮');
expectRect(frozenColHit[0].rect, 52, 72, 40, 20, '冻结列高亮水平锁定、垂直随滚动');
expectRect(frozenColHit[0].clip, HEADER_WIDTH, 62, 60, 238, '冻结列高亮裁剪到冻结列象限');

// 命中落在冻结行（横向在滚动区）：只锁 Y 轴
const frozenRowHit = matchRects({ rect: { left: 150, top: 5, right: 250, bottom: 25 } });
expectEqual(frozenRowHit.length, 1, '冻结行命中只产生一块高亮');
expectRect(frozenRowHit[0].rect, 162, 27, 100, 20, '冻结行高亮垂直锁定、水平随滚动');
expectRect(frozenRowHit[0].clip, 102, HEADER_HEIGHT, 298, 40, '冻结行高亮裁剪到冻结行象限');

// 命中跨冻结列边界：切成两块，滚动侧绝不覆盖冻结区
const crossingColHit = matchRects({ rect: { left: 40, top: 100, right: 200, bottom: 130 } });
expectEqual(crossingColHit.length, 2, '跨冻结列边界的命中切成两块');
expectRect(crossingColHit[0].rect, 82, 72, 20, 30, '冻结侧高亮只保留落在冻结列内的部分');
expectRect(crossingColHit[1].rect, 102, 72, 110, 30, '滚动侧高亮从冻结边界开始绘制');
expectTrue(crossingColHit[1].rect.x >= crossingColHit[0].clip.x + crossingColHit[0].clip.width,
  '滚动区高亮起点不早于冻结区右边界');
expectTrue(crossingColHit[0].rect.x + crossingColHit[0].rect.width <=
  crossingColHit[0].clip.x + crossingColHit[0].clip.width, '冻结区高亮不越过冻结列右边界');

// 命中跨冻结行边界：纵向切成两块
const crossingRowHit = matchRects({ rect: { left: 150, top: 20, right: 250, bottom: 120 } });
expectEqual(crossingRowHit.length, 2, '跨冻结行边界的命中纵向切成两块');
expectRect(crossingRowHit[0].rect, 162, 42, 100, 20, '冻结侧高亮只保留落在冻结行内的部分');
expectRect(crossingRowHit[1].rect, 162, 62, 100, 30, '滚动侧高亮从冻结行下边界开始绘制');

// 命中跨行列双边界：切成四块，逐块验证裁剪包含关系
const crossingBothHit = matchRects({ rect: { left: 40, top: 20, right: 200, bottom: 130 } });
expectEqual(crossingBothHit.length, 4, '跨行列双边界命中切成四块');
const expectedBoth: number[][] = [
  [82, 42, 20, 20],
  [82, 62, 20, 40],
  [102, 42, 110, 20],
  [102, 62, 110, 40]
];
for (let i = 0; i < expectedBoth.length; i++) {
  const e = expectedBoth[i];
  expectRect(crossingBothHit[i].rect, e[0], e[1], e[2], e[3], `跨双边界第 ${i + 1} 块高亮位置`);
}
for (const piece of crossingBothHit) {
  const insideClip = piece.rect.x >= piece.clip.x - 1e-6 &&
    piece.rect.y >= piece.clip.y - 1e-6 &&
    piece.rect.x + piece.rect.width <= piece.clip.x + piece.clip.width + 1e-6 &&
    piece.rect.y + piece.rect.height <= piece.clip.y + piece.clip.height + 1e-6;
  expectTrue(insideClip, '每块高亮都必须裁剪在所属象限内');
}

// 高亮超出正文下边界时被裁剪
const overflowHit = matchRects({ rect: { left: 150, top: 300, right: 250, bottom: 900 } });
expectEqual(overflowHit.length, 1, '超出正文下边界的高亮只产生一块');
expectEqual(overflowHit[0].rect.y + overflowHit[0].rect.height, 300, '高亮下边界裁剪到正文底部');

// 高亮完全位于正文右下方不可见区域时不产生区块
const offscreenHit = matchRects({ rect: { left: 1000, top: 1000, right: 1100, bottom: 1100 } });
expectEqual(offscreenHit.length, 0, '完全不可见的命中不产生高亮块');

// 无冻结时退化为单块且裁剪区等于整个正文区（与改造前一致）
const plainHit = mapMatchRectToQuadrants({
  rect: { left: 10, top: 10, right: 60, bottom: 30 },
  headerW: HEADER_WIDTH,
  headerH: HEADER_HEIGHT,
  offsetX: 0,
  offsetY: 0,
  scale: 1,
  frozenDocW: 0,
  frozenDocH: 0,
  bodyRight: 400,
  bodyBottom: 300
});
expectEqual(plainHit.length, 1, '无冻结时高亮只有一块');
expectRect(plainHit[0].rect, HEADER_WIDTH + 10, HEADER_HEIGHT + 10, 50, 20, '无冻结时高亮位置与改造前一致');
expectRect(plainHit[0].clip, HEADER_WIDTH, HEADER_HEIGHT, 400 - HEADER_WIDTH, 300 - HEADER_HEIGHT,
  '无冻结时高亮裁剪区为整个正文区');

// 高缩放下极细单元格仍撑到 2vp 可见
const thinHit = mapMatchRectToQuadrants({
  rect: { left: 0.2, top: 0.2, right: 0.8, bottom: 0.8 },
  headerW: HEADER_WIDTH,
  headerH: HEADER_HEIGHT,
  offsetX: 0,
  offsetY: 0,
  scale: 0.5,
  frozenDocW: 0,
  frozenDocH: 0,
  bodyRight: 400,
  bodyBottom: 300
});
expectEqual(thinHit.length, 1, '极细单元格仍产出一块');
expectTrue(thinHit[0].rect.width >= 1.999 && thinHit[0].rect.height >= 1.999, '极细单元格高亮撑到 2vp');

// ---------------------------------------------------------------------------
// 6. 跳转避让
//    基准：400x300 视口，冻结 2 行 1 列（60x40 文档尺寸），当前偏移 (-25, -35)
//    => 可滚动视口 X 中心 251、Y 中心 181
// ---------------------------------------------------------------------------
function scrollTarget(patch: Partial<ScrollAvoidInput>): ScrollTarget {
  const base = {
    row: 0,
    column: 0,
    rect: { left: 200, top: 200, right: 260, bottom: 220 },
    effFrozenRows: 2,
    effFrozenCols: 1,
    frozenDataW: 60,
    frozenDataH: 40,
    headerW: HEADER_WIDTH,
    headerH: HEADER_HEIGHT,
    viewWidth: 400,
    viewHeight: 300,
    scale: 1,
    currentOffsetX: -25,
    currentOffsetY: -35,
    maxScrollX: 1000,
    maxScrollY: 1000
  };
  return resolveScrollToTarget({
    row: patch.row ?? base.row,
    column: patch.column ?? base.column,
    rect: patch.rect ?? base.rect,
    effFrozenRows: patch.effFrozenRows ?? base.effFrozenRows,
    effFrozenCols: patch.effFrozenCols ?? base.effFrozenCols,
    frozenDataW: patch.frozenDataW ?? base.frozenDataW,
    frozenDataH: patch.frozenDataH ?? base.frozenDataH,
    headerW: patch.headerW ?? base.headerW,
    headerH: patch.headerH ?? base.headerH,
    viewWidth: patch.viewWidth ?? base.viewWidth,
    viewHeight: patch.viewHeight ?? base.viewHeight,
    scale: patch.scale ?? base.scale,
    currentOffsetX: patch.currentOffsetX ?? base.currentOffsetX,
    currentOffsetY: patch.currentOffsetY ?? base.currentOffsetY,
    maxScrollX: patch.maxScrollX ?? base.maxScrollX,
    maxScrollY: patch.maxScrollY ?? base.maxScrollY
  });
}

// 命中冻结列：保持当前水平滚动位置
const keepFrozenCol = scrollTarget({ column: 0, row: 50 });
expectEqual(keepFrozenCol.offsetX, -25, '命中冻结列时保持当前水平偏移');

// 命中冻结行：保持当前垂直滚动位置
const keepFrozenRow = scrollTarget({ row: 0, column: 20 });
expectEqual(keepFrozenRow.offsetY, -35, '命中冻结行时保持当前垂直偏移');

// 命中交叉角：两轴都保持
const keepCorner = scrollTarget({ row: 0, column: 0 });
expectTrue(keepCorner.offsetX === -25 && keepCorner.offsetY === -35, '命中交叉角时两轴都保持当前偏移');

// 命中滚动行列：居中到可滚动视口中心（X 中心 251、Y 中心 181）
const scrollCenter = scrollTarget({ column: 20, row: 50 });
expectEqual(scrollCenter.offsetX, -21, '命中滚动列时水平居中到可滚动视口中心');
expectEqual(scrollCenter.offsetY, -51, '命中滚动行时垂直居中到可滚动视口中心');

// 混用：命中冻结列 + 滚动行
const mixed = scrollTarget({ column: 0, row: 50 });
expectEqual(mixed.offsetX, -25, '冻结列轴保持当前偏移');
expectEqual(mixed.offsetY, -51, '滚动行轴仍居中对齐');

// 无冻结时退化为改造前的居中公式
const legacy = scrollTarget({
  effFrozenRows: 0,
  effFrozenCols: 0,
  frozenDataW: 0,
  frozenDataH: 0,
  rect: { left: 200, top: 200, right: 240, bottom: 220 },
  currentOffsetX: 0,
  currentOffsetY: 0
});
expectEqual(legacy.offsetX, (400 - HEADER_WIDTH) / 2 - 220, '无冻结时水平居中公式与改造前一致');
expectEqual(legacy.offsetY, (300 - HEADER_HEIGHT) / 2 - 210, '无冻结时垂直居中公式与改造前一致');

// 冻结侧也受合法滚动范围钳位
const clampedFrozen = scrollTarget({
  column: 0,
  row: 0,
  currentOffsetX: -5000,
  currentOffsetY: -5000,
  maxScrollX: 120,
  maxScrollY: 80
});
expectEqual(clampedFrozen.offsetX, -120, '冻结侧偏移仍钳位到最大水平滚动距离');
expectEqual(clampedFrozen.offsetY, -80, '冻结侧偏移仍钳位到最大垂直滚动距离');

// 滚动侧目标超出合法范围时钳位到最大滚动距离
const clampedTarget = scrollTarget({
  column: 3,
  row: 3,
  rect: { left: 2000, top: 2000, right: 2100, bottom: 2100 },
  maxScrollX: 50,
  maxScrollY: 60
});
expectEqual(clampedTarget.offsetX, -50, '目标水平偏移钳位到最大水平滚动距离');
expectEqual(clampedTarget.offsetY, -60, '目标垂直偏移钳位到最大垂直滚动距离');

// 滚动侧目标位于正文左上方时钳位到 0（不允许反向滚动）
const clampedToZero = scrollTarget({
  column: 3,
  row: 3,
  rect: { left: 20, top: 20, right: 200, bottom: 40 },
  maxScrollX: 50,
  maxScrollY: 60
});
expectEqual(clampedToZero.offsetX, 0, '目标水平偏移超出左边界时钳位到 0');
expectEqual(clampedToZero.offsetY, 0, '目标垂直偏移超出上边界时钳位到 0');

// 高缩放下冻结区与单元格中心都按缩放换算（行列号需落在滚动侧才走居中分支）
const scaledTarget = scrollTarget({
  scale: 2,
  row: 50,
  column: 50,
  rect: { left: 100, top: 100, right: 140, bottom: 120 },
  currentOffsetX: 0,
  currentOffsetY: 0
});
expectEqual(scaledTarget.offsetX, -31, '缩放 2 倍时水平居中按缩放换算单元格中心');
expectEqual(scaledTarget.offsetY, -61, '缩放 2 倍时垂直居中按缩放换算单元格中心');

// 冻结分割线颜色需区别于网格线 #dce1e5 与表头线 #bfc7cd
expectTrue(FREEZE_LINE_COLOR === '#9aa5b1', '冻结分割线颜色为 #9aa5b1');

// ---------------------------------------------------------------------------
// 7. 接入点静态检查：确认 SpreadsheetView 与 OfficeModel 的冻结接入完整
// ---------------------------------------------------------------------------
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';

const root = resolve(import.meta.dirname, '../..');
const modelSource = readFileSync(resolve(root, 'viewer-ohos/src/main/ets/core/OfficeModel.ets'), 'utf8');
const viewSource = readFileSync(resolve(root, 'viewer-ohos/src/main/ets/render/SpreadsheetView.ets'), 'utf8');

checks++;
if (!/readonly frozenRows\?: number;/.test(modelSource) || !/readonly frozenColumns\?: number;/.test(modelSource)) {
  throw new Error('OfficeModel.Sheet 缺少可选的 frozenRows / frozenColumns 字段');
}

checks++;
if (!viewSource.includes('resolveFreezeQuadrants(') || !viewSource.includes('drawQuadrant(')) {
  throw new Error('SpreadsheetView 未接入四象限绘制');
}

checks++;
if (!viewSource.includes('FREEZE_LINE_COLOR')) {
  throw new Error('SpreadsheetView 未使用冻结分割线颜色');
}

checks++;
if (!viewSource.includes('resolveScrollToTarget(')) {
  throw new Error('SpreadsheetView.scrollToMatch 未接入跳转避让');
}

checks++;
if (!viewSource.includes('mapMatchRectToQuadrants(')) {
  throw new Error('SpreadsheetView 未按象限映射检索高亮');
}

// 旧的全量裁剪绘制入口（单次 clip 覆盖整个正文区）必须已移除，避免与象限绘制重复
checks++;
if (/ctx\.rect\(\s*HEADER_WIDTH,\s*HEADER_HEIGHT,\s*bodyRight - HEADER_WIDTH,\s*bodyBottom - HEADER_HEIGHT\s*\)/.test(viewSource)) {
  throw new Error('SpreadsheetView 仍存在改造前的单区裁剪绘制代码');
}

// 可滚动行标头必须从冻结边界起算（取正文底边会导致无冻结时行头整体消失）
checks++;
if (viewSource.includes('rows.first(unscaledFrozenBottom)')) {
  throw new Error('可滚动行标头起始行错误地取自正文底边');
}

// 跨象限绘制合并单元格时，代际去重必须在象限内生成（共享代际会让跨界合并只画一次）
checks++;
if (!/private nextMergeGen\(/.test(viewSource)) {
  throw new Error('缺少象限内合并单元格代际生成入口');
}

console.log(`Sheet freeze checks passed: ${checks}`);
