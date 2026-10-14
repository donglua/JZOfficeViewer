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
ohrs build --release

echo "==> [2/4] Syncing .so libraries to viewer-ohos/libs..."
mkdir -p "${HAR_DIR}/libs/arm64-v8a" "${HAR_DIR}/libs/x86_64" "${HAR_DIR}/libs/armeabi-v7a"
cp -f "${NATIVE_DIR}/dist/arm64-v8a/libjz_office_ohos.so" "${HAR_DIR}/libs/arm64-v8a/"
cp -f "${NATIVE_DIR}/dist/x86_64/libjz_office_ohos.so" "${HAR_DIR}/libs/x86_64/"
if [[ -f "${NATIVE_DIR}/dist/armeabi-v7a/libjz_office_ohos.so" ]]; then
    cp -f "${NATIVE_DIR}/dist/armeabi-v7a/libjz_office_ohos.so" "${HAR_DIR}/libs/armeabi-v7a/"
fi

echo "==> [3/4] Syncing index.d.ts to viewer-ohos types..."
TYPES_DIR="${HAR_DIR}/src/main/cpp/types/libjz_office_ohos"
mkdir -p "${TYPES_DIR}"
cp -f "${NATIVE_DIR}/dist/index.d.ts" "${TYPES_DIR}/index.d.ts"

echo "==> [4/4] Generating showcase fixtures to demo-ohos rawfile..."
cd "${ROOT_DIR}"
mkdir -p "${DEMO_RAWFILE_DIR}"
cargo run -p jz-office-core --example fixtures -- "${DEMO_RAWFILE_DIR}"

HVIGORW="${DEVECO_HVIGOR:-/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw}"
if [[ -x "${HVIGORW}" ]]; then
    export NODE_HOME="${NODE_HOME:-/Applications/DevEco-Studio.app/Contents/tools/node}"
    "${HVIGORW}" --mode module -p module=viewer_ohos assembleHar
fi

echo "==> Done!"
