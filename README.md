# Voice Memos CLI (`vmemo`)

Safe, agent-friendly, read-only access to Apple Voice Memos on macOS. `vmemo` lists, searches, inspects, and exports user-owned copies of recordings; it never renames, deletes, or writes to Voice Memos.

面向 agent 的安全只读 macOS 命令行工具。`vmemo` 可列出、搜索、查看和导出录音副本；绝不重命名、删除或写入 Voice Memos。

> **Production contract / 生产契约** — v0.1.1 production data access is intentionally narrow: **macOS 26 with Voice Memos build 1380 only**. Any other environment fails closed rather than guessing at a private data format.
>
> v0.1.1 的生产数据访问刻意限定为 **macOS 26 且 Voice Memos build 1380**；其他环境会安全拒绝，不会猜测私有数据格式。

## What it does / 能力

| Command | English | 中文 |
| --- | --- | --- |
| `list` | List active recordings. | 列出活跃录音。 |
| `search --query <text>` | Case-insensitive title search only. | 仅按标题进行大小写不敏感搜索。 |
| `show --id <id>` | Inspect one recording by its opaque ID. | 通过不透明 ID 查看单条录音。 |
| `export --id <id> --output-path <path>` | Copy a supported local `.m4a` asset to a new destination. | 将受支持的本地 `.m4a` 资产复制到一个新目标路径。 |
| `doctor` | Check runtime, app, library, schema, and signing readiness. | 检查运行时、App、资料库、schema 与签名就绪状态。 |

`rename`, `delete`, transcript access, UI automation, and direct database/asset/CloudKit writes are deliberately out of scope. The tool does not use Accessibility, CGEvent, Apple Events, mutation tokens, or Voice Memos private entitlements.

`rename`、`delete`、转写访问、UI 自动化，以及直接写数据库、资产或 CloudKit 均明确不在范围内。工具不使用辅助功能、CGEvent、Apple Events、写入授权 token 或 Voice Memos 私有 entitlement。

## Install / 安装

### One-line installer (recommended) / 一行安装（推荐）

The v0.1.1 release channel is an Apple-notarized universal2 ZIP published to an immutable GitHub Release, installed by a version-pinned script. No sudo, no installer GUI, and no PKG.

v0.1.1 的发布渠道是放在不可变 GitHub Release 上的 Apple 公证 universal2 ZIP，由固定版本的安装脚本完成安装；不需要 sudo，不弹安装器，也不再使用 PKG。

```sh
curl -fsSL https://raw.githubusercontent.com/patrick-fu/voice-memos-cli/v0.1.1/install.sh | sh
```

The script installs `~/.local/bin/vmemo` and stops before writing anything unless every check passes:

脚本把 `vmemo` 安装到 `~/.local/bin/vmemo`；以下任一项不通过都会在写入前中止：

- The release is marked immutable, and `vmemo-0.1.1-macos-universal2.zip` matches its `SHA256SUMS` entry.
- The executable is signed by a `Developer ID Application` identity for `com.paaatrick.voice-memos-cli` and Team ID `9N7UKH59LC`, carries a secure timestamp and Hardened Runtime, and passes `spctl` assessment against Apple's notarization ticket.
- The binary contains both `arm64` and `x86_64` slices and reports the expected version, consistent with `provenance.json`.
- The new binary replaces an existing `vmemo` in the same directory atomically, so a failed install leaves the previous one in place.

- Release 已标记为不可变，且 `vmemo-0.1.1-macos-universal2.zip` 与 `SHA256SUMS` 记录的校验和一致。
- 可执行文件由 `Developer ID Application` 身份签名，identifier 为 `com.paaatrick.voice-memos-cli`、Team ID 为 `9N7UKH59LC`，带安全时间戳与 Hardened Runtime，并通过基于 Apple 公证票据的 `spctl` 校验。
- 二进制同时包含 `arm64` 与 `x86_64` slice，报告的版本号符合预期，并与 `provenance.json` 一致。
- 新版本在同一目录内原子替换旧 `vmemo`，安装失败不会破坏已有安装。

Prefer to read before running: download `install.sh` from the same tag, inspect it, then run `sh ./install.sh`. Keep the pinned tag instead of a mutable branch such as `main`.

建议先读再执行：从同一个 tag 下载 `install.sh`，审阅后运行 `sh ./install.sh`。请保留固定的 tag，不要改用 `main` 这类可变分支。

If `~/.local/bin` is not on your `PATH`, the installer prints the command that adds it and never edits your shell configuration. Use `VMEMO_INSTALL_DIR` for a different directory, and `VMEMO_VERSION` to select another published version.

若 `~/.local/bin` 不在 `PATH` 中，脚本只会提示应执行的 PATH 命令，不会改动 shell 配置。换安装目录用 `VMEMO_INSTALL_DIR`，选择其他已发布版本用 `VMEMO_VERSION`。

