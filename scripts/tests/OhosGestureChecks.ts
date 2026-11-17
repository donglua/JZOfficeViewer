import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';

let checks = 0;
const failures: string[] = [];

function expect(condition: boolean, message: string): void {
  checks++;
  if (!condition) failures.push(message);
}

const root = resolve(import.meta.dirname, '../..');
const previewPath = resolve(root, 'viewer-ohos/src/main/ets/render/OfficePreviewView.ets');
const spreadsheetPath = resolve(root, 'viewer-ohos/src/main/ets/render/SpreadsheetView.ets');

/**
 * 截取指定 struct 的源码范围。
 * 同一个文件里 DOCX 与 PPTX 各有一套手势链，逐项检查必须落在目标 struct 内部，
 * 否则 DOCX 新增的 onTouch 会遮蔽 PPTX 的检查目标。
 */
function structSource(source: string, structName: string): string | null {
  const marker = `struct ${structName} {`;
  const start = source.indexOf(marker);
  if (start < 0) return null;
  let depth = 0;
  let index = source.indexOf('{', start);
  const bodyStart = index;
  for (; index < source.length; index++) {
    const ch = source[index];
    if (ch === '{') depth++;
    else if (ch === '}') {
      depth--;
      if (depth === 0) {
        return source.slice(bodyStart, index + 1);
      }
    }
  }
  return null;
}

function checkDoubleTapThreshold(path: string, label: string): void {
  const source = readFileSync(path, 'utf8');
  const gestures = source.matchAll(/TapGesture\(\{([^}]*)\}\)/g);
  let doubleTapCount = 0;
  for (const gesture of gestures) {
    const options = gesture[1];
    if (!/count:\s*2\b/.test(options)) continue;
    doubleTapCount++;
    const threshold = options.match(/distanceThreshold:\s*(\d+(?:\.\d+)?)/);
    expect(threshold !== null, `${label} 双击必须设置 distanceThreshold，避免滑动被累计为点击`);
    if (threshold) {
      const value = Number(threshold[1]);
      expect(value > 0 && value < 5, `${label} 双击移动阈值必须大于 0 且小于 Pan 的 5vp 识别距离，实际 ${value}`);
    }
  }
  expect(doubleTapCount > 0, `${label} 未找到双击手势，无法验证滑动防误触配置`);
}

function checkPanCancelsZoomTween(path: string, label: string, scope?: string): void {
  const full = readFileSync(path, 'utf8');
  const source = scope ? (structSource(full, scope) ?? '') : full;
  expect(source.length > 0, `${label} 未找到 ${scope ?? ''} 结构，无法验证 Pan 手势`);
  if (source.length === 0) {
    checks += 2;
    failures.push(`${label} Pan 生命周期不完整`);
    failures.push(`${label} 单指 Pan 开始必须取消旧缩放补间`);
    return;
  }
  const panIndex = source.indexOf('PanGesture()');
  expect(panIndex >= 0, `${label} 未找到全向 PanGesture`);
  if (panIndex < 0) {
    checks += 2;
    failures.push(`${label} Pan 生命周期不完整`);
    failures.push(`${label} 单指 Pan 开始必须取消旧缩放补间`);
    return;
  }
  const startIndex = source.indexOf('.onActionStart', panIndex);
  const updateIndex = source.indexOf('.onActionUpdate', startIndex);
  expect(startIndex >= 0 && updateIndex > startIndex, `${label} Pan 生命周期不完整`);
  if (startIndex < 0 || updateIndex <= startIndex) {
    failures.push(`${label} 单指 Pan 开始必须取消旧缩放补间`);
    checks++;
    return;
  }
  const startBody = source.slice(startIndex, updateIndex);
  expect(startBody.includes('this.stopZoomTween();'), `${label} 单指 Pan 开始必须取消旧缩放补间`);
}

