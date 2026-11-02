import { harTasks } from '@ohos/hvigor-ohos-plugin';
import { HvigorNode, HvigorPlugin } from '@ohos/hvigor';
import { execFileSync } from 'child_process';
import * as path from 'path';

/**
 * 每次构建（含 demo-ohos 运行/打包）前自动编译 Rust 原生库并同步 .so，
 * 避免 core 改动后因 libs/ 下的旧 .so 未更新而不生效。cargo 为增量编译，无改动时开销很小。
 * 设置环境变量 JZ_SKIP_NATIVE_BUILD=1 可跳过（例如 CI 已预先产出 .so）。
 */
function nativeBuildPlugin(): HvigorPlugin {
  return {
    pluginId: 'jzNativeBuildPlugin',
    apply(node: HvigorNode): void {
      node.registerTask({
        name: 'BuildRustNative',
        run: (): void => {
          if (process.env.JZ_SKIP_NATIVE_BUILD === '1') {
            console.warn('[jz-native] JZ_SKIP_NATIVE_BUILD=1，跳过原生库编译');
            return;
          }
          const script = path.resolve(node.getNodeDir().filePath, '..', 'scripts', 'build-ohos-native.sh');
          try {
            execFileSync('bash', [script], { stdio: 'inherit' });
          } catch (e) {
            throw new Error(`[jz-native] 原生库编译失败，请检查 Rust/ohrs 环境：${e}`);
          }
        },
        postDependencies: ['default@PreBuild']
      });
    }
  };
}

export default {
  system: harTasks,
  plugins: [nativeBuildPlugin()]
}
