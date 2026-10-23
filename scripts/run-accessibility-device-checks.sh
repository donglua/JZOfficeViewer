#!/usr/bin/env bash
# Runs the accessibility instrumentation suite on a connected device or emulator.
#
#   scripts/run-accessibility-device-checks.sh [serial]
#
# Build the APK first: ./gradlew :viewer:assembleDebugAndroidTest
#
# Environment:
#   OFFICE_TEST_APK       androidTest APK path (default: debug variant output)
#   OFFICE_CHECK_OUTPUT   instrumentation log path (default: build/device-checks/accessibility.log)
#   OFFICE_ALLOW_SKIP     set to 1 to accept the SKIP of the announcement probe
#                         (vendor ROMs that strip the probe service from
#                         enabled_accessibility_services); CI keeps it strict.
set -euo pipefail

apk="${OFFICE_TEST_APK:-viewer/build/outputs/apk/androidTest/debug/viewer-debug-androidTest.apk}"
log="${OFFICE_CHECK_OUTPUT:-build/device-checks/accessibility.log}"
serial="${1:-}"

adb_args=()
if [[ -n "$serial" ]]; then
    adb_args+=(-s "$serial")
fi

if ! command -v adb >/dev/null 2>&1; then
    echo "Missing adb. Install Android platform-tools and add them to PATH." >&2
    exit 1
fi
if [[ ! -f "$apk" ]]; then
    echo "Missing test APK: $apk" >&2
    echo "Run ./gradlew :viewer:assembleDebugAndroidTest first." >&2
    exit 1
fi

device_state="$(adb "${adb_args[@]}" get-state 2>/dev/null || true)"
if [[ "$device_state" != device ]]; then
    echo "No single device in state 'device'${serial:+ for serial $serial}." >&2
    adb devices >&2
    exit 1
fi

mkdir -p "$(dirname "$log")"
adb "${adb_args[@]}" install -r -t "$apk" >/dev/null
echo "Running accessibility suite; log: $log"
adb "${adb_args[@]}" shell am instrument -w -e suite accessibility \
    cn.jingzhuan.lib.office.test/cn.jingzhuan.lib.office.OfficeInstrumentation | tee "$log"

failed=0
if ! grep -q 'ALL ACCESSIBILITY CHECKS PASSED' "$log"; then
    echo "Accessibility suite did not report 'ALL ACCESSIBILITY CHECKS PASSED'." >&2
    failed=1
fi
if grep -q 'FAILED:' "$log"; then
    echo "Accessibility suite reported a failure." >&2
    failed=1
fi
if grep -q '^SKIP' "$log"; then
    if [[ "${OFFICE_ALLOW_SKIP:-0}" == 1 ]]; then
        echo "Announcement probe skipped; accepted because OFFICE_ALLOW_SKIP=1." >&2
    else
        echo "Announcement probe skipped: the device refused to enable the probe" >&2
        echo "accessibility service, so announcement delivery was not verified." >&2
        failed=1
    fi
fi

if [[ "$failed" != 0 ]]; then
    exit 1
fi
echo "Accessibility device checks passed."
