export interface DocxWrapObstacle {
  top: number;
  bottom: number;
  left: number;
  right: number;
  side: 'left' | 'right';
}

export interface DocxWrapBlockInput {
  readonly type: string;
  readonly x: number;
  readonly y: number;
  readonly width: number;
  readonly height: number;
  readonly wrapMode: string;
  readonly horizontalAlign: number;
  readonly behindDoc: boolean;
  readonly distTop: number;
  readonly distBottom: number;
  readonly distLeft: number;
  readonly distRight: number;
  readonly hasParagraphs: boolean;
}

export interface DocxFloatBox {
  readonly x: number;
  readonly width: number;
  readonly height: number;
}

export interface DocxPlacedFloatPlan {
  readonly blockIndex: number;
  readonly x: number;
  readonly y: number;
  readonly width: number;
  readonly height: number;
  readonly behind: boolean;
}

export interface DocxWrapGroupPlan {
  readonly renderIndex: number;
  readonly endIndex: number;
  readonly width: number;
  readonly height: number;
  readonly flowStartY: number;
  readonly floats: DocxPlacedFloatPlan[];
  readonly flowBlockIndices: number[];
  readonly obstacles: DocxWrapObstacle[];
}

export interface DocxWrapPlanResult {
  readonly groups: Map<number, DocxWrapGroupPlan>;
  readonly consumedToGroup: Map<number, number>;
}

export function isDocxFloatingWrap(wrapMode: string | undefined): boolean {
  return wrapMode !== undefined && wrapMode !== 'INLINE';
}

function isDocxTextBlockInput(el: DocxWrapBlockInput): boolean {
  return el.type === 'TEXT' && el.hasParagraphs;
}

export function resolveDocxFloatBox(
  docWidth: number,
  marginLeft: number,
  marginRight: number,
  el: DocxWrapBlockInput,
  contentW: number
): DocxFloatBox {
  const docW = docWidth > 0 ? docWidth : 595;
  const coreMarginL = marginLeft > 0 ? marginLeft : 72;
  const coreMarginR = marginRight > 0 ? marginRight : 72;
  const coreContentW = Math.max(1, docW - coreMarginL - coreMarginR);
  let w = el.width > 0 ? el.width : contentW;
  let h = el.height > 0 ? el.height : (el.type === 'IMAGE' ? 100 : 60);
  if (w > contentW && el.width > 0 && el.type === 'IMAGE') {
    h = h * (contentW / w);
    w = contentW;
  }
  const align = el.horizontalAlign ?? 0;
  let x = 0;
  if (align === 1) {
    x = 0;
  } else if (align === 2) {
    x = Math.max(0, (contentW - w) / 2);
  } else if (align === 3) {
    x = Math.max(0, contentW - w);
  } else {
    const scaled = (el.x - coreMarginL) * (contentW / coreContentW);
    x = Math.max(0, Math.min(Math.max(0, contentW - w), scaled));
  }
  return { x, width: w, height: h };
}

export function resolveDocxItemTopMargin(
  index: number,
  headerCount: number,
  bodyCount: number,
  sectionGap: number,
  isWrapGroup: boolean,
  wrapMode: string | undefined,
  y: number,
  distTop: number
): number {
  const secTop = (headerCount + bodyCount > 0 && headerCount + bodyCount === index) ? sectionGap : 0;
  if (isWrapGroup || !isDocxFloatingWrap(wrapMode)) {
    return secTop;
  }
  return secTop + Math.max(0, y || 0, distTop || 0);
}

