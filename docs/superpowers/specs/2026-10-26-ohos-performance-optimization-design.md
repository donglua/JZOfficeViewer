# HarmonyOS 端加载、图片解码与渲染帧率性能优化设计规格（子项目 A）

- **日期**：2026-10-26
- **状态**：已确认设计（Sub-project A）
- **关联模块**：`core`、`viewer-ohos/native`、`viewer-ohos`

---

## 1. 背景与目标

在 HarmonyOS NEXT 真机运行过程中，针对多图/大图 PPTX 与 DOCX、长文档快速滚动、双指捏合缩放以及高刷屏（90Hz/120Hz）XLSX 表格惯性滑动场景，当前 `viewer-ohos` 存在以下五个核心性能瓶颈：

1. **文档 AST 被 `@State` 包装产生全局 `Proxy` 拦截开销**：
   `OfficePreviewView.ets` 将 `document` 声明为 `@State`，导致 ArkUI V1 状态管理器使用 `ObservedObject`（ES6 `Proxy`）包裹整棵文档模型并传入子组件。在 `SpreadsheetView`、`PptxSlidesView`、`DocxFlowView` 的高频绘制循环中，每帧数千次属性访问均经过 `SubscribableHandler.get` 拦截器。
2. **图片解码无并发上限、采样预算固定且全局清空缓存误伤多实例**：
   - `PptxSlideCanvas.loadImages` 对单页所有图片直接 `Promise.all` 全并发请求，且每张图片固定按 `4,000,000` 像素上限解码，未结合元素的实际屏幕显示面积动态下采样。当单页包含多张高分辨率小图标/插图时，瞬时像素总量可突破 `8,000,000` 预算且因 `refCounts > 0` 无法被淘汰。
   - 缺少对损坏或缺失部件的负缓存（`failedParts`），往返滚动会重复跨 NAPI 读取。
   - `ImageStore.release()` 直接调用 `NativeCore.clearCache()` 清空全局 `GLOBAL_CACHE`，多预览实例并存或切换过渡期会误清其他活跃实例的 ZIP 句柄。
3. **Canvas 文本测量、颜色字符串与单元格折行缺少缓存**：
   - `RenderUtils.argbToCss` 与 `resolveFontFamily` 每帧高频拼接字符串。
   - `CanvasElementDrawer.layoutParagraph` 与 `SpreadsheetView.drawSingleCell` 在每次重绘（如多图逐张异步就绪重绘、表格平移）时重复执行二分 `ctx.measureText`。
4. **列表缺少 `@Reusable` 节点复用且双指缩放每帧触发 `List` 布局重排**：
   - `DocxFlowView` 与 `PptxSlidesView` 的 `LazyForEach` 子组件未启用 `@Reusable`，快速滚动时频繁销毁与重建自定义组件及 `CanvasRenderingContext2D`。
   - `List.padding` 直接绑定依赖 `@State zoom` 的 `verticalZoomPad()`，导致 60~120Hz `PinchGesture.onActionUpdate` 每帧使 `List` 触发整表重排（Relayout）。
5. **XLSX 惯性滚动未对齐硬件 VSync 且合并单元格每帧全表扫描**：
   - `SpreadsheetView` 使用 `setTimeout(..., 16)` 驱动惯性滚动，在 90Hz/120Hz 屏幕上存在步进抖动。
   - 每帧对 `layout.merges`（最多 1000 项）做全表线性扫描，未按可见行区间建立空间索引。

### 1.1 优化目标与约束
- **100% 向后兼容**：`viewer-ohos/Index.ets` 导出的所有组件、控制器方法与 `OfficeModel.ets` 类型定义保持完全兼容；`NativeCore.clearCache()` 保留，新增 `NativeCore.evictCache(path: string)`。
- **零额外依赖与体积控制**：不引入任何第三方依赖，保持 HAR 产物体积在 ~1 MB 量级。
- **跨平台核心隔离**：`core` 仅新增平台无关的 `evict_package_cache(path: &Path)` 接口，不破坏 `SCHEMA_VERSION = 9` 与 Android JNI 兼容性。

---

## 2. 架构与模块设计

### 2.1 文档 AST 去代理化（`OfficePreviewView.ets`）

- **状态解耦**：
  - 将 `OfficePreviewView` 中的 `@State document: model.OfficeDocument | null = null` 替换为普通私有属性 `private rawDocument: model.OfficeDocument | null = null`。
  - 新增 `@State private docRevision: number = 0`。每当 `rawDocument` 更新或清空时递增 `this.docRevision`。
