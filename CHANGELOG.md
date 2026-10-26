# 更新日志

## 0.8.0

发布页面：[v0.8.0 Release](https://github.com/donglua/JZOfficeViewer/releases/tag/v0.8.0)。

本版本主要更新鸿蒙端加载与渲染性能全链路重构、大图加载硬限制突破、双端表格合并单元格空间分桶索引与底层文档包缓存精准淘汰能力。

### 性能与渲染

- **双端表格空间分桶索引**：Android 与 HarmonyOS NEXT 双端为 `SheetRenderer` 引入行高分桶空间索引（Row Buckets），合并单元格按行范围分桶注册，帧绘制时仅遍历视口覆盖区间所命中的桶，并借助代数生成标记实现 $O(1)$ 无额外内存分配的跨桶去重，显著降低含数百上千合并单元格大表格的滚动开销。
- **鸿蒙端硬件 VSync 滚动**：Spreadsheet 滚动调度接入硬件 `DisplaySync`，解耦每帧重绘与高频手势事件，手势惯性滑行动画更加丝滑流畅。
- **鸿蒙端零代理 AST 与组件复用**：去代理化（Zero-Proxy）AST 数据结构，消除 ArkUI `@State` 深层代理遍历开销；拆分并重构 `@Reusable` DOCX 文本块与 PPTX 画布组件池，列表长滑动时内存与帧率大幅提升。
- **鸿蒙端 Canvas 排版 WeakMap 缓存**：引入针对段落排版计算结果的 `WeakMap` 缓存，避免相同文本与样式在滚动中重复测算折行。
- **鸿蒙端图片并发调度与下采样**：重构 `ImageStore`，实施并发信号量队列调度与带元数据的按需下采样解码，保证多图并发展开时的内存峰值平稳。

### 特性与接口

- **精准文档缓存淘汰**：跨平台 Rust 核心新增 `evict_package_cache(path)`，鸿蒙端导出 `NativeCore.evictCache(path)` 与 `OfficePreviewController.clearDocumentCache(path)`，支持在多文档切换时精准释放特定文档的 ZIP 句柄与内存索引。

### 修复

- **突破鸿蒙 Node-API 2MB 传输硬限制**：修复大于 2MB 的高清图片在 OpenHarmony Node-API 传递因 `napi_create_buffer` 限制导致报错返回 null 的问题，改用 `napi_create_arraybuffer` 直接分配。
- **鸿蒙端图片异步竞态与复用修复**：修复组件复用脏标记与异步图片回填竞态，避免快速滑动时图片偶现闪烁或错位。
- **ArkTS 严格模式与 Rust 规范**：消除 `RenderUtils.ets` 中的严格模式类型警告，规范 Rust 单测与全局格式化。

## 0.7.0

发布页面：[v0.7.0 Release](https://github.com/donglua/JZOfficeViewer/releases/tag/v0.7.0)。

本版本主要更新读屏无障碍能力（Android 与 HarmonyOS NEXT 双端）。

### 无障碍

- Android 端 `OfficePreviewView` 在文档加载完成后按格式设置内容摘要（页数与工作表名），翻页、切表与打开失败时向读屏软件播报状态；惯性滚动期间保持静默，停稳后补播最终页码，避免连续翻页时反复播报。
- Android 端补齐读屏自定义导航动作：翻页、切表、步进缩放与视口平滑滚动按当前页码与缩放档位动态显隐，页码或缩放变化时刷新无障碍节点，避免读屏读到过期动作。
- 鸿蒙端为 Canvas 自绘的 PPTX 幻灯片与 XLSX 工作表补充无障碍文本摘要，经 `accessibilityText` 与 `accessibilityGroup(true)` 合并为单一可朗读节点；DOCX 流式列表由原生 `Text` 组件构成，读屏可直接朗读，不作改动。
- 新增 `accessibility` 设备测试套件，覆盖内容摘要、动作菜单显隐、动作执行、Fling 停稳播报与失败态摘要清理；末段通过测试探针服务（与 TalkBack 消费同一事件流）验证播报端到端送达。

### 修复

- 鸿蒙端修复大图调色板索引降采样后内容出现空白的问题。
- Android 端打开文档失败时清空上一份文档的内容摘要，避免读屏播报过期的页数与工作表信息。

### 工程与发布

- 新增 `scripts/run-accessibility-device-checks.sh`；CI 增加 `accessibility` 设备测试任务，在 x86_64 模拟器上运行该套件。播报探针在模拟器与厂商 ROM 上可能无法绑定，该段自动 SKIP，其余断言失败仍使任务失败。
- 鸿蒙 `oh-package.json5` 补充 `homepage` 与 `keywords` 元数据。
- 升级 GitHub Actions 版本以适配 Node.js 24 运行时。

## 0.6.0

发布页面：[v0.6.0 Release](https://github.com/donglua/JZOfficeViewer/releases/tag/v0.6.0)。

### 渲染与性能

- Android 端重构 `DocumentDecoder` 为基于流式的零 DOM 解析，避免将完整 JSON 树反序列化至内存，降低大文档解析时的内存峰值。
- Android 端将排版测量与表格空间索引预构建移至后台线程执行，避免阻塞主线程；优化绘制热路径，复用对象以减少垃圾回收停顿。
- Android 端延迟按需打开 `ZipFile` 句柄，并为 `OfficePreviewView` 支持屏幕旋转与配置变更时的状态保存与恢复（`onSaveInstanceState` / `onRestoreInstanceState`）。
- 鸿蒙端 DOCX 与 PPTX 列表切换为 `LazyForEach` 按需虚拟化渲染，降低长文档内存占用并提升浏览连贯性。
- 鸿蒙端完善全格式捏合缩放、双击缩放、平移浏览及边界阻尼体验；支持 DOCX 内嵌图片裁剪与表格单元格单遍排版复用。

### 接口与控制器

- 鸿蒙端新增 `OfficePreviewController` 控制器，补齐页面跳转（`jumpToPage`）、缩放控制（`setZoom`/`resetZoom`）以及翻页回调与宿主生命周期管理，对齐 Android 端接口设计。
- 在线模块 `viewer-online` 增加总耗时超时控制（`totalTimeoutMillis`，默认 60 秒）及重定向私有网段/环回拦截配置（`blockPrivateRedirect`，防范 SSRF 风险）。
- 在线模块净化 `Content-Disposition` 与 URL 解析出的下载文件名，移除路径分隔符与相对路径导航，防范路径穿越。

### 核心与工程规范

- Rust 核心序列化 JSON 模型时省略空集合与空值字段，减少跨语言传输体积与反序列化开销；XML 属性存储由 `HashMap` 调整为紧凑 `Vec`。
- 新增 `scripts/check-versions.py` 自动化多端版本一致性校验脚本；日常 CI 补齐 Rust、JVM 专项检查套件及 Android/HarmonyOS 双端构建门禁。

## 0.5.0

发布页面：[v0.5.0 Release](https://github.com/donglua/JZOfficeViewer/releases/tag/v0.5.0)。

### 格式解析与排版

- 暴露 `parse_path_to_json` 原生接口，由 Rust 核心直接完成路径解析与序列化，去除 Android JNI 与鸿蒙 NAPI 中重复的中间层胶水代码。
- 过滤 DOCX 中的 `vanish` 和 `webHidden` 隐藏文本，忽略 `rt`/`rp` ruby 注音标记，并设置单文档 8 MiB 文本上限保护。
- XLSX 支持分号 `;` 切分多段格式（正数/负数/零/文本），支持 `[$-409]` 等区域代码与颜色标签解析，支持负数括号表示与 1900 虚拟日期。
- 超长单元格截断逻辑收敛至 Rust 核心统一处理；统一 PPTX 表格列宽归一化计算，以及双端字体与列表符号默认样式。

### 资源解压与内存管理

- 新增线程安全的 `package_cache` 模块，通过 LRU 缓存与文件修改感知重载复用 ZIP 句柄与中央目录，减少并发读图时的重复 I/O。
- ZIP 解压采用动态流式读取，避免未经校验的大内存预分配；整包累计跟踪 256 MiB 解压预算（`MAX_EXPANDED`），防范畸形压缩包导致的内存超限。
- 规范原生句柄、Bitmap 与 PixelMap 的生命周期与释放时机，优化图片缓存（`ImageStore` / `OfficeCache` / `OfficeImages`）的 LRU 淘汰机制，降低跨语言调用时的内存泄漏风险与峰值占用。

### 鸿蒙端渲染与交互

- 手势缩放后支持上下滚动浏览全文，横向平移查看边缘内容。
- XLSX 电子表格支持单元格自动换行（`style.wrap`）、超长截断与 UTF-16 代理对截断保护。
- DOCX 修复首行缩进与左边距叠加计算，支持 `textIndent`、`fontFamily`、`lineHeight` 行距与 `DocxShapeView` 矢量形状绘制。
- Canvas 文本排版复用测量结果，避免每帧重复测量。
- HAR 打包排除 native 源码及编译中间缓存，移除 32 位架构预编译库，缩减产物体积。

## 0.4.0

发布页面：[v0.4.0 Release](https://github.com/donglua/JZOfficeViewer/releases/tag/v0.4.0)。

> **说明**：本版本主要更新 **鸿蒙端（HarmonyOS NEXT / `@jzdy/office`）**，补齐手势交互与表格渲染能力；Android 端（`viewer` / `viewer-online`）与 Rust 核心层主要同步版本号。

### 交互与视口

- PPTX 与 DOCX 全局视口支持双指捏合缩放（1.0x~4.0x，跟随触摸中心锚点）与双击快速切换（1.0x / 2.0x）。
- 放大状态下支持二维平移拖拽与边界阻尼，各视口容器启用硬件裁剪（`.clip(true)`），避免内容溢出容器边界。

### 渲染与性能

- DOCX 接入 `ImageStore` 统一管理图片生命周期，通过 `DocxImageView` 异步解压并解码 ZIP 内嵌图片为 PixelMap；支持拉伸图元按文档声明尺寸等比渲染，并增加视口宽度约束防止大图溢出。
- XLSX 采用轴前缀和（`SheetAxis`）与稀疏行索引二分查找可见单元格，避免全表遍历。
- XLSX 使用 `Uint8Array` 紧凑记录合并单元格从属，减少滑动过程中的对象分配与垃圾回收 (GC) 影响。
- XLSX 增加惯性滑动（Fling）支持，改善电子表格触摸滚动的连贯度。
- 限制网格线、合并单元格、边框及表头仅在视口可见区间绘制，减少无效重绘。

### 发布与脚本

- `publish-ohpm.py` 禁用终端回显以保护口令安全，增加 300 秒发布超时机制，并在退出时清理伪终端文件描述符。

## 0.3.1

发布页面：[v0.3.1 Release](https://github.com/donglua/JZOfficeViewer/releases/tag/v0.3.1)。

### 显示与修复

- PPTX 解析幻灯片、版式和母版中的 `blipFill` 图片背景，输出全幅 IMAGE 元素供平台层绘制。
- `viewer-ohos` 增加 `ImageStore` 图片缓存与解码逻辑，修复 PPTX 内嵌图片与背景图未显示的问题。

## 0.3.0

发布页面：[v0.3.0 Release](https://github.com/donglua/JZOfficeViewer/releases/tag/v0.3.0)。

### 升级说明

- `viewer` 和 `viewer-online` 的 Maven groupId 改为 `io.github.donglua.office`，artifactId 和 Java 包名不变。升级时同时更新 groupId 和版本号，例如 `io.github.donglua.office:viewer-online:0.3.0`；它会依赖同组、同版本的 `viewer`。已发布的 `0.2.0` 保留原坐标。
- Rust 文档模型与 Android 解码器同步演进，使用完整版本的 AAR，不能混用不同版本的 Java 类和原生库。

### 性能与显示

- PPTX 仅为可见页及前后相邻页准备文字和绘图布局，释放远处页面的布局；保留完整页面尺寸和位置，支持跳页、缩放和返回后重建。文档仍一次解析为有界模型。
- 图片缓存保留最近使用的离屏图片，返回时复用未被淘汰的 Bitmap，减少重复解码；当前可见图片优先获得清晰度预算。全部缓存仍共用 800 万像素预算，通常最多保留 32 项。
- 保留 PPTX 小数字号，修复紧凑章节标题意外换行及显示不完整的问题；改善 Demo PPTX 文字与背景的对比度。

### 内部实现

- 将 Office 容器校验集中到 Rust，减少 Android 层重复校验。
- 将 PPTX 纯几何计算移入 Rust，Android 继续负责文字测量和 Canvas 绘制。
- 提取与平台无关的 XLSX 行列布局，保留 Android 绘制和交互入口。

### 验证范围

- 新增按需排版、最近图片复用、缓存淘汰、清晰度升级和小数字号回归；图片、PPTX 与 Demo 样例已在 Android 真机通过，覆盖全部 16 页内置 PPTX。
- `0.3.0` 候选版本的双模块本地发布、Release 构建与 lint、Rust 检查、47 项下载器检查及缓存检查已通过。独立消费项目已验证新坐标的 Gradle 元数据和纯 POM 传递依赖；容器限制、图片、PPTX、XLSX、排版、Demo 样例及在线模块生命周期专项均在真机通过。
- 完整设备套件仍有未通过项：曾出现输入分发 ANR，诊断运行捕获到约 26 万字符的 XLSX 单元格在主线程断行计算中持续阻塞；另有 PPTX 屏幕背景色断言失败，截图中已绘出内容。这两项作为本版本已知问题保留。
- 性能收益分别对应排版和图片请求阶段，不代表整份文档打开耗时按相同比例下降；缓存预算不包含解码中的图片和应用其他内存。
- 仍为有限内容预览，格式、资源和在线预览限制见 [README](README.md)。正式签名和上传由发布 CI 执行，结果见 [Actions](https://github.com/donglua/JZOfficeViewer/actions/workflows/publish-sonatype.yml)。

## 0.2.0

发布页面：[v0.2.0 Release](https://github.com/donglua/JZOfficeViewer/releases/tag/v0.2.0)。

### 在线预览与缓存

- 新增可选 `viewer-online` 模块，支持文件直链、签名 URL、自定义请求头、下载进度、取消和可替换下载器；完整下载后交给 `viewer` 预览。
- `RemoteOfficeLoader` 管理下载与预览生命周期，取消或关闭时抑制旧回调并清空预览；下载、解析或显示中的文件由使用者持有，最后一个使用者释放后删除。
- `OfficeCache` 统一管理 `cacheDir/office-preview/`，清理时保留正在使用的文件，并返回删除、跳过和失败统计。
- Demo 增加在线打开、取消、重试、关闭文档和清理缓存入口。

### 发布配置

- 提供 `io.github.donglua:viewer:0.2.0` 和 `io.github.donglua:viewer-online:0.2.0` 两个坐标。Maven 接入在线预览只需后者，它通过 `api` 依赖同版本 `viewer`；直接引用 AAR 时必须同时引入两个文件。
- 两个模块共用发布配置。根任务 `:prepareRelease` 在 `build/release-repository/` 生成两套 AAR、sources/Javadoc JAR、POM 和 Gradle Module Metadata，并检查坐标、依赖和 AAR 内容。
- 根任务 `:publishToSonatype` 上传两个模块后只向 Central Portal 交接一次；旧入口 `:viewer:publishToSonatype` 同样发布两个模块。
- `PUBLISHED_ARTIFACT_ID` 仍指定 `viewer` 的 artifactId，在线模块使用其值加 `-online`。根项目默认版本、Demo `versionName` 和 Rust workspace 版本统一为 `0.2.0`，Gradle daemon 固定使用 JDK 21。
- `Publish libraries to Sonatype Central` 工作流在上传前运行 Java 网络与缓存检查、Rust 检查和发布准备，并向 Release 上传两个带版本号的 AAR。

### 已知限制

- 仍为 DOCX、PPTX、XLSX 的有限内容预览，不保证 Office 版式一致；不支持旧版 `.doc/.ppt/.xls`、加密文档、ZIP64/分卷容器或编辑。具体格式与资源限制见 [README](README.md)。
- 在线预览不支持边下载边看、断点续传或持久离线缓存。缓存使用状态仅在同一应用进程内共享，不支持多个进程共用缓存目录。
- 取消立即使旧任务回调失效，但默认下载器的阻塞网络读取可能等到超时才退出，同一 loader 的后续下载需等待线程退出。默认连接超时 15 秒、读取超时 30 秒，可通过请求配置缩短。
- URI 交接会额外复制一份预览文件，单个文档可能占用约两倍文件大小的磁盘空间。DOCX/PPTX 的预览副本保留至关闭，XLSX 在解析完成后释放。

### 验证状态

- Debug/Release 构建、lint、47 项网络检查、缓存检查及 Rust 检查已通过。
- 双模块本地发布产物检查已通过。独立消费项目使用 Gradle 元数据和纯 POM 均能从 `viewer-online:0.2.0` 解析出同版本的 `viewer`。
- 正式签名和上传由发布 CI 执行，结果见 [Actions](https://github.com/donglua/JZOfficeViewer/actions/workflows/publish-sonatype.yml)。
- Android Instrumentation APK 已编译，尚无可用设备或 AVD 执行，设备验收未完成。

## 0.1.0（已发布）

`viewer` 的历史版本已发布至 [Maven Central](https://central.sonatype.com/artifact/io.github.donglua/viewer/0.1.0)，AAR 附件见 [v0.1.0 Release](https://github.com/donglua/JZOfficeViewer/releases/tag/v0.1.0)。
