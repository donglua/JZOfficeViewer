#!/usr/bin/env python3
"""Verify that all multi-platform package manifests declare the same SemVer version."""

import argparse
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SEMVER_RE = re.compile(r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$")

TARGETS = [
    ("Cargo.toml", re.compile(r'^\s*version\s*=\s*"([^"]+)"', re.MULTILINE)),
    (
        "build.gradle",
        re.compile(
            r"configuredValue\(\s*'publishedVersion'\s*,\s*'PUBLISHED_VERSION'\s*,\s*'([^']+)'\s*\)"
        ),
    ),
    ("oh-package.json5", re.compile(r'"version"\s*:\s*"([^"]+)"')),
    ("viewer-ohos/oh-package.json5", re.compile(r'"version"\s*:\s*"([^"]+)"')),
    (
        "viewer-ohos/src/main/cpp/types/libjz_office_ohos/oh-package.json5",
        re.compile(r'"version"\s*:\s*"([^"]+)"'),
    ),
    ("demo-ohos/oh-package.json5", re.compile(r'"version"\s*:\s*"([^"]+)"')),
    ("AppScope/app.json5", re.compile(r'"versionName"\s*:\s*"([^"]+)"')),
]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--version",
        dest="expected",
        help="Optional expected version (e.g. 0.5.0 or v0.5.0) to match against",
    )
    args = parser.parse_args()
    expected = args.expected.lstrip("v") if args.expected else None
    if expected is not None and not SEMVER_RE.match(expected):
        print(f"ERROR: invalid expected SemVer version: {args.expected}", file=sys.stderr)
        return 1

    found = {}
    errors = []
    for rel_path, pattern in TARGETS:
        path = ROOT / rel_path
        if not path.is_file():
            errors.append(f"Missing file: {rel_path}")
            continue
        content = path.read_text(encoding="utf-8")
        match = pattern.search(content)
        if not match:
            errors.append(f"Could not extract version from {rel_path}")
            continue
        version = match.group(1)
        if not SEMVER_RE.match(version):
            errors.append(f"{rel_path}: '{version}' is not a valid SemVer (X.Y.Z)")
        found[rel_path] = version

    if errors:
        for err in errors:
            print(f"ERROR: {err}", file=sys.stderr)
        return 1

    unique_versions = sorted(set(found.values()))
    if len(unique_versions) != 1:
        print("ERROR: version mismatch across project manifests:", file=sys.stderr)
        for rel_path, version in found.items():
            print(f"  - {rel_path}: {version}", file=sys.stderr)
        return 1

    actual = unique_versions[0]
    if expected is not None and actual != expected:
        print(
            f"ERROR: manifest version ({actual}) does not match expected release version ({expected})",
            file=sys.stderr,
        )
        return 1

    print(f"PASS version check ({len(found)} manifests aligned at {actual})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
