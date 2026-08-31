#!/bin/bash
set -euo pipefail

readonly REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
readonly VERSION="0.1.2"
readonly IDENTIFIER="com.paaatrick.voice-memos-cli"
readonly EXECUTABLE_NAME="vmemo"
readonly DEPLOYMENT_TARGET="15.0"
readonly DIST_DIR="$REPOSITORY_ROOT/dist/v$VERSION"
readonly ARTIFACT_NAME="$EXECUTABLE_NAME-$VERSION-macos-universal2.zip"
readonly PAYLOAD_NAME="$EXECUTABLE_NAME-$VERSION-macos-universal2"

PATH='/usr/bin:/bin:/usr/sbin:/sbin'
export PATH

application_identity="${VMEMO_APPLICATION_IDENTITY:-}"
team_id="${VMEMO_TEAM_ID:-}"
notary_profile="${VMEMO_NOTARY_PROFILE:-}"
dry_run=false

usage() {
    cat <<'USAGE'
Usage: scripts/release/build-and-notarize.sh [options]

Builds, signs, notarizes, and verifies the v0.1.2 universal2 ZIP release artifact.
It refuses to reuse or overwrite dist/v0.1.2 and never modifies prior release output.

Options:
  --application-identity VALUE  Developer ID Application identity (or VMEMO_APPLICATION_IDENTITY)
  --team-id VALUE               Expected Apple Developer Team ID (or VMEMO_TEAM_ID)
  --notary-profile VALUE        notarytool keychain profile (or VMEMO_NOTARY_PROFILE)
  --dry-run                     Validate inputs, tools, and static contract without creating output
  --help                        Show this help

ZIP archives and bare Mach-O executables cannot be stapled. The release is notarized by
submitting the ZIP; this script then checks the standalone executable's online notary
ticket with codesign. It never creates a tag, GitHub Release, or installation.
USAGE
}

fail() { printf 'release failed: %s\n' "$1" >&2; exit 1; }

require_value() {
    [[ -n "${2:-}" ]] || fail "$1 requires a value"
}

while (($# > 0)); do
    case "$1" in
        --application-identity) require_value "$1" "${2:-}"; application_identity="$2"; shift 2 ;;
        --team-id) require_value "$1" "${2:-}"; team_id="$2"; shift 2 ;;
        --notary-profile) require_value "$1" "${2:-}"; notary_profile="$2"; shift 2 ;;
        --dry-run) dry_run=true; shift ;;
        --help|-h) usage; exit 0 ;;
        *) fail "unknown option: $1" ;;
    esac
done

[[ ! -e "$DIST_DIR" ]] || fail "dist/v$VERSION already exists; refusing to overwrite it"
require_value "Developer ID Application identity" "$application_identity"
require_value "Apple Developer Team ID" "$team_id"
require_value "notarytool keychain profile" "$notary_profile"
[[ "$team_id" =~ ^[A-Z0-9]{10}$ ]] || fail "Apple Developer Team ID must be ten uppercase letters or digits"

for tool in codesign ditto find lipo plutil shasum unzip xcrun; do
    command -v "$tool" >/dev/null 2>&1 || fail "required tool is unavailable: $tool"
done
xcrun --find notarytool >/dev/null 2>&1 || fail "required tool is unavailable: notarytool"
xcrun --find vtool >/dev/null 2>&1 || fail "required tool is unavailable: vtool"
xcrun swift build --help 2>&1 | grep -Fq -- '--triple' || fail "the selected SwiftPM does not support --triple"
xcrun swift build --help 2>&1 | grep -Fq -- '--only-use-versions-from-resolved-file' || fail "the selected SwiftPM cannot enforce Package.resolved"
"$REPOSITORY_ROOT/scripts/release/check-contract.sh" >/dev/null

if "$dry_run"; then
    printf '%s\n' "release dry run passed: inputs, tools, and static contract are valid; no artifact was created"
    exit 0
fi

