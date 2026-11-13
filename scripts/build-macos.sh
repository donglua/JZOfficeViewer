#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MACOS_DIR="${ROOT_DIR}/viewer-macos"
LIBS_DIR="${MACOS_DIR}/libs"
BUILD_OUT_DIR="${MACOS_DIR}/build"
HEADERS_DIR="${MACOS_DIR}/Headers"
XCFRAMEWORK_DIR="${LIBS_DIR}/CJZOffice.xcframework"
XCFRAMEWORK_ZIP="${BUILD_OUT_DIR}/CJZOffice.xcframework.zip"

export PATH="${HOME}/.cargo/bin:${PATH}"

UNIVERSAL=0
if [[ "${1:-}" == "--universal" || "${1:-}" == "--xcframework" || "${CI:-}" == "true" ]]; then
    UNIVERSAL=1
fi

mkdir -p "${LIBS_DIR}" "${BUILD_OUT_DIR}"

shrink_staticlib() {
    local arch="$1"
    local input_a="$2"
    local output_a="$3"
    local tmp_o="${BUILD_OUT_DIR}/jz_office_${arch}.o"
    xcrun ld -r -S -x -arch "${arch}" -platform_version macos 14.0.0 14.0.0 \
        -exported_symbol _jz_office_parse_path \
        -exported_symbol _jz_office_parse_first_viewport \
        -exported_symbol _jz_office_metadata_path \
        -exported_symbol _jz_office_prewarm_search_index \
        -exported_symbol _jz_office_search_path \
        -exported_symbol _jz_office_read_part \
        -exported_symbol _jz_office_evict_cache \
        -exported_symbol _jz_office_clear_cache \
        -exported_symbol _jz_office_free_string \
        -exported_symbol _jz_office_free_bytes \
        "${input_a}" \
        -o "${tmp_o}"
    xcrun libtool -static -o "${output_a}" "${tmp_o}"
    rm -f "${tmp_o}"
}

cd "${ROOT_DIR}"
INSTALLED_TARGETS="$(rustup target list --installed 2>/dev/null || true)"
if [[ "${UNIVERSAL}" -eq 1 ]]; then
    if ! grep -q "^aarch64-apple-darwin$" <<<"${INSTALLED_TARGETS}"; then
        rustup target add aarch64-apple-darwin
    fi
    if ! grep -q "^x86_64-apple-darwin$" <<<"${INSTALLED_TARGETS}"; then
        rustup target add x86_64-apple-darwin
    fi
    INSTALLED_TARGETS="$(rustup target list --installed 2>/dev/null || true)"
fi

if grep -q "^aarch64-apple-darwin$" <<<"${INSTALLED_TARGETS}" && grep -q "^x86_64-apple-darwin$" <<<"${INSTALLED_TARGETS}"; then
    echo "==> [1/4] Building universal jz-office-macos static library (arm64 + x86_64)..."
    cargo build --release -p jz-office-macos --target aarch64-apple-darwin --target x86_64-apple-darwin
    shrink_staticlib arm64 \
        "${ROOT_DIR}/target/aarch64-apple-darwin/release/libjz_office_macos.a" \
        "${BUILD_OUT_DIR}/libjz_office_arm64.a"
    shrink_staticlib x86_64 \
        "${ROOT_DIR}/target/x86_64-apple-darwin/release/libjz_office_macos.a" \
        "${BUILD_OUT_DIR}/libjz_office_x86_64.a"
    lipo -create \
        "${BUILD_OUT_DIR}/libjz_office_arm64.a" \
        "${BUILD_OUT_DIR}/libjz_office_x86_64.a" \
        -output "${LIBS_DIR}/libjz_office_macos.a"
    rm -f "${BUILD_OUT_DIR}/libjz_office_arm64.a" "${BUILD_OUT_DIR}/libjz_office_x86_64.a"
    SLICE_ID="macos-arm64_x86_64"
    ARCH_ARRAY_XML="<string>arm64</string><string>x86_64</string>"
else
    echo "==> [1/4] Building host jz-office-macos static library..."
    cargo build --release -p jz-office-macos
    HOST_ARCH="$(uname -m)"
    shrink_staticlib "${HOST_ARCH}" \
        "${ROOT_DIR}/target/release/libjz_office_macos.a" \
        "${LIBS_DIR}/libjz_office_macos.a"
    SLICE_ID="macos-${HOST_ARCH}"
    ARCH_ARRAY_XML="<string>${HOST_ARCH}</string>"
fi

echo "==> [2/4] Packaging CJZOffice.xcframework..."
rm -rf "${XCFRAMEWORK_DIR}" "${XCFRAMEWORK_ZIP}"
if xcodebuild -version >/dev/null 2>&1; then
    xcodebuild -create-xcframework \
        -library "${LIBS_DIR}/libjz_office_macos.a" \
        -headers "${HEADERS_DIR}" \
        -output "${XCFRAMEWORK_DIR}"
else
    mkdir -p "${XCFRAMEWORK_DIR}/${SLICE_ID}/Headers"
    cp -f "${LIBS_DIR}/libjz_office_macos.a" "${XCFRAMEWORK_DIR}/${SLICE_ID}/libjz_office_macos.a"
    cp -f "${HEADERS_DIR}/jz_office.h" "${XCFRAMEWORK_DIR}/${SLICE_ID}/Headers/jz_office.h"
    cp -f "${HEADERS_DIR}/module.modulemap" "${XCFRAMEWORK_DIR}/${SLICE_ID}/Headers/module.modulemap"
    cat > "${XCFRAMEWORK_DIR}/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>AvailableLibraries</key>
	<array>
		<dict>
			<key>BinaryPath</key>
			<string>libjz_office_macos.a</string>
			<key>HeadersPath</key>
			<string>Headers</string>
			<key>LibraryIdentifier</key>
			<string>${SLICE_ID}</string>
			<key>LibraryPath</key>
			<string>libjz_office_macos.a</string>
			<key>SupportedArchitectures</key>
			<array>
				${ARCH_ARRAY_XML}
			</array>
			<key>SupportedPlatform</key>
			<string>macos</string>
		</dict>
	</array>
	<key>CFBundlePackageType</key>
	<string>XFWK</string>
	<key>XCFrameworkFormatVersion</key>
	<string>1.0</string>
</dict>
</plist>
EOF
fi

(
    cd "${LIBS_DIR}"
    zip -qry "${XCFRAMEWORK_ZIP}" "CJZOffice.xcframework"
)
CHECKSUM="$(shasum -a 256 "${XCFRAMEWORK_ZIP}" | awk '{print $1}')"
ZIP_SIZE="$(du -h "${XCFRAMEWORK_ZIP}" | awk '{print $1}')"
echo "    Created ${XCFRAMEWORK_ZIP} (${ZIP_SIZE}, sha256=${CHECKSUM})"

echo "==> [3/4] Ensuring showcase fixtures exist..."
if [[ ! -f "${ROOT_DIR}/demo/src/main/assets/samples/sample.docx" ]]; then
    cargo run -p jz-office-core --example fixtures
fi

echo "==> [4/4] Building and testing Swift Package (viewer-macos)..."
cd "${MACOS_DIR}"
CLT_TESTING_PLUGIN="/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
if [[ -f "${CLT_TESTING_PLUGIN}" ]]; then
    swift test --enable-swift-testing --disable-xctest \
        -Xswiftc -load-plugin-library -Xswiftc "${CLT_TESTING_PLUGIN}"
else
    swift test --enable-swift-testing --disable-xctest
fi
swift build

echo "==> macOS build, XCFramework packaging, and tests succeeded!"
