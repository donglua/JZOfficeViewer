# AGENT.md

面向 AI 编码代理与项目维护者的仓库工程手册。面向接入方的使用文档见 [README](README.md)，版本历史见 [CHANGELOG](CHANGELOG.md)。

## 1. 项目概览

JZOfficeViewer：轻量、离线、只读的 DOCX / PPTX / XLSX 预览库。Rust 核心负责解析与安全边界校验，平台层（Android 与 HarmonyOS NEXT）负责排版、绘制与手势交互。

| 目录 | 语言 | 职责 |
| --- | --- | --- |
| `core/` | Rust | `jz-office-core`：ZIP/OOXML 校验与解析、样式与几何预计算、`package_cache` 句柄缓存，输出平台无关文档模型（`core/src/model.rs`） |
| `viewer/` | Java | Android AAR：`OfficePreviewView`、文字排版、Canvas 绘制、图片 LRU 缓存 |
| `viewer/native/` | Rust | `jz-office-android`：JNI 桥接，调用 `core::parse_path_to_json` 生成 `libjz_office.so` |
| `viewer-online/` | Java | 可选 Android AAR：HTTP/HTTPS 下载、重定向安全策略、取消与缓存清理 |
| `demo/` | Java | Android 演示应用，综合样例位于 `demo/src/main/assets/samples/` |
| `viewer-ohos/` | ArkTS | HarmonyOS NEXT HAR（`@jzdy/office`）：流式 DOCX、PPTX Canvas、XLSX 表格视图及手势控制 |
| `viewer-ohos/native/` | Rust | `jz-office-ohos`：`napi-ohos` 桥接，生成 `libjz_office_ohos.so` |
| `demo-ohos/` | ArkTS | 鸿蒙演示应用，样例位于 `demo-ohos/src/main/resources/rawfile/` |
| `scripts/` | Shell/Python/Java | `build-native.sh`、`build-ohos.sh`、`publish-ohpm.py` 及纯 JVM 检查用例（`scripts/tests/`） |

Cargo workspace 成员：`core`、`viewer/native`、`viewer-ohos/native`（根 `Cargo.toml`）。Gradle 管理 `:viewer`、`:viewer-online`、`:demo`；鸿蒙工程由根目录的 DevEco/hvigor 配置（`build-profile.json5`、`AppScope/`、`hvigor/`）管理。

## 2. 架构与实现约束

- **核心层平台无关**：`core` 不得依赖任何平台 API；坐标、尺寸、字号统一使用 `point`。图片以 ZIP 包内路径引用，不将图片字节放入 JSON 模型。
- **单次解析与跨语言协议**：
  - 每份文档只调用一次 `jz_office_core::parse_path_to_json`，输出带 `schemaVersion` 的 JSON 模型；滚动、缩放等高频交互严禁再次跨越 JNI/NAPI。
  - 模型版本：`core/src/model.rs` 中的 `SCHEMA_VERSION`（当前为 `9`）必须与 Android `DocumentDecoder.java` 及鸿蒙 `NativeCore.ets` / `OfficeModel.ets` 的校验值严格同步。
- **几何与排版分工**：
  - Rust 预计算 PPTX 元素的完整绘制变换矩阵（平移、旋转、翻转）、线性渐变端点及背景渐变逆矩阵、图片裁剪矩形、表格列宽归一化及超长单元格截断（4096 UTF-16 码元）。
  - 平台层负责结合系统字体完成最终文本测量、折行与 Canvas/组件绘制。
- **图片提取与缓存**：
  - 鸿蒙 NAPI 读图通过 `core::package_cache`（线程安全 LRU + 文件修改感知）复用 ZIP 中央目录与句柄，流式读取并累计跟踪整包 256 MiB 解压预算（`MAX_EXPANDED`），页面退出时通过 `clear_cache` 释放。
  - Android 端通过 `OfficePackage` 与 `OfficeImages` 维护 800 万像素预算（约 30.5 MiB）的 Bitmap LRU 缓存，优先保障当前可见页分辨率。
- **体积与依赖红线**：
  - 不内置字体、不引入第三方重型网络库或渲染引擎；`viewer` 不声明网络权限。
  - Android 核心 AAR 与鸿蒙 HAR（仅保留 64 位架构 `arm64-v8a` / `x86_64`，排除 native 编译缓存与重复归档）目标体积均控制在 1 MB 左右。
  - 不支持旧版 `.doc/.ppt/.xls`、加密文档、宏和编辑功能，不要扩展这些范围。

## 3. 代码规范