source_status() { git -C "$REPOSITORY_ROOT" status --porcelain=v1 --untracked-files=all -- . ':(exclude)dist'; }
[[ -z "$(source_status)" ]] || fail "release requires a clean, committed working tree"
readonly SOURCE_REVISION="$(git -C "$REPOSITORY_ROOT" rev-parse HEAD)"

verify_source_unchanged() {
    [[ "$(git -C "$REPOSITORY_ROOT" rev-parse HEAD)" == "$SOURCE_REVISION" ]] || fail "source revision changed during the release"
    [[ -z "$(source_status)" ]] || fail "working tree changed during the release"
}

umask 077
mkdir -p "$DIST_DIR"
readonly work_dir="$DIST_DIR/.work"
readonly arm64_scratch="$work_dir/build-arm64"
readonly x86_64_scratch="$work_dir/build-x86_64"
readonly payload_dir="$work_dir/$PAYLOAD_NAME"
readonly universal_binary="$payload_dir/$EXECUTABLE_NAME"
readonly archive_path="$DIST_DIR/$ARTIFACT_NAME"
readonly signature_info="$work_dir/codesign-info.txt"
readonly notarization_result="$work_dir/notarization.json"
release_succeeded=false

cleanup() {
    rm -rf "$work_dir"
    if ! "$release_succeeded"; then
        rm -f "$archive_path" "$DIST_DIR/SHA256SUMS" "$DIST_DIR/provenance.json"
        rmdir "$DIST_DIR" 2>/dev/null || true
    fi
}
trap cleanup EXIT
mkdir -p "$arm64_scratch" "$x86_64_scratch" "$payload_dir"

build_architecture() {
    xcrun swift build --package-path "$REPOSITORY_ROOT" --product "$EXECUTABLE_NAME" --configuration release \
        --only-use-versions-from-resolved-file --triple "$1-apple-macosx$DEPLOYMENT_TARGET" --scratch-path "$2"
}

