#!/usr/bin/env bash
set -euo pipefail

native_output="$1"
shift
if [[ -d "${HOME}/.cargo/bin" ]] && [[ ":${PATH}:" != *":${HOME}/.cargo/bin:"* ]]; then
    export PATH="${HOME}/.cargo/bin:${PATH}"
fi

for tool in rustup cargo; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "Missing $tool. Install Rust 1.87 or newer with rustup (https://rustup.rs), and add its bin directory to PATH." >&2
        exit 1
    fi
done
: "${ANDROID_NDK_HOME:?Set ANDROID_NDK_HOME to an installed NDK 28 or newer}"
case "$(uname -s)" in
    Darwin) host_tag=darwin-x86_64 ;;
    Linux) host_tag=linux-x86_64 ;;
    *) echo 'This build script supports macOS and Linux.' >&2; exit 1 ;;
esac
toolchain="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/$host_tag/bin"
export CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER="$toolchain/aarch64-linux-android23-clang"
export CARGO_TARGET_X86_64_LINUX_ANDROID_LINKER="$toolchain/x86_64-linux-android23-clang"
export CARGO_TARGET_ARMV7_LINUX_ANDROIDEABI_LINKER="$toolchain/armv7a-linux-androideabi23-clang"
export RUSTFLAGS="${RUSTFLAGS:-} -C link-arg=-Wl,-z,max-page-size=16384"
installed_targets="$(rustup target list --installed)"
cargo_args=(build --locked --release -p jz-office-android)
if [[ "${OFFICE_OFFLINE:-false}" == true ]]; then
    cargo_args+=(--offline)
fi
for abi in "$@"; do
    case "$abi" in
        arm64-v8a) rust_target=aarch64-linux-android ;;
        x86_64) rust_target=x86_64-linux-android ;;
        armeabi-v7a) rust_target=armv7-linux-androideabi ;;
        *) echo "Unsupported ABI: $abi" >&2; exit 1 ;;
    esac
    if ! printf '%s\n' "$installed_targets" | grep -Fxq "$rust_target"; then
        if [[ "${OFFICE_OFFLINE:-false}" == true ]]; then
            echo "Missing Rust target $rust_target. Run Gradle without --offline once to install it." >&2
            exit 1
        fi
        echo "Installing missing Rust target: $rust_target"
        rustup target add "$rust_target"
    fi
    cargo "${cargo_args[@]}" --target "$rust_target"
    mkdir -p "$native_output/$abi"
    cp "target/$rust_target/release/libjz_office.so" "$native_output/$abi/"
done