- **视图挂载与更新**：
  - `build()` 中通过 `this.docRevision > 0 && this.rawDocument !== null` 判断文档就绪状态，并为 `DocxFlowView`、`PptxSlidesView`、`SpreadsheetView` 绑定 `.key(\`doc-${this.docRevision}-${this.rawDocument.kind}\`)`。
  - 子组件接收到的 `document` 为未经过 `ObservedObject.createNew` 包装的原生 JS 对象，所有属性读取零 `Proxy` 开销。

### 2.2 按路径精准淘汰 ZIP 缓存（`core` + `viewer-ohos/native` + `NativeCore.ets` + `ImageStore.ets`）

1. **Rust Core 层（`core/src/package_cache.rs` & `core/src/lib.rs`）**：
   - 在 `package_cache.rs` 新增 `pub(crate) fn evict(path: &Path)`：
     使用与 `read_part` 一致的路径规范化逻辑 `fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf())`，从 `cache.entries` 中移除匹配的 `CacheEntry`（同时移除原始 `path` 匹配项以兼容文件已被删除的场景）。
   - 在 `core/src/lib.rs` 导出 `pub fn evict_package_cache(path: &Path)`。
2. **NAPI 桥接层（`viewer-ohos/native/src/lib.rs` & `index.d.ts` & `NativeCore.ets`）**：
   - 新增 `#[napi] pub fn evict_cache(path: String) -> Result<()>`，调用 `jz_office_core::evict_package_cache(Path::new(&path))`。
   - 同步更新 `viewer-ohos/src/main/cpp/types/libjz_office_ohos/index.d.ts`：导出 `export function evictCache(path: string): void;`。
   - 在 `NativeCore.ets` 新增 `public static evictCache(path: string): void`。
3. **引用计数管理（`ImageStore.ets`）**：
   - `ImageStore` 维护静态 `private static readonly activePathRefs: Map<string, number> = new Map()` 及实例级布尔标记 `private pathRegistered: boolean = false`。
   - 构造时（若 `filePath` 非空）将该路径计数 `+1`；`release()` 时幂等将计数 `-1`，仅当计数归零时从 `activePathRefs` 删除并调用 `NativeCore.evictCache(this.filePath)`。

### 2.3 受控图片解码队列、动态采样预算与渐进重绘（`ImageStore.ets` + `RenderUtils.ets` + `OfficePreviewView.ets`）

1. **采样元数据与同步图像信息（`RenderUtils.ets`）**：
   - 新增内部结果接口 `DecodedImageResult { pixelMap: image.PixelMap; pixels: number; sampled: boolean; budget: number }` 及方法 `RenderUtils.decodeImageBufferDetailed(buffer: ArrayBuffer, maxPixels: number): Promise<DecodedImageResult | null>`（原 `decodeImageBuffer` 保留并委托调用以维持 API 兼容）。
   - 解码成功后优先使用同步 `pixelMap.getImageInfoSync()`（失败时回退异步 `getImageInfo()`）计算实际像素数 `width * height`，省去 `ImageStore` 中的二次异步 `getImageInfo()` 调用。
2. **并发信号量、按需采样预算与自动升级（`ImageStore.ets`）**：
   - **最大并发控制**：`private static readonly MAX_CONCURRENT_DECODES: number = 3`，维护 `activeDecodes: number` 与等待队列 `waitQueue: Array<() => void>`。
   - **快速划过跳过**：排队协程唤醒后，若 `this.closed` 为真或 `(this.refCounts.get(part) ?? 0) <= 0`，直接放弃本次 NAPI 读取与解码。
   - **动态像素预算与高清升级**：
     - `load(part: string, desiredMaxPixels: number = RenderUtils.DEFAULT_MAX_PIXELS): Promise<boolean>` 返回本次是否新增或更新了缓存像素图。
     - 维护 `sampledFlags: Map<string, boolean>` 与 `decodedBudgets: Map<string, number>`。若缓存已命中：
       - 当 `sampledFlags.get(part) === true` 且 `desiredMaxPixels > (decodedBudgets.get(part) ?? 0) * 1.5` 时，允许后台解码更高清版本并原子替换旧 `PixelMap`（释放旧图并更新 `totalPixels`）。
       - 否则直接 `touch(part)` 返回 `false`。
   - **失败负缓存**：维护 `failedParts: Set<string>`。当 `this.closed === false` 且解码返回 `null` 时记录 `part`，后续对同一损坏部件直接返回 `false`。
