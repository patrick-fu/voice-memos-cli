# Voice Memos CLI (`vmemo`)

> **🌐 产品主页：[https://patrick-fu.github.io/voice-memos-cli/](https://patrick-fu.github.io/voice-memos-cli/)**

[English](README.md) · **简体中文**

面向 agent 的安全只读 macOS 命令行工具。`vmemo` 可列出、搜索、查看和导出录音副本；绝不重命名、删除或写入 Voice Memos。

> **生产契约**：v0.1.2 的生产数据访问刻意限定为 **macOS 26 且 Voice Memos build 1380**；其他环境会安全拒绝，不会猜测私有数据格式。

## 能力

| 命令 | 说明 |
| --- | --- |
| `list` | 列出活跃录音。 |
| `search --query <text>` | 仅按标题进行大小写不敏感搜索。 |
| `show --id <id>` | 通过不透明 ID 查看单条录音。 |
| `export --id <id> --output-path <path>` | 将受支持的本地 `.m4a` 资产复制到一个新目标路径。 |
| `doctor` | 检查运行时、App、资料库、schema 与签名就绪状态。 |

`rename`、`delete`、转写访问、UI 自动化，以及直接写数据库、资产或 CloudKit 均明确不在范围内。工具不使用辅助功能、CGEvent、Apple Events、写入授权 token 或 Voice Memos 私有 entitlement。

## 安装

### 一行安装（推荐）

v0.1.2 的发布渠道是放在不可变 GitHub Release 上的 Apple 公证 universal2 ZIP，由固定版本的安装脚本完成安装；不需要 sudo，不弹安装器，也不再使用 PKG。

```sh
curl -fsSL https://raw.githubusercontent.com/patrick-fu/voice-memos-cli/v0.1.2/install.sh | sh
```

脚本把 `vmemo` 安装到 `~/.local/bin/vmemo`；以下任一项不通过都会在写入前中止：

- Release 已标记为不可变，且 `vmemo-0.1.2-macos-universal2.zip` 与 `SHA256SUMS` 记录的校验和一致。
- 可执行文件由 `Developer ID Application` 身份签名，identifier 为 `com.paaatrick.voice-memos-cli`、Team ID 为 `9N7UKH59LC`，带安全时间戳与 Hardened Runtime，并满足 `codesign` 在线 `notarized` 要求。
- 二进制同时包含 `arm64` 与 `x86_64` slice，报告的版本号符合预期，并与 `provenance.json` 一致。
- 新版本在同一目录内原子替换旧 `vmemo`，安装失败不会破坏已有安装。

建议先读再执行：从同一个 tag 下载 `install.sh`，审阅后运行 `sh ./install.sh`。请保留固定的 tag，不要改用 `main` 这类可变分支。

若 `~/.local/bin` 不在 `PATH` 中，脚本只会提示应执行的 PATH 命令，不会改动 shell 配置。换安装目录用 `VMEMO_INSTALL_DIR`，选择其他已发布版本用 `VMEMO_VERSION`。

验证安装结果：

```sh
"$HOME/.local/bin/vmemo" --version
codesign -d -vv "$HOME/.local/bin/vmemo" 2>&1 | grep -E 'Identifier|TeamIdentifier|Authority'
codesign -vvvv -R='notarized' --check-notarization "$HOME/.local/bin/vmemo"
lipo -archs "$HOME/.local/bin/vmemo"
```

安装过程不需要 Full Disk Access，因为它只写安装目录；之后 `vmemo` 真正读取 Voice Memos 数据时 macOS 才可能要求授权，`vmemo doctor` 会报告当前状态。

### 手动下载

也可以从 [GitHub Releases](https://github.com/patrick-fu/voice-memos-cli/releases) 下载 `vmemo-0.1.2-macos-universal2.zip`、`SHA256SUMS` 与 `provenance.json`，压缩包内的二进制位于 `vmemo-0.1.2-macos-universal2/vmemo`，把它放到 `PATH` 上的任意目录即可。裸可执行文件无法 staple 公证票据，因此 Gatekeeper 会在线校验公证状态。

```sh
shasum -a 256 -c SHA256SUMS
```

### 源码构建

使用支持 Swift 6 的 Xcode 工具链：

```sh
git clone https://github.com/patrick-fu/voice-memos-cli.git
cd voice-memos-cli
swift build -c release
mkdir -p "$HOME/.local/bin"
install -m 755 .build/release/vmemo "$HOME/.local/bin/vmemo"
"$HOME/.local/bin/vmemo" --version
```

源码构建产物没有 Developer ID 签名，也没有公证票据，适用于开发与审阅，但不等同于已签名、公证的发布包。

## 权限与兼容性

- Voice Memos 的 group container 可能需要**完全磁盘访问权限**或其他用户授予的容器权限。请在**系统设置 → 隐私与安全性**中自行授权；`vmemo` 无法自行获取。
- 访问录音前先运行 `doctor`。它检查隔离的只读 SQLite snapshot metadata，不读取录音行。
- `list`、`search`、`show` 与 `export` 会创建隔离 SQLite snapshot，验证精确的 App/model/schema 契约；遇到不支持的 schema、拒绝访问、不安全的资产路径或不一致的导出时会安全拒绝。
- 仅暴露活跃录音，不包含“最近删除”。目前只可导出本地 regular `.m4a` 文件，且目标路径必须尚不存在。
- macOS 15 可用于构建和验证 fail-closed 测试，但**不是**受支持的生产数据路径。新的 Voice Memos build 必须明确加入契约后才受支持。

## 快速开始

```sh
# 先检查精确运行环境
vmemo doctor --json

# 获取 opaque ID；search 仅匹配标题
vmemo list --json
vmemo search --query "<title fragment>" --json

# 原样复用返回的 ID
vmemo show --id "<opaque-recording-id>" --json
vmemo export --id "<opaque-recording-id>" \
  --output-path "$HOME/Downloads/recording.m4a" --json
```

请把 recording ID 当作不透明值：不要从标题、路径或数据库行推导它。`search` 仅搜索标题，不搜索音频、转写、日期或路径。`export` 只复制源文件，不修改 Voice Memos 中的录音。

## Agent 契约

所有命令均可接受 `--json`。使用 `--json` 时，通常成功结果会把带版本的 envelope 写到 stdout，失败会把 error envelope 写到 stderr。`doctor` 是例外：即使状态为 `blocked` 或 `incomplete`，报告也始终写到 stdout。

```json
{"version":1,"status":"ok","data":{}}
```

| 退出码 | 含义 |
| --- | --- |
| `0` | 成功；`doctor` 为 `ready`。 |
| `2` | 用法或参数错误。 |
| `3` | 运行/输出错误，例如 ID 不存在或目标已存在。 |
| `4` | 安全或适配器阻断，例如 schema 不受支持或访问被拒。 |
| `5` | 部分或不完整报告。 |

agent 应遵循：`doctor --json` → 仅在 `data.status == "ready"` 时继续 → `list` 或 `search` → 可选 `show` → `export`。必须原样使用返回的 opaque ID；重试前同时检查 JSON `code` 与进程退出码。完整的机器可读接口、输出结构和稳定错误码见 [agent contract](docs/agent-contract.md)。

## 隐私与安全

录音标题属于敏感信息。不要把标题、疑似标题的搜索词、recording ID 或包含标题的路径写入日志、issue、转录或错误报告。`vmemo` 只会在调用方请求的 stdout payload 中返回标题；调用方负责避免后续泄露。

实现对 Voice Memos 保持只读：读取前 snapshot 资料库、验证狭窄且已知的 schema、排除最近删除项、将资产路径限制在录音根目录、要求新的导出目标，并在复制时检查源文件是否发生变化。

## 开发

```sh
swift test
swift build -c release
.build/release/vmemo --help
```

测试使用隔离的合成 fixture；请勿把开发 override 指向真实 Voice Memos 资料库。`VMEMO_RECORDINGS_ROOT` 仅用于 debug/test，只接受系统临时目录的后代路径，并会被 release build 拒绝。

## 链接与证据

- [代码仓库](https://github.com/patrick-fu/voice-memos-cli) · [GitHub Releases](https://github.com/patrick-fu/voice-memos-cli/releases) · [发行说明](release-notes/v0.1.2.md) · [规划记录](https://github.com/patrick-fu/voice-memos-cli/issues/1)
- [文档](docs/agent-contract.md) · [调研](docs/research)
- [项目 Pages](https://patrick-fu.github.io/voice-memos-cli/)

调研笔记说明了为何本发布契约排除私有存储写入、辅助功能驱动的自动化，以及未经验证的兼容性承诺。

## 许可证

[MIT](LICENSE)
