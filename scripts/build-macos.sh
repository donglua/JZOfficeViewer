#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MACOS_DIR="${ROOT_DIR}/viewer-macos"
LIBS_DIR="${MACOS_DIR}/libs"

export PATH="${HOME}/.cargo/bin:${PATH}"

echo "==> [1/3] Building jz-office-macos C-ABI static library..."
cd "${ROOT_DIR}"
cargo build --release -p jz-office-macos

mkdir -p "${LIBS_DIR}"
cp -f "${ROOT_DIR}/target/release/libjz_office_macos.a" "${LIBS_DIR}/libjz_office_macos.a"

echo "==> [2/3] Ensuring showcase fixtures exist..."
if [[ ! -f "${ROOT_DIR}/demo/src/main/assets/samples/sample.docx" ]]; then
    cargo run -p jz-office-core --example fixtures
fi

echo "==> [3/3] Building and testing Swift Package (viewer-macos)..."
cd "${MACOS_DIR}"
CLT_TESTING_PLUGIN="/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
if [[ -f "${CLT_TESTING_PLUGIN}" ]]; then
    swift test --enable-swift-testing --disable-xctest \
        -Xswiftc -load-plugin-library -Xswiftc "${CLT_TESTING_PLUGIN}"
else
    swift test --enable-swift-testing --disable-xctest
fi
swift build

echo "==> macOS build and tests succeeded!"
