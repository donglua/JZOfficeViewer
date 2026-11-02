#!/usr/bin/env bash
# 编译 Rust 原生库并同步到 viewer-ohos（.so 与 index.d.ts）。
# 既可手动执行，也由 viewer-ohos/hvigorfile.ts 在每次构建前自动调用（cargo 增量编译，无改动时很快）。
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NATIVE_DIR="${ROOT_DIR}/viewer-ohos/native"
HAR_DIR="${ROOT_DIR}/viewer-ohos"

export OHOS_NDK_HOME="${OHOS_NDK_HOME:-/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony}"
export PATH="${HOME}/.cargo/bin:${PATH}"

echo "==> Building jz-office-ohos via ohrs..."
cd "${NATIVE_DIR}"
ARCH_ARGS=(-a arm64 -a x64)
if [[ "${OHOS_BUILD_ARM32:-0}" == "1" ]]; then
    ARCH_ARGS+=(-a arm)
fi
ohrs build --release "${ARCH_ARGS[@]}"

sync_so() {
    local abi="$1"
    local src="${NATIVE_DIR}/dist/${abi}/libjz_office_ohos.so"
    local dst="${HAR_DIR}/libs/${abi}/libjz_office_ohos.so"
    [[ -f "${src}" ]] || return 0
    mkdir -p "${HAR_DIR}/libs/${abi}"
    if ! cmp -s "${src}" "${dst}"; then
        cp -f "${src}" "${dst}"
        echo "    synced ${abi}"
    fi
}
sync_so arm64-v8a
sync_so x86_64
if [[ "${OHOS_BUILD_ARM32:-0}" == "1" ]]; then
    sync_so armeabi-v7a
fi

TYPES_DIR="${HAR_DIR}/src/main/cpp/types/libjz_office_ohos"
mkdir -p "${TYPES_DIR}"
if ! cmp -s "${NATIVE_DIR}/dist/index.d.ts" "${TYPES_DIR}/index.d.ts"; then
    cp -f "${NATIVE_DIR}/dist/index.d.ts" "${TYPES_DIR}/index.d.ts"
fi
