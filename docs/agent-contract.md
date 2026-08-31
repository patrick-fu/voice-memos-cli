# vmemo Agent Contract

面向 agent 的稳定 CLI 合同。构建、安装与发行验证方式见 [README](../README.md)。本文只定义 CLI 行为，不重复承诺具体分发容器或未来安装渠道。

## 命令与参数

所有命令都可选追加 `--json`。

| 命令 | 必填参数 | 说明 |
| --- | --- | --- |
| `vmemo list [--json]` | 无 | 返回 Active recordings。 |
| `vmemo search --query <text> [--json]` | `--query` | 只按 `title` 做大小写不敏感包含匹配，不检索 transcript、日期、路径或其它字段。 |
| `vmemo show --id <opaque-recording-id> [--json]` | `--id` | 返回一条 recording。ID 必须原样使用 `list`/`search` 返回的 opaque ID，不要用 title 或路径推导。 |
| `vmemo export --id <opaque-recording-id> --output-path <destination> [--json]` | `--id`, `--output-path` | 导出录音副本；目标路径必须不存在。当前生产 export 支持 `.m4a`，不修改源录音。 |
| `vmemo doctor [--json]` | 无 | 运行系统/App/library/schema/signing 预检；通过隔离的只读 SQLite snapshot 检查 metadata，不读取 recording rows。 |

未知命令、未注册的 `rename`/`delete`、`doctor --ui` 等旧接口都返回 usage error。

## stdout / stderr

- 成功：结果写到 stdout，stderr 为空。
- 失败：stdout 为空，stderr 写结果（human 模式为 `error: <message>`，`--json` 模式为 JSON error envelope）。
- usage error：如果命令行任意位置带 `--json`，stderr 写 JSON error envelope；否则为普通文本。
- `doctor` 特殊：报告总是写到 stdout，stderr 为空。非零退出的 `doctor` 不意味着 error envelope；JSON 模式下仍是一个 `status: "ok"` envelope，但 `data.status` 是 `blocked` 或 `incomplete`。

## JSON v1 Envelope

成功：

```json
{"version":1,"status":"ok","data":{...}}
```

失败：

```json
{"version":1,"status":"error","error":{"code":"<code>","message":"<message>"}}
```

### Success data shapes

`list` / `search`：

```json
{"version":1,"status":"ok","data":{"recordings":[{"id":"<opaque-id>","title":"<title>"}]}}
```

`show`：

```json
{"version":1,"status":"ok","data":{"id":"<opaque-id>","title":"<title>"}}
```

`export`：

```json
{"version":1,"status":"ok","data":{"id":"<opaque-id>","destination":"<absolute-destination>"}}
```

`doctor`：

```json
{"version":1,"status":"ok","data":{"status":"ready|blocked|incomplete","checks":[{"id":"<check-id>","status":"ready|blocked|incomplete","code":"<check-code>","details":["<detail>"]}]}}
```

`doctor` check IDs 固定为 `runtime`、`voice_memos`、`library`、`schema`、`signing`。

## Human mode output

- `list` / `search`：每行 `id<TAB>title`；空结果输出 `No recordings.`
- `show`：`id<TAB>title`
- `export`：`Exported <id> to <destination>.`
- `doctor`：首行 `Doctor: ready|blocked|incomplete`，随后每项 `check-id<TAB>status<TAB>code<TAB>details`

## Exit codes

| 退出码 | 含义 |
| --- | --- |
| `0` | 成功；`doctor` 的 `ready` 也是 `0`。 |
| `2` | usage error：参数解析、未知命令/选项、旧接口。 |
| `3` | operational/output error：目标不存在、目标已存在、输出编码失败、doctor probe 失败等。 |
| `4` | safety/adapter block：schema 不支持、snapshot 或 asset 安全拒绝、权限/访问被拒。 |
| `5` | partial/incomplete result；当前主要来自 `doctor` 的非完整报告。 |

## Stable error codes

以下为当前源码实际导出的 error envelope `error.code` 与默认 exit code。

