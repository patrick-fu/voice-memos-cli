# Domain Docs

Before exploring, read the root `CONTEXT.md` and relevant ADRs under `docs/adr/` when present. Missing files are expected and should not block work.

This is a single-context repository:

```text
/
├── CONTEXT.md
├── docs/adr/
└── src/
```

Use vocabulary defined in `CONTEXT.md`. Surface conflicts with existing ADRs instead of silently overriding them. Domain files are created lazily as terms and durable decisions crystallise.
