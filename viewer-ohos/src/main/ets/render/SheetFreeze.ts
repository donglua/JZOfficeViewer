/**
 * XLSX 冻结窗格纯逻辑模块（HarmonyOS）。
 *
 * 本模块只做几何与数值计算，不依赖 ArkUI / Canvas，便于用 node 直接执行
 * scripts/tests/SheetFreezeChecks.ts 做纯逻辑回归。
 *
 * 坐标约定（对齐设计文档 §3.2.2 的屏幕 vp 坐标系）：
 * 1. 屏幕坐标：以画布左上角为原点、单位为 vp，列头宽 HEADER_WIDTH=42 固定在左侧，
 *    行头高 HEADER_HEIGHT=22 固定在顶部。
 * 2. 文档坐标：core 输出的行高/列宽前缀和，不含缩放、不含滚动。
 * 3. 屏幕 = 表头偏移 + 滚动偏移 + 文档坐标 * 缩放；某轴冻结时该轴滚动偏移取 0。
 *
 * 长度单位在接口注释中显式标注「屏幕 vp」或「文档坐标」，两者不可混用：
 * 冻结区尺寸在占比保护与四象限/跳转中统一用屏幕 vp（已乘缩放），
 * 在检索高亮的文档矩形切分中统一用文档坐标。
 */

/** 冻结区允许占据的正文视口比例上限，超过则本帧取消该轴冻结（按轴独立判断） */
export const MAX_FROZEN_RATIO = 0.75;

/** 冻结分割线颜色，区别于普通网格线 #dce1e5 与表头分隔线 #bfc7cd */
export const FREEZE_LINE_COLOR = '#9aa5b1';

/**
 * 归一化单轴冻结数量：缺省、负数、非有限值按 0 处理，小数向下取整，并钳位到表维度。
 * 入参来自 core JSON（可选字段，缺省表示不冻结）。
 */
export function normalizeFrozen(value: number | undefined | null, limit: number): number {
  const safeLimit = Number.isFinite(limit) ? Math.max(0, Math.floor(limit)) : 0;
  const raw = value === undefined || value === null ? 0 : value;
  if (!Number.isFinite(raw)) return 0;
  return Math.min(Math.max(0, Math.floor(raw)), safeLimit);
}

/** 视口占比保护入参（长度单位：屏幕 vp，frozenDataW/H 已乘缩放） */
export interface FrozenRatioInput {
  /** 归一化后的冻结行数 */
  readonly frozenRows: number;
  /** 归一化后的冻结列数 */
  readonly frozenColumns: number;
  /** 表格总行数 */
  readonly rowCount: number;
  /** 表格总列数 */
  readonly colCount: number;
  /** 扣除列头后的正文可用宽度（屏幕 vp） */
  readonly availBodyW: number;
  /** 扣除行头后的正文可用高度（屏幕 vp） */
  readonly availBodyH: number;
  /** 前 frozenColumns 列在当前缩放下的宽度（屏幕 vp） */
  readonly frozenDataW: number;
  /** 前 frozenRows 行在当前缩放下的高度（屏幕 vp） */
  readonly frozenDataH: number;
}

/** 本帧生效的冻结行列数（按轴独立降级后的结果） */
export interface EffectiveFrozen {
  readonly effFrozenRows: number;
  readonly effFrozenCols: number;
}

/**
 * 按轴独立判断本帧有效冻结行列数（设计文档 §3.2.1）：
 * 冻结数为 0、可用区 <= 0、或冻结区超过可用区 75% 时该轴置 0，两轴互不影响。
 * 因此高倍放大下若只有冻结列超出 75% 视口宽度，仅取消列冻结，冻结行仍保持锁定。
 */