/** 惯性运行中手指按下必须立刻停住；只靠 PanGesture.onActionStart 会等到移动超过识别距离才响应 */
function checkTouchDownStopsFling(path: string, label: string, scope?: string): void {
  const full = readFileSync(path, 'utf8');
  const source = scope ? (structSource(full, scope) ?? '') : full;
  const touchIndex = source.indexOf('.onTouch(');
  expect(touchIndex >= 0, `${label} 缺少 onTouch，惯性滑动无法在手指按下时停止`);
  if (touchIndex < 0) {
    checks += 2;
    failures.push(`${label} onTouch 必须判断 TouchType.Down`);
    failures.push(`${label} 手指按下（Down）必须立刻停止 Fling`);
    return;
  }
  const body = source.slice(touchIndex, source.indexOf('.gesture(', touchIndex));
  expect(body.includes('TouchType.Down'), `${label} onTouch 必须判断 TouchType.Down`);
  expect(body.includes('this.stopFling();'), `${label} 手指按下（Down）必须立刻停止 Fling`);
}

/** 切表入口只能有一处：预览视图内嵌工作表条与 OfficeSheetTabs 并存会出现两层标签栏 */
function checkNoEmbeddedSheetTabs(path: string, label: string): void {
  const source = readFileSync(path, 'utf8');
  expect(!/ScrollDirection\.Horizontal|listDirection\(\s*Axis\.Horizontal\s*\)/.test(source),
    `${label} 预览视图不得内嵌工作表标签栏，切表统一交给 OfficeSheetTabs`);
}

/**
 * 从源码中解析 `const NAME: number = <数字>;` 形式的常量值。
 * 手势时长等参数以命名常量表达，校验时需回读真实数值而非拒绝常量写法。
 */
function resolveNumberConstant(source: string, name: string): number | null {
  const match = source.match(new RegExp(`const\\s+${name}\\s*:\\s*number\\s*=\\s*(\\d+(?:\\.\\d+)?)\\s*;`));
  return match ? Number(match[1]) : null;
}

/** 读取 `key: <数字|常量名>` 形式的选项值并解析为数字 */
function readNumericOption(source: string, options: string, key: string): number | null {
  const match = options.match(new RegExp(`${key}:\\s*([A-Za-z_$][\\w$]*|-?\\d+(?:\\.\\d+)?)`));
  if (!match) return null;
  const raw = match[1];
  if (/^-?\d+(?:\.\d+)?$/.test(raw)) {
    return Number(raw);
  }
  return resolveNumberConstant(source, raw);
}

/**
 * 长按选词必须使用 400ms 且不重复触发。
 * 时长过短会与单击/滚动冲突，过长（系统默认 500ms）在拖选场景手感明显滞后。
 */
function checkLongPressSelection(path: string, label: string): void {
  const source = readFileSync(path, 'utf8');
  const gestures = [...source.matchAll(/LongPressGesture\(\{([^}]*)\}\)/g)];
  expect(gestures.length > 0, `${label} 缺少 LongPressGesture，无法长按选词`);
  for (const gesture of gestures) {
    const options = gesture[1];
    const duration = readNumericOption(source, options, 'duration');
    expect(duration !== null, `${label} 长按必须显式设置 duration`);
    if (duration !== null) {
      expect(duration > 0 && duration <= 400, `${label} 长按触发时长不得超过 400ms，实际 ${duration}`);
    }
    expect(/repeat:\s*false/.test(options), `${label} 长按必须关闭 repeat，避免拖选期间重复选词`);
  }
  // 长按回调必须真正进入选词逻辑（命中测试 + 词界提取），而不是仅做视觉反馈
  expect(source.includes('handleLongPress'), `${label} 长按回调必须调用选词处理函数`);
  expect(source.includes('wordRange('), `${label} 长按选词必须调用 TextSelectionModel.wordRange 提取词界`);
}

/**
 * 单击清除选区不得放大识别阈值：单指 TapGesture 一旦带 distanceThreshold
 * 之外的额外约束（fingers/count 混用），会与双击手势竞争导致双击缩放失效。
 * 这里校验单击手势显式声明 count: 1，且双击仍保留 count: 2 + distanceThreshold。
 */
