# Voice Memos CLI

An agent-friendly macOS CLI project for safely searching, inspecting, exporting, renaming, and deleting Voice Memos.

> Status: production read and `.m4a` export are enabled only for the exact macOS 26 / Voice Memos build 1380 contract. Rename and delete use the same exact DB gate plus native Accessibility pre/post verification. The build 1380 live tree is virtualized: recording items are `AXButton` elements and custom actions are opaque native tokens. Raw-token handling is implemented. Live probing disproved `AXSetValue` search isolation and `AXPress` recording selection. In a clean single-window state, AX frame verification plus a native `CGEvent` double-click selected the exact item; its fresh raw `编辑标题` action entered title editing and native cancel exited without changing the title. Production mutation remains fail closed while the project decides whether this verified input synthesis belongs in the public backend and validates the rename commit transition. Every unsupported condition fails closed.

The v0.1 contract is being designed around stable JSON, explicit exit codes, stdout/stderr separation, dry-run and confirmation controls, and the current plus previous major macOS versions.

`list`, `search`, `show`, and `export` first create a temporary SQLite snapshot, then validate the exact bundle identity, Core Data persistent-store metadata, and 29-column `ZCLOUDRECORDING` schema. Only rows whose `ZEVICTIONDATE` is SQLite `NULL` are exposed. `VMEMO_RECORDINGS_ROOT` is a test-only root override; subprocess tests must always set it to an isolated fixture directory.

`rename` and `delete` retain their two-call shape: `--dry-run` returns a 30-second token; a second identical invocation needs `--token` and `--confirm`. Tokens bind canonical request, fresh DB source, fresh AX verification, and environment fingerprints; only their hashes are stored. The authorization directory is created lazily only by a mutation attempt at `~/Library/Application Support/vmemo/mutation-authorizations` (tests may set `VMEMO_MUTATION_TOKEN_ROOT`). A process-wide session lock covers verification, consumption before UI action, and fresh DB/UI postconditions. No read, help, or doctor command creates or accesses it.

## Plan

The completed design roadmap is [Plan a safe, agent-friendly macOS Voice Memos CLI](https://github.com/patrick-fu/voice-memos-cli/issues/1). Its child issues hold each decision and the evidence behind it.

Current research found no supported direct Voice Memos data API or transcript write-back interface. Direct private-store mutation is excluded; supported UI/Share paths and opt-in Shortcuts helpers are evaluated separately.

The release target is macOS 15.0+, distributed as a universal2 signed, notarized, and stapled PKG. The same PKG will be available through a project-owned Homebrew cask; source builds remain a secondary developer path.

## Research

- [Voice Memos data access boundaries](docs/research/voice-memos-data-access.md)
- [Private API and community implementation survey](docs/research/private-api-community-survey.md)
- [Mutation backends beyond input synthesis](docs/research/voice-memos-mutation-alternatives.md)
- [macOS permission and automation constraints](docs/research/macos-permissions-and-automation.md)
- [SQLite snapshot and concurrency strategy](docs/research/sqlite-snapshot-strategy.md)
- [Distribution and compatibility matrix](docs/research/distribution-and-compatibility-matrix.md)
- [Test fixtures and integration isolation](docs/research/test-fixtures-and-integration-isolation.md)
- [Transcript write-back feasibility](docs/research/voice-memos-transcript-writeback.md)
- [Shortcuts bridge feasibility](docs/research/voice-memos-shortcuts-bridge.md)

## License

[MIT](LICENSE)
