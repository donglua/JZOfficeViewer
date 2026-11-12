export interface PptxViewportPage {
  readonly y: number;
  readonly height: number;
}

/**
 * 根据视口位置计算当前幻灯片页码。
 * 顶部与底部优先使用边界页码，避免小页面并排显示时“可见面积最大页”停留在相邻页。
 */
export function resolvePptxCurrentPage(
  pages: PptxViewportPage[],
  currentPage: number,
  offsetY: number,
  maxOffsetY: number,
  visibleTop: number,
  visibleBottom: number
): number {
  if (pages.length === 0) return 0;

  const pageCount = pages.length;
  const maxOffset = Math.max(0, maxOffsetY);
  if (maxOffset > 0 && offsetY >= maxOffset - 0.5) return pageCount;
  if (offsetY <= 0.5) return 1;

  // 页面底边随 y 单调递增，二分找到第一块可能可见的页面，避免每帧遍历整份文档。
  let low = 0;
  let high = pageCount;
  while (low < high) {
    const mid = Math.floor((low + high) / 2);
    const page = pages[mid];
    if (page.y + page.height < visibleTop) {
      low = mid + 1;
    } else {
      high = mid;
    }
  }

  let bestPage = Math.max(1, Math.min(pageCount, currentPage));
  let bestVisible = -1;
  for (let i = low; i < pageCount; i++) {
    const page = pages[i];
    if (page.y > visibleBottom) break;
    const visible = Math.max(0, Math.min(visibleBottom, page.y + page.height) - Math.max(visibleTop, page.y));
    if (visible > bestVisible + 0.01 || (Math.abs(visible - bestVisible) <= 0.01 && i + 1 === currentPage)) {
      bestVisible = visible;
      bestPage = i + 1;
    }
  }
  return bestPage;
}
