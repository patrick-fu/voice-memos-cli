# Voice Memos CLI (`vmemo`)

> **🌐 [Product page: https://patrick-fu.github.io/voice-memos-cli/](https://patrick-fu.github.io/voice-memos-cli/)**

**English** · [简体中文](README.zh-CN.md)

Safe, agent-friendly, read-only access to Apple Voice Memos on macOS. `vmemo` lists, searches, inspects, and exports user-owned copies of recordings; it never renames, deletes, or writes to Voice Memos.

> **Production contract** — v0.1.2 production data access is intentionally narrow: **macOS 26 with Voice Memos build 1380 only**. Any other environment fails closed rather than guessing at a private data format.

## What it does

| Command | Description |
| --- | --- |
| `list` | List active recordings. |
| `search --query <text>` | Case-insensitive title search only. |
| `show --id <id>` | Inspect one recording by its opaque ID. |
| `export --id <id> --output-path <path>` | Copy a supported local `.m4a` asset to a new destination. |
| `doctor` | Check runtime, app, library, schema, and signing readiness. |

`rename`, `delete`, transcript access, UI automation, and direct database/asset/CloudKit writes are deliberately out of scope. The tool does not use Accessibility, CGEvent, Apple Events, mutation tokens, or Voice Memos private entitlements.

## Install

### One-line installer (recommended)

The v0.1.2 release channel is an Apple-notarized universal2 ZIP published to an immutable GitHub Release, installed by a version-pinned script. No sudo, no installer GUI, and no PKG.

```sh
curl -fsSL https://raw.githubusercontent.com/patrick-fu/voice-memos-cli/v0.1.2/install.sh | sh
```

The script installs `~/.local/bin/vmemo` and stops before writing anything unless every check passes:

- The release is marked immutable, and `vmemo-0.1.2-macos-universal2.zip` matches its `SHA256SUMS` entry.
- The executable is signed by a `Developer ID Application` identity for `com.paaatrick.voice-memos-cli` and Team ID `9N7UKH59LC`, carries a secure timestamp and Hardened Runtime, and satisfies `codesign`'s online `notarized` requirement.
- The binary contains both `arm64` and `x86_64` slices and reports the expected version, consistent with `provenance.json`.
- The new binary replaces an existing `vmemo` in the same directory atomically, so a failed install leaves the previous one in place.

Prefer to read before running: download `install.sh` from the same tag, inspect it, then run `sh ./install.sh`. Keep the pinned tag instead of a mutable branch such as `main`.

If `~/.local/bin` is not on your `PATH`, the installer prints the command that adds it and never edits your shell configuration. Use `VMEMO_INSTALL_DIR` for a different directory, and `VMEMO_VERSION` to select another published version.

Verify a completed install:

```sh
"$HOME/.local/bin/vmemo" --version
codesign -d -vv "$HOME/.local/bin/vmemo" 2>&1 | grep -E 'Identifier|TeamIdentifier|Authority'
codesign -vvvv -R='notarized' --check-notarization "$HOME/.local/bin/vmemo"
lipo -archs "$HOME/.local/bin/vmemo"
```

Installing needs no Full Disk Access because it only writes to the install directory. macOS may ask for library access later, when `vmemo` actually reads Voice Memos data; `vmemo doctor` reports the current state.

### Manual download

You can also download `vmemo-0.1.2-macos-universal2.zip`, `SHA256SUMS`, and `provenance.json` from [GitHub Releases](https://github.com/patrick-fu/voice-memos-cli/releases) and put the binary, which the archive holds at `vmemo-0.1.2-macos-universal2/vmemo`, anywhere on your `PATH`. A bare executable cannot carry a stapled ticket, so Gatekeeper checks the notarization ticket online on first use.

```sh
shasum -a 256 -c SHA256SUMS
```

### Build from source

Use a Swift 6-capable Xcode toolchain:

```sh
git clone https://github.com/patrick-fu/voice-memos-cli.git
cd voice-memos-cli
swift build -c release
mkdir -p "$HOME/.local/bin"
install -m 755 .build/release/vmemo "$HOME/.local/bin/vmemo"
"$HOME/.local/bin/vmemo" --version
```

A source-built executable has no Developer ID signature and no notarization ticket. It is useful for development and review, but it is not a substitute for the signed, notarized release archive.

## Permissions and compatibility

- Voice Memos' group container may require **Full Disk Access** or another user-granted container permission. Grant it yourself in **System Settings → Privacy & Security**; `vmemo` cannot grant it.
- Run `doctor` before accessing recordings. It checks isolated read-only SQLite snapshot metadata and does not read recording rows.
- `list`, `search`, `show`, and `export` create an isolated SQLite snapshot, validate the exact app/model/schema contract, and fail closed on an unsupported schema, denied access, unsafe asset path, or inconsistent export.
- Only active recordings are exposed; Recently Deleted items are excluded. Export currently accepts local regular `.m4a` files only, and the destination must not already exist.
- macOS 15 may be used to build and exercise fail-closed tests, but it is **not** a supported production data path. New Voice Memos builds are unsupported until explicitly added to the contract.

## Quick start

```sh
# Check the exact environment first
vmemo doctor --json

# Discover opaque IDs; search matches titles only
vmemo list --json
vmemo search --query "<title fragment>" --json

# Reuse the returned ID exactly
vmemo show --id "<opaque-recording-id>" --json
vmemo export --id "<opaque-recording-id>" \
  --output-path "$HOME/Downloads/recording.m4a" --json
```

Treat recording IDs as opaque: do not derive them from a title, path, or database row. `search` is title-only; it does not search recording audio, transcripts, dates, or paths. `export` copies the source without modifying the Voice Memos recording.

## Agent contract

Every command accepts `--json`. With `--json`, normal success writes a versioned envelope to stdout and failures write an error envelope to stderr. `doctor` is the exception: its report is always stdout, even when its status is `blocked` or `incomplete`.

```json
{"version":1,"status":"ok","data":{}}
```

| Exit code | Meaning |
| --- | --- |
| `0` | Success; `doctor` is `ready`. |
| `2` | Usage or argument error. |
| `3` | Operational/output error, such as an unknown ID or existing destination. |
| `4` | Safety or adapter block, such as unsupported schema or denied access. |
| `5` | Partial/incomplete report. |

Agents should follow this sequence: `doctor --json` → require `data.status == "ready"` → `list` or `search` → optionally `show` → `export`. Use the returned opaque ID exactly, and inspect both the JSON `code` and the process exit code before retrying. The complete machine-readable interface, output shapes, and stable error codes are in the [agent contract](docs/agent-contract.md).

## Privacy and safety

Recording titles are sensitive. Avoid putting titles, title-like queries, recording IDs, or title-bearing paths into logs, issues, transcripts, or error reports. `vmemo` returns titles only in the requested stdout payload; callers are responsible for preventing downstream disclosure.

The implementation is read-only with respect to Voice Memos. It snapshots the library before reading, validates a narrow known schema, excludes Recently Deleted rows, constrains asset paths to the recordings root, requires a new export destination, and checks for source changes while copying.

## Development

```sh
swift test
swift build -c release
.build/release/vmemo --help
```

Tests use isolated synthetic fixtures; do not point development overrides at a real Voice Memos library. `VMEMO_RECORDINGS_ROOT` is debug/test-only, accepts only descendants of the system temporary directory, and is rejected by release builds.

## Links and evidence

- [Repository](https://github.com/patrick-fu/voice-memos-cli) · [Releases](https://github.com/patrick-fu/voice-memos-cli/releases) · [Release notes](release-notes/v0.1.2.md) · [Planning record](https://github.com/patrick-fu/voice-memos-cli/issues/1)
- [Documentation](docs/agent-contract.md) · [Research](docs/research)
- [Project Pages](https://patrick-fu.github.io/voice-memos-cli/)

The research notes document why private-store mutation, Accessibility-driven automation, and unverified compatibility claims are excluded from this release contract.

## License

[MIT](LICENSE)
