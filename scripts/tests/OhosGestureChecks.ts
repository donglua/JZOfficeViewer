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

function checkPanCancelsZoomTween(path: string, label: string): void {
  const source = readFileSync(path, 'utf8');
  const panIndex = source.indexOf('PanGesture()');
  expect(panIndex >= 0, `${label} 未找到全向 PanGesture`);
  if (panIndex < 0) return;
  const startIndex = source.indexOf('.onActionStart', panIndex);
  const updateIndex = source.indexOf('.onActionUpdate', startIndex);
  expect(startIndex >= 0 && updateIndex > startIndex, `${label} Pan 生命周期不完整`);
  if (startIndex < 0 || updateIndex <= startIndex) return;
  const startBody = source.slice(startIndex, updateIndex);
  expect(startBody.includes('this.stopZoomTween();'), `${label} 单指 Pan 开始必须取消旧缩放补间`);
}

/** 惯性运行中手指按下必须立刻停住；只靠 PanGesture.onActionStart 会等到移动超过识别距离才响应 */
function checkTouchDownStopsFling(path: string, label: string): void {
  const source = readFileSync(path, 'utf8');
  const touchIndex = source.indexOf('.onTouch(');
  expect(touchIndex >= 0, `${label} 缺少 onTouch，惯性滑动无法在手指按下时停止`);
  if (touchIndex < 0) return;
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

checkDoubleTapThreshold(previewPath, 'DOCX/PPTX');
checkDoubleTapThreshold(spreadsheetPath, 'XLSX');
checkPanCancelsZoomTween(previewPath, 'PPTX');
checkPanCancelsZoomTween(spreadsheetPath, 'XLSX');
checkTouchDownStopsFling(previewPath, 'PPTX');
checkTouchDownStopsFling(spreadsheetPath, 'XLSX');
checkNoEmbeddedSheetTabs(spreadsheetPath, 'XLSX');

if (failures.length > 0) {
  throw new Error(`手势回归检查失败（${failures.length}/${checks}）：\n- ${failures.join('\n- ')}`);
}

console.log(`OHOS gesture checks passed: ${checks}`);