function checkSingleTapClearsSelection(path: string, label: string): void {
  const source = readFileSync(path, 'utf8');
  const single = [...source.matchAll(/TapGesture\(\{([^}]*)\}\)/g)].filter(
    (g) => /count:\s*1\b/.test(g[1])
  );
  expect(single.length > 0, `${label} 缺少单指 TapGesture，单击无法清除选区`);
  for (const gesture of single) {
    const options = gesture[1];
    expect(!/distanceThreshold/.test(options),
      `${label} 单指单击不得设置 distanceThreshold，否则会与双击阈值语义混淆`);
  }
  expect(source.includes('handleSingleTap'), `${label} 单击回调必须调用选区清除处理函数`);

  const double = [...source.matchAll(/TapGesture\(\{([^}]*)\}\)/g)].filter(
    (g) => /count:\s*2\b/.test(g[1])
  );
  expect(double.length > 0, `${label} 单击接入后双击手势不得丢失`);
  for (const gesture of double) {
    expect(/distanceThreshold:\s*[1-4](\b|\.)/.test(gesture[1]),
      `${label} 单击接入后双击 distanceThreshold 必须保持 0<v<5`);
  }
}

/**
 * 拖选期间必须关闭列表滚动交互（DOCX）或屏蔽 PanGesture（PPTX），
 * 否则手指纵向滑动会被滚动容器抢走，选区无法连续扩展。
 */
function checkDragSuppressesScroll(path: string, label: string): void {
  const source = readFileSync(path, 'utf8');
  const docx = structSource(source, 'DocxFlowView');
  expect(docx !== null, `${label} 未找到 DocxFlowView`);
  if (docx) {
    expect(docx.includes('enableScrollInteraction(!this.isSelectionDragging)'),
      `${label} DOCX 拖选期间必须通过 enableScrollInteraction 关闭列表滚动`);
    const panIdx = docx.indexOf('PanGesture({ direction: PanDirection.Horizontal })');
    expect(panIdx !== -1, `${label} 未找到 DOCX 横向 PanGesture`);
    if (panIdx !== -1) {
      expect(docx.slice(panIdx).includes('this.isSelectionDragging'),
        `${label} DOCX 拖选期间横向 PanGesture 必须让步`);
    }
    expect(docx.includes('GestureMode.Exclusive'),
      `${label} DOCX 单击与双击必须通过 GestureMode.Exclusive 互斥`);
  }
  const pptx = structSource(source, 'PptxSlidesView');
  expect(pptx !== null, `${label} 未找到 PptxSlidesView`);
  if (pptx) {
    expect(pptx.includes('this.isSelectionDragging'),
      `${label} PPTX 拖选期间必须屏蔽 PanGesture`);
    expect(pptx.includes('GestureMode.Exclusive'),
      `${label} PPTX 单击与双击必须通过 GestureMode.Exclusive 互斥`);
  }
}

checkDoubleTapThreshold(previewPath, 'DOCX/PPTX');
checkDoubleTapThreshold(spreadsheetPath, 'XLSX');
checkPanCancelsZoomTween(previewPath, 'PPTX', 'PptxSlidesView');
checkPanCancelsZoomTween(spreadsheetPath, 'XLSX');
checkTouchDownStopsFling(previewPath, 'PPTX', 'PptxSlidesView');
checkTouchDownStopsFling(spreadsheetPath, 'XLSX');
checkNoEmbeddedSheetTabs(spreadsheetPath, 'XLSX');
checkLongPressSelection(previewPath, 'DOCX/PPTX');
checkSingleTapClearsSelection(previewPath, 'DOCX/PPTX');
checkDragSuppressesScroll(previewPath, 'DOCX/PPTX');

if (failures.length > 0) {
  throw new Error(`手势回归检查失败（${failures.length}/${checks}）：\n- ${failures.join('\n- ')}`);
}

console.log(`OHOS gesture checks passed: ${checks}`);