export function planDocxWrapGroups(
  allBlocks: DocxWrapBlockInput[],
  secRanges: [number, number][],
  docWidth: number,
  marginLeft: number,
  marginRight: number,
  contentWidth: number,
  measureTextHeight: (blockIndex: number, startY: number, obstacles: DocxWrapObstacle[]) => number
): DocxWrapPlanResult {
  const groups: Map<number, DocxWrapGroupPlan> = new Map();
  const consumedToGroup: Map<number, number> = new Map();

  for (const range of secRanges) {
    const secStart = range[0];
    const secEnd = range[1];
    let i = secStart;
    while (i < secEnd) {
      const firstEl = allBlocks[i];
      if (!isDocxFloatingWrap(firstEl.wrapMode) || firstEl.wrapMode === 'TOP_AND_BOTTOM') {
        i++;
        continue;
      }
      const floatIndices: number[] = [];
      let j = i;
      while (j < secEnd && isDocxFloatingWrap(allBlocks[j].wrapMode) && allBlocks[j].wrapMode !== 'TOP_AND_BOTTOM') {
        floatIndices.push(j);
        j++;
      }
      const floats: DocxPlacedFloatPlan[] = [];
      let obstacles: DocxWrapObstacle[] = [];
      let maxFloatBottom = 0;
      let flowStartY = 0;
      let noneMaxBottom = 0;
      for (const fIdx of floatIndices) {
        const fEl = allBlocks[fIdx];
        const box = resolveDocxFloatBox(docWidth, marginLeft, marginRight, fEl, contentWidth);
        const fy = flowStartY + Math.max(0, fEl.y || 0);
        floats.push({
          blockIndex: fIdx,
          x: box.x,
          y: fy,
          width: box.width,
          height: box.height,
          behind: fEl.behindDoc === true
        });
        maxFloatBottom = Math.max(maxFloatBottom, fy + box.height);
        if (fEl.wrapMode === 'NONE') {
          noneMaxBottom = Math.max(noneMaxBottom, fy + box.height);
        } else {
          const obsLeft = box.x - Math.max(0, fEl.distLeft || 0);
          const obsRight = box.x + box.width + Math.max(0, fEl.distRight || 0);
          const obsTop = fy - Math.max(0, fEl.distTop || 0);
          const obsBot = fy + box.height + Math.max(0, fEl.distBottom || 0);
          const align = fEl.horizontalAlign ?? 0;
          const side: 'left' | 'right' = align === 1
            ? 'left'
            : (align === 3 ? 'right' : (box.x + box.width * 0.5 <= contentWidth * 0.5 ? 'left' : 'right'));
          if (obsLeft <= 36 && obsRight >= contentWidth - 36) {
            flowStartY = Math.max(flowStartY, obsBot + 6);
            obstacles = obstacles.filter((o: DocxWrapObstacle): boolean => o.bottom > flowStartY);
          } else {
            obstacles.push({ top: obsTop, bottom: obsBot, left: obsLeft, right: obsRight, side });
          }
        }
      }
      let maxObsBottom = 0;
      for (const o of obstacles) {
        if (o.bottom > maxObsBottom) {
          maxObsBottom = o.bottom;
        }
      }
      const hasOverlappingNone = noneMaxBottom > flowStartY;
      const flowBlockIndices: number[] = [];
      let curY = flowStartY;
      if (obstacles.length > 0 || hasOverlappingNone) {
        while (j < secEnd && !isDocxFloatingWrap(allBlocks[j].wrapMode) && isDocxTextBlockInput(allBlocks[j])) {
          const textH = measureTextHeight(j, curY, obstacles);
          flowBlockIndices.push(j);
          curY += textH + 8;
          j++;
          if (obstacles.length === 0 || curY >= maxObsBottom) {
            break;
          }
        }
      }
      const contentBottom = flowBlockIndices.length > 0 ? Math.max(0, curY - 8) : 0;
      const clearBottom = flowStartY > 0 ? Math.max(0, flowStartY - 8) : 0;
      const totalHeight = Math.max(1, maxFloatBottom, maxObsBottom, clearBottom, contentBottom);
      const endIndex = j - 1;
      groups.set(i, {
        renderIndex: i,
        endIndex,
        width: contentWidth,
        height: totalHeight,
        flowStartY,
        floats,
        flowBlockIndices,
        obstacles
      });
      for (let k = i + 1; k <= endIndex; k++) {
        consumedToGroup.set(k, i);
      }
      i = j;
    }
  }

  return { groups, consumedToGroup };
}