find_built_executable() {
    local -a candidates=()
    while IFS= read -r candidate; do candidates+=("$candidate"); done < <(find "$1" -type f -path "*/release/$EXECUTABLE_NAME" -print)
    ((${#candidates[@]} == 1)) || fail "expected exactly one $EXECUTABLE_NAME executable in $1"
    printf '%s\n' "${candidates[0]}"
}

build_architecture arm64 "$arm64_scratch" & arm64_pid=$!
build_architecture x86_64 "$x86_64_scratch" & x86_64_pid=$!
arm64_status=0; x86_64_status=0
wait "$arm64_pid" || arm64_status=$?
wait "$x86_64_pid" || x86_64_status=$?
((arm64_status == 0 && x86_64_status == 0)) || fail "one or more architecture builds failed"
verify_source_unchanged

arm64_binary="$(find_built_executable "$arm64_scratch")"
x86_64_binary="$(find_built_executable "$x86_64_scratch")"
[[ -x "$arm64_binary" && -x "$x86_64_binary" ]] || fail "one or more architecture executables were not produced"
[[ "$(lipo -archs "$arm64_binary")" == "arm64" ]] || fail "arm64 build is not a single arm64 slice"
[[ "$(lipo -archs "$x86_64_binary")" == "x86_64" ]] || fail "x86_64 build is not a single x86_64 slice"
lipo -create "$arm64_binary" "$x86_64_binary" -output "$universal_binary"
architecture_set="$(lipo -archs "$universal_binary" | tr ' ' '\n' | sort | paste -sd ' ' -)"
[[ "$architecture_set" == "arm64 x86_64" ]] || fail "universal executable does not contain exactly arm64 and x86_64"

verify_deployment_target() {
    local build_info
    build_info="$(xcrun vtool -arch "$1" -show-build "$universal_binary")"
    grep -Eq '^[[:space:]]*platform MACOS$' <<<"$build_info" || fail "$1 executable does not declare a macOS build target"
    grep -Eq "^[[:space:]]*minos ${DEPLOYMENT_TARGET}$" <<<"$build_info" || fail "$1 executable deployment target is not macOS $DEPLOYMENT_TARGET"
}
verify_deployment_target arm64
verify_deployment_target x86_64
[[ "$("$universal_binary" --version)" == "$VERSION" ]] || fail "universal executable does not report version $VERSION"

codesign --force --sign "$application_identity" --identifier "$IDENTIFIER" --options runtime --timestamp "$universal_binary"
codesign --verify --strict --verbose=4 "$universal_binary"
verify_architecture_signature() {
    codesign -d --arch "$1" -vv "$universal_binary" 2>"$signature_info"
    grep -Fqx "Identifier=$IDENTIFIER" "$signature_info" || fail "signed executable identifier is incorrect"
    grep -Fqx "TeamIdentifier=$team_id" "$signature_info" || fail "signed executable team identifier is incorrect"
    grep -Eq '^Authority=Developer ID Application:' "$signature_info" || fail "signed executable is not a Developer ID Application signature"
    grep -Eq '^Timestamp=' "$signature_info" || fail "signed executable has no secure timestamp"
    grep -Eq '^CodeDirectory .*flags=.*runtime' "$signature_info" || fail "signed executable does not enable hardened runtime"
}
verify_architecture_signature arm64
verify_architecture_signature x86_64
codesign -d --entitlements :- "$universal_binary" >"$work_dir/entitlements.plist" 2>/dev/null || true
! grep -Eq '<key>com\.apple\.security\.get-task-allow</key>[[:space:]]*<true/>' "$work_dir/entitlements.plist" || fail "signed executable enables get-task-allow"

ditto -c -k --norsrc --keepParent "$payload_dir" "$archive_path"
archive_entries="$(unzip -Z1 "$archive_path")"
expected_entries="$PAYLOAD_NAME/"$'\n'"$PAYLOAD_NAME/$EXECUTABLE_NAME"
[[ "$archive_entries" == "$expected_entries" ]] || fail "ZIP archive must contain only $PAYLOAD_NAME/$EXECUTABLE_NAME"

verify_source_unchanged
if ! xcrun notarytool submit "$archive_path" --keychain-profile "$notary_profile" \
    --wait --timeout 30m --output-format json >"$notarization_result" 2>&1; then
    sed -E 's/(password|token|secret|credential)[^,}]*/\1=<redacted>/Ig' "$notarization_result" >&2
    fail "notarization submission failed"
fi
grep -Eq '"status"[[:space:]]*:[[:space:]]*"Accepted"' "$notarization_result" || fail "notarization was not accepted"
# ZIP archives and bare Mach-O executables cannot be stapled. For standalone
# "other code", codesign checks the notary ticket published online by Apple.
codesign -vvvv -R='notarized' --check-notarization "$universal_binary"

(cd "$DIST_DIR" && shasum -a 256 "$ARTIFACT_NAME" > SHA256SUMS)
provenance_plist="$work_dir/provenance.plist"
/usr/bin/plutil -create xml1 "$provenance_plist"
/usr/bin/plutil -insert artifact -string "$ARTIFACT_NAME" "$provenance_plist"
/usr/bin/plutil -insert version -string "$VERSION" "$provenance_plist"
/usr/bin/plutil -insert identifier -string "$IDENTIFIER" "$provenance_plist"
/usr/bin/plutil -insert install_path -string '~/.local/bin/vmemo' "$provenance_plist"
/usr/bin/plutil -insert deployment_target -string "$DEPLOYMENT_TARGET" "$provenance_plist"
/usr/bin/plutil -insert architectures -json '["arm64","x86_64"]' "$provenance_plist"
/usr/bin/plutil -insert source_revision -string "$SOURCE_REVISION" "$provenance_plist"
/usr/bin/plutil -insert swift_version -string "$(xcrun swift --version | tr '\n' ' ')" "$provenance_plist"
/usr/bin/plutil -insert sdk_version -string "$(xcrun --sdk macosx --show-sdk-version)" "$provenance_plist"
/usr/bin/plutil -insert built_at_utc -string "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$provenance_plist"
/usr/bin/plutil -convert json -o "$DIST_DIR/provenance.json" "$provenance_plist"
release_succeeded=true
printf '%s\n' "release artifacts are ready in ${DIST_DIR#$REPOSITORY_ROOT/}"
