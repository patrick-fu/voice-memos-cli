#!/bin/bash
set -euo pipefail

readonly REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
readonly VERSION="0.1.0"
readonly IDENTIFIER="com.paaatrick.voice-memos-cli"
readonly INSTALL_LOCATION="/usr/local/bin"
readonly EXECUTABLE_NAME="vmemo"
readonly DEPLOYMENT_TARGET="15.0"
readonly DIST_DIR="$REPOSITORY_ROOT/dist"

application_identity="${VMEMO_APPLICATION_IDENTITY:-}"
installer_identity="${VMEMO_INSTALLER_IDENTITY:-}"
team_id="${VMEMO_TEAM_ID:-}"
notary_profile="${VMEMO_NOTARY_PROFILE:-}"
dry_run=false

usage() {
    cat <<'USAGE'
Usage: scripts/release/build-and-notarize.sh [options]

Builds, signs, packages, notarizes, staples, and verifies the v0.1.0 universal2 PKG.
It refuses to reuse or overwrite an existing dist directory.

Options:
  --application-identity VALUE  Developer ID Application identity (or VMEMO_APPLICATION_IDENTITY)
  --installer-identity VALUE    Developer ID Installer identity (or VMEMO_INSTALLER_IDENTITY)
  --team-id VALUE               Expected Apple Developer Team ID (or VMEMO_TEAM_ID)
  --notary-profile VALUE        notarytool keychain profile (or VMEMO_NOTARY_PROFILE)
  --dry-run                     Validate inputs and tools without building or creating output
  --help                        Show this help

The script never creates a tag, a GitHub Release, or an installation. It does not print
identity or keychain-profile values, and expects signing material to remain in Keychain.
USAGE
}

fail() {
    printf 'release failed: %s\n' "$1" >&2
    exit 1
}

require_value() {
    local option="$1"
    local value="${2:-}"
    [[ -n "$value" ]] || fail "${option} requires a value"
}

while (($# > 0)); do
    case "$1" in
        --application-identity)
            require_value "$1" "${2:-}"
            application_identity="$2"
            shift 2
            ;;
        --installer-identity)
            require_value "$1" "${2:-}"
            installer_identity="$2"
            shift 2
            ;;
        --team-id)
            require_value "$1" "${2:-}"
            team_id="$2"
            shift 2
            ;;
        --notary-profile)
            require_value "$1" "${2:-}"
            notary_profile="$2"
            shift 2
            ;;
        --dry-run)
            dry_run=true
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            fail "unknown option: $1"
            ;;
    esac
done

[[ ! -e "$DIST_DIR" ]] || fail "dist already exists; refusing to overwrite it"

require_value "Developer ID Application identity" "$application_identity"
require_value "Developer ID Installer identity" "$installer_identity"
require_value "Apple Developer Team ID" "$team_id"
require_value "notarytool keychain profile" "$notary_profile"
[[ "$team_id" =~ ^[A-Z0-9]{10}$ ]] || fail "Apple Developer Team ID must be ten uppercase letters or digits"

for tool in codesign lipo pkgbuild productsign pkgutil shasum spctl xcrun; do
    command -v "$tool" >/dev/null 2>&1 || fail "required tool is unavailable: $tool"
done
xcrun --find notarytool >/dev/null 2>&1 || fail "required tool is unavailable: notarytool"
xcrun --find stapler >/dev/null 2>&1 || fail "required tool is unavailable: stapler"
xcrun --find vtool >/dev/null 2>&1 || fail "required tool is unavailable: vtool"
xcrun swift build --help 2>&1 | grep -Fq -- '--triple' || fail "the selected SwiftPM does not support --triple"
xcrun swift build --help 2>&1 | grep -Fq -- '--only-use-versions-from-resolved-file' \
    || fail "the selected SwiftPM cannot enforce Package.resolved"

"$REPOSITORY_ROOT/scripts/release/check-contract.sh" >/dev/null

if "$dry_run"; then
    printf '%s\n' "release dry run passed: inputs, tools, and static contract are valid; no artifact was created"
    exit 0
fi

source_status() {
    git -C "$REPOSITORY_ROOT" status --porcelain=v1 --untracked-files=all -- . ':(exclude)dist'
}

[[ -z "$(source_status)" ]] \
    || fail "release requires a clean, committed working tree"
readonly SOURCE_REVISION="$(git -C "$REPOSITORY_ROOT" rev-parse HEAD)"

verify_source_unchanged() {
    [[ "$(git -C "$REPOSITORY_ROOT" rev-parse HEAD)" == "$SOURCE_REVISION" ]] \
        || fail "source revision changed during the release"
    [[ -z "$(source_status)" ]] \
        || fail "working tree changed during the release"
}

umask 077
mkdir "$DIST_DIR"
readonly work_dir="$DIST_DIR/.work"
readonly arm64_scratch="$work_dir/build-arm64"
readonly x86_64_scratch="$work_dir/build-x86_64"
readonly payload_dir="$work_dir/payload"
readonly universal_binary="$work_dir/$EXECUTABLE_NAME"
readonly unsigned_pkg="$work_dir/$EXECUTABLE_NAME-$VERSION-unsigned.pkg"
readonly package_name="$EXECUTABLE_NAME-$VERSION-macos-universal2.pkg"
readonly package_path="$DIST_DIR/$package_name"
readonly signature_info="$work_dir/codesign-info.txt"
readonly notarization_result="$work_dir/notarization.json"
release_succeeded=false

