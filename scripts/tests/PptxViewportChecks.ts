import {
  PptxViewportPage,
  resolvePptxCurrentPage
} from '../../viewer-ohos/src/main/ets/render/PptxViewport';

let checks = 0;

function expectEqual(actual: number, expected: number, message: string): void {
  checks++;
  if (actual !== expected) {
    throw new Error(`${message}: 期望 ${expected}，实际 ${actual}`);
  }
}

const pages: PptxViewportPage[] = [
  { y: 0, height: 100 },
  { y: 116, height: 100 },
  { y: 232, height: 100 }
];

// 到达底部时，上一页的可见面积更大，也必须显示末页页码。
expectEqual(
  resolvePptxCurrentPage(pages, 2, 190, 190, 100, 250),
  3,
  '底部边界应强制选择末页'
);

// 到达顶部时，不沿用之前的页码。
expectEqual(
  resolvePptxCurrentPage(pages, 3, 0, 190, -12, 138),
  1,
  '顶部边界应强制选择首页'
);

// 文档无需滚动时保持首页，避免顶部与底部边界同时命中导致跳页。
expectEqual(
  resolvePptxCurrentPage(pages, 3, 0, 0, -12, 500),
  1,
  '整页可见时保持首页'
);

// 非边界区域仍按可见面积选择当前页。
expectEqual(
  resolvePptxCurrentPage(pages, 1, 60, 190, 50, 170),
  2,
  '中间区域选择可见面积最大的页面'
);

// 页面高度不同时，可见区域查找不能依赖固定页高。
const variablePages: PptxViewportPage[] = [
  { y: 0, height: 80 },
  { y: 96, height: 140 },
  { y: 252, height: 60 },
  { y: 328, height: 120 }
];
expectEqual(
  resolvePptxCurrentPage(variablePages, 1, 100, 500, 120, 300),
  2,
  '可变页高下正确计算可见面积'
);

expectEqual(resolvePptxCurrentPage([], 1, 0, 0, 0, 100), 0, '空文档页码为零');

console.log(`PPTX viewport checks passed: ${checks}`);
