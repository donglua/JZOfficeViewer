#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NATIVE_DIR="${ROOT_DIR}/viewer-ohos/native"
HAR_DIR="${ROOT_DIR}/viewer-ohos"
DEMO_RAWFILE_DIR="${ROOT_DIR}/demo-ohos/src/main/resources/rawfile"

export OHOS_NDK_HOME="${OHOS_NDK_HOME:-/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony}"
export PATH="${HOME}/.cargo/bin:${PATH}"

echo "==> [1/4] Building jz-office-ohos via ohrs..."
cd "${NATIVE_DIR}"
ARCH_ARGS=(-a arm64 -a x64)
if [[ "${OHOS_BUILD_ARM32:-0}" == "1" ]]; then
    ARCH_ARGS+=(-a arm)
fi
ohrs build --release "${ARCH_ARGS[@]}"

echo "==> [2/4] Syncing .so libraries to viewer-ohos/libs..."
rm -rf "${HAR_DIR}/libs"
mkdir -p "${HAR_DIR}/libs/arm64-v8a" "${HAR_DIR}/libs/x86_64"
cp -f "${NATIVE_DIR}/dist/arm64-v8a/libjz_office_ohos.so" "${HAR_DIR}/libs/arm64-v8a/"
cp -f "${NATIVE_DIR}/dist/x86_64/libjz_office_ohos.so" "${HAR_DIR}/libs/x86_64/"
if [[ "${OHOS_BUILD_ARM32:-0}" == "1" && -f "${NATIVE_DIR}/dist/armeabi-v7a/libjz_office_ohos.so" ]]; then
    mkdir -p "${HAR_DIR}/libs/armeabi-v7a"
    cp -f "${NATIVE_DIR}/dist/armeabi-v7a/libjz_office_ohos.so" "${HAR_DIR}/libs/armeabi-v7a/"
fi

echo "==> [3/4] Syncing index.d.ts to viewer-ohos types..."
TYPES_DIR="${HAR_DIR}/src/main/cpp/types/libjz_office_ohos"
mkdir -p "${TYPES_DIR}"
cp -f "${NATIVE_DIR}/dist/index.d.ts" "${TYPES_DIR}/index.d.ts"
cp -f "${ROOT_DIR}/LICENSE" "${HAR_DIR}/LICENSE"
if [[ ! -f "${HAR_DIR}/README.md" && -f "${ROOT_DIR}/README.md" ]]; then
    cp -f "${ROOT_DIR}/README.md" "${HAR_DIR}/README.md"
fi
if [[ ! -f "${HAR_DIR}/CHANGELOG.md" && -f "${ROOT_DIR}/CHANGELOG.md" ]]; then
    cp -f "${ROOT_DIR}/CHANGELOG.md" "${HAR_DIR}/CHANGELOG.md"
    cp -f "${ROOT_DIR}/CHANGELOG.md" "${HAR_DIR}/changelog.md"
fi

echo "==> [4/4] Generating showcase fixtures to demo-ohos rawfile..."
cd "${ROOT_DIR}"
mkdir -p "${DEMO_RAWFILE_DIR}"
cargo run -p jz-office-core --example fixtures -- "${DEMO_RAWFILE_DIR}"

if command -v hvigorw >/dev/null 2>&1; then
    HVIGORW="hvigorw"
else
    HVIGORW="${DEVECO_HVIGOR:-/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw}"
fi

if command -v "${HVIGORW}" >/dev/null 2>&1 || [[ -x "${HVIGORW}" ]]; then
    if ! command -v node >/dev/null 2>&1; then
        export NODE_HOME="${NODE_HOME:-/Applications/DevEco-Studio.app/Contents/tools/node}"
    fi
    "${HVIGORW}" --mode module -p module=viewer_ohos assembleHar
fi

echo "==> Done!"