cleanup() {
    rm -rf "$work_dir"
    if ! "$release_succeeded"; then
        rm -f "$package_path" "$DIST_DIR/SHA256SUMS" "$DIST_DIR/provenance.json"
        rmdir "$DIST_DIR" 2>/dev/null || true
    fi
}
trap cleanup EXIT

mkdir -p "$arm64_scratch" "$x86_64_scratch" "$payload_dir"

build_architecture() {
    local architecture="$1"
    local scratch_path="$2"
    xcrun swift build --package-path "$REPOSITORY_ROOT" --product "$EXECUTABLE_NAME" \
        --configuration release --only-use-versions-from-resolved-file \
        --triple "$architecture-apple-macosx$DEPLOYMENT_TARGET" --scratch-path "$scratch_path"
}

find_built_executable() {
    local scratch_path="$1"
    local -a candidates=()
    while IFS= read -r candidate; do
        candidates+=("$candidate")
    done < <(find "$scratch_path" -type f -path "*/release/$EXECUTABLE_NAME" -print)
    ((${#candidates[@]} == 1)) || fail "expected exactly one $EXECUTABLE_NAME executable in $scratch_path"
    printf '%s\n' "${candidates[0]}"
}

build_architecture arm64 "$arm64_scratch" &
arm64_pid=$!
build_architecture x86_64 "$x86_64_scratch" &
x86_64_pid=$!

arm64_status=0
x86_64_status=0
wait "$arm64_pid" || arm64_status=$?
wait "$x86_64_pid" || x86_64_status=$?
((arm64_status == 0 && x86_64_status == 0)) || fail "one or more architecture builds failed"
verify_source_unchanged

arm64_binary="$(find_built_executable "$arm64_scratch")"
x86_64_binary="$(find_built_executable "$x86_64_scratch")"
[[ -x "$arm64_binary" ]] || fail "arm64 executable was not produced"
[[ -x "$x86_64_binary" ]] || fail "x86_64 executable was not produced"
[[ "$(lipo -archs "$arm64_binary")" == "arm64" ]] || fail "arm64 build is not a single arm64 slice"
[[ "$(lipo -archs "$x86_64_binary")" == "x86_64" ]] || fail "x86_64 build is not a single x86_64 slice"

lipo -create "$arm64_binary" "$x86_64_binary" -output "$universal_binary"
architecture_set="$(lipo -archs "$universal_binary" | tr ' ' '\n' | sort | paste -sd ' ' -)"
[[ "$architecture_set" == "arm64 x86_64" ]] || fail "universal executable does not contain exactly arm64 and x86_64"

verify_deployment_target() {
    local architecture="$1"
    local build_info
    build_info="$(xcrun vtool -arch "$architecture" -show-build "$universal_binary")"
    grep -Eq '^[[:space:]]*platform MACOS$' <<<"$build_info" \
        || fail "$architecture executable does not declare a macOS build target"
    grep -Eq "^[[:space:]]*minos ${DEPLOYMENT_TARGET}$" <<<"$build_info" \
        || fail "$architecture executable deployment target is not macOS $DEPLOYMENT_TARGET"
}

verify_deployment_target arm64
verify_deployment_target x86_64
[[ "$("$universal_binary" --version)" == "$VERSION" ]] \
    || fail "universal executable does not report version $VERSION"

codesign --force --sign "$application_identity" --identifier "$IDENTIFIER" --options runtime --timestamp "$universal_binary"
codesign --verify --strict --verbose=4 "$universal_binary"

verify_architecture_signature() {
    local architecture="$1"
    codesign -d --arch "$architecture" -vv "$universal_binary" 2>"$signature_info"
    grep -Fqx "Identifier=$IDENTIFIER" "$signature_info" || fail "signed executable identifier is incorrect"
    grep -Fqx "TeamIdentifier=$team_id" "$signature_info" || fail "signed executable team identifier is incorrect"
    grep -Eq '^Authority=Developer ID Application:' "$signature_info" || fail "signed executable is not a Developer ID Application signature"
    grep -Eq '^Timestamp=' "$signature_info" || fail "signed executable has no secure timestamp"
    grep -Eq '^CodeDirectory .*flags=.*runtime' "$signature_info" || fail "signed executable does not enable hardened runtime"
}

verify_architecture_signature arm64
verify_architecture_signature x86_64
codesign -d --entitlements :- "$universal_binary" >"$work_dir/entitlements.plist" 2>/dev/null || true
! grep -Eq '<key>com\.apple\.security\.get-task-allow</key>[[:space:]]*<true/>' "$work_dir/entitlements.plist" \
    || fail "signed executable enables get-task-allow"

install -m 0755 "$universal_binary" "$payload_dir/$EXECUTABLE_NAME"
[[ "$(find "$payload_dir" -mindepth 1 -maxdepth 1 -type f -print | wc -l | tr -d ' ')" == "1" ]] \
    || fail "package payload must contain exactly one executable"
[[ -f "$payload_dir/$EXECUTABLE_NAME" ]] || fail "package payload is missing vmemo"

verify_package_payload() {
    local package_path_to_check="$1"
    local inspection_name="$2"
    local entry
    local root_marker_count=0
    local executable_count=0
    local apple_double_count=0
    local entry_count=0
    local inspection_dir="$work_dir/payload-inspection-$inspection_name"
    while IFS= read -r entry; do
        ((entry_count += 1))
        case "$entry" in
            .)
                ((root_marker_count += 1))
                ;;
            "./$EXECUTABLE_NAME")
                ((executable_count += 1))
                ;;
            "./._$EXECUTABLE_NAME")
                ((apple_double_count += 1))
                ;;
            *)
                fail "package payload contains an unexpected entry"
                ;;
        esac
    done < <(pkgutil --payload-files "$package_path_to_check")
    ((root_marker_count == 1 && executable_count == 1 && apple_double_count <= 1 && entry_count == 2 + apple_double_count)) \
        || fail "package payload must contain only $EXECUTABLE_NAME"

    pkgutil --expand-full "$package_path_to_check" "$inspection_dir"
    [[ -d "$inspection_dir/Payload" && ! -L "$inspection_dir/Payload" ]] \
        || fail "expanded package payload is not a real directory"
    [[ -f "$inspection_dir/Payload/$EXECUTABLE_NAME" && ! -L "$inspection_dir/Payload/$EXECUTABLE_NAME" ]] \
        || fail "expanded package payload is missing a regular $EXECUTABLE_NAME"
    [[ "$(find "$inspection_dir/Payload" -mindepth 1 -print | wc -l | tr -d ' ')" == "1" ]] \
        || fail "expanded package payload contains an unexpected file or directory"
    codesign --verify --strict --verbose=4 "$inspection_dir/Payload/$EXECUTABLE_NAME"
}

