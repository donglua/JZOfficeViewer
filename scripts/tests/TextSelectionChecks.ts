/**
 * JZOffice 鸿蒙端纯 TS 选区模型回归检查（Node.js 直接运行，无需构建）
 *
 * 运行：node scripts/tests/TextSelectionChecks.ts
 * 期望输出：OHOS TextSelectionChecks passed: 8
 */
import {
  ArrayLineMetrics,
  DocumentTextLayout,
  TextBlockLayout
} from '../../viewer-ohos/src/main/ets/render/TextSelectionModel.ts';
import type {
  TextRect,
  TextSelection
} from '../../viewer-ohos/src/main/ets/render/TextSelectionModel.ts';

let checks = 0;

function check(cond: boolean, msg: string): void {
  checks++;
  if (!cond) {
    throw new Error(msg);
  }
}

/** ArkTS 禁止无接口类型的对象字面量，一律经工厂函数构造 TextRect */
function makeRect(l: number, t: number, r: number, b: number): TextRect {
  const rect: TextRect = { left: l, top: t, right: r, bottom: b };
  return rect;
}

function makeBlock(blockIndex: number, tx: number, ty: number, text: string, charW: number): TextBlockLayout {
  const offsets: number[] = [];
  for (let i = 0; i <= text.length; i++) {
    offsets.push(i * charW);
  }
  const line = new ArrayLineMetrics(0, 0, text.length * charW, 20, 0, 0, text.length, 0, offsets);
  const bounds = makeRect(tx, ty, tx + Math.max(1, text.length * charW), ty + 20);
  const transform: number[] = [1, 0, 0, 1, tx, ty];
  return new TextBlockLayout(blockIndex, 0, bounds, transform, text, [line]);
}

const layout = new DocumentTextLayout([
  makeBlock(0, 10, 20, 'Hello world', 10),
  makeBlock(1, 10, 60, '你好世界', 16)
]);

// 1. 字符命中：局部 x = 35 - 10 = 25，字符宽度 10，字形中点 25 恰好落到字符 3 的起点
const hit = layout.hitTest(35, 30);
check(hit !== null && hit.blockIndex === 0 && hit.charIndex === 3, 'Hit test maps x=35 to char 3');

// 2. 反向跨块选区提取纯文本
const rev: TextSelection = {
  anchor: { blockIndex: 1, charIndex: 2 },
  focus: { blockIndex: 0, charIndex: 6 }
};
check(layout.selectedText(rev) === 'world\n你好', 'Reverse cross-block selectedText');

// 3. 跨块选区产生 2 个高亮矩形
const rects = layout.selectionRects(rev);
check(rects.length === 2, 'Cross-block selection yields 2 rects');

// 4. 块局部矩形宽度与 ranged 字符宽度一致（块 1 的 "你好" = 2 * 16 = 32）
const block1Rects = layout.selectionRectsForBlock(rev, 1);
check(block1Rects.length === 1 && Math.abs(block1Rects[0].localRect.right - 32) < 0.1, 'Block-local rect matches width');

// 5. 起始手柄 docX 落在块 1 的第 2 个字符边界：10 + 2 * 16 = 42？
//    注意起点是 (block 1, char 2) 与 (block 0, char 6) 中较早者，即 block 0 char 6 → 10 + 6 * 10 = 70
const handles = layout.handleGeometry(rev);
check(handles !== null && Math.abs(handles.start.docX - 70) < 0.1, 'Start handle docX matches');

// 6. 词界：charIndex 1 位于 "Hello" 中部
const word = layout.wordRange({ blockIndex: 0, charIndex: 1 });
check(word !== null && layout.selectedText(word) === 'Hello', 'Word range selects Hello');

// 7. 全选跨块以换行连接
const all = layout.allTextRange();
check(all !== null && layout.selectedText(all) === 'Hello world\n你好世界', 'Select all joins blocks');

// 8. 代理对保护：'A😀B' 中 x=21 不得切在代理对之间
const emojiLayout = new DocumentTextLayout([makeBlock(0, 0, 0, 'A\uD83D\uDE00B', 10)]);
const emojiHit = emojiLayout.hitTest(21, 10);
check(emojiHit !== null && (emojiHit.charIndex === 1 || emojiHit.charIndex === 3), 'Surrogate pair protected');

console.log(`OHOS TextSelectionChecks passed: ${checks}`);