export function resolveEffectiveFrozen(input: FrozenRatioInput): EffectiveFrozen {
  const rowCount = Math.max(0, Math.floor(input.rowCount));
  const colCount = Math.max(0, Math.floor(input.colCount));
  const availW = Math.max(0, input.availBodyW);
  const availH = Math.max(0, input.availBodyH);

  let effFrozenRows = 0;
  if (input.frozenRows > 0 && availH > 0 && input.frozenDataH <= availH * MAX_FROZEN_RATIO) {
    effFrozenRows = Math.min(Math.floor(input.frozenRows), rowCount);
  }
  let effFrozenCols = 0;
  if (input.frozenColumns > 0 && availW > 0 && input.frozenDataW <= availW * MAX_FROZEN_RATIO) {
    effFrozenCols = Math.min(Math.floor(input.frozenColumns), colCount);
  }
  return { effFrozenRows: effFrozenRows, effFrozenCols: effFrozenCols };
}

/** 屏幕 vp 坐标下的矩形（与 CanvasElementDrawer.OfficeRect 字段一致，此处独立声明以免依赖 .ets） */
export interface FreezeRect {
  readonly x: number;
  readonly y: number;
  readonly width: number;
  readonly height: number;
}

/** 文档坐标系（未缩放）下的矩形，用于合并单元格与命中范围计算 */
export interface FreezeDocRect {
  readonly left: number;
  readonly top: number;
  readonly right: number;
  readonly bottom: number;
}

/**
 * 单个绘制象限（设计文档 §3.2.2 表格）。
 * 行列范围均为左闭右开区间：rows 为 [rowStart, rowEnd)，cols 为 [colStart, colEnd)。
 */
export interface FreezeQuadrant {
  /** 本象限的裁剪区域（屏幕 vp） */
  readonly clip: FreezeRect;
  /** 象限标识：scroll / frozenCols / frozenRows / corner */
  readonly kind: string;
  readonly rowStart: number;
  readonly rowEnd: number;
  readonly colStart: number;
  readonly colEnd: number;
  /** X 轴是否锁定（锁定表示不随水平滚动位移） */
  readonly lockX: boolean;
  /** Y 轴是否锁定 */
  readonly lockY: boolean;
  /** 本象限实际使用的水平屏幕偏移（锁定轴恒为 0，单位屏幕 vp、取值 <= 0） */
  readonly offsetX: number;
  /** 本象限实际使用的垂直屏幕偏移（锁定轴恒为 0） */
  readonly offsetY: number;
}

/** 四象限切分入参（长度单位：屏幕 vp） */
export interface FreezeQuadrantInput {
  readonly headerW: number;
  readonly headerH: number;
  /** 屏幕水平滚动偏移（<= 0） */
  readonly offsetX: number;
  /** 屏幕垂直滚动偏移（<= 0） */
  readonly offsetY: number;
  /** 冻结列区宽度（屏幕 vp，= columnOffsets[effFrozenCols] * 缩放） */
  readonly frozenDataW: number;
  /** 冻结行区高度（屏幕 vp，= rowOffsets[effFrozenRows] * 缩放） */
  readonly frozenDataH: number;
  /** 正文可绘制右边界（屏幕 vp，已按画布与表格范围取小） */
  readonly bodyRight: number;
  /** 正文可绘制下边界（屏幕 vp） */
  readonly bodyBottom: number;
  readonly rowCount: number;
  readonly colCount: number;
  readonly effFrozenRows: number;
  readonly effFrozenCols: number;
}

/**
 * 把象限矩形收敛到正文可绘制区域，避免画布窄于冻结区时越界绘制到表头上。
 * 返回的宽高可能非正，由调用方据此剔除象限。
 */
function clampRectToBody(
  x: number,
  y: number,
  width: number,
  height: number,
  headerW: number,
  headerH: number,
  bodyRight: number,
  bodyBottom: number
): FreezeRect {
  const left = Math.max(headerW, x);
  const top = Math.max(headerH, y);
  const right = Math.min(bodyRight, x + width);
  const bottom = Math.min(bodyBottom, y + height);
  return { x: left, y: top, width: right - left, height: bottom - top };
}