| code | exit | 含义与动作 |
| --- | --- | --- |
| `usage_error` | 2 | 参数不可解析；检查命令/选项与 `--json` 位置。 |
| `recording_not_found` | 3 | `show`/`export` 的 ID 不在当前 Active 投影中；重新用 `list`/`search` 取 exact opaque ID。 |
| `destination_exists` | 3 | export 目标已存在；换新路径。 |
| `destination_unavailable` | 3 | export 目标父目录不可用或路径非法；确认目标目录存在且可写。 |
| `doctor_probe_failed` | 3 | doctor 无法完成检查；检查运行环境和系统状态后重试。 |
| `output_encoding_failed` | 3 | JSON 输出编码失败；可重试，属输出层故障。 |
| `adapter_operation_failed` | 3 | 未归类 adapter 故障；按具体 stderr 信息排查。 |
| `invalid_recordings_root` | 4 | debug/test root override 非法，或 release build 收到该 override；移除变量或使用系统临时目录下的隔离 fixture。 |
| `unsupported_os` | 4 | 当前生产 adapter 只支持 macOS 26；macOS 15 仅用于编译和 fail-closed 验证。 |
| `production_artifacts_missing` | 4 | Voice Memos App 或固定 model artifact 缺失/不可读。 |
| `invalid_model_evidence` | 4 | Voice Memos model/version evidence 与 exact build contract 不符。 |
| `unsupported_schema` | 4 | 不是 exact macOS 26 / Voice Memos build 1380 / VoiceMemos14 契约，或 snapshot schema 不匹配；检查运行环境和 Voice Memos build。 |
| `snapshot_creation_failed` | 4 | 临时 SQLite snapshot 创建失败；常见原因是 library/FDA/容器权限、DB 被锁或 snapshot 工具失败。 |
| `snapshot_cleanup_failed` | 4 | 临时 snapshot 清理失败；安全失败，保留错误上下文。 |
| `asset_unavailable` | 4 | 本地 asset 引用缺失或文件不可读；常见为 iCloud 外置/未下载或路径失效。 |
| `path_outside_recordings_root` | 4 | asset 路径逃逸 recordings root；按安全策略拒绝，不读出目标。 |
| `not_regular_file` | 4 | asset 不是 regular file；拒绝复制。 |
| `unsupported_asset_format` | 4 | asset 格式不支持；当前生产 export 只接受 `.m4a` 路径。 |
| `export_inconsistent` | 4 | 复制期间源文件改变；源哈希/元数据校验失败。 |
| `export_cleanup_failed` | 4 | 部分导出临时文件无法删除；安全失败并报告。 |
| `access_denied_unattributed` | 4 | 源或目标打开失败为 `EACCES`/`EPERM`；需要用户在 System Settings 中授予 Full Disk Access 或容器权限。 |

源码 runner 另有 `adapter_not_configured`（exit 4），但标准 production composition 下通常表现为 `unsupported_schema`。

`doctor` 的稳定 check code：

- `runtime_supported`, `unsupported_os`, `unsupported_architecture`
- `app_available`, `voice_memos_app_missing`, `unsupported_voice_memos_build`
- `library_accessible`, `library_not_configured`, `library_path_missing`, `library_path_inaccessible`
- `schema_recognized`, `schema_not_configured`, `unsupported_schema`, `snapshot_creation_failed`, `snapshot_cleanup_failed`
- `invalid_recordings_root`, `production_artifacts_missing`, `invalid_model_evidence`（production configuration failure 也由 `schema` check 报告）
- `signing_metadata_available`, `signing_metadata_unavailable`

`schema_recognized` 只证明隔离 snapshot 的 Core Data metadata 与 exact contract 匹配；各读取命令仍会为本次操作重新创建 snapshot 并执行完整 schema/row/asset gate。

## 推荐 agent 流程

1. 先跑 `vmemo doctor --json`。只有 `data.status == "ready"` 才继续；`blocked` 表示当前环境不满足生产准入，`incomplete` 表示诊断证据不完整。
2. 用 `vmemo list --json` 或 `vmemo search --query <text> --json` 获取 exact opaque recording ID。`search` 只匹配 `title`。
3. 需要确认目标时先用 `vmemo show --id <id> --json`。
4. 导出用 `vmemo export --id <id> --output-path <dest> --json`；目标必须不存在，产物为 `.m4a` 副本。

## 敏感性与日志

Recording title 是敏感字段。CLI 只把 title 放进调用方请求的 stdout payload；agent 不得再把 title、疑似 title 的搜索词或含标题的路径复制进日志、issue、transcript 或错误上下文。日志建议只保留命令名、参数名、输出路径、exit code 与 error code。
