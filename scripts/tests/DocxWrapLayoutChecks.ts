import {
  planDocxWrapGroups,
  resolveDocxItemTopMargin
} from '../../viewer-ohos/src/main/ets/render/DocxWrapLayout.ts';
import type {
  DocxWrapBlockInput,
  DocxWrapObstacle
} from '../../viewer-ohos/src/main/ets/render/DocxWrapLayout.ts';

let checks = 0;

function expectEqual(actual: number, expected: number, message: string): void {
  checks++;
  if (Math.abs(actual - expected) > 1e-4) {
    throw new Error(`${message}: 期望 ${expected}，实际 ${actual}`);
  }
}

function expectTrue(condition: boolean, message: string): void {
  checks++;
  if (!condition) {
    throw new Error(message);
  }
}

function makeBlock(partial: Partial<DocxWrapBlockInput>): DocxWrapBlockInput {
  return {
    type: partial.type ?? 'IMAGE',
    x: partial.x ?? 0,
    y: partial.y ?? 0,
    width: partial.width ?? 100,
    height: partial.height ?? 60,
    wrapMode: partial.wrapMode ?? 'SQUARE',
    horizontalAlign: partial.horizontalAlign ?? 0,
    behindDoc: partial.behindDoc ?? false,
    distTop: partial.distTop ?? 0,
    distBottom: partial.distBottom ?? 0,
    distLeft: partial.distLeft ?? 0,
    distRight: partial.distRight ?? 0,
    hasParagraphs: partial.hasParagraphs ?? false
  };
}

function makeText(hasParagraphs = true): DocxWrapBlockInput {
  return makeBlock({
    type: 'TEXT',
    width: 400,
    height: 0,
    wrapMode: 'INLINE',
    hasParagraphs
  });
}

// 1. 全宽浮动块后紧跟窄环绕浮动块和文本：后续窄浮动块必须承接前一个全宽浮动块的推进游标，而非叠在 y=0。
{
  const blocks: DocxWrapBlockInput[] = [
    makeBlock({ width: 400, height: 100, y: 0, distBottom: 4, wrapMode: 'SQUARE', horizontalAlign: 1 }),
    makeBlock({ width: 120, height: 80, y: 0, distRight: 8, wrapMode: 'SQUARE', horizontalAlign: 1 }),
    makeText()
  ];
  let measuredStartY = -1;
  let measuredObstacles: DocxWrapObstacle[] = [];
  const plan = planDocxWrapGroups(
    blocks,
    [[0, blocks.length]],
    595,
    72,
    72,
    400,
    (_idx, startY, obstacles) => {
      measuredStartY = startY;
      measuredObstacles = obstacles;
      return 40;
    }
  );
  const group = plan.groups.get(0);
  expectTrue(group !== undefined, '连续浮动块应生成环绕组');
  if (group) {
    expectEqual(group.floats[0].y, 0, '第一个全宽浮动块位于 y=0');
    // 全宽浮动块 bottom=100 + distBottom=4 + gap=6 = 110
    expectEqual(group.floats[1].y, 110, '第二个窄浮动块应下推至全宽浮动块下方');
    expectEqual(group.flowStartY, 110, '正文起点应位于第二个窄浮动块起点（与全宽浮动块下方对齐）');
    expectEqual(measuredStartY, 110, '测量后续段落的起始 Y 应为 110');
    expectEqual(measuredObstacles.length, 1, '第二个窄浮动块应保留为绕排障碍物');
    expectEqual(measuredObstacles[0].top, 110, '窄浮动块障碍物上界应同步下移到 110');
    expectEqual(measuredObstacles[0].bottom, 190, '窄浮动块障碍物下界应为 190');
  }
}

// 2. 先窄浮动块（较短）后全宽浮动块（靠下）：被全宽浮动块越过的窄障碍物必须被剪枝，且不拉文本进 Canvas。
{
  const blocks: DocxWrapBlockInput[] = [
    makeBlock({ width: 100, height: 50, y: 0, wrapMode: 'SQUARE', horizontalAlign: 1 }),
    makeBlock({ width: 400, height: 40, y: 100, distBottom: 10, wrapMode: 'SQUARE', horizontalAlign: 1 }),
    makeText()
  ];
  const plan = planDocxWrapGroups(
    blocks,
    [[0, blocks.length]],
    595,
    72,
    72,
    400,
    () => 30
  );
  const group = plan.groups.get(0);
  expectTrue(group !== undefined, '先窄后全宽浮动块应生成组');
  if (group) {
    expectEqual(group.obstacles.length, 0, '已被全宽浮动块越过的窄障碍物应被剪枝');
    expectEqual(group.flowStartY, 156, '全宽浮动块推进到 100+40+10+6=156');
    expectEqual(group.flowBlockIndices.length, 0, '无剩余障碍物或重叠 NONE 块时，后续文本无需拉入 Canvas');
    // 156 - 8 = 148，外层 ListItem margin.bottom=8 后，下一块起点正好在 156
    expectEqual(group.height, 148, '组总高度应保留 distBottom+6 间距');
  }
}