/**
 * 计算最多 4 个互不重叠的绘制象限，返回顺序即绘制顺序（滚动区 -> 冻结列 -> 冻结行 -> 交叉角）。
 * 所有裁剪区都会再收敛到正文可绘制区域；尺寸非正的象限（正文不可见或冻结区被完全挤出视口）
 * 会被剔除，因此 effFrozenRows/effFrozenCols 均为 0 时结果只含一个覆盖整个正文区的滚动区。
 */
export function resolveFreezeQuadrants(input: FreezeQuadrantInput): FreezeQuadrant[] {
  const headerW = input.headerW;
  const headerH = input.headerH;
  const frozenRight = headerW + Math.max(0, input.frozenDataW);
  const frozenBottom = headerH + Math.max(0, input.frozenDataH);
  const bodyRight = input.bodyRight;
  const bodyBottom = input.bodyBottom;
  const rowCount = Math.max(0, Math.floor(input.rowCount));
  const colCount = Math.max(0, Math.floor(input.colCount));
  const effRows = Math.min(Math.max(0, Math.floor(input.effFrozenRows)), rowCount);
  const effCols = Math.min(Math.max(0, Math.floor(input.effFrozenCols)), colCount);
  const offsetX = Math.min(0, input.offsetX);
  const offsetY = Math.min(0, input.offsetY);
  const quadrants: FreezeQuadrant[] = [];

  // 1. 滚动正文区（右下）：两轴均未完全冻结时才存在
  if (effCols < colCount && effRows < rowCount) {
    quadrants.push({
      clip: clampRectToBody(frozenRight, frozenBottom, bodyRight - frozenRight, bodyBottom - frozenBottom,
        headerW, headerH, bodyRight, bodyBottom),
      kind: 'scroll',
      rowStart: effRows,
      rowEnd: rowCount,
      colStart: effCols,
      colEnd: colCount,
      lockX: false,
      lockY: false,
      offsetX: offsetX,
      offsetY: offsetY
    });
  }
  // 2. 冻结列区（左下）：X 锁定、Y 正常滚动
  if (effCols > 0 && effRows < rowCount) {
    quadrants.push({
      clip: clampRectToBody(headerW, frozenBottom, frozenRight - headerW, bodyBottom - frozenBottom,
        headerW, headerH, bodyRight, bodyBottom),
      kind: 'frozenCols',
      rowStart: effRows,
      rowEnd: rowCount,
      colStart: 0,
      colEnd: effCols,
      lockX: true,
      lockY: false,
      offsetX: 0,
      offsetY: offsetY
    });
  }
  // 3. 冻结行区（右上）：Y 锁定、X 正常滚动
  if (effRows > 0 && effCols < colCount) {
    quadrants.push({
      clip: clampRectToBody(frozenRight, headerH, bodyRight - frozenRight, frozenBottom - headerH,
        headerW, headerH, bodyRight, bodyBottom),
      kind: 'frozenRows',
      rowStart: 0,
      rowEnd: effRows,
      colStart: effCols,
      colEnd: colCount,
      lockX: false,
      lockY: true,
      offsetX: offsetX,
      offsetY: 0
    });
  }
  // 4. 交叉冻结角（左上）：两轴均锁定
  if (effCols > 0 && effRows > 0) {
    quadrants.push({
      clip: clampRectToBody(headerW, headerH, frozenRight - headerW, frozenBottom - headerH,
        headerW, headerH, bodyRight, bodyBottom),
      kind: 'corner',
      rowStart: 0,
      rowEnd: effRows,
      colStart: 0,
      colEnd: effCols,
      lockX: true,
      lockY: true,
      offsetX: 0,
      offsetY: 0
    });
  }

  const visible: FreezeQuadrant[] = [];
  for (const q of quadrants) {
    if (q.clip.width > 0 && q.clip.height > 0) {
      visible.push(q);
    }
  }
  return visible;
}