Verify a completed install / 验证安装结果：

```sh
"$HOME/.local/bin/vmemo" --version
codesign -d -vv "$HOME/.local/bin/vmemo" 2>&1 | grep -E 'Identifier|TeamIdentifier|Authority'
spctl --assess --type execute --verbose=4 "$HOME/.local/bin/vmemo"
lipo -archs "$HOME/.local/bin/vmemo"
```

Installing needs no Full Disk Access because it only writes to the install directory. macOS may ask for library access later, when `vmemo` actually reads Voice Memos data; `vmemo doctor` reports the current state.

安装过程不需要 Full Disk Access，因为它只写安装目录；之后 `vmemo` 真正读取 Voice Memos 数据时 macOS 才可能要求授权，`vmemo doctor` 会报告当前状态。

### Manual download / 手动下载

You can also download `vmemo-0.1.1-macos-universal2.zip`, `SHA256SUMS`, and `provenance.json` from [GitHub Releases](https://github.com/patrick-fu/voice-memos-cli/releases) and put the binary, which the archive holds at `vmemo-0.1.1-macos-universal2/vmemo`, anywhere on your `PATH`. A bare executable cannot carry a stapled ticket, so Gatekeeper checks the notarization ticket online on first use.

```sh
shasum -a 256 -c SHA256SUMS
```

也可以从 [GitHub Releases](https://github.com/patrick-fu/voice-memos-cli/releases) 下载 `vmemo-0.1.1-macos-universal2.zip`、`SHA256SUMS` 与 `provenance.json`，压缩包内的二进制位于 `vmemo-0.1.1-macos-universal2/vmemo`，把它放到 `PATH` 上的任意目录即可。裸可执行文件无法 staple 公证票据，因此 Gatekeeper 会在线校验公证状态。

### Build from source / 源码构建

Use a Swift 6-capable Xcode toolchain:

使用支持 Swift 6 的 Xcode 工具链：

```sh
git clone https://github.com/patrick-fu/voice-memos-cli.git
cd voice-memos-cli
swift build -c release
mkdir -p "$HOME/.local/bin"
install -m 755 .build/release/vmemo "$HOME/.local/bin/vmemo"
"$HOME/.local/bin/vmemo" --version
```

A source-built executable has no Developer ID signature and no notarization ticket. It is useful for development and review, but it is not a substitute for the signed, notarized release archive.

源码构建产物没有 Developer ID 签名，也没有公证票据，适用于开发与审阅，但不等同于已签名、公证的发布包。

## Permissions and compatibility / 权限与兼容性

- Voice Memos' group container may require **Full Disk Access** or another user-granted container permission. Grant it yourself in **System Settings → Privacy & Security**; `vmemo` cannot grant it.
- Run `doctor` before accessing recordings. It checks isolated read-only SQLite snapshot metadata and does not read recording rows.
- `list`, `search`, `show`, and `export` create an isolated SQLite snapshot, validate the exact app/model/schema contract, and fail closed on an unsupported schema, denied access, unsafe asset path, or inconsistent export.
- Only active recordings are exposed; Recently Deleted items are excluded. Export currently accepts local regular `.m4a` files only, and the destination must not already exist.
- macOS 15 may be used to build and exercise fail-closed tests, but it is **not** a supported production data path. New Voice Memos builds are unsupported until explicitly added to the contract.

- Voice Memos 的 group container 可能需要**完全磁盘访问权限**或其他用户授予的容器权限。请在**系统设置 → 隐私与安全性**中自行授权；`vmemo` 无法自行获取。
- 访问录音前先运行 `doctor`。它检查隔离的只读 SQLite snapshot metadata，不读取录音行。
- `list`、`search`、`show` 与 `export` 会创建隔离 SQLite snapshot，验证精确的 App/model/schema 契约；遇到不支持的 schema、拒绝访问、不安全的资产路径或不一致的导出时会安全拒绝。
- 仅暴露活跃录音，不包含“最近删除”。目前只可导出本地 regular `.m4a` 文件，且目标路径必须尚不存在。
- macOS 15 可用于构建和验证 fail-closed 测试，但**不是**受支持的生产数据路径。新的 Voice Memos build 必须明确加入契约后才受支持。

## Quick start / 快速开始

```sh
# Check the exact environment first / 先检查精确运行环境
vmemo doctor --json

# Discover opaque IDs; search matches titles only / 获取 opaque ID；search 仅匹配标题
vmemo list --json
vmemo search --query "<title fragment>" --json

# Reuse the returned ID exactly / 原样复用返回的 ID
vmemo show --id "<opaque-recording-id>" --json
vmemo export --id "<opaque-recording-id>" \
  --output-path "$HOME/Downloads/recording.m4a" --json
```

Treat recording IDs as opaque: do not derive them from a title, path, or database row. `search` is title-only; it does not search recording audio, transcripts, dates, or paths. `export` copies the source without modifying the Voice Memos recording.

请把 recording ID 当作不透明值：不要从标题、路径或数据库行推导它。`search` 仅搜索标题，不搜索音频、转写、日期或路径。`export` 只复制源文件，不修改 Voice Memos 中的录音。

## Agent contract / Agent 契约

Every command accepts `--json`. With `--json`, normal success writes a versioned envelope to stdout and failures write an error envelope to stderr. `doctor` is the exception: its report is always stdout, even when its status is `blocked` or `incomplete`.

所有命令均可接受 `--json`。使用 `--json` 时，通常成功结果会把带版本的 envelope 写到 stdout，失败会把 error envelope 写到 stderr。`doctor` 是例外：即使状态为 `blocked` 或 `incomplete`，报告也始终写到 stdout。

```json
{"version":1,"status":"ok","data":{}}
```

| Exit code | English | 中文 |
| --- | --- | --- |
| `0` | Success; `doctor` is `ready`. | 成功；`doctor` 为 `ready`。 |
| `2` | Usage or argument error. | 用法或参数错误。 |
| `3` | Operational/output error, such as an unknown ID or existing destination. | 运行/输出错误，例如 ID 不存在或目标已存在。 |
| `4` | Safety or adapter block, such as unsupported schema or denied access. | 安全或适配器阻断，例如 schema 不受支持或访问被拒。 |
| `5` | Partial/incomplete report. | 部分或不完整报告。 |

Agents should follow this sequence: `doctor --json` → require `data.status == "ready"` → `list` or `search` → optionally `show` → `export`. Use the returned opaque ID exactly, and inspect both the JSON `code` and the process exit code before retrying. The complete machine-readable interface, output shapes, and stable error codes are in the [agent contract](docs/agent-contract.md).

agent 应遵循：`doctor --json` → 仅在 `data.status == "ready"` 时继续 → `list` 或 `search` → 可选 `show` → `export`。必须原样使用返回的 opaque ID；重试前同时检查 JSON `code` 与进程退出码。完整的机器可读接口、输出结构和稳定错误码见 [agent contract](docs/agent-contract.md)。

## Privacy and safety / 隐私与安全

Recording titles are sensitive. Avoid putting titles, title-like queries, recording IDs, or title-bearing paths into logs, issues, transcripts, or error reports. `vmemo` returns titles only in the requested stdout payload; callers are responsible for preventing downstream disclosure.

录音标题属于敏感信息。不要把标题、疑似标题的搜索词、recording ID 或包含标题的路径写入日志、issue、转录或错误报告。`vmemo` 只会在调用方请求的 stdout payload 中返回标题；调用方负责避免后续泄露。

The implementation is read-only with respect to Voice Memos. It snapshots the library before reading, validates a narrow known schema, excludes Recently Deleted rows, constrains asset paths to the recordings root, requires a new export destination, and checks for source changes while copying.

实现对 Voice Memos 保持只读：读取前 snapshot 资料库、验证狭窄且已知的 schema、排除最近删除项、将资产路径限制在录音根目录、要求新的导出目标，并在复制时检查源文件是否发生变化。

## Development / 开发

```sh
swift test
swift build -c release
.build/release/vmemo --help
```

Tests use isolated synthetic fixtures; do not point development overrides at a real Voice Memos library. `VMEMO_RECORDINGS_ROOT` is debug/test-only, accepts only descendants of the system temporary directory, and is rejected by release builds.

测试使用隔离的合成 fixture；请勿把开发 override 指向真实 Voice Memos 资料库。`VMEMO_RECORDINGS_ROOT` 仅用于 debug/test，只接受系统临时目录的后代路径，并会被 release build 拒绝。

## Links and evidence / 链接与证据

- [Repository](https://github.com/patrick-fu/voice-memos-cli) · [Releases](https://github.com/patrick-fu/voice-memos-cli/releases) · [Release notes / 发行说明](release-notes/v0.1.1.md) · [Planning record / 规划记录](https://github.com/patrick-fu/voice-memos-cli/issues/1)
- [Documentation / 文档](docs/agent-contract.md) · [Research / 调研](docs/research)
- [Project Pages / 项目 Pages](https://patrick-fu.github.io/voice-memos-cli/)

The research notes document why private-store mutation, Accessibility-driven automation, and unverified compatibility claims are excluded from this release contract.

调研笔记说明了为何本发布契约排除私有存储写入、辅助功能驱动的自动化，以及未经验证的兼容性承诺。

## License / 许可证

[MIT](LICENSE)