// 3. 先窄浮动块（较高）后全宽浮动块（较矮）：较高窄障碍物仍跨越全宽块下方，后续文本需从全宽块下方起算并继续避让窄障碍物。
{
  const blocks: DocxWrapBlockInput[] = [
    makeBlock({ width: 100, height: 220, y: 0, wrapMode: 'SQUARE', horizontalAlign: 1 }),
    makeBlock({ width: 400, height: 50, y: 100, wrapMode: 'SQUARE', horizontalAlign: 1 }),
    makeText()
  ];
  let measuredStartY = -1;
  const plan = planDocxWrapGroups(
    blocks,
    [[0, blocks.length]],
    595,
    72,
    72,
    400,
    (_idx, startY) => {
      measuredStartY = startY;
      return 30;
    }
  );
  const group = plan.groups.get(0);
  expectTrue(group !== undefined, '较高窄障碍物+全宽障碍物应生成组');
  if (group) {
    expectEqual(group.obstacles.length, 1, '未越过的窄障碍物应保留');
    expectEqual(group.flowStartY, 156, '文本起点应从全宽浮动块下方 156 开始');
    expectEqual(measuredStartY, 156, '测量正文起点应为 156');
    expectEqual(group.flowBlockIndices.length, 1, '仍存在障碍物时应消费文本绕排');
  }
}

// 4. 全宽浮动块后紧跟表格（无文本进 flows）：高度不能丢失 distBottom。
{
  const blocks: DocxWrapBlockInput[] = [
    makeBlock({ width: 400, height: 100, y: 20, distBottom: 16, wrapMode: 'SQUARE', horizontalAlign: 1 }),
    makeBlock({ type: 'TABLE', width: 400, height: 0, wrapMode: 'INLINE' })
  ];
  const plan = planDocxWrapGroups(
    blocks,
    [[0, blocks.length]],
    595,
    72,
    72,
    400,
    () => 30
  );
  const group = plan.groups.get(0);
  expectTrue(group !== undefined, '全宽浮动块后接表格应生成组');
  if (group) {
    expectEqual(group.flowBlockIndices.length, 0, '表格不应被吸收进 flows');
    // flowStartY = 20+100+16+6 = 142；减去 ListItem margin.bottom 8 得 134
    expectEqual(group.height, 134, '无 flows 时组高度也应包含 distBottom');
  }
}

// 5. wrapMode=NONE（衬于文字下方）无障碍物但与文本垂直重叠，必须吸收文本到组内绘制。
{
  const blocks: DocxWrapBlockInput[] = [
    makeBlock({ width: 300, height: 120, y: 0, wrapMode: 'NONE', behindDoc: true, horizontalAlign: 1 }),
    makeText()
  ];
  const plan = planDocxWrapGroups(
    blocks,
    [[0, blocks.length]],
    595,
    72,
    72,
    400,
    () => 30
  );
  const group = plan.groups.get(0);
  expectTrue(group !== undefined, 'NONE 浮动块应生成组');
  if (group) {
    expectEqual(group.flowBlockIndices.length, 1, 'NONE 浮动块覆盖范围必须拉入首段文本叠绘');
    expectEqual(group.flowStartY, 0, 'NONE 浮动块不推开文本起点');
  }
}

// 6. ListItem 顶部外边距：wrapGroup 不应重复叠加 element.distTop；独立 TOP_AND_BOTTOM 应尊重 y 与 distTop 最大值。
{
  expectEqual(
    resolveDocxItemTopMargin(0, 0, 2, 16, true, 'SQUARE', 20, 12),
    0,
    'DocxWrapGroup 外层 ListItem 不得额外叠加 distTop'
  );
  expectEqual(
    resolveDocxItemTopMargin(0, 0, 2, 16, false, 'TOP_AND_BOTTOM', 40, 12),
    40,
    '独立 TOP_AND_BOTTOM 顶部留白应取 max(y, distTop)'
  );
  expectEqual(
    resolveDocxItemTopMargin(0, 0, 2, 16, false, 'TOP_AND_BOTTOM', 6, 18),
    18,
    '独立 TOP_AND_BOTTOM 当 distTop 大于 y 时取 distTop'
  );
  expectEqual(
    resolveDocxItemTopMargin(0, 0, 0, 16, false, 'INLINE', 0, 0),
    0,
    '仅有页脚且位于索引 0 时不应误加 sectionGap'
  );
}

console.log(`DOCX wrap layout checks passed: ${checks}`);
