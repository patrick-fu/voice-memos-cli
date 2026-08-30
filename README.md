# Voice Memos CLI

A safe, agent-friendly macOS CLI for read-only Voice Memos retrieval and export.

> Current scope: `list`, `search`, `show`, `export`, and `doctor`. `rename` and `delete` are not supported. This CLI does not require or use Accessibility, CGEvent, mutation tokens, confirmation/dry-run flows, or Shortcuts write backends.

## Status

Production `read`, `list`, `search`, `show`, and `.m4a` `export` are enabled only for the exact macOS 26 / Voice Memos build 1380 contract. The package deployment target and CI may run on macOS 15 to compile and verify fail-closed behavior, but macOS 15 is not a supported production data path here, and supporting it later is an open product decision. All other builds and environments fail closed as unsupported.

The CLI targets stable JSON, explicit exit codes, and stdout/stderr separation for the exact supported production build and its fail-closed environments. The machine-readable agent contract is [docs/agent-contract.md](docs/agent-contract.md).

## Build and run

Source build is currently the primary developer path. There is no published PKG, Homebrew tap/cask, tagged Release, or signed/notarized installer to install yet.

```sh
cd <repository-root>
swift build -c release
.build/release/vmemo doctor
.build/release/vmemo list --json
```

Run the built binary directly at `.build/release/vmemo`, or copy it to a directory on your PATH:

```sh
cp .build/release/vmemo /your/preferred/bin/vmemo
```

## Access and first run

Full Disk Access or group-container protection may be required to read the Voice Memos recording library. Only the user can grant this in System Settings > Privacy & Security; the CLI cannot grant it on its own.

Run `doctor` before `list`, `search`, `show`, or `export`. Doctor creates an isolated read-only SQLite snapshot and checks Core Data store metadata; it does not read recording rows.

Use the reported `code` and exit code to decide the next action:

- `3`: operational/output error, for example `recording_not_found` or `destination_exists`.
- `4`: safety or adapter block, for example `unsupported_schema`, `snapshot_creation_failed`, or `access_denied_unattributed`; check the envelope code and grant access or use the exact supported environment when needed.
- `5`: partial or incomplete report; for example, signing metadata was unavailable while no safety check was blocked.

## Supported commands

- `list`
- `search`
- `show`
- `export`
- `doctor`

`list`, `search`, `show`, and `export` first create a temporary SQLite snapshot, then validate the exact bundle identity, Core Data persistent-store metadata, and 29-column `ZCLOUDRECORDING` schema. Only rows whose `ZEVICTIONDATE` is SQLite `NULL` are exposed. `VMEMO_RECORDINGS_ROOT` is a debug/test-only override: it accepts only descendants of the system temporary directory and is rejected by release builds.

`doctor` reports diagnostics without requesting or using Accessibility and without changing Voice Memos data. `search` matches recording titles only.

## Out of scope

- `rename`
- `delete`
- Accessibility/CGEvent-driven UI automation
- mutation authorization tokens or a mutation authorization directory
- direct Voice Memos DB, asset, or CloudKit writes

Research documents that discuss mutation, Accessibility, and CGEvent are retained as historical and decision evidence, not as the current implementation plan.

## Plan and research

The completed design roadmap is [Plan a safe, agent-friendly macOS Voice Memos CLI](https://github.com/patrick-fu/voice-memos-cli/issues/1). Its child issues hold each decision and the evidence behind it.

Current research found no supported direct Voice Memos data API or transcript write-back interface. Direct private-store mutation is excluded.

There is no PKG, Homebrew tap, tag, or Release artifact at this point; source build is the supported route. Research documents that cover PKG, Homebrew, signing, and notarization are retained as historical and decision evidence, not as a claim about a shipped installer.

## Research

- [Voice Memos data access boundaries](docs/research/voice-memos-data-access.md)
- [Private API and community implementation survey](docs/research/private-api-community-survey.md)
- [Community implementation patterns](docs/research/community-implementation-patterns.md)
- [Mutation backends beyond input synthesis](docs/research/voice-memos-mutation-alternatives.md)
- [macOS permission and automation constraints](docs/research/macos-permissions-and-automation.md)
- [SQLite snapshot and concurrency strategy](docs/research/sqlite-snapshot-strategy.md)
- [Distribution and compatibility matrix](docs/research/distribution-and-compatibility-matrix.md)
- [Test fixtures and integration isolation](docs/research/test-fixtures-and-integration-isolation.md)
- [Transcript write-back feasibility](docs/research/voice-memos-transcript-writeback.md)
- [Shortcuts bridge feasibility](docs/research/voice-memos-shortcuts-bridge.md)

## License

[MIT](LICENSE)
