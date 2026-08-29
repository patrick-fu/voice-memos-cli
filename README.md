# Voice Memos CLI

An agent-friendly macOS CLI project for safely searching, inspecting, exporting, renaming, and deleting Voice Memos.

> Status: production read and `.m4a` export are enabled only for the exact macOS 26 / Voice Memos build 1380 contract. Every other OS, build, store manifest, physical schema, or row-value shape fails closed. Mutations remain unconfigured.

The v0.1 contract is being designed around stable JSON, explicit exit codes, stdout/stderr separation, dry-run and confirmation controls, and the current plus previous major macOS versions.

`list`, `search`, `show`, and `export` first create a temporary SQLite snapshot, then validate the exact bundle identity, Core Data persistent-store metadata, and 29-column `ZCLOUDRECORDING` schema. Only rows whose `ZEVICTIONDATE` is SQLite `NULL` are exposed. `VMEMO_RECORDINGS_ROOT` is a test-only root override; subprocess tests must always set it to an isolated fixture directory.

## Plan

The completed design roadmap is [Plan a safe, agent-friendly macOS Voice Memos CLI](https://github.com/patrick-fu/voice-memos-cli/issues/1). Its child issues hold each decision and the evidence behind it.

Current research found no supported direct Voice Memos data API or transcript write-back interface. Direct private-store mutation is excluded; supported UI/Share paths and opt-in Shortcuts helpers are evaluated separately.

The release target is macOS 15.0+, distributed as a universal2 signed, notarized, and stapled PKG. The same PKG will be available through a project-owned Homebrew cask; source builds remain a secondary developer path.

## Research

- [Voice Memos data access boundaries](docs/research/voice-memos-data-access.md)
- [Private API and community implementation survey](docs/research/private-api-community-survey.md)
- [macOS permission and automation constraints](docs/research/macos-permissions-and-automation.md)
- [SQLite snapshot and concurrency strategy](docs/research/sqlite-snapshot-strategy.md)
- [Distribution and compatibility matrix](docs/research/distribution-and-compatibility-matrix.md)
- [Test fixtures and integration isolation](docs/research/test-fixtures-and-integration-isolation.md)
- [Transcript write-back feasibility](docs/research/voice-memos-transcript-writeback.md)
- [Shortcuts bridge feasibility](docs/research/voice-memos-shortcuts-bridge.md)

## License

[MIT](LICENSE)
