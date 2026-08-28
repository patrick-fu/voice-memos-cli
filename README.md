# Voice Memos CLI

An agent-friendly macOS CLI project for safely searching, inspecting, exporting, renaming, and deleting Voice Memos.

> Status: planning. No production CLI has been implemented yet.

The v0.1 contract is being designed around stable JSON, explicit exit codes, stdout/stderr separation, dry-run and confirmation controls, and the current plus previous major macOS versions.

## Plan

The canonical roadmap is [Plan a safe, agent-friendly macOS Voice Memos CLI](https://github.com/patrick-fu/voice-memos-cli/issues/1). Its child issues hold each decision and the evidence behind it.

Current research found no supported direct Voice Memos data API or transcript write-back interface. Direct private-store mutation is excluded; supported UI/Share paths and opt-in Shortcuts helpers are evaluated separately.

## Research

- [Voice Memos data access boundaries](docs/research/voice-memos-data-access.md)
- [Private API and community implementation survey](docs/research/private-api-community-survey.md)
- [macOS permission and automation constraints](docs/research/macos-permissions-and-automation.md)
- [SQLite snapshot and concurrency strategy](docs/research/sqlite-snapshot-strategy.md)
- [Distribution and compatibility matrix](docs/research/distribution-and-compatibility-matrix.md)
- [Test fixtures and integration isolation](docs/research/test-fixtures-and-integration-isolation.md)
- [Transcript write-back feasibility](docs/research/voice-memos-transcript-writeback.md)
- [Shortcuts bridge feasibility](docs/research/voice-memos-shortcuts-bridge.md)