- **Rust**：workspace lints 拒绝 `unwrap`/`expect`、无注释的 `unsafe` 块和未处理的 `must_use`；原生入口必须用 `catch_unwind` 拦截 panic 并转为错误返回。提交前必须通过 `cargo fmt`、`cargo clippy` 和 `cargo test`。
- **Android (Java)**：兼容 `--release 11` 纯 JVM 编译检查（`SheetLayout`、`OfficeCache`、`RemoteOfficeDownloader` 等核心逻辑类不得引入 Android 专属 API）。UI 接口在主线程调用，I/O、解析与解码在后台工作线程执行。
- **HarmonyOS (ArkTS)**：大型文档模型以普通属性传递，避免 `@Prop` 触发深拷贝；高频手势偏移量避免触发整树脏检查；文档解析与图片读取必须使用异步接口（`parseDocumentAsync` / `readZipPartAsync`）。
- **语言与提交规范**：
  - 注释与文档统一使用中文；保留与改动无关的已有注释。
  - 提交信息遵循 Conventional Commits，例如 `feat(viewer-ohos): ...`、`fix(core): ...`、`perf(xlsx): ...`。

## 4. 构建与验证命令

### 4.1 Rust 核心与样例生成

```sh
# 格式、静态检查与全量测试（CI 必跑）
cargo fmt --all -- --check
cargo clippy --workspace --all-targets --locked -- -D warnings
cargo test --workspace --locked

# 生成综合样例（默认输出到 demo/src/main/assets/samples/）及专项测试固件
cargo run -p jz-office-core --example fixtures
cargo run -p jz-office-core --example fixtures -- --tests
```

### 4.2 纯 JVM 快速回归测试（无需连接设备）

使用 JDK 11+ 直接在桌面验证缓存、在线下载器与表格稀疏布局算法：

```sh
# 1. 在线下载器与缓存管理检查（47 项网络与并发缓存检查）
mkdir -p /tmp/jz-office-online-checks
javac --release 11 -d /tmp/jz-office-online-checks \
    viewer/src/main/java/cn/jingzhuan/lib/office/OfficeCache.java \
    viewer-online/src/main/java/cn/jingzhuan/lib/office/online/RemoteOfficeRequest.java \
    viewer-online/src/main/java/cn/jingzhuan/lib/office/online/RemoteOfficeDownloader.java \
    viewer-online/src/main/java/cn/jingzhuan/lib/office/online/HttpUrlConnectionOfficeDownloader.java \
    scripts/tests/OfficeCacheChecks.java scripts/tests/RemoteDownloaderChecks.java
java -cp /tmp/jz-office-online-checks cn.jingzhuan.lib.office.OfficeCacheChecks
java -cp /tmp/jz-office-online-checks RemoteDownloaderChecks

# 2. XLSX 表格布局与合并单元格检查及基准测试
mkdir -p viewer/build/sheet-layout-checks
javac --release 11 -Xlint:all -Werror -d viewer/build/sheet-layout-checks \
    viewer/src/main/java/cn/jingzhuan/lib/office/OfficeDocument.java \
    viewer/src/main/java/cn/jingzhuan/lib/office/SpreadsheetDocument.java \
    viewer/src/main/java/cn/jingzhuan/lib/office/SheetLayout.java \
    viewer/src/androidTest/java/cn/jingzhuan/lib/office/SheetLayoutChecks.java \
    viewer/src/androidTest/java/cn/jingzhuan/lib/office/SheetLayoutBenchmark.java
java -cp viewer/build/sheet-layout-checks cn.jingzhuan.lib.office.SheetLayoutChecks
java -cp viewer/build/sheet-layout-checks cn.jingzhuan.lib.office.SheetLayoutBenchmark
```

### 4.3 Android 构建与设备 Instrumentation 测试

构建需要 JDK 21（已在 `gradle/gradle-daemon-jvm.properties` 固定）、Android SDK 35、NDK `28.2.13676358`：

```sh
# 构建 Release AAR 与 Debug Demo
./gradlew :viewer:assembleRelease :viewer-online:assembleRelease :demo:assembleDebug

# 按需指定 ABI（默认 arm64-v8a,armeabi-v7a）
./gradlew :viewer:assembleRelease -PofficeAbis=arm64-v8a,armeabi-v7a,x86_64

# 构建并安装设备测试 APK
./gradlew :viewer:assembleDebugAndroidTest :viewer-online:assembleDebugAndroidTest
adb install -r viewer/build/outputs/apk/androidTest/debug/viewer-debug-androidTest.apk

# 运行全量或指定专项 suite（输出 ALL ... CHECKS PASSED 表示通过）
adb shell am instrument -w cn.jingzhuan.lib.office.test/cn.jingzhuan.lib.office.OfficeInstrumentation
adb shell am instrument -w -e suite <suite_name> cn.jingzhuan.lib.office.test/cn.jingzhuan.lib.office.OfficeInstrumentation

# 在线模块设备集成测试
adb install -r viewer-online/build/outputs/apk/androidTest/debug/viewer-online-debug-androidTest.apk
adb shell am instrument -w cn.jingzhuan.lib.office.online.test/cn.jingzhuan.lib.office.online.OnlineInstrumentation
```

