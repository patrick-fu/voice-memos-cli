#!/bin/bash
set -euo pipefail

readonly REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
readonly EXPECTED_VERSION="0.1.0"
readonly EXPECTED_IDENTIFIER="com.paaatrick.voice-memos-cli"
readonly EXPECTED_INSTALL_PATH="/usr/local/bin/vmemo"
readonly EXPECTED_DEPLOYMENT_TARGET="15.0"
readonly EXPECTED_PRODUCTION_OS="26"
readonly EXPECTED_VOICE_MEMOS_BUILD="1380"

fail() {
    printf 'release contract check failed: %s\n' "$1" >&2
    exit 1
}

require_exact_line() {
    local expected="$1"
    local file="$2"
    grep -Fqx "$expected" "$file" || fail "expected contract is missing from ${file#$REPOSITORY_ROOT/}"
}

cd "$REPOSITORY_ROOT"

require_exact_line "    static let current = \"${EXPECTED_VERSION}\"" "Sources/VMemo/ProductVersion.swift"
require_exact_line "    platforms: [.macOS(.v15)]," "Package.swift"
require_exact_line "readonly VERSION=\"${EXPECTED_VERSION}\"" "scripts/release/build-and-notarize.sh"
require_exact_line "readonly IDENTIFIER=\"${EXPECTED_IDENTIFIER}\"" "scripts/release/build-and-notarize.sh"
require_exact_line "readonly INSTALL_LOCATION=\"/usr/local/bin\"" "scripts/release/build-and-notarize.sh"
require_exact_line "readonly EXECUTABLE_NAME=\"vmemo\"" "scripts/release/build-and-notarize.sh"
require_exact_line "readonly DEPLOYMENT_TARGET=\"${EXPECTED_DEPLOYMENT_TARGET}\"" "scripts/release/build-and-notarize.sh"
grep -Fq "static let bundleBuild = \"${EXPECTED_VOICE_MEMOS_BUILD}\"" Sources/VMemo/RealSchemaRecognizer.swift \
    || fail "Voice Memos build contract is missing"
grep -Fq "identity.osMajor == ${EXPECTED_PRODUCTION_OS}" Sources/VMemo/RealSchemaRecognizer.swift \
    || fail "production macOS contract is missing"
grep -Fq "guard runtime.osMajor == ${EXPECTED_PRODUCTION_OS}" Sources/VMemo/Doctor.swift \
    || fail "doctor macOS contract is missing"

printf '%s\n' "release contract is valid"
printf '%s\n' "version=${EXPECTED_VERSION} identifier=${EXPECTED_IDENTIFIER} install_path=${EXPECTED_INSTALL_PATH} deployment_target=${EXPECTED_DEPLOYMENT_TARGET} production_contract=macOS-${EXPECTED_PRODUCTION_OS}/VoiceMemos-${EXPECTED_VOICE_MEMOS_BUILD}"
