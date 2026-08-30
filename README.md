# Voice Memos CLI

A safe, agent-friendly macOS CLI for read-only Voice Memos retrieval and export.

> Current scope: `list`, `search`, `show`, `export`, and `doctor`. `rename` and `delete` are not supported. This CLI does not require or use Accessibility, CGEvent, mutation tokens, confirmation/dry-run flows, or Shortcuts write backends.

## Status

Production read and `.m4a` export are enabled only for the exact macOS 26 / Voice Memos build 1380 contract. All other builds and environments fail closed as unsupported.

The v0.1 contract targets stable JSON, explicit exit codes, and stdout/stderr separation across the supported macOS majors.

## Supported commands

- `list`
- `search`
- `show`
- `export`
- `doctor`

`list`, `search`, `show`, and `export` first create a temporary SQLite snapshot, then validate the exact bundle identity, Core Data persistent-store metadata, and 29-column `ZCLOUDRECORDING` schema. Only rows whose `ZEVICTIONDATE` is SQLite `NULL` are exposed. `VMEMO_RECORDINGS_ROOT` is a test-only root override; subprocess tests must always set it to an isolated fixture directory.

`doctor` reports diagnostics without requesting or using Accessibility and without changing Voice Memos data.

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

The release target is macOS 15.0+, distributed as a universal2 signed, notarized, and stapled PKG. The same PKG will be available through a project-owned Homebrew cask; source builds remain a secondary developer path.

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