pkgbuild \
    --filter '(^|/)(\.svn|CVS)(/|$)' \
    --filter '(^|/)\.DS_Store$' \
    --filter '(^|/)\._[^/]+$' \
    --root "$payload_dir" \
    --identifier "$IDENTIFIER" \
    --version "$VERSION" \
    --install-location "$INSTALL_LOCATION" \
    "$unsigned_pkg"
verify_package_payload "$unsigned_pkg" unsigned
if ! productsign --sign "$installer_identity" "$unsigned_pkg" "$package_path" >"$work_dir/productsign.log" 2>&1; then
    fail "package signing failed"
fi
verify_package_payload "$package_path" signed
pkgutil --check-signature "$package_path" >"$work_dir/package-signature.txt"
grep -Eq 'Developer ID Installer:' "$work_dir/package-signature.txt" || fail "package is not signed with a Developer ID Installer identity"
grep -Fq "($team_id)" "$work_dir/package-signature.txt" || fail "package signer does not match the expected team"

verify_source_unchanged
if ! xcrun notarytool submit "$package_path" --keychain-profile "$notary_profile" --wait --output-format json >"$notarization_result" 2>&1; then
    fail "notarization submission failed"
fi
grep -Eq '"status"[[:space:]]*:[[:space:]]*"Accepted"' "$notarization_result" || fail "notarization was not accepted"
xcrun stapler staple "$package_path"
xcrun stapler validate "$package_path"
spctl --assess --type install --verbose=4 "$package_path"

(
    cd "$DIST_DIR"
    shasum -a 256 "$package_name" > SHA256SUMS
)

provenance_plist="$work_dir/provenance.plist"
/usr/bin/plutil -create xml1 "$provenance_plist"
/usr/bin/plutil -insert artifact -string "$package_name" "$provenance_plist"
/usr/bin/plutil -insert version -string "$VERSION" "$provenance_plist"
/usr/bin/plutil -insert identifier -string "$IDENTIFIER" "$provenance_plist"
/usr/bin/plutil -insert install_path -string "$INSTALL_LOCATION/$EXECUTABLE_NAME" "$provenance_plist"
/usr/bin/plutil -insert deployment_target -string "$DEPLOYMENT_TARGET" "$provenance_plist"
/usr/bin/plutil -insert architectures -json '["arm64","x86_64"]' "$provenance_plist"
/usr/bin/plutil -insert source_revision -string "$SOURCE_REVISION" "$provenance_plist"
/usr/bin/plutil -insert swift_version -string "$(xcrun swift --version | tr '\n' ' ')" "$provenance_plist"
/usr/bin/plutil -insert sdk_version -string "$(xcrun --sdk macosx --show-sdk-version)" "$provenance_plist"
/usr/bin/plutil -insert built_at_utc -string "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$provenance_plist"
/usr/bin/plutil -convert json -o "$DIST_DIR/provenance.json" "$provenance_plist"

release_succeeded=true
printf '%s\n' "release artifacts are ready in ${DIST_DIR#$REPOSITORY_ROOT/}"