支持的 `<suite_name>` 列表：
- `compatibility`：XLSX 调色板/tint、PPTX 16 种编号、DOCX 显式字体、三角形/菱形等几何
- `xlsx` / `xlsx-text` / `sheet-layout`：表格渲染、26 万字符超长单元格截断、行列索引与合并区域
- `pptx` / `pptx-geometry` / `backgrounds`：组合变换、折线图、渐变文字、换行对照、背景图与 Display P3 色差容差（±1）
- `images` / `image-cache`：图片按需解码、清晰度升级、LRU 复用与 256 MiB 累计读取限制
- `layout` / `limits`：DOCX 流式排版、页码回调、异常容器与超限拦截
- `demo-samples` / `demo-xlsx`：需先安装 `demo-debug.apk`，验证内置综合样例加载、翻页与无障碍切表

### 4.4 HarmonyOS NEXT 构建

需要 DevEco Studio（含 OpenHarmony SDK/NDK、hvigor、node）与 `ohrs`：

```sh
# 默认构建 arm64-v8a 与 x86_64（如需 32 位可设 OHOS_BUILD_ARM32=1）
./scripts/build-ohos.sh
```

脚本自动完成：`ohrs build --release` -> 拷贝 `.so` 到 `viewer-ohos/libs/` -> 同步 `index.d.ts` -> 生成 `demo-ohos` 的 `rawfile` 综合样例 -> 调用 `hvigorw assembleHar` 生成 HAR 包。

## 5. 发布流程与版本管理

### 5.1 版本号同步清单

发布新版本前，必须同步修改以下所有位置的版本号：
1. `Cargo.toml`：`[workspace.package] version`（并运行 `cargo check` 更新 `Cargo.lock`）
2. `build.gradle`：`publishedVersion` 默认值
3. `demo/build.gradle`：递增 `versionCode`
4. `AppScope/app.json5`：更新 `versionName` 与 `versionCode`（如 `0.5.0` 对应 `500`）
5. `oh-package.json5`、`viewer-ohos/oh-package.json5`、`demo-ohos/oh-package.json5`、`viewer-ohos/src/main/cpp/types/libjz_office_ohos/oh-package.json5` 及其对应的 `oh-package-lock.json5`
6. `README.md`、`viewer-ohos/README.md`、`CHANGELOG.md`、`viewer-ohos/CHANGELOG.md`

### 5.2 自动化发布（GitHub Actions）

1. **本地预检**：运行 `cargo fmt --all -- --check`、`cargo clippy`、`cargo test` 及 `./gradlew :prepareRelease`（在 `build/release-repository/` 本地生成并校验双模块 AAR、POM 与元数据）。
2. **打标与创建 Release**：
   - 提交版本变更：`chore(release): prepare X.Y.Z publication`
   - 推送带 `v` 前缀的标签（如 `v0.5.0`），并创建正式 GitHub Release（非 draft / prerelease）。
3. **CI 自动触发**：
   - **[Publish libraries to Sonatype Central](.github/workflows/publish-sonatype.yml)**：在 `maven-central` 环境下运行 Rust/JVM 检查，签名并上传 `viewer` 和 `viewer-online` 至 Maven Central Portal，同时将两个 AAR 上传至 GitHub Release Assets。
     - 依赖 Secrets：`SONATYPE_USERNAME`、`SONATYPE_PASSWORD`、`SIGNING_KEY`、`SIGNING_PASSWORD` 及 POM 相关 Variables。
   - **[Publish HAR to OHPM](.github/workflows/publish-ohpm.yml)**：交叉编译鸿蒙原生库，打包 `jzdy-office-<version>.har`，通过 `scripts/publish-ohpm.py` 发布至 OpenHarmony 三方库中心仓，并将 HAR 上传至 GitHub Release Assets。
     - 依赖 Secrets：`OHPM_PUBLISH_ID`、`OHPM_KEY`（及可选 `OHPM_PASSPHRASE`）。
   - 若 CI 因网络波动失败，修复后可在 GitHub Actions 页面通过 `workflow_dispatch` 手动填入版本号重试。

## 6. 其他注意事项

- **禁止提交构建产物**：`build/`、`target/`、`dist/`、`*.so`、`viewer-ohos/libs/`、`oh_modules/`、`local.properties`、`VERIFICATION.md` 均已在 `.gitignore` 中忽略。
- **签名隔离**：根目录 `build-profile.json5` 必须保持 `"signingConfigs": []`，切勿提交本地真机调试自动生成的个人证书路径与密码。
