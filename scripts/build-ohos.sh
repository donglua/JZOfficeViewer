#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NATIVE_DIR="${ROOT_DIR}/viewer-ohos/native"
HAR_DIR="${ROOT_DIR}/viewer-ohos"
DEMO_RAWFILE_DIR="${ROOT_DIR}/demo-ohos/src/main/resources/rawfile"

export OHOS_NDK_HOME="${OHOS_NDK_HOME:-/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony}"
export PATH="${HOME}/.cargo/bin:${PATH}"

echo "==> [1/3] Building native library and syncing .so / index.d.ts..."
"${ROOT_DIR}/scripts/build-ohos-native.sh"

echo "==> [2/3] Syncing docs..."
cp -f "${ROOT_DIR}/LICENSE" "${HAR_DIR}/LICENSE"
if [[ ! -f "${HAR_DIR}/README.md" && -f "${ROOT_DIR}/README.md" ]]; then
    cp -f "${ROOT_DIR}/README.md" "${HAR_DIR}/README.md"
fi
if [[ ! -f "${HAR_DIR}/CHANGELOG.md" && -f "${ROOT_DIR}/CHANGELOG.md" ]]; then
    cp -f "${ROOT_DIR}/CHANGELOG.md" "${HAR_DIR}/CHANGELOG.md"
    cp -f "${ROOT_DIR}/CHANGELOG.md" "${HAR_DIR}/changelog.md"
fi

echo "==> [3/3] Generating showcase fixtures to demo-ohos rawfile..."
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
