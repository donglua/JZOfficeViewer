# AGENT.md

面向 AI 编码代理与新贡献者的仓库速查。用户文档见 [README](README.md)，变更记录见 [CHANGELOG](CHANGELOG.md)。

## 项目概览

JZOfficeViewer：轻量、离线、只读的 DOCX / PPTX / XLSX 预览库。Rust 核心负责解析，平台层负责排版与绘制。

| 目录 | 语言 | 职责 |
| --- | --- | --- |
| `core/` | Rust | `jz-office-core`：ZIP/OOXML 校验与解析，输出平台无关文档模型（`core/src/model.rs`） |
| `viewer/` | Java | Android AAR：`OfficePreviewView`、文字排版、Canvas 绘制、图片缓存 |
| `viewer/native/` | Rust | `jz-office-android`：JNI 桥接，生成 `libjz_office.so` |
| `viewer-online/` | Java | 可选 AAR：HTTP 下载、取消、缓存清理 |
| `demo/` | Java | Android 演示应用，样例在 `demo/src/main/assets/samples/` |
| `viewer-ohos/` | ArkTS | 实验性 HarmonyOS NEXT HAR（`@jzdy/office`） |
| `viewer-ohos/native/` | Rust | `jz-office-ohos`：`napi-ohos` 桥接，生成 `libjz_office_ohos.so` |
| `demo-ohos/` | ArkTS | 鸿蒙演示应用，样例在 `resources/rawfile/` |
| `scripts/` | Shell/Java | `build-native.sh`、`build-ohos.sh`、JVM 检查用例 |

Cargo workspace 成员：`core`、`viewer/native`、`viewer-ohos/native`（根 `Cargo.toml`）。Gradle 只包含 `:viewer`、`:viewer-online`、`:demo`；鸿蒙模块由根目录的 DevEco/hvigor 工程（`build-profile.json5`、`AppScope/`、`hvigor/`）管理。

## 架构约束

- `core` 不得依赖任何平台 API；单位统一为 point，图片以 ZIP 包内路径引用，不把图片字节放进模型。
- 每份文档只调用一次原生解析，结果为 JSON 模型；滚动、缩放不应再次进入原生层。
- 模型版本：`core/src/model.rs` 中 `schema_version`（当前 9）必须与 `viewer/.../DocumentDecoder.java` 的校验值同步修改；鸿蒙端 `viewer-ohos/src/main/ets/core/OfficeModel.ets` 的类型也要跟随字段变化。
- 资源上限（文件大小、条目数、XML 节点、PPTX 元素、XLSX 单元格等）集中在 Rust 校验，改动需同步 README「资源限制」。
- 不内置字体、不引入网络库或大型依赖；`viewer` 不声明网络权限。核心 AAR 目标保持在 1 MB 以内。
- 不支持旧版 `.doc/.ppt/.xls`、加密文档和编辑功能，不要顺手扩展这些范围。

## 代码规范

- Rust：workspace lints 拒绝 `unwrap`/`expect`、无注释的 `unsafe` 块和未处理的 `must_use`；原生入口用 `catch_unwind` 把 panic 转成错误。提交前运行 fmt / clippy / test。
- Android：Java 源码兼容 `--release 11` 的纯 JVM 检查（`SheetLayout`、`OfficeCache` 等不依赖 Android 的类不要引入 Android API）。UI 接口在主线程调用，IO/解析/解码在工作线程。
- ArkTS：大型文档模型以普通属性传递，避免 `@Prop` 深拷贝；解析使用 `NativeCore.parseDocumentAsync`，不要在 UI 线程调用同步接口。
- 注释与文档使用中文，与现有风格一致；保留与改动无关的注释。
- 提交信息遵循 Conventional Commits，范围用模块名，描述用中文，例如 `fix(viewer-ohos): 修复 XLSX 表格不显示问题`、`feat(pptx): ...`、`chore(gradle): ...`。

## 常用命令

```sh
# Rust 核心（CI 同款检查）
cargo fmt --all -- --check
cargo test --workspace --locked
cargo clippy --workspace --all-targets --locked -- -D warnings

# 生成综合样例（默认写入 demo 样例目录；可追加输出目录）与专项测试文档
cargo run -p jz-office-core --example fixtures
cargo run -p jz-office-core --example fixtures -- --tests

# Android 构建（需 JDK 21、SDK 35、NDK 28.2.13676358、rustup）
./gradlew :viewer:assembleRelease :viewer-online:assembleRelease :demo:assembleDebug
./gradlew :prepareRelease          # 本地生成并检查发布产物，不上传

# Android 设备测试（输出 ALL ... CHECKS PASSED 为通过）
./gradlew :viewer:assembleDebugAndroidTest
adb install -r viewer/build/outputs/apk/androidTest/debug/viewer-debug-androidTest.apk
adb shell am instrument -w [-e suite <name>] cn.jingzhuan.lib.office.test/cn.jingzhuan.lib.office.OfficeInstrumentation

# HarmonyOS（需 DevEco Studio 与 ohrs）
./scripts/build-ohos.sh
```

可用的 `suite`：`compatibility`、`xlsx`、`xlsx-text`、`sheet-layout`、`demo-xlsx`、`demo-samples`、`layout`、`limits`、`images`、`image-cache`、`pptx`、`pptx-geometry`、`backgrounds`。JVM 检查（缓存、下载器、`SheetLayout`）的 `javac` 命令见 README 与 `.github/workflows/publish-sonatype.yml`。

## 测试样例约定

- 样例生成器为 `core/examples/fixtures.rs`，复用 `core/tests/support/`。Android 测试 APK 打包前会自动生成专项文档到 `viewer/build/generated/test-fixtures/`。
- 新增渲染能力时：在 `core/tests/` 加 Rust 回归，在综合样例中加展示页，在 Android 专项 suite 中加断言；鸿蒙 `rawfile` 样例由 `build-ohos.sh` 重新生成。
- 截图颜色断言允许 RGB 各通道 ±1（Display P3 量化），模型和离屏 Canvas 断言保持精确。

## 注意事项

- 不要提交构建产物：`build/`、`target/`、`dist/`、`*.so`、`viewer-ohos/libs/`、`oh_modules/`、`BuildProfile.ets`、`local.properties`（见 `.gitignore`）。`VERIFICATION.md` 是本地验证记录，已被忽略。
- 根 `build-profile.json5` 默认保持 `"signingConfigs": []`，在 DevEco 中调试时自动生成的个人签名配置勿提交；发布凭据只放在用户级 Gradle 属性、环境变量或 GitHub Secrets。
- 版本号需同时修改：根 `build.gradle` 的默认 `publishedVersion`（Demo `versionName` 由它派生）、`Cargo.toml` workspace 版本，以及鸿蒙的 `oh-package.json5`（根目录、`viewer-ohos`、`demo-ohos`）和 `AppScope/app.json5`。
- `Cargo.toml` 声明 `rust-version = "1.88"`，修改 Rust 工具链要求时同步 README 与 CI 工作流。
- 发布流程：Android 端通过 GitHub 正式 Release 触发 Sonatype Central 发布（`publish-sonatype.yml`）；鸿蒙 HAR 包通过 `publish-ohpm.yml` 自动交叉编译并发布至 OHPM（依赖 Secrets `OHPM_PUBLISH_ID` 与 `OHPM_KEY`）。已发布版本号不可覆盖重用。
- 功能或限制变化时同步更新 README（中文）和 CHANGELOG；未发布的新能力需注明“尚未包含在当前发布包中”。
