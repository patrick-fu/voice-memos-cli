#!/bin/bash
set -euo pipefail

readonly REPOSITORY="patrick-fu/voice-memos-cli"
readonly EXPECTED_VERSION="0.1.2"
readonly EXPECTED_IDENTIFIER="com.paaatrick.voice-memos-cli"
readonly EXPECTED_TEAM_ID="9N7UKH59LC"
readonly EXECUTABLE_NAME="vmemo"

readonly ORIGINAL_PATH="${PATH:-}"
PATH='/usr/bin:/bin:/usr/sbin:/sbin'
export PATH

version="${VMEMO_VERSION:-$EXPECTED_VERSION}"
install_dir="${VMEMO_INSTALL_DIR:-${HOME:?HOME is required}/.local/bin}"

fail() { printf 'vmemo installation failed: %s\n' "$1" >&2; exit 1; }

[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.]+)?$ ]] || fail "VMEMO_VERSION must be a safe semantic version without a leading v"
[[ "$install_dir" == /* && ! "$install_dir" =~ (^|/)\.\.?(/|$) ]] || fail "VMEMO_INSTALL_DIR must be an absolute path without . or .. components"
readonly release_tag="v$version"
readonly payload_name="$EXECUTABLE_NAME-$version-macos-universal2"
readonly artifact_name="$payload_name.zip"
readonly release_base_url="https://github.com/$REPOSITORY/releases/download/$release_tag"
readonly release_api_url="https://api.github.com/repos/$REPOSITORY/releases/tags/$release_tag"

for tool in codesign curl find lipo plutil shasum unzip; do
    command -v "$tool" >/dev/null 2>&1 || fail "required tool is unavailable: $tool"
done

umask 077
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/vmemo-install.XXXXXX")"
cleanup() { rm -rf "$work_dir"; }
trap cleanup EXIT

download() {
    curl --fail --location --proto '=https' --tlsv1.2 --retry 3 --silent --show-error "$1" --output "$2"
}

release_metadata="$work_dir/release.json"
download "$release_api_url" "$release_metadata"
plutil -convert json -o /dev/null "$release_metadata" || fail "GitHub Release metadata is not valid JSON"
[[ "$(plutil -extract tag_name raw "$release_metadata")" == "$release_tag" ]] || fail "GitHub Release tag does not match VMEMO_VERSION"
[[ "$(plutil -extract immutable raw "$release_metadata")" == "true" ]] || fail "GitHub Release must be immutable"
[[ "$(plutil -extract draft raw "$release_metadata")" == "false" ]] || fail "GitHub Release must not be a draft"

archive_path="$work_dir/$artifact_name"
checksums_path="$work_dir/SHA256SUMS"
provenance_path="$work_dir/provenance.json"
download "$release_base_url/$artifact_name" "$archive_path"
download "$release_base_url/SHA256SUMS" "$checksums_path"
download "$release_base_url/provenance.json" "$provenance_path"

checksum_lines="$(awk -v artifact="$artifact_name" 'NF == 2 && length($1) == 64 && $1 ~ /^[[:xdigit:]]+$/ && $2 == artifact { print }' "$checksums_path")"
[[ "$(printf '%s\n' "$checksum_lines" | sed '/^$/d' | wc -l | tr -d ' ')" == "1" ]] || fail "SHA256SUMS must contain exactly one checksum for $artifact_name"
expected_checksum="${checksum_lines%% *}"
actual_checksum="$(shasum -a 256 "$archive_path" | awk '{print $1}')"
[[ "$actual_checksum" == "$expected_checksum" ]] || fail "SHA-256 verification failed for $artifact_name"

plutil -convert json -o /dev/null "$provenance_path" || fail "provenance.json is not valid JSON"
[[ "$(plutil -extract artifact raw "$provenance_path")" == "$artifact_name" ]] || fail "provenance artifact does not match download"
[[ "$(plutil -extract version raw "$provenance_path")" == "$version" ]] || fail "provenance version does not match download"
[[ "$(plutil -extract identifier raw "$provenance_path")" == "$EXPECTED_IDENTIFIER" ]] || fail "provenance identifier is unexpected"
[[ "$(plutil -extract architectures.0 raw "$provenance_path")" == "arm64" ]] || fail "provenance is missing arm64"
[[ "$(plutil -extract architectures.1 raw "$provenance_path")" == "x86_64" ]] || fail "provenance is missing x86_64"

archive_entries="$(unzip -Z1 "$archive_path")"
expected_entries="$payload_name/"$'\n'"$payload_name/$EXECUTABLE_NAME"
[[ "$archive_entries" == "$expected_entries" ]] || fail "ZIP archive must contain only $payload_name/$EXECUTABLE_NAME"
unzip -q "$archive_path" -d "$work_dir/extract"
candidate="$work_dir/extract/$payload_name/$EXECUTABLE_NAME"
[[ -f "$candidate" && ! -L "$candidate" && -x "$candidate" ]] || fail "ZIP payload is not a regular executable"
[[ "$(find "$work_dir/extract" -mindepth 1 -print | wc -l | tr -d ' ')" == "2" ]] || fail "ZIP extraction contains unexpected files"

codesign --verify --strict --verbose=4 "$candidate"
signature_info="$work_dir/codesign-info.txt"
codesign -d -vv "$candidate" 2>"$signature_info"
grep -Fqx "Identifier=$EXPECTED_IDENTIFIER" "$signature_info" || fail "binary identifier is unexpected"
grep -Fqx "TeamIdentifier=$EXPECTED_TEAM_ID" "$signature_info" || fail "binary team identifier is unexpected"
grep -Eq '^Authority=Developer ID Application:' "$signature_info" || fail "binary is not signed by a Developer ID Application certificate"
grep -Eq '^Timestamp=' "$signature_info" || fail "binary signature has no secure timestamp"
grep -Eq '^CodeDirectory .*flags=.*runtime' "$signature_info" || fail "binary does not enable hardened runtime"
architectures="$(lipo -archs "$candidate" | tr ' ' '\n' | sort | paste -sd ' ' -)"
[[ "$architectures" == "arm64 x86_64" ]] || fail "binary is not universal2"

# ZIP archives and bare Mach-O executables cannot be stapled. Apple's supported
# check for "other code" verifies the standalone binary's online notary ticket.
codesign -vvvv -R='notarized' --check-notarization "$candidate"
[[ "$("$candidate" --version)" == "$version" ]] || fail "binary version does not match VMEMO_VERSION"

mkdir -p "$install_dir"
[[ ! -d "$install_dir/$EXECUTABLE_NAME" ]] || fail "installation target is an existing directory"
staging_dir="$(mktemp -d "$install_dir/.vmemo-install.XXXXXX")"
staged_binary="$staging_dir/$EXECUTABLE_NAME"
cp "$candidate" "$staged_binary"
chmod 0755 "$staged_binary"
codesign --verify --strict --verbose=4 "$staged_binary"
mv -f "$staged_binary" "$install_dir/$EXECUTABLE_NAME"
rmdir "$staging_dir"

printf 'Installed %s %s to %s\n' "$EXECUTABLE_NAME" "$version" "$install_dir/$EXECUTABLE_NAME"
case ":$ORIGINAL_PATH:" in
    *":$install_dir:"*) ;;
    *) printf 'Add %s to PATH to run %s from a new shell.\n' "$install_dir" "$EXECUTABLE_NAME" ;;
esac
