#!/bin/bash
set -euo pipefail

readonly REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
readonly BUILD_SCRIPT="$REPOSITORY_ROOT/scripts/release/build-and-notarize.sh"
readonly INSTALL_SCRIPT="$REPOSITORY_ROOT/install.sh"

fail() { printf 'release script test failed: %s\n' "$1" >&2; exit 1; }
require_source() { grep -Fq -- "$1" "$2" || fail "missing required source contract: $1"; }

bash -n "$BUILD_SCRIPT"
bash -n "$INSTALL_SCRIPT"
"$REPOSITORY_ROOT/scripts/release/check-contract.sh" >/dev/null

require_source 'readonly ARTIFACT_NAME="$EXECUTABLE_NAME-$VERSION-macos-universal2.zip"' "$BUILD_SCRIPT"
require_source 'xcrun notarytool submit "$archive_path"' "$BUILD_SCRIPT"
require_source '--wait --timeout 30m --output-format json' "$BUILD_SCRIPT"
require_source "sed -E 's/(password|token|secret|credential)" "$BUILD_SCRIPT"
require_source "codesign -vvvv -R='notarized' --check-notarization \"\$universal_binary\"" "$BUILD_SCRIPT"
require_source "PATH='/usr/bin:/bin:/usr/sbin:/sbin'" "$BUILD_SCRIPT"
require_source 'shasum -a 256 "$ARTIFACT_NAME" > SHA256SUMS' "$BUILD_SCRIPT"
require_source 'readonly EXPECTED_TEAM_ID="9N7UKH59LC"' "$INSTALL_SCRIPT"
require_source "PATH='/usr/bin:/bin:/usr/sbin:/sbin'" "$INSTALL_SCRIPT"
require_source 'GitHub Release must be immutable' "$INSTALL_SCRIPT"
require_source 'SHA-256 verification failed' "$INSTALL_SCRIPT"
require_source 'awk -v artifact="$artifact_name"' "$INSTALL_SCRIPT"
require_source 'ZIP archive must contain only' "$INSTALL_SCRIPT"
require_source 'codesign --verify --strict --verbose=4 "$candidate"' "$INSTALL_SCRIPT"
require_source "codesign -vvvv -R='notarized' --check-notarization \"\$candidate\"" "$INSTALL_SCRIPT"
require_source 'binary is not universal2' "$INSTALL_SCRIPT"
require_source 'mv -f "$staged_binary" "$install_dir/$EXECUTABLE_NAME"' "$INSTALL_SCRIPT"

notary_line="$(awk '/codesign -vvvv -R=.notarized. --check-notarization \"\$candidate\"/ { print NR }' "$INSTALL_SCRIPT")"
version_line="$(awk '/binary version does not match VMEMO_VERSION/ { print NR }' "$INSTALL_SCRIPT")"
[[ "$notary_line" -lt "$version_line" ]] || fail 'downloaded binary version is checked before notarization assessment'

if grep -En 'VMEMO_INSTALLER_IDENTITY|pkgbuild|productsign|pkgutil|stapler|INSTALL_LOCATION' "$BUILD_SCRIPT" "$INSTALL_SCRIPT"; then
    fail 'obsolete PKG release path remains'
fi

if VMEMO_VERSION='../0.1.1' bash "$INSTALL_SCRIPT" >/dev/null 2>&1; then
    fail 'unsafe VMEMO_VERSION was accepted'
fi
if VMEMO_INSTALL_DIR='relative/path' bash "$INSTALL_SCRIPT" >/dev/null 2>&1; then
    fail 'relative VMEMO_INSTALL_DIR was accepted'
fi

printf '%s\n' 'release script tests passed'
