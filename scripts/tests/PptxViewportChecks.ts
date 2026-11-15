import {
  resolvePptxCurrentPage,
  resolvePptxVisibleRange
} from '../../viewer-ohos/src/main/ets/render/PptxViewport.ts';
import type {
  PptxViewportPage,
  PptxVisibleRange
} from '../../viewer-ohos/src/main/ets/render/PptxViewport.ts';

let checks = 0;

function expectEqual(actual: number, expected: number, message: string): void {
  checks++;
  if (actual !== expected) {
    throw new Error(`${message}: 期望 ${expected}，实际 ${actual}`);
  }
}

function expectRange(actual: PptxVisibleRange, start: number, end: number, message: string): void {
  checks++;
  if (actual.start !== start || actual.end !== end) {
    throw new Error(`${message}: 期望 [${start}, ${end})，实际 [${actual.start}, ${actual.end})`);
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

expectRange(resolvePptxVisibleRange(pages, -12, 80), 0, 1, '顶部视口只返回首页');
expectRange(resolvePptxVisibleRange(pages, 90, 130), 0, 2, '跨页视口返回相交页面');
expectRange(resolvePptxVisibleRange(pages, 101, 115), 1, 1, '页间空隙不返回页面');
expectRange(resolvePptxVisibleRange(pages, 232, 332), 2, 3, '边界相等时包含末页');
expectRange(resolvePptxVisibleRange([], 0, 100), 0, 0, '空文档可见范围为空');

const longPages: PptxViewportPage[] = [];
for (let i = 0; i < 100; i++) longPages.push({ y: i * 116, height: 100 });
expectRange(resolvePptxVisibleRange(longPages, 5800, 5900), 50, 51, '长文档二分定位中间页');

console.log(`PPTX viewport checks passed: ${checks}`);