/** 判断两个文档矩形是否相交（边贴边不算相交，避免零面积重复绘制） */
export function intersectsDocRect(a: FreezeDocRect, b: FreezeDocRect): boolean {
  return a.right > b.left && a.left < b.right && a.bottom > b.top && a.top < b.bottom;
}

/**
 * 把象限裁剪区反算成文档坐标可见范围（返回值单位：文档坐标）。
 * 锁定轴因偏移为 0，反算结果即冻结区的文档范围。
 */
export function resolveQuadrantDocClip(
  quadrant: FreezeQuadrant,
  headerW: number,
  headerH: number,
  scale: number
): FreezeDocRect {
  const s = scale > 0 ? scale : 1;
  const left = (quadrant.clip.x - headerW - quadrant.offsetX) / s;
  const right = (quadrant.clip.x + quadrant.clip.width - headerW - quadrant.offsetX) / s;
  const top = (quadrant.clip.y - headerH - quadrant.offsetY) / s;
  const bottom = (quadrant.clip.y + quadrant.clip.height - headerH - quadrant.offsetY) / s;
  return { left: left, top: top, right: right, bottom: bottom };
}

/**
 * 跨冻结边界合并单元格的裁剪辅助（免分配版本，入参为文档坐标边界）。
 * 与象限裁剪区不相交时返回 null（该象限不参与绘制）；部分相交时返回合并区域的完整屏幕矩形，
 * 由调用方在象限 clip 内自然裁剪，从而只画出落在本象限的那一部分。
 */
export function resolveQuadrantMergeBounds(
  left: number,
  top: number,
  right: number,
  bottom: number,
  quadrant: FreezeQuadrant,
  headerW: number,
  headerH: number,
  scale: number
): FreezeRect | null {
  const s = scale > 0 ? scale : 1;
  const docClip = resolveQuadrantDocClip(quadrant, headerW, headerH, s);
  const overlap = right > docClip.left && left < docClip.right && bottom > docClip.top && top < docClip.bottom;
  if (!overlap) return null;
  return {
    x: headerW + quadrant.offsetX + left * s,
    y: headerH + quadrant.offsetY + top * s,
    width: (right - left) * s,
    height: (bottom - top) * s
  };
}

/**
 * 跨冻结边界合并单元格的裁剪辅助：`merge` 与返回值含义同 resolveQuadrantMergeBounds。
 */
export function resolveQuadrantMergeRect(
  merge: FreezeDocRect,
  quadrant: FreezeQuadrant,
  headerW: number,
  headerH: number,
  scale: number
): FreezeRect | null {
  return resolveQuadrantMergeBounds(merge.left, merge.top, merge.right, merge.bottom,
    quadrant, headerW, headerH, scale);
}

/** 检索高亮象限映射入参（冻结区尺寸为文档坐标，其余偏移为屏幕 vp） */
export interface MatchHighlightInput {
  /** 命中范围的文档矩形（文档坐标；合并单元格取整个合并区域） */
  readonly rect: FreezeDocRect;
  readonly headerW: number;
  readonly headerH: number;
  /** 屏幕水平滚动偏移（<= 0） */
  readonly offsetX: number;
  /** 屏幕垂直滚动偏移（<= 0） */
  readonly offsetY: number;
  readonly scale: number;
  /** 生效冻结列区宽度（文档坐标；effFrozenCols 为 0 时传 0） */
  readonly frozenDocW: number;
  /** 生效冻结行区高度（文档坐标；effFrozenRows 为 0 时传 0） */
  readonly frozenDocH: number;
  readonly bodyRight: number;
  readonly bodyBottom: number;
}

/** 高亮切片结果：rect 为屏幕矩形，clip 为所属象限的裁剪区域 */
export interface MatchQuadrantRect {
  readonly clip: FreezeRect;
  readonly rect: FreezeRect;
}

