# 更新日志

## 未发布

### 性能

- **元数据与缩略图的轻量路径（`core` / `viewer` / `viewer-ohos` / `viewer-macos`）**：
  - 新增 native 轻量元数据接口（`metadata_path_to_json` / `NativeCore.metadata` / `readMetadataAsync` / `jz_office_metadata_path`），元数据速读只读取判定格式与页数所需的少量 ZIP 部件，不再触发整篇文档的样式、几何与文本解析，输出独立的紧凑协议。
  - 缩略图改走首屏范围解析：PPTX 只渲染首张幻灯片，XLSX 只解析首个工作表，DOCX 只解析首屏正文块并在排版越过首页视口底部后停止。封面像素与完整解析一致，但不再承担整篇文档的解析与排版成本。
  - 新增按 文件路径 + 大小 + 修改时间 + 解析范围 命中的解析结果缓存。同一文件连续执行「元数据 → 缩略图 → 打开预览」不再重复解析；更完整的解析结果可直接服务封面请求，文件内容变化后自动失效。`clear_package_cache` / `evict_package_cache` 一并清理该缓存，避免检索索引与解析结果错配。

## 0.13.1

发布页面：[v0.13.1 Release](https://github.com/donglua/JZOfficeViewer/releases/tag/v0.13.1)。

本版本主要增强 DOCX 排版完整度（保留文本框文字内容、支持图片裁剪映射），并优化鸿蒙 NEXT 端 PPTX 滑动渲染性能与末页页码计算。

### 排版与特性

- **DOCX 文本框内容保留（`core`）**：
  - 支持解析 `w:pict`、`w:object` 和 `w:txbxContent` 内部文本框段落，将其内容按流式保留在文档正文中，避免此前直接跳过文本框导致文字丢失。
- **DOCX 图片裁剪映射（`core`）**：
  - 解析图形与内嵌图片的 `a:srcRect` 裁剪比例属性，映射并投影到现有数据模型的 `imageBounds` 中；各平台视图层（Android / HarmonyOS NEXT / macOS）无需修改即可自动正确显示裁剪后的局部图片。

### 细节修复与交互优化

- **鸿蒙端 PPTX 滑动重绘与页码修正（`viewer-ohos`）**：
  - 优化高频滑动过程中的重绘通知逻辑，仅在页码实际变化时通知 ArkUI 状态与外部回调，降低冗余渲染开销。
  - 修正 PPTX 视口滚动到底部边界时因上一页可见面积较大而无法选中末页的问题，确保首尾边界页码准确对应。

## 0.13.0

发布页面：[v0.13.0 Release](https://github.com/donglua/JZOfficeViewer/releases/tag/v0.13.0)。

本版本主要支持跨平台字体族解析与排版修饰属性（字体回退、字间距、字重、上下标、删除线）、高级段落间距与网格间距补偿，以及全端文本高亮、段落底纹与段落边框高保真渲染。

### 排版与字体属性

- **跨平台字体族解析与排版修饰（`core` / `viewer` / `viewer-ohos` / `viewer-macos`）**：
  - **核心模型下沉（`core`）**：数据模型新增完整 Typography 支持，涵盖西文字体族（`font_family`）、东亚字体族（`font_family_east_asia`）、通用字体族类别（`GenericFontFamily`：Serif / Sans-Serif / Monospace）、字间距（`spacing`）、基线偏移与上下标（`baseline`）、单/双删除线（`strike` / `double_strike`）以及标准化字重（`weight` 100–900）。
  - **文档解析支持**：DOCX、PPTX 及 XLSX 全面支持字体族提取与东亚字体（中文字符）优先匹配规则；XLSX 单元格样式支持提取字体族、删除线及垂直对齐方式。
  - **Android 端（`viewer`）**：引入通用字体族后备映射系统与 `Typeface` 缓存池，支持字重匹配、字间距（`letterSpacing`）、上下标基线对齐与删除线渲染；修复细字重（Light）与加粗样式的兼容表现。
  - **HarmonyOS NEXT 端（`viewer-ohos`）**：支持字体族级联回退、Canvas 文字排版字间距补偿，以及 DOCX 上下标基线偏移对齐。
  - **macOS 端（`viewer-macos`）**：接入 CoreText 字体匹配与系统通用字体回退；新增有界 `TypefaceCache`（LRU 缓存）避免高频文本测量与绘制时重复解析字体对象。

### 段落间距与网格补偿

- **DOCX 高级段落间距与网格补偿（`core`）**：
  - 支持行数单位段落间距（`lineRule="auto"` 行距计算），解析上下文间距标记（`w:contextualSpacing`）自动消除同级段落间的重复间距。
  - 引入文档网格行间距补偿算法（`w:docGrid` pitch compensation），精准对齐 Word 标准排版网格。
- **PPTX 段落间距与排版对齐（`core`）**：
  - 支持百分比与点数行距/段前段后间距（`spcPct` / `spcPts`）计算。
  - 支持两端对齐（justified alignment）排版。

### 底纹、边框与文本高亮

- **文本高亮与段落底纹边框（`core` / `viewer` / `viewer-ohos` / `viewer-macos`）**：
  - **模型与解析（`core`）**：支持解析文本高亮颜色（`w:highlight`）、段落底纹填充（`w:shd`）及段落上下左右与段间边框（`w:pBdr`），并对边框线宽实施安全钳位与边界校验。
  - **全端绘制支持**：Android Canvas、鸿蒙 NEXT Canvas 与 macOS CoreGraphics 原生预览层均已完整支持段落底纹区域填充、多边边框线条绘制与文本 run 背景高亮矩形渲染。

### 细节修复与稳定性

- **PPTX 属性继承修复**：修复当幻灯片段落显式声明 `baseline=0` 时意外继承母版/上下文基线偏移的问题。
- **排版与测试规范**：统一修复核心层边框计算边界条件，规范测试用例断言风格与格式化。

## 0.12.0

发布页面：[v0.12.0 Release](https://github.com/donglua/JZOfficeViewer/releases/tag/v0.12.0)。

本版本主要支持 DOCX 表格单元格内图片解析与全端渲染对齐、表格边框样式支持，以及 macOS 原生预览端重大架构重构（接入 `OfficeImageLoader` 异步按需解码、视口裁剪虚拟化渲染与滚动页码感知）。

### 平台与架构

- **macOS 端视口虚拟化与异步解码架构（`viewer-macos`）**：
  - **解耦预加载**：新增 `OfficeImageLoader`，文档打开阶段彻底解耦整篇图片预加载，采用异步队列按需解码与 LRU 内存预算管理。
  - **滚动视口监听**：监听 `NSClipView` 滚动视口边界，动态计算可见区域并按需触发当前页及邻近页图片解码。
  - **绘制层视口裁剪**：PPTX 幻灯片与 DOCX 页面接入视口可见区域裁剪，非视口内的元素直接跳过绘制，大幅降低长文档渲染与合成开销。
  - **动态页码与资源释放**：支持基于视口滚动几何中心动态感知当前页码与跨页通知；离开视口的离屏图片资源受 LRU 内存预算管控并优雅释放。
  - **演示工程重构**：规范 macOS Demo 入口为 `JZOfficeMacDemoApp.swift`，清理冗余 benchmark 文件。

### DOCX 排版与特性

- **表格单元格图片解析与排版（`core` / `viewer` / `viewer-ohos` / `viewer-macos`）**：
  - **解析核心（`core`）**：支持提取 DOCX 表格单元格内嵌入的图形图片（`w:drawing` / `pic:pic`），计算原始/建议宽高，并在数据模型中安全透出。
  - **Android 端（`viewer`）**：`OfficeRenderer` 支持单元格图片异步加载、水平居中排版与上下内边距自适应，保持文本与图片混排稳定。
  - **HarmonyOS NEXT 端（`viewer-ohos`）**：支持单元格图片异步读取与 Canvas 居中绘制，图片加载完成后触发局部脏重绘。
  - **macOS 端（`viewer-macos`）**：支持单元格图片按需加载、自适应高宽比缩放与居中排版。
- **表格边框样式支持**：
  - Rust 核心与三端渲染层完善 DOCX 表格边框样式（`top` / `bottom` / `left` / `right` / `insideH` / `insideV`）解析与粗细/颜色渲染。

### 稳定性与修复

- **macOS 端图片缓存与生命周期修复**：
  - 修复连续快速翻页时，前序页面图片被 LRU 缓存自我淘汰导致返回后出现灰块占位的问题。
  - 修复 `OfficePreviewView` 在 teardown 析构时越权关闭外部注入的共享 `imageLoader` 的问题。
  - 优化视口快速重入时的取消与请求队列复用，避免多线程竞态与无效重解。
  - 补充 `OfficeImageLoader` 视口虚拟化、预算超限淘汰及与 `OfficePeek` 的集成兼容性测试用例。
- **代码规范**：
  - 格式化 Rust 核心 `docx_tables.rs`，确保通过 `cargo fmt` 检查。

## 0.11.0

发布页面：[v0.11.0 Release](https://github.com/donglua/JZOfficeViewer/releases/tag/v0.11.0)。

本版本主要新增 macOS 原生平台支持、三端跨平台全文检索与搜索交互组件、DOCX 编号列表与表格合并排版增强，以及多项端侧渲染与稳定性优化。

### 平台与架构

- **macOS 原生平台支持（`viewer-macos`）**：
  - 新增基于 CoreGraphics / CoreText / ImageIO / SwiftUI 的原生预览组件，提供纯 Swift API 与标准预览控制接口。
  - 支持编译生成 Apple Silicon（`arm64`）与 Intel（`x86_64`）通用静态库及 XCFramework，并接入 GitHub Actions 自动化归档与发布。
  - 支持按页缩略图绘制、幻灯片跳转滚动以及矢量 PDF / PNG 导出能力。
  - 引入空间索引与文本选择模型（`DocumentTextLayout`），支持鼠标拖拽选区、连续多击选词/选行、光标适配与快捷键复制（⌘C）。
- **三端全文检索与搜索组件（`core` / `viewer` / `viewer-macos` / `viewer-ohos`）**：
  - Rust 核心下沉跨平台全文检索协议，支持 DOCX、PPTX、XLSX 跨 run 文本匹配与 UTF-16 偏移精确计算。
  - Android、macOS 与 HarmonyOS NEXT 三端支持检索关键词高亮绘制、命中项视口居中平滑滚动以及开箱即用的搜索交互栏组件。
  - 优化 XLSX 表格全量检索命中绘制性能，避免高亮覆盖冻结表头与跨合并单元格错位。

### DOCX 排版与特性

- **编号与多级列表**：解析 `numbering.xml` 自动编号与多级列表，正确继承外层占位符引用及数字格式。
- **单元格合并**：支持表格横向跨列（`gridSpan`）与纵向跨行（`vMerge`）合并，完善缺列闭合与覆盖单元格边界处理。
- **排版对齐与缩进**：支持字符单位段落缩进（`leftChars` / `firstLineChars`）与三端两端对齐（justified）拉伸排版。
- **主题字体解析**：支持从 `word/theme/theme1.xml` 解析 EastAsia 主题字体，优先匹配中文字体避免日文字体抢占。

### 渲染与修复

- **DOCX 属性与符号修复**：修复段落标记 `rPr` 泄漏至所有 run 以及隐藏段尾符致整段消失的问题；修复带 bullet 段落搜索高亮重复累加偏移的问题。
- **HarmonyOS 端检索交互**：修复检索命中样式在列表复用后不刷新、关键词变更后高亮未刷新以及 bullet 匹配渲染问题。
- **macOS 端坐标与选区**：修复 DOCX 检索高亮坐标转换、段尾两端对齐及表格文本框选问题。

### 工程与文档

- 升级 Android 构建插件至 9.5.1。
- 将 Android 无障碍设备测试移出常规 Push/PR CI，转为独立按需手动触发工作流。
- 新增英文版 `README.en.md` 并提供中英文互链。

## 0.10.0

发布页面：[v0.10.0 Release](https://github.com/donglua/JZOfficeViewer/releases/tag/v0.10.0)。

本版本主要新增 `OfficeMetadata`、`OfficeThumbnail`、`OfficeSheetTabs` 三个标准组件，并升级双端手势缩放越界回弹与鸿蒙 PPTX 统一矢量视口。

### 手势与视口

- **缩放越界抵抗与回弹**：双端引入橡胶带（rubber-band）阻尼，双指捏合越界后按抵抗曲线让步，松手以 220 ms 减速动画回弹到边界（1.0x/4.0x，表格为 0.5x/4.0x）；双击与读屏无障碍缩放动作同样采用该补间。
- **鸿蒙 PPTX 统一 2D 矢量视口**：改用单层全屏 Canvas，支持全向拖拽、`displaySync` 驱动的惯性抛掷、焦点双指缩放与双击补间缩放，缩放直接作用于绘图矩阵保持矢量清晰，并加入视口裁剪与页码胶囊。

### 组件化与标准包装

- **无头元数据读取（`OfficeMetadata`）**：Android 与 HarmonyOS NEXT 双端提供无头文档元数据快速读取接口（`OfficeMetadata.read` / `readAsync` 与 `readOfficeMetadata`），支持在不初始化 UI 视图的情况下快速获取文档格式（DOCX / PPTX / XLSX）、页数、宽高尺寸、工作表名称列表及告警信息。
- **离屏封面/缩略图生成（`OfficeThumbnail`）**：Android 端提供 `OfficeThumbnail.decode` / `load` API，鸿蒙端提供 `renderOfficeThumbnail(filePath, maxWidth, maxHeight)`，支持双端脱离 UI 视图离屏渲染文档首页面（PPTX 幻灯片、DOCX 首屏、XLSX 工作表）为指定最大边界的 `Bitmap` / `PixelMap`，带严格的内存预算与资源自动释放机制。
- **多工作表切换标准组件（`OfficeSheetTabs`）**：
  - Android 沉淀 `cn.jingzhuan.lib.office.widget.OfficeSheetTabs` 组件，支持 `attachTo(OfficePreviewView)` 自动联动绑定及窗口重挂载恢复，Demo 模块已完成解耦接入并移除旧私有类。
  - 鸿蒙端导出声明式 `@Component OfficeSheetTabs`，支持仅传入 `controller` 自动订阅工作表列表与激活页码联动（非 XLSX 自动隐藏），并接入 `demo-ohos` 演示工程。
- **双端多监听器扩展**：Android `OfficePreviewView` 与鸿蒙 `OfficePreviewController` 均新增 `addOnPageChangeListener` 与 `removeOnPageChangeListener`，支持与外部扩展组件解耦联动。

## 0.9.0

发布页面：[v0.9.0 Release](https://github.com/donglua/JZOfficeViewer/releases/tag/v0.9.0)。

本版本主要更新 PPTX 垂直簇状柱状图渲染、DOCX 随内容滚动页眉页脚、XLSX 表格几何预计算下沉至 Rust Core、鸿蒙原生自动化构建及双端排版与无障碍细节修复。

### 特性与排版

- **PPTX 垂直簇状柱状图**：DrawingML 图表管线新增支持垂直柱状图（`<c:barChart>`，`barDir="col"`，簇状并列 `grouping="clustered"`），数值轴自动吸附 0 基准线（支持正负值双向延伸），槽位等宽划分并绘制柱体与色块图例；内置演示样例 `sample.pptx` 图表章节同步更新为柱状图演示页。
- **DOCX 页眉页脚支持**：解析 `sectPr` 节属性中的 `headerReference` / `footerReference` 与 `pgMar` 页边距，Android 与 HarmonyOS NEXT 双端将页眉置于文档流首部、页脚追加至尾部随内容平滑滚动，并支持页眉页脚内独立图片 relationships 映射与多节文档继承逻辑。
- **鸿蒙 hvigor 自动化增量构建**：`viewer-ohos/hvigorfile.ts` 注册 `BuildRustNative` 增量任务，在 DevEco Studio 编译或运行 HAR 前自动增量编译 Rust 原生库并同步 `.so` 与 `index.d.ts`。

### 架构与性能

- **XLSX 几何计算下沉至 Rust Core**：表格的列宽偏移、行高偏移、可见索引、起始行与合并单元格矩形（`SheetGeometry`）在 Rust core 中一次性预计算，双端直接消费预计算数据，消除平台层 250+ 行重复计算逻辑，保证双端排版绝对一致。
- **Android geometry 解码消除装箱**：Java 端 geometry 数组解码改用基本类型数组（`float[]` / `int[]`），消除大表格几何反序列化时的对象装箱开销与 GC 压力。
- **鸿蒙端合并单元格空间分桶优化**：合并单元格改用自身行范围注册到分桶索引，降低密集大表格滚动遍历开销。

### 修复

- **DOCX 正文可用宽度与间距对齐**：正文可用宽度按 `pgMar` 边距精算，对齐双端页眉页脚与正文的内容边距。
- **XLSX 几何边界校验**：严格校验 core 下发的 `sheet.geometry` 数组边界与长度，拦截异常损坏文件。
- **Android 视口滚动与无障碍体验**：无障碍滚动步进驱动优化，修复极端缩放时视口滚动边界裁剪溢出。

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