3. **幻灯片与文档图片按面积请求与渐进重绘（`OfficePreviewView.ets`）**：
   - **预算计算辅助函数 `computeDesiredPixels(elW: number, elH: number, pageImageCount: number): number`**：
     - 将元素点尺寸通过 `vp2px` 换算为屏幕物理像素（若 `vp2px` 在单元测试环境不可用则按 `3.0` 倍兜底），乘以 `2.25`（对应 `1.5x` 缩放清晰度余量）。
     - 页面级预算上限 `pageShare = Math.max(512_000, Math.floor(8_000_000 / Math.max(1, pageImageCount)))`。
     - 最终预算限制在 `[65_536, Math.min(4_000_000, pageShare)]` 区间。
   - **渐进合并重绘（`PptxSlideCanvas`）**：
     - 收集当前页唯一图片部件及其在本页的最大显示尺寸預算 `partBudgets: Map<string, number>`。
     - 若部分图片已在 `imageStore.cache` 中，首帧 `onReady` 立即绘制已缓存图片。
     - 对每张图片并发发起 `this.imageStore.load(part, budget)`，每当单张图片返回 `true`（新图就绪或高清升级）时调用 `this.scheduleRedraw()`（通过 `16ms` 定时器窗口合并同一帧内的多次完成回调，仅执行一次 `drawSlide(true)`）；组件回收或卸载时清理定时器。

### 2.4 多级颜色/字体/段落排版缓存（`RenderUtils.ets` + `CanvasElementDrawer.ets`）

1. **颜色与字体缓存（`RenderUtils.ets`）**：
   - `colorCache: Map<number, string | null>`（上限 `512` 项，超出时淘汰最早插入键）：缓存 `argbToCss(argb)` 结果。
   - `fontFamilyCache: Map<string, string>`（上限 `128` 项，键为 `${quoteCustom ? 1 : 0}:${fontFace ?? ''}`）：缓存 `resolveFontFamily` 结果。
2. **段落折行 `WeakMap` 缓存（`CanvasElementDrawer.ets`）**：
   - 定义 `interface CachedParagraphEntry { widthKey: number; wrap: boolean; lines: WrappedLine[] }`。
   - 维护静态 `private static readonly paragraphCache: WeakMap<model.Paragraph, CachedParagraphEntry[]> = new WeakMap()`。
   - 在 `layoutParagraph(ctx, para, maxWidth, wrap)` 入口计算 `widthKey = Math.round(maxWidth * 10)`：
     - 若 `paragraphCache.get(para)` 中存在相同 `widthKey` 与 `wrap` 的条目，直接返回缓存的 `lines`。
     - 否则执行测量与折行，将结果写入该 `para` 对应的数组（每个 `Paragraph` 最多保留最近 `2` 个不同宽度的结果，避免横竖屏切换无限增长）。

### 2.5 列表 `@Reusable` 组件复用与双指缩放降噪（`OfficePreviewView.ets`）

1. **列表子组件 `@Reusable` 改造**：
   - 新增 `@Reusable @Component struct DocxTextBlockView`，封装原先在 `DocxFlowView` 内联的文本段落 `Column`。
   - 为 `DocxTextBlockView`、`DocxTableView`、`DocxImageView`、`DocxShapeView` 以及 `PptxSlideCanvas` 添加 `@Reusable` 装饰器：
     - 在 `DocxFlowView` 的 `LazyForEach` 中，根据块类型设置 `ListItem().reuseId(this.blockReuseId(element))`（区分 `'TEXT'`、`'TABLE'`、`'IMAGE'`、`'SHAPE'` 四类复用池）。
     - 在 `DocxTextBlockView` 与 `DocxTableView` 中引入 `@State private reuseVersion: number = 0`，在 `aboutToReuse(params: Record<string, Object>)` 中更新 `this.element = params['element'] as model.Element` 并递增 `this.reuseVersion`，驱动内部结构刷新且不触发 AST 深拷贝。
     - 在 `DocxImageView`、`DocxShapeView`、`PptxSlideCanvas` 中实现 `aboutToReuse(params)` 与 `aboutToRecycle()`：在回收时立即释放旧图片的 `acquire` 引用并取消未决重绘定时器；在复用时重置状态、绑定新元素/页面并触发加载与重绘。
2. **双指缩放手势与 `List` 布局解耦**：
   - 在 `DocxFlowView` 与 `PptxSlidesView` 中新增 `@State settledZoomPad: number = 0`，将 `List.padding` 中的 `this.verticalZoomPad()` 替换为 `this.settledZoomPad`。
   - 在 `PinchGesture.onActionUpdate` 与 `PanGesture.onActionUpdate` 期间仅更新 `this.zoom` 与 `this.offsetX`（驱动外层 `Stack` 的 `.scale` 与 `.translate` 渲染变换），不修改 `this.settledZoomPad`。
   - 仅在 `PinchGesture.onActionEnd`、`onActionCancel`、`TapGesture`、`setZoom` 及 `onAreaChange` 时调用 `this.syncSettledZoomPad()` 更新 `settledZoomPad`，从而保证 60~120Hz 手势帧期间 `List` 零布局重排。

### 2.6 XLSX `DisplaySync` 硬件 VSync 与空间索引优化（`SpreadsheetView.ets`）