/** 单轴上的高亮分段：文档坐标区间 + 是否处于冻结侧 */
interface HighlightBand {
  readonly docStart: number;
  readonly docEnd: number;
  readonly locked: boolean;
}

/** 按冻结边界把文档坐标区间切成冻结侧与滚动侧分段 */
function splitHighlightBands(start: number, end: number, frozenExtent: number): HighlightBand[] {
  const bands: HighlightBand[] = [];
  if (frozenExtent > 0 && start < frozenExtent && end > 0) {
    bands.push({ docStart: Math.max(0, start), docEnd: Math.min(frozenExtent, end), locked: true });
  }
  const scrollStart = frozenExtent > 0 ? Math.max(frozenExtent, start) : start;
  if (end > scrollStart) {
    bands.push({ docStart: scrollStart, docEnd: end, locked: false });
  }
  return bands;
}

/**
 * 检索高亮象限映射：把命中矩形按冻结边界切成若干带裁剪的屏幕矩形，
 * 保证落在滚动区的部分绝不覆盖冻结区，落在冻结区的部分只随未冻结轴滚动。
 * 宽或高不足 2vp 时会撑到 2vp（仍限制在象限裁剪区内），避免高缩放下细线不可见。
 */
export function mapMatchRectToQuadrants(input: MatchHighlightInput): MatchQuadrantRect[] {
  const s = input.scale > 0 ? input.scale : 1;
  const frozenW = Math.max(0, input.frozenDocW);
  const frozenH = Math.max(0, input.frozenDocH);
  const frozenRight = input.headerW + frozenW * s;
  const frozenBottom = input.headerH + frozenH * s;
  const bodyRight = input.bodyRight;
  const bodyBottom = input.bodyBottom;
  const rect = input.rect;

  const xBands = splitHighlightBands(rect.left, rect.right, frozenW);
  const yBands = splitHighlightBands(rect.top, rect.bottom, frozenH);

  const result: MatchQuadrantRect[] = [];
  for (const xb of xBands) {
    for (const yb of yBands) {
      const xOffset = input.headerW + (xb.locked ? 0 : input.offsetX);
      const yOffset = input.headerH + (yb.locked ? 0 : input.offsetY);
      const x = xOffset + xb.docStart * s;
      const y = yOffset + yb.docStart * s;
      const right = xOffset + xb.docEnd * s;
      const bottom = yOffset + yb.docEnd * s;

      let clip: FreezeRect;
      if (xb.locked && yb.locked) {
        clip = { x: input.headerW, y: input.headerH, width: frozenRight - input.headerW, height: frozenBottom - input.headerH };
      } else if (xb.locked) {
        clip = { x: input.headerW, y: frozenBottom, width: frozenRight - input.headerW, height: bodyBottom - frozenBottom };
      } else if (yb.locked) {
        clip = { x: frozenRight, y: input.headerH, width: bodyRight - frozenRight, height: frozenBottom - input.headerH };
      } else {
        clip = { x: frozenRight, y: frozenBottom, width: bodyRight - frozenRight, height: bodyBottom - frozenBottom };
      }
      if (clip.width <= 0 || clip.height <= 0) continue;

      const clippedLeft = Math.max(x, clip.x);
      const clippedTop = Math.max(y, clip.y);
      let clippedRight = Math.min(right, clip.x + clip.width);
      let clippedBottom = Math.min(bottom, clip.y + clip.height);
      if (clippedRight <= clippedLeft || clippedBottom <= clippedTop) continue;
      if (clippedRight - clippedLeft < 2) {
        clippedRight = Math.min(clip.x + clip.width, clippedLeft + 2);
      }
      if (clippedBottom - clippedTop < 2) {
        clippedBottom = Math.min(clip.y + clip.height, clippedTop + 2);
      }
      result.push({
        clip: clip,
        rect: {
          x: clippedLeft,
          y: clippedTop,
          width: clippedRight - clippedLeft,
          height: clippedBottom - clippedTop
        }
      });
    }
  }
  return result;
}

