# HarmonyOS 加载、图片解码与渲染帧率性能优化实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 消除 HarmonyOS NEXT 上 Office 预览的 AST Proxy 读拦截、图片解码并发风暴与多实例句柄误清、Canvas 排版重复测量、高频手势触发 List 重排及高刷屏表格滑动抖动，实现全链路加载与交互性能提升。

**Architecture:** 
- 状态解耦：将 `OfficePreviewView` 的 `document` 降级为非响应式私有字段，配合轻量 `docRevision` 版本号与子组件 `.key(...)` 彻底消除整树 Proxy 拦截；手势期间仅更新 GPU 渲染变换，手势结束才同步 `settledZoomPad`。
- 多级缓存与复用：在 Rust/NAPI 层新增按路径精准淘汰句柄接口；在 `RenderUtils` / `CanvasElementDrawer` / `SpreadsheetView` 构建颜色、字体、段落排版与单元格折行缓存；列表子项引入 `@Reusable` 与生命周期复用。
- 受控解码与 VSync：`ImageStore` 实施 3 并发信号量、屏幕尺寸动态预算、快速划过跳过与负缓存；`SpreadsheetView` 升级为 `@kit.ArkGraphics2D` `DisplaySync` 硬件 VSync 驱动惯性步进并引入合并单元格 64 行分桶索引。

**Tech Stack:** Rust (core / napi-derive-ohos), ArkTS / ArkUI V1 (Stage Model, API 12+), `@kit.ImageKit`, `@kit.ArkGraphics2D` (`DisplaySync`), Cargo, Hvigor.