1. **`DisplaySync` 硬件 VSync 驱动惯性滑动**：
   - 引入 `import { displaySync } from '@kit.ArkGraphics2D'`。
   - 在 `SpreadsheetView` 中管理 `private vsync: displaySync.DisplaySync | null = null` 與 `private flingRunning: boolean = false`：
     - 首次启动惯性滚动时尝试 `displaySync.create()` 并注册 `'frame'` 回调，利用 `IntervalInfo.timestamp`（纳秒转秒 `(timestamp - lastTimestamp) / 1e9`）计算精确帧间隔 `dt`（夹逼在 `[0.001, 0.032]` 秒之间）。
     - `stopFling()` 与 `aboutToDisappear()` 中调用 `this.vsync.stop()` 并清理 fallback 定时器。
     - 若运行环境不支持 `displaySync.create()`（抛出异常），自动回退至原有的 `setTimeout(this.stepFling, 16)` 机制。
2. **合并单元格按行分桶索引（`SheetLayoutData`）**：
   - 在 `SheetLayoutData` 中新增按 `64` 行为一桶的索引 `readonly mergeBuckets: Int32Array[]` 以及去重世代数组 `readonly mergeSeenGen: Int32Array`、`currentGen: number`。
   - 构建 `SheetLayoutData` 时，将每个合并区域 `m` 的下标写入其覆盖的所有行桶 `Math.floor(m.startRow / 64) .. Math.floor(m.endRow / 64)`。
   - 每帧绘制时，根据当前可见首尾行号计算起止桶下标，仅遍历对应桶内的合并区域并进一步校验列区间 `[unscaledBodyLeft, unscaledBodyRight]`，将合并单元格查找复杂度从 `O(M)` 降至 `O(可见合并数)`。
3. **换行文本缓存与列标表预计算**：
   - 预计算静态 `COLUMN_LETTERS: string[]`（覆盖 `0..255` 即 `A..IV`），256 列以内直接数组下标 `O(1)` 读取。
   - 新增 `private readonly cellWrapCache: WeakMap<model.Cell, { widthKey: number; fontKey: number; maxLines: number; lines: string[] }> = new WeakMap()`，当开启 `style.wrap` 的单元格在相同缩放比与列宽下平移重绘时，直接复用已折行文本数组，跳过二分 `ctx.measureText`。

---

## 3. 异常处理与边界防护

- **组件快速挂载/卸载竞争**：所有异步操作（`loadDocument`、`ImageStore.load`、`PptxSlideCanvas.scheduleRedraw`）均通过世代号（`loadGeneration`）或生命周期标志（`closed`、`isDisappeared`）校验有效性；若组件已进入 `aboutToRecycle` 或 `aboutToDisappear`，立即释放新解码的 `PixelMap` 并中止绘制。
- **单页超多图片内存兜底**：即便单页内所有图片均处于 `acquire` 状态（`refCount > 0`），通过 `computeDesiredPixels` 的 `pageShare = Math.floor(8_000_000 / pageImageCount)` 约束，单页全部图片解码后的总像素量严格受控在 `8,000,000` 像素（约 32 MB）以内。
- **无效路径淘汰容错**：`evict_package_cache` 对不存在的路径、已删除的沙箱临时文件或空字符串均安静返回，不抛出错误。

---

## 4. 测试与验证计划

1. **Rust 单元测试（`core/tests/package_cache.rs`）**：
   - 新增 `evict_package_cache_removes_only_target_package_and_is_idempotent`：验证同时缓存多个 ZIP 包时，调用 `evict_package_cache` 仅淘汰指定路径句柄，其余缓存仍命中；对未缓存或不存在路径调用幂等无异常。
2. **编译与静态检查门禁**：
   - `cargo test --workspace` 全量通过。
   - `cargo clippy -p jz-office-core -- -D warnings` 与 `cargo clippy -p jz-office-ohos -- -D warnings` 零警告。
   - `./scripts/build-ohos.sh` 成功编译 `arm64-v8a` 与 `x86_64` 动态库并打包 `viewer_ohos.har`。
   - `hvigorw --mode module -p module=demo_ohos@default -p product=default assembleHap --no-daemon` 通过严格 ArkTS 类型检查与 HAP 构建。
3. **真机交互验收**：
   - 包含 >2 MiB 大图及多张插图的 PPTX/DOCX：首屏渐进渲染流畅，无解码风暴卡顿，切换文档及返回列表无句柄或 PixelMap 泄漏。
   - DOCX/PPTX 快速滚动与双指缩放：列表节点复用正常无图文错位，捏合缩放过程无卡顿掉帧。
   - XLSX 大表格平移、缩放与松手惯性滚动：高刷屏下帧步进平滑无抖动。