/** 检索跳转避让入参（长度单位：屏幕 vp） */
export interface ScrollAvoidInput {
  /** 命中锚点行（合并单元格取左上锚点行） */
  readonly row: number;
  /** 命中锚点列 */
  readonly column: number;
  /** 目标单元格（或合并区域）的文档矩形 */
  readonly rect: FreezeDocRect;
  readonly effFrozenRows: number;
  readonly effFrozenCols: number;
  /** 生效冻结列区宽度（屏幕 vp；effFrozenCols 为 0 时传 0） */
  readonly frozenDataW: number;
  /** 生效冻结行区高度（屏幕 vp；effFrozenRows 为 0 时传 0） */
  readonly frozenDataH: number;
  readonly headerW: number;
  readonly headerH: number;
  readonly viewWidth: number;
  readonly viewHeight: number;
  readonly scale: number;
  /** 当前水平滚动偏移（<= 0） */
  readonly currentOffsetX: number;
  /** 当前垂直滚动偏移（<= 0） */
  readonly currentOffsetY: number;
  /** 合法水平滚动距离上限（>= 0，屏幕 vp） */
  readonly maxScrollX: number;
  /** 合法垂直滚动距离上限（>= 0，屏幕 vp） */
  readonly maxScrollY: number;
}

/** 跳转目标偏移（屏幕滚动偏移，<= 0） */
export interface ScrollTarget {
  readonly offsetX: number;
  readonly offsetY: number;
}

/** 把目标偏移钳位到合法滚动范围 [0, maxScroll]（屏幕偏移取负号） */
function clampScrollOffset(offset: number, maxScroll: number): number {
  const limit = Math.max(0, maxScroll);
  if (!Number.isFinite(offset)) return 0;
  return Math.min(0, Math.max(-limit, offset));
}

/**
 * 跳转避让（设计文档 §3.3）：命中冻结侧时该轴保持当前滚动位置，命中滚动侧时把目标居中到
 * 可滚动视口 [HEADER_WIDTH + frozenDataW .. viewWidth]（Y 轴同理）并钳位到合法滚动范围。
 * 跨界合并单元格按锚点行列判断，锚点在冻结侧即保持该轴当前偏移。
 */
export function resolveScrollToTarget(input: ScrollAvoidInput): ScrollTarget {
  const s = input.scale > 0 ? input.scale : 1;
  const frozenW = input.effFrozenCols > 0 ? Math.max(0, input.frozenDataW) : 0;
  const frozenH = input.effFrozenRows > 0 ? Math.max(0, input.frozenDataH) : 0;
  const centerX = input.headerW + frozenW + Math.max(0, input.viewWidth - input.headerW - frozenW) / 2;
  const centerY = input.headerH + frozenH + Math.max(0, input.viewHeight - input.headerH - frozenH) / 2;
  const cellCenterX = (input.rect.left + input.rect.right) / 2 * s;
  const cellCenterY = (input.rect.top + input.rect.bottom) / 2 * s;

  // 命中冻结列：目标已固定可见，保持当前水平滚动位置；否则居中到可滚动视口中心
  const offsetX = input.effFrozenCols > 0 && input.column < input.effFrozenCols
    ? clampScrollOffset(input.currentOffsetX, input.maxScrollX)
    : clampScrollOffset(centerX - input.headerW - cellCenterX, input.maxScrollX);

  // 命中冻结行：目标已固定可见，保持当前垂直滚动位置；否则居中到可滚动视口中心
  const offsetY = input.effFrozenRows > 0 && input.row < input.effFrozenRows
    ? clampScrollOffset(input.currentOffsetY, input.maxScrollY)
    : clampScrollOffset(centerY - input.headerH - cellCenterY, input.maxScrollY);

  return { offsetX: offsetX, offsetY: offsetY };
}