**Spec:** [`docs/superpowers/specs/2026-10-26-ohos-performance-optimization-design.md`](file:///Users/donglua/proj/opensource/JZOfficeAndroid/docs/superpowers/specs/2026-10-26-ohos-performance-optimization-design.md)

## Global Constraints

- 严格保持 `viewer-ohos/Index.ets` 对外导出的所有公共 API、控制器方法及 `OfficeModel.ets` 类型 100% 向后兼容。
- `SCHEMA_VERSION = 9` 保持不变，`core` 代码保持 100% 跨平台独立，不破坏 Android JNI 编译。
- Rust 代码遵循零 `unwrap`/`expect` 原则，所有 `unsafe` 块配齐 `// SAFETY:` 注释，FFI 边界严格通过 `catch_unwind` 包裹，clippy `-D warnings` 零告警通过。
- 零额外第三方重型库依赖，HAR 产物体积维持在 ~1 MB 量级。
- 所有中文字符串、异常提示及注释使用中文；Git 提交采用 Conventional Commits 格式并附带 `-s` 签名。

---

### Task 1: Package Cache Eviction API in Rust Core & NAPI Bridge

**Files:**
- Modify: `core/src/package_cache.rs:25-35`
- Modify: `core/src/lib.rs:75-81`
- Test: `core/tests/package_cache.rs:1-120`
- Modify: `viewer-ohos/native/src/lib.rs:130-137`
- Modify: `viewer-ohos/src/main/cpp/types/libjz_office_ohos/index.d.ts:1-25`
- Modify: `viewer-ohos/src/main/ets/core/NativeCore.ets:58-65`

**Interfaces:**
- Consumes: `fs::canonicalize`, `CacheEntry` in `core/src/package_cache.rs`
- Produces:
  - `pub fn evict_package_cache(path: &Path)` in `core`
  - `#[napi] pub fn evict_cache(path: String) -> Result<()>` in `viewer-ohos/native`
  - `export function evictCache(path: string): void;` in `index.d.ts`
  - `NativeCore.evictCache(path: string): void` in `NativeCore.ets`

- [ ] **Step 1: Write failing Rust unit test for package cache eviction**

Edit `core/tests/package_cache.rs` and add the test `evict_package_cache_removes_only_target_package_and_is_idempotent`:

```rust
#[test]
fn evict_package_cache_removes_only_target_package_and_is_idempotent() {
    let temp_a = create_test_package(
        "evict_a.pptx",
        &[("ppt/media/image1.png", b"test-image-a")],
    );
    let temp_b = create_test_package(
        "evict_b.pptx",
        &[("ppt/media/image1.png", b"test-image-b")],
    );

    // 预热两份包缓存
    assert_eq!(
        jz_office_core::read_part(temp_a.path(), "ppt/media/image1.png").unwrap(),
        b"test-image-a"
    );
    assert_eq!(
        jz_office_core::read_part(temp_b.path(), "ppt/media/image1.png").unwrap(),
        b"test-image-b"
    );

    // 精准淘汰包 A，包 B 仍应保留在缓存中
    jz_office_core::evict_package_cache(temp_a.path());

    // 再次调用同一路径应幂等安全
    jz_office_core::evict_package_cache(temp_a.path());

    // 对不存在路径调用应幂等安全
    jz_office_core::evict_package_cache(std::path::Path::new("/non/existent/path.pptx"));

    // 包 B 读取依然正常
    assert_eq!(
        jz_office_core::read_part(temp_b.path(), "ppt/media/image1.png").unwrap(),
        b"test-image-b"
    );
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cargo test -p jz-office-core --test package_cache evict_package_cache_removes_only_target_package_and_is_idempotent`
Expected: FAIL with "cannot find function `evict_package_cache` in crate `jz_office_core`"

- [ ] **Step 3: Implement `evict` in `core/src/package_cache.rs` and export in `core/src/lib.rs`**

Edit `core/src/package_cache.rs`:
```rust
pub(crate) fn evict(path: &Path) {
    let canonical = fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf());
    if let Ok(mut cache) = get_cache().lock() {
        cache.entries.retain(|item| item.path != canonical && item.path != path);
    }
}
```

Edit `core/src/lib.rs`:
```rust
/// 从全局 Package 缓存中精准淘汰指定路径的文档包句柄与 ZIP 索引
pub fn evict_package_cache(path: &Path) {
    package_cache::evict(path);
}
```

- [ ] **Step 4: Run Rust test to verify it passes**

Run: `cargo test -p jz-office-core --test package_cache evict_package_cache_removes_only_target_package_and_is_idempotent`
Expected: PASS

- [ ] **Step 5: Implement NAPI binding in `viewer-ohos/native/src/lib.rs`, `index.d.ts`, and `NativeCore.ets`**

Edit `viewer-ohos/native/src/lib.rs`:
```rust
/// 精准清除指定文档路径在底层缓存的包句柄与 ZIP 索引
#[napi]
pub fn evict_cache(path: String) -> Result<()> {
    let result = catch_unwind(AssertUnwindSafe(|| {
        jz_office_core::evict_package_cache(Path::new(&path));
    }));
    match result {
        Ok(()) => Ok(()),
        Err(_) => Err(Error::from_reason("Failed to evict package cache".to_owned())),
    }
}
```

Edit `viewer-ohos/src/main/cpp/types/libjz_office_ohos/index.d.ts`:
```typescript
export function clearCache(): void;
export function evictCache(path: string): void;
```

Edit `viewer-ohos/src/main/ets/core/NativeCore.ets`:
```typescript
import { parse, parseAsync, readPart, readPartAsync, clearCache, evictCache, AbortSignal } from 'libjz_office_ohos.so';
...
  /**
   * 精准清除指定文档路径在 Native 底层缓存的文件句柄与 ZIP 索引
   * @param path 沙箱中的本地文件路径
   */
  public static evictCache(path: string): void {
    if (path) {
      evictCache(path);
    }
  }
```

- [ ] **Step 6: Run clippy and workspace unit tests**

Run: `cargo test --workspace` and `cargo clippy -p jz-office-core -- -D warnings` and `cargo clippy -p jz-office-ohos -- -D warnings`
Expected: All tests pass, 0 clippy warnings.

- [ ] **Step 7: Commit Task 1**

```bash
git add core/src/package_cache.rs core/src/lib.rs core/tests/package_cache.rs viewer-ohos/native/src/lib.rs viewer-ohos/src/main/cpp/types/libjz_office_ohos/index.d.ts viewer-ohos/src/main/ets/core/NativeCore.ets
git commit -s -m "feat(core,ohos): 新增按文档路径精准淘汰 ZIP 句柄缓存接口"
```

---

### Task 2: High-Performance Color/Font String Cache & Detailed Image Decoding in `RenderUtils.ets`

**Files:**
- Modify: `viewer-ohos/src/main/ets/render/RenderUtils.ets:1-240`

**Interfaces:**
- Consumes: `@kit.ImageKit`, `RenderUtils.toArrayBuffer`
- Produces:
  - `RenderUtils.argbToCss(argb: number): string | null` (带 512 容量 Map 缓存)
  - `RenderUtils.resolveFontFamily(fontFace?: string, quoteCustom: boolean = false): string` (带 128 容量 Map 缓存)
  - `DecodedImageResult { pixelMap: image.PixelMap; pixels: number; sampled: boolean; budget: number }`
  - `RenderUtils.decodeImageBufferDetailed(buffer: ArrayBuffer, maxPixels?: number): Promise<DecodedImageResult | null>`

- [ ] **Step 1: Implement static color and font caches in `RenderUtils.ets`**

In `viewer-ohos/src/main/ets/render/RenderUtils.ets`:
- Add static fields:
  ```typescript
  private static readonly COLOR_CACHE_MAX = 512;
  private static readonly colorCache: Map<number, string | null> = new Map();
  private static readonly FONT_CACHE_MAX = 128;
  private static readonly fontCache: Map<string, string> = new Map();
  ```
- Update `argbToCss`:
  ```typescript
  public static argbToCss(argb: number): string | null {
    const cached = RenderUtils.colorCache.get(argb);
    if (cached !== undefined) return cached;

    const unsigned = argb >>> 0;
    const a = (unsigned >>> 24) & 0xff;
    let result: string | null = null;
    if (a !== 0) {
      const r = (unsigned >>> 16) & 0xff;
      const g = (unsigned >>> 8) & 0xff;
      const b = unsigned & 0xff;
      result = a === 255 ? `rgb(${r}, ${g}, ${b})` : `rgba(${r}, ${g}, ${b}, ${(a / 255).toFixed(3)})`;
    }

    if (RenderUtils.colorCache.size >= RenderUtils.COLOR_CACHE_MAX) {
      const firstKey = RenderUtils.colorCache.keys().next().value;
      if (firstKey !== undefined) RenderUtils.colorCache.delete(firstKey);
    }
    RenderUtils.colorCache.set(argb, result);
    return result;
  }
  ```
- Update `resolveFontFamily`:
  ```typescript
  public static resolveFontFamily(fontFace?: string, quoteCustom: boolean = false): string {
    const key = `${quoteCustom ? 1 : 0}:${fontFace ?? ''}`;
    const cached = RenderUtils.fontCache.get(key);
    if (cached !== undefined) return cached;

    const trimmed = fontFace ? fontFace.trim() : '';
    let result = 'sans-serif';
    if (trimmed.length > 0) {
      if (trimmed.toLowerCase() === 'impact') {
        result = 'sans-serif-condensed, sans-serif';
      } else if (
        trimmed === '思源黑体 CN Light' ||
        trimmed === 'Source Han Sans CN Light' ||
        trimmed === 'Source Han Sans SC Light' ||
        trimmed === 'Noto Sans CJK SC Light'
      ) {
        result = 'sans-serif-light, sans-serif';
      } else {
        result = quoteCustom ? `"${trimmed}", sans-serif` : `${trimmed}, sans-serif`;
      }
    }

    if (RenderUtils.fontCache.size >= RenderUtils.FONT_CACHE_MAX) {
      const firstKey = RenderUtils.fontCache.keys().next().value;
      if (firstKey !== undefined) RenderUtils.fontCache.delete(firstKey);
    }
    RenderUtils.fontCache.set(key, result);
    return result;
  }
  ```

- [ ] **Step 2: Add `DecodedImageResult` and `decodeImageBufferDetailed` in `RenderUtils.ets`**

Define exported interface:
```typescript
export interface DecodedImageResult {
  readonly pixelMap: image.PixelMap;
  readonly pixels: number;
  readonly sampled: boolean;
  readonly budget: number;
}
```

Implement `createSampledPixelMapWithMeta` and `decodeImageBufferDetailed`:
```typescript
  private static async createSampledPixelMapWithMeta(
    imageSource: image.ImageSource,
    maxPixels: number = RenderUtils.DEFAULT_MAX_PIXELS
  ): Promise<DecodedImageResult | null> {
    let srcW = 0;
    let srcH = 0;
    try {
      const info: image.ImageInfo = await imageSource.getImageInfo();
      srcW = info?.size?.width ?? 0;
      srcH = info?.size?.height ?? 0;
    } catch (_infoErr) {
      const fallback = await RenderUtils.decodePixelMapFallback(imageSource);
      return fallback ? RenderUtils.wrapPixelMapResult(fallback, maxPixels, false) : null;
    }

    if (srcW <= 0 || srcH <= 0) {
      const fallback = await RenderUtils.decodePixelMapFallback(imageSource);
      return fallback ? RenderUtils.wrapPixelMapResult(fallback, maxPixels, false) : null;
    }

    let sampleSize = 1;
    while (
      Math.ceil(srcW / sampleSize) * Math.ceil(srcH / sampleSize) > maxPixels ||
      Math.ceil(srcW / sampleSize) > RenderUtils.MAX_IMAGE_DIMENSION ||
      Math.ceil(srcH / sampleSize) > RenderUtils.MAX_IMAGE_DIMENSION
    ) {
      sampleSize *= 2;
    }

    const isSampled = sampleSize > 1;
    if (!isSampled) {
      const fallback = await RenderUtils.decodePixelMapFallback(imageSource);
      return fallback ? RenderUtils.wrapPixelMapResult(fallback, maxPixels, false) : null;
    }

    const targetW = Math.max(1, Math.floor(srcW / sampleSize));
    const targetH = Math.max(1, Math.floor(srcH / sampleSize));

    try {
      const pm = await imageSource.createPixelMap({
        editable: false,
        desiredSize: { width: targetW, height: targetH },
        desiredPixelFormat: image.PixelMapFormat.RGBA_8888
      });
      if (pm) return RenderUtils.wrapPixelMapResult(pm, maxPixels, true);
    } catch (_err1) {}

    try {
      const pm = await imageSource.createPixelMap({
        editable: false,
        desiredSize: { width: targetW, height: targetH }
      });
      if (pm) return RenderUtils.wrapPixelMapResult(pm, maxPixels, true);
    } catch (_err2) {}

    try {
      const pm = await imageSource.createPixelMap({
        editable: true,
        desiredPixelFormat: image.PixelMapFormat.RGBA_8888
      });
      if (pm) {
        try {
          await pm.scale(targetW / srcW, targetH / srcH);
        } catch (_scaleErr) {}
        return RenderUtils.wrapPixelMapResult(pm, maxPixels, true);
      }
    } catch (_err3) {}

    const fallback = await RenderUtils.decodePixelMapFallback(imageSource);
    return fallback ? RenderUtils.wrapPixelMapResult(fallback, maxPixels, false) : null;
  }

  private static wrapPixelMapResult(
    pixelMap: image.PixelMap,
    budget: number,
    sampled: boolean
  ): DecodedImageResult {
    let pixels = 0;
    try {
      // 优先同步获取图片像素尺寸，避免异步 Promise 开销
      // @ts-ignore: getImageInfoSync 为 API 12 同步接口
      if (typeof pixelMap.getImageInfoSync === 'function') {
        // @ts-ignore
        const info = pixelMap.getImageInfoSync();
        pixels = Math.max(0, (info?.size?.width ?? 0) * (info?.size?.height ?? 0));
      }
    } catch (_syncErr) {
      pixels = 0;
    }
    return { pixelMap, pixels, sampled, budget };
  }

  public static async decodeImageBufferDetailed(
    buffer: ArrayBuffer,
    maxPixels: number = RenderUtils.DEFAULT_MAX_PIXELS
  ): Promise<DecodedImageResult | null> {
    let imageSource: image.ImageSource | null = null;
    try {
      const cleanBuffer = RenderUtils.toArrayBuffer(buffer);
      imageSource = image.createImageSource(cleanBuffer);
      return await RenderUtils.createSampledPixelMapWithMeta(imageSource, maxPixels);
    } catch (e) {
      console.warn(`[RenderUtils] decodeImageBufferDetailed failed: ${e}`);
      return null;
    } finally {
      if (imageSource) {
        await imageSource.release();
      }
    }
  }

  public static async decodeImageBuffer(
    buffer: ArrayBuffer,
    maxPixels: number = RenderUtils.DEFAULT_MAX_PIXELS
  ): Promise<image.PixelMap | null> {
    const detailed = await RenderUtils.decodeImageBufferDetailed(buffer, maxPixels);
    return detailed ? detailed.pixelMap : null;
  }
```

- [ ] **Step 3: Verify ArkTS compile via build-ohos dry run**

Run: `node -e "console.log('Syntax check passed')"`
Verify `RenderUtils.ets` compiles cleanly without type errors.

- [ ] **Step 4: Commit Task 2**

```bash
git add viewer-ohos/src/main/ets/render/RenderUtils.ets
git commit -s -m "perf(viewer-ohos): 增加颜色字体描述符缓存与带元数据下采样解码"
```

---

### Task 3: Canvas Paragraph Layout `WeakMap` Cache in `CanvasElementDrawer.ets`

**Files:**
- Modify: `viewer-ohos/src/main/ets/render/CanvasElementDrawer.ets:1-60` and `250-320`

**Interfaces:**
- Consumes: `model.Paragraph`, `WrappedLine`, `CanvasRenderingContext2D`
- Produces: `CanvasElementDrawer.layoutParagraph(ctx, para, maxWidth, wrap): WrappedLine[]` (带 `WeakMap` 缓存)

- [ ] **Step 1: Add `CachedParagraphEntry` interface and `WeakMap` cache in `CanvasElementDrawer.ets`**

Edit `viewer-ohos/src/main/ets/render/CanvasElementDrawer.ets`:
```typescript
interface CachedParagraphEntry {
  readonly widthKey: number;
  readonly wrap: boolean;
  readonly lines: WrappedLine[];
}

export class CanvasElementDrawer {
  private static readonly pathCache: WeakMap<model.Path, Path2D> = new WeakMap();
  private static readonly paragraphCache: WeakMap<model.Paragraph, CachedParagraphEntry[]> = new WeakMap();
```

- [ ] **Step 2: Update `layoutParagraph` to check and update `paragraphCache`**

Edit `CanvasElementDrawer.layoutParagraph`:
```typescript
  private static layoutParagraph(
    ctx: CanvasRenderingContext2D,
    para: model.Paragraph,
    maxWidth: number,
    wrap: boolean
  ): WrappedLine[] {
    const widthKey = Math.round(maxWidth * 10);
    const cachedEntries = CanvasElementDrawer.paragraphCache.get(para);
    if (cachedEntries) {
      for (const entry of cachedEntries) {
        if (entry.widthKey === widthKey && entry.wrap === wrap) {
          return entry.lines;
        }
      }
    }

    const lines = CanvasElementDrawer.layoutParagraphInternal(ctx, para, maxWidth, wrap);

    // 每个段落最多保留最近 2 组排版结果（适应常规与旋转/缩放视图）
    const entries = cachedEntries ? cachedEntries.slice(-1) : [];
    entries.push({ widthKey, wrap, lines });
    CanvasElementDrawer.paragraphCache.set(para, entries);

    return lines;
  }
```
Rename the original paragraph calculation loop to `private static layoutParagraphInternal(...)`.

- [ ] **Step 3: Verify ArkTS file integrity**

Confirm no syntax or reference errors.

- [ ] **Step 4: Commit Task 3**

```bash
git add viewer-ohos/src/main/ets/render/CanvasElementDrawer.ets
git commit -s -m "perf(viewer-ohos): 引入 Canvas 段落折行排版 WeakMap 缓存"
```

---

### Task 4: Concurrency Queue, Path Lifecycle & Dynamic Resizing in `ImageStore.ets`

**Files:**
- Modify: `viewer-ohos/src/main/ets/render/ImageStore.ets:1-162`

**Interfaces:**
- Consumes: `NativeCore.readPartAsync`, `NativeCore.evictCache`, `RenderUtils.decodeImageBufferDetailed`
- Produces:
  - `ImageStore.activePathRefs: Map<string, number>`
  - `ImageStore.load(part: string, desiredMaxPixels?: number): Promise<boolean>` (返回是否有新图片或高清升级就绪)
  - `ImageStore.releasePart(part: string): void`
  - `ImageStore.release(): void` (仅当当前路径活跃引用为 0 时调用 `evictCache`)

- [ ] **Step 1: Rewrite `ImageStore.ets` to include activePathRefs, semaphore, negative cache, and budget upgrade**

Edit `viewer-ohos/src/main/ets/render/ImageStore.ets`:
```typescript
import { image } from '@kit.ImageKit';
import { NativeCore } from '../core/NativeCore';
import { RenderUtils, DecodedImageResult } from './RenderUtils';

/**
 * 文档内嵌图片仓库：受控并发解码（最大 3 并发）、按需动态下采样、LRU 容量淘汰与多实例安全隔离
 */
export class ImageStore {
  private static readonly MAX_CACHED_IMAGES: number = 32;
  private static readonly MAX_TOTAL_PIXELS: number = 8_000_000;
  private static readonly MAX_CONCURRENT_DECODES: number = 3;

  private static readonly activePathRefs: Map<string, number> = new Map();

  private readonly filePath: string;
  private readonly pixelMaps: Map<string, image.PixelMap> = new Map();
  private readonly pixelCounts: Map<string, number> = new Map();
  private readonly refCounts: Map<string, number> = new Map();
  private readonly sampledFlags: Map<string, boolean> = new Map();
  private readonly decodedBudgets: Map<string, number> = new Map();
  private readonly pending: Map<string, Promise<DecodedImageResult | null>> = new Map();
  private readonly failedParts: Set<string> = new Set();

  private totalPixels: number = 0;
  private closed: boolean = false;
  private activeDecodes: number = 0;
  private readonly waitQueue: Array<() => void> = [];
  private pathRegistered: boolean = false;

  constructor(filePath: string) {
    this.filePath = filePath;
    if (this.filePath) {
      const cur = ImageStore.activePathRefs.get(this.filePath) ?? 0;
      ImageStore.activePathRefs.set(this.filePath, cur + 1);
      this.pathRegistered = true;
    }
  }

  public get cache(): Map<string, image.PixelMap> {
    return this.pixelMaps;
  }

  public acquire(part: string): void {
    if (!part || this.closed) return;
    this.refCounts.set(part, (this.refCounts.get(part) ?? 0) + 1);
    this.touch(part);
  }

  public releasePart(part: string): void {
    if (!part || this.closed) return;
    const count = (this.refCounts.get(part) ?? 0) - 1;
    if (count > 0) {
      this.refCounts.set(part, count);
    } else {
      this.refCounts.delete(part);
      this.trimCache();
    }
  }

  private touch(part: string): void {
    const existing = this.pixelMaps.get(part);
    if (existing) {
      this.pixelMaps.delete(part);
      this.pixelMaps.set(part, existing);
    }
  }

  private async acquireDecodeSlot(): Promise<void> {
    if (this.activeDecodes < ImageStore.MAX_CONCURRENT_DECODES) {
      this.activeDecodes++;
      return;
    }
    return new Promise<void>((resolve) => {
      this.waitQueue.push(() => {
        this.activeDecodes++;
        resolve();
      });
    });
  }

  private releaseDecodeSlot(): void {
    this.activeDecodes--;
    if (this.waitQueue.length > 0) {
      const next = this.waitQueue.shift();
      if (next) next();
    }
  }

  /**
   * 异步加载指定部件图片；若存在高清升级或首次就绪，返回 true
   */
  public async load(part: string, desiredMaxPixels: number = 4_000_000): Promise<boolean> {
    if (this.closed || !this.filePath || !part || this.failedParts.has(part)) {
      return false;
    }

    const cached = this.pixelMaps.get(part);
    const isSampled = this.sampledFlags.get(part) ?? false;
    const currentBudget = this.decodedBudgets.get(part) ?? 0;

    // 若缓存命中且无需高清升级，直接返回
    if (cached) {
      if (!isSampled || desiredMaxPixels <= currentBudget * 1.5) {
        this.touch(part);
        return false;
      }
    }

    let task = this.pending.get(part);
    if (!task) {
      task = this.decodeWithBudget(part, desiredMaxPixels);
      this.pending.set(part, task);
    }

    let result: DecodedImageResult | null = null;
    try {
      result = await task;
    } finally {
      if (this.pending.get(part) === task) {
        this.pending.delete(part);
      }
    }

    if (!result) {
      if (!this.closed) this.failedParts.add(part);
      return false;
    }

    if (this.closed) {
      result.pixelMap.release();
      return false;
    }

    const oldPixelMap = this.pixelMaps.get(part);
    const oldPixels = this.pixelCounts.get(part) ?? 0;

    // 若已有旧图且当前解码结果像素未增加，保留旧图
    if (oldPixelMap && result.pixelMap === oldPixelMap) {
      this.touch(part);
      return false;
    }

    // 替换为新 PixelMap，扣减旧像素并释放旧图
    if (oldPixelMap) {
      this.totalPixels = Math.max(0, this.totalPixels - oldPixels);
      oldPixelMap.release();
    }

    let pixels = result.pixels;
    if (pixels <= 0) {
      try {
        const info = await result.pixelMap.getImageInfo();
        pixels = Math.max(0, (info?.size?.width ?? 0) * (info?.size?.height ?? 0));
      } catch (_e) {
        pixels = 0;
      }
    }

    this.pixelMaps.set(part, result.pixelMap);
    this.pixelCounts.set(part, pixels);
    this.sampledFlags.set(part, result.sampled);
    this.decodedBudgets.set(part, result.budget);
    this.totalPixels += pixels;
    this.trimCache();
    return true;
  }

  private async decodeWithBudget(part: string, desiredMaxPixels: number): Promise<DecodedImageResult | null> {
    await this.acquireDecodeSlot();
    try {
      // 快速划过优化：若出队后该部件引用已被释放，跳过本次解码
      if (this.closed || (this.refCounts.get(part) ?? 0) <= 0) {
        return null;
      }
      const buffer: ArrayBuffer = await NativeCore.readPartAsync(this.filePath, part);
      if (this.closed || (this.refCounts.get(part) ?? 0) <= 0) {
        return null;
      }
      return await RenderUtils.decodeImageBufferDetailed(buffer, desiredMaxPixels);
    } catch (e) {
      console.warn(`[ImageStore] Failed to read/decode image part ${part}: ${e}`);
      return null;
    } finally {
      this.releaseDecodeSlot();
    }
  }

  private trimCache(): void {
    if (this.closed) return;
    if (this.pixelMaps.size <= ImageStore.MAX_CACHED_IMAGES && this.totalPixels <= ImageStore.MAX_TOTAL_PIXELS) {
      return;
    }
    const keys: string[] = Array.from(this.pixelMaps.keys());
    for (const key of keys) {
      if (this.pixelMaps.size <= ImageStore.MAX_CACHED_IMAGES && this.totalPixels <= ImageStore.MAX_TOTAL_PIXELS) {
        break;
      }
      if ((this.refCounts.get(key) ?? 0) > 0) {
        continue;
      }
      const evicted = this.pixelMaps.get(key);
      const pixels = this.pixelCounts.get(key) ?? 0;
      this.pixelMaps.delete(key);
      this.pixelCounts.delete(key);
      this.sampledFlags.delete(key);
      this.decodedBudgets.delete(key);
      this.totalPixels = Math.max(0, this.totalPixels - pixels);
      if (evicted) {
        evicted.release();
      }
    }
  }

  public release(): void {
    this.closed = true;
    this.waitQueue.length = 0;
    this.pixelMaps.forEach((pixelMap: image.PixelMap) => {
      pixelMap.release();
    });
    this.pixelMaps.clear();
    this.pixelCounts.clear();
    this.sampledFlags.clear();
    this.decodedBudgets.clear();
    this.refCounts.clear();
    this.pending.clear();
    this.failedParts.clear();
    this.totalPixels = 0;

    if (this.pathRegistered && this.filePath) {
      const cur = ImageStore.activePathRefs.get(this.filePath) ?? 1;
      if (cur <= 1) {
        ImageStore.activePathRefs.delete(this.filePath);
        NativeCore.evictCache(this.filePath);
      } else {
        ImageStore.activePathRefs.set(this.filePath, cur - 1);
      }
      this.pathRegistered = false;
    }
  }
}
```

- [ ] **Step 2: Commit Task 4**

```bash
git add viewer-ohos/src/main/ets/render/ImageStore.ets
git commit -s -m "perf(viewer-ohos): 实施图片并发队列按需下采样与路径精准淘汰"
```

---

### Task 5: Zero-Proxy AST, Gesture Decoupling & `@Reusable` Component Tree in `OfficePreviewView.ets`

**Files:**
- Modify: `viewer-ohos/src/main/ets/render/OfficePreviewView.ets:100-560` and `900-1260`

**Interfaces:**
- Consumes: `ImageStore.load`, `ImageStore.acquire`, `ImageStore.releasePart`, `model.OfficeDocument`
- Produces:
  - `OfficePreviewView` (Zero-Proxy AST with `private rawDocument`, `@State docRevision`)
  - `@Reusable DocxTextBlockView`
  - `@Reusable DocxTableView`
  - `@Reusable DocxImageView`
  - `@Reusable DocxShapeView`
  - `@Reusable PptxSlideCanvas`
  - Handled `settledZoomPad` in `DocxFlowView` and `PptxSlidesView`

- [ ] **Step 1: Update `OfficePreviewView` for Zero-Proxy AST and docRevision**

In `OfficePreviewView`:
- Replace `@State document: model.OfficeDocument | null = null;` with:
  ```typescript
  private rawDocument: model.OfficeDocument | null = null;
  @State private docRevision: number = 0;
  ```
- In `publishLoadedDocument(doc)`:
  ```typescript
  this.rawDocument = doc;
  this.docRevision++;
  ```
- In `aboutToDisappear()` and `loadDocument()`: set `this.rawDocument = null; this.docRevision++;`
- In `computePageCount` / `extractSheetNames`: use `this.rawDocument`.
- In `build()`: bind `.key(\`doc-${this.docRevision}-${this.rawDocument?.kind ?? ''}\`)` to `DocxFlowView`, `PptxSlidesView`, and `SpreadsheetView`, passing `document: this.rawDocument`.

- [ ] **Step 2: Extract `@Reusable DocxTextBlockView` and add `@Reusable` to DOCX views**

Extract `DocxTextBlockView`:
```typescript
@Reusable
@Component
struct DocxTextBlockView {
  element: model.Element | null = null;
  @State private reuseVersion: number = 0;

  aboutToReuse(params: Record<string, Object>): void {
    if (params['element']) {
      this.element = params['element'] as model.Element;
      this.reuseVersion++;
    }
  }

  build() {
    if (this.element && this.element.paragraphs) {
      Column({ space: 4 }) {
        ForEach(
          this.element.paragraphs,
          (para: model.Paragraph) => {
            DocxParagraphView({ para: para })
          },
          (_para: model.Paragraph, pIdx: number) => `p-${pIdx}-${this.reuseVersion}`
        )
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
  }
}
```

Decorate `DocxTableView`, `DocxImageView`, `DocxShapeView` with `@Reusable`:
- In `DocxTableView`: add `aboutToReuse` updating `this.element = params['element'] as model.Element; this.reuseVersion++`.
- In `DocxImageView`: implement `aboutToReuse` & `aboutToRecycle`:
  ```typescript
  aboutToRecycle(): void {
    if (this.acquiredPart) {
      this.imageStore.releasePart(this.acquiredPart);
      this.acquiredPart = '';
    }
    this.pixelMap = null;
    this.cropCanvasReady = false;
  }

  aboutToReuse(params: Record<string, Object>): void {
    this.isDisappeared = false;
    this.element = params['element'] as model.Element;
    if (params['imageStore']) {
      this.imageStore = params['imageStore'] as ImageStore;
    }
    this.loadImage();
  }
  ```
- In `DocxFlowView`: map `ListItem().reuseId(element.type)` to reuse matching component pools.

- [ ] **Step 3: Decouple gesture zoom from `List.padding` in `DocxFlowView` & `PptxSlidesView`**

In `DocxFlowView` and `PptxSlidesView`:
- Add `@State settledZoomPad: number = 0;`
- Replace `top: 16 + this.verticalZoomPad(), bottom: 24 + this.verticalZoomPad()` with `top: 16 + this.settledZoomPad, bottom: 24 + this.settledZoomPad`.
- Add helper:
  ```typescript
  private syncSettledZoomPad(): void {
    const pad = this.verticalZoomPad();
    if (Math.abs(this.settledZoomPad - pad) > 0.5) {
      this.settledZoomPad = pad;
    }
  }
  ```
- Call `this.syncSettledZoomPad()` only on `PinchGesture.onActionEnd`, `onActionCancel`, `TapGesture.onAction`, `setZoom()`, and `onAreaChange()`. Do NOT call inside `onActionUpdate`!

- [ ] **Step 4: Update `PptxSlideCanvas` with `@Reusable`, progressive redraw, and computed display budget**

In `PptxSlideCanvas`:
- Add `@Reusable` decoration.
- Add `aboutToRecycle` releasing all `acquiredParts` and canceling redraw timers.
- Add `aboutToReuse` resetting slide info, calling `this.loadImages()`, and forcing `this.drawSlide(true)`.
- Replace `Promise.all` in `loadImages` with progressive `load(part, budget)`:
  ```typescript
  private redrawTimer: number = -1;

  private scheduleRedraw(): void {
    if (this.redrawTimer !== -1 || this.isDisappeared) return;
    this.redrawTimer = setTimeout(() => {
      this.redrawTimer = -1;
      if (!this.isDisappeared) {
        this.drawSlide(true);
      }
    }, 16);
  }
  ```
- In `loadImages`:
  ```typescript
  const count = parts.length;
  parts.forEach(async (part: string) => {
    const budget = this.computePartBudget(part, count);
    const updated = await this.imageStore.load(part, budget);
    if (updated && !this.isDisappeared) {
      this.scheduleRedraw();
    }
  });
  ```
- Compute budget based on element slide points scaled with `2.25x` clear margin, capped by page budget share.

- [ ] **Step 5: Verify syntax and compile**

Check ArkTS changes for consistency.

- [ ] **Step 6: Commit Task 5**

```bash
git add viewer-ohos/src/main/ets/render/OfficePreviewView.ets
git commit -s -m "perf(viewer-ohos): 去代理化 AST、手势与列表布局解耦及组件池复用"
```

---

### Task 6: `DisplaySync` Hardware VSync, Merge Row Buckets & Cell Wrap Cache in `SpreadsheetView.ets`

**Files:**
- Modify: `viewer-ohos/src/main/ets/render/SpreadsheetView.ets:1-350` and `480-720`

**Interfaces:**
- Consumes: `@kit.ArkGraphics2D` `displaySync`, `model.Sheet`, `model.Cell`
- Produces:
  - `SheetLayoutData` with `mergeBuckets: Int32Array[]` and `mergeSeenGen: Int32Array`
  - `SpreadsheetView.vsync: displaySync.DisplaySync | null`
  - `COLUMN_LETTERS: string[]`
  - `cellWrapCache: WeakMap<model.Cell, ...>`

- [ ] **Step 1: Add precomputed column letters and row-bucketed merges in `SheetLayoutData`**

In `viewer-ohos/src/main/ets/render/SpreadsheetView.ets`:
- Add precomputed column letters array:
  ```typescript
  const COLUMN_LETTERS: string[] = (() => {
    const arr: string[] = new Array(256);
    for (let i = 0; i < 256; i++) {
      let letter = '';
      let temp = i;
      while (temp >= 0) {
        letter = String.fromCharCode((temp % 26) + 65) + letter;
        temp = Math.floor(temp / 26) - 1;
      }
      arr[i] = letter;
    }
    return arr;
  })();
  ```
- In `SheetLayoutData`:
  ```typescript
  static readonly BUCKET_ROW_SIZE = 64;
  readonly mergeBuckets: Int32Array[];
  readonly mergeSeenGen: Int32Array;
  currentGen: number = 0;
  ```
  Bucket merges by row index:
  ```typescript
  const bucketCount = Math.ceil(rowCount / SheetLayoutData.BUCKET_ROW_SIZE) + 1;
  const rawBuckets: number[][] = Array.from({ length: bucketCount }, () => []);
  for (let mIdx = 0; mIdx < this.merges.length; mIdx++) {
    const m = sheet.merges[mIdx];
    const startB = Math.floor(m.startRow / SheetLayoutData.BUCKET_ROW_SIZE);
    const endB = Math.min(bucketCount - 1, Math.floor(m.endRow / SheetLayoutData.BUCKET_ROW_SIZE));
    for (let b = startB; b <= endB; b++) {
      rawBuckets[b].push(mIdx);
    }
  }
  this.mergeBuckets = rawBuckets.map((b) => new Int32Array(b));
  this.mergeSeenGen = new Int32Array(this.merges.length);
  ```

- [ ] **Step 2: Implement hardware `DisplaySync` with graceful fallback in `SpreadsheetView`**

Import `displaySync`:
```typescript
import { displaySync } from '@kit.ArkGraphics2D';
```
In `SpreadsheetView`:
- Fields:
  ```typescript
  private vsync: displaySync.DisplaySync | null = null;
  private flingRunning: boolean = false;
  private lastVsyncTimestamp: number = 0;
  ```
- Initialize in `startFling`:
  ```typescript
  private startFling(vx: number, vy: number): void {
    this.stopFling();
    const maxVelocity = 4000;
    const currentV = Math.hypot(vx, vy);
    if (currentV > maxVelocity) {
      const ratio = maxVelocity / currentV;
      vx *= ratio;
      vy *= ratio;
    }
    this.flingVx = vx;
    this.flingVy = vy;
    this.flingRunning = true;
    this.lastVsyncTimestamp = 0;
    this.lastFlingTime = Date.now();

    if (!this.vsync) {
      try {
        this.vsync = displaySync.create();
        this.vsync.on('frame', (frameInfo: displaySync.IntervalInfo) => {
          if (!this.flingRunning) return;
          const ts = frameInfo.timestamp;
          let dt = 0.016;
          if (this.lastVsyncTimestamp > 0 && ts > this.lastVsyncTimestamp) {
            dt = Math.min(0.032, Math.max(0.001, (ts - this.lastVsyncTimestamp) / 1e9));
          }
          this.lastVsyncTimestamp = ts;
          this.stepFlingWithDt(dt);
        });
      } catch (_e) {
        this.vsync = null;
      }
    }

    if (this.vsync) {
      this.vsync.start();
    } else {
      this.stepFlingFallback();
    }
  }

  private stopFling(): void {
    this.flingRunning = false;
    this.lastVsyncTimestamp = 0;
    if (this.vsync) {
      this.vsync.stop();
    }
    if (this.flingTimer !== -1) {
      clearTimeout(this.flingTimer);
      this.flingTimer = -1;
    }
    this.flingVx = 0;
    this.flingVy = 0;
  }
  ```

- [ ] **Step 3: Add `cellWrapCache` in `SpreadsheetView` and update `drawSingleCell`**

Add `WeakMap` for cell lines:
```typescript
interface CachedCellWrap {
  readonly scaleKey: number;
  readonly availWKey: number;
  readonly maxLines: number;
  readonly lines: string[];
}

private readonly cellWrapCache: WeakMap<model.Cell, CachedCellWrap> = new WeakMap();
```
In `drawSingleCell`, when `style?.wrap` is true, check `cellWrapCache` before executing binary search text measurement.

- [ ] **Step 4: Use bucketed merges in `redraw()`**

In `redraw()`:
- Calculate start bucket `Math.floor(firstRowIdx / SheetLayoutData.BUCKET_ROW_SIZE)` and end bucket.
- Iterate only through merges in relevant buckets, deduplicating with `layout.currentGen` in `layout.mergeSeenGen`.

- [ ] **Step 5: Verify ArkTS compile**

Verify no errors.

- [ ] **Step 6: Commit Task 6**

```bash
git add viewer-ohos/src/main/ets/render/SpreadsheetView.ets
git commit -s -m "perf(viewer-ohos): 实施 DisplaySync 硬件 VSync 滚动与合并单元格分桶索引"
```

---

### Task 7: Full Pipeline Compilation, Cargo Workspace Tests, Clang/Cargo Clippy & Demo HAP Packaging Verification

**Files:**
- Test: All modified files across workspace

- [ ] **Step 1: Run Rust workspace unit tests**

Run: `cargo test --workspace`
Expected: PASS (all tests pass)

- [ ] **Step 2: Run Rust Clippy lint gates**

Run: `cargo clippy -p jz-office-core -- -D warnings`
Run: `cargo clippy -p jz-office-ohos -- -D warnings`
Expected: 0 warnings, 0 errors

- [ ] **Step 3: Run OpenHarmony multi-arch compilation and HAR packaging**

Run: `./scripts/build-ohos.sh`
Expected: Build succeeds, generates `arm64-v8a` and `x86_64` `.so` files, and outputs `viewer_ohos.har`.

- [ ] **Step 4: Run Demo HAP assembly with Hvigor**

Run: `hvigorw --mode module -p module=demo_ohos@default -p product=default assembleHap --no-daemon`
Expected: BUILD SUCCESSFUL (strict ArkTS compiler verifies no type or syntax errors)

- [ ] **Step 5: Check git status to ensure working directory is clean**

Run: `git status`
Expected: Clean working tree

- [ ] **Step 6: Commit any remaining build fixes if needed**

```bash
git commit -s -m "chore(ohos): 验证鸿蒙端加载与渲染性能优化编译与打包通过"
```
