# 更新日志

## 0.4.0

发布页面：[v0.4.0 Release](https://github.com/donglua/JZOfficeViewer/releases/tag/v0.4.0)。

> **说明**：本版本主要为 **鸿蒙端（HarmonyOS NEXT / `@jzdy/office`）** 的交互体验与渲染性能升级，手势操作与表格渲染机制全面对齐 Android 端；Android 端（`viewer` / `viewer-online`）与 Rust 核心层主要进行版本号同步。

### 鸿蒙端（viewer-ohos）

#### 交互与视口（对齐 Android 端）

- **全局视口手势控制**：支持 PPTX 与 DOCX 全局视口双指捏合缩放（1.0x~4.0x，跟随触摸中心锚点对齐）与双击快速切换缩放（1.0x <-> 2.0x）。
- **视口平移与边界限制**：支持缩放状态下的二维平移拖拽，具备边界阻尼限制，并为各视口容器补充硬件裁剪（`.clip(true)`），解决内容放大溢出遮挡外部界面问题。

#### 渲染与性能

- **DOCX 内嵌图片异步提取与填充**：`DocxFlowView` 接入 `ImageStore` 统一管理生命周期与内存释放，通过 `DocxImageView` 异步解压并解码 ZIP 内嵌图片为 PixelMap；支持 `ImageFit.Fill`，让 1x1 等纯色/矢量拉伸图元按文档声明尺寸等比渲染，并增加最大视口宽度约束防止大图溢出。
- **XLSX 表格流畅度与性能优化**：
  - 采用轴前缀和（`SheetAxis`）与稀疏行索引二分查找视口可见单元格，消除全表 O(N) 冗余遍历。
  - 使用 `Uint8Array` 紧凑记录合并单元格从属，消除滑动过程中的高频临时字符串分配与垃圾回收 (GC) 抖动。
  - 引入 Fling 物理惯性滑动仿真，大幅提升电子表格触控滑动的跟手性与丝滑度。
  - 优化网格线、合并单元格、边框及表头的可见区间裁剪，减少无效重绘。

### 工程与 CI

- **OHPM 发布脚本加固**：`publish-ohpm.py` 禁用终端 PTY ECHO，防止密钥口令回显；增加 300 秒发布超时机制与 master 文件描述符释放保障。

## 0.3.1

发布页面：[v0.3.1 Release](https://github.com/donglua/JZOfficeViewer/releases/tag/v0.3.1)。

### 修复与显示

- **PPTX 背景图支持**：解析幻灯片、版式和母版中的 `blipFill` 图片背景，输出全幅 IMAGE 元素供平台层绘制。
- **鸿蒙端图片渲染**：`viewer-ohos` 新增 `ImageStore` 异步图片缓存与解码机制，修复 PPTX 内嵌图片与背景图缺失问题。

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
