# 隔离 fixtures 与集成测试架构

> **当前产品决策（2026-08-30）：** `voice-memos-cli` 当前是安全只读检索/导出 CLI，只支持 `list/search/show/export/doctor`；不支持 `rename/delete`，不要求也不使用 Accessibility、CGEvent、mutation token 或 Shortcuts 写后端。本文是研究/历史证据，记录既有调研与失败路径，不作为当前实现计划。

研究日期：2026-08-28。目标是让未来 Swift CLI 能在**完全不接触真实 Voice Memos 库、iCloud 数据、用户 Shortcut 或真实 UI mutation**的条件下，构建、回归和发布。本文是 build-ready 测试设计，不是对私有 schema 的兼容承诺。

## 当前只读测试架构与已废止的 mutation 设计

**当前结论：**采用「合成 SQLite/Core Data-shaped fixture + 明确 read/asset ports」测试只读检索与导出。下文的 AX 状态机 fake、`RecordingWritePort`、token 和 mutation 人工 gate 是早期设计，已经废止；保留仅用于说明当时的隔离边界，不代表当前源码或测试布局。

| 标记 | 本文含义 |
| --- | --- |
| **证据** | 可由 SQLite/Apple 官方资料或仓库既有研究直接支持。 |
| **工程推论** | 为满足项目安全契约而作的设计选择。 |
| **需实机验证** | synthetic test 不能证明，且不得在真实用户库上验证。 |

当前仍有效的词汇约束是：fixture 的 `Recording ID` 是 opaque selector，绝不由 Title、数据库 row ID 或 asset path 推导。[CONTEXT.md](../../CONTEXT.md)

## 证据与不可跨越边界

- **证据：**Voice Memos 的 `CloudRecordings.db`、`ZCLOUDRECORDING`、`ZUNIQUEID`、`.m4a`、`.qta`、WAL 和 CloudKit mirror 都是当前系统观察到的私有实现，不是第三方 API；schema 与资产状态必须 runtime preflight、版本白名单和 fail-closed。[数据访问研究](voice-memos-data-access.md)
- **证据：**WAL reader 看到一致 end mark；`sqlite3_backup` 完成后提供最后一次有效 start/restart 的一致 snapshot。只读 WAL 打开仍可能涉及 `-shm`，`immutable=1` 只适用于绝不会变化的文件，`nolock=1` 不可使用。[SQLite snapshot 研究](sqlite-snapshot-strategy.md)、[SQLite WAL](https://www.sqlite.org/wal.html)、[Backup API](https://www.sqlite.org/backup.html)
- **证据：**Apple 未提供普通第三方 CLI 可用的 Voice Memos store/XPC 契约；直接 SQL/asset/CloudKit 写入不进入产品路径。[私有 API 调研](private-api-community-survey.md)
- **证据：**原生 `AXUIElement` 的 trust 是当前进程的状态，且 UI tree/action 没有稳定 Voice Memos 合约；token、显式确认与每项 fresh pre/post verification 是现有 v0.1 约束。[权限与自动化研究](macos-permissions-and-automation.md)、[AXIsProcessTrustedWithOptions](https://developer.apple.com/documentation/applicationservices/1459186-axisprocesstrustedwithoptions)
- **工程推论：**任何能以真实路径、真实标题、真实音频、真实 Apple Account 或运行的 Voice Memos 为输入的测试，都不属于 CI，也不属于普通开发机自动测试。

## 目录与 fixture 生产规则

未来实现按下列布局；`Generated/` 一律由 test support 生成，禁止提交从任何 Apple/用户目录复制的二进制。

```text
Tests/
  Support/
    FixtureFactory.swift              # 仅创建 synthetic DB、asset、时钟、临时目录
    SQLiteFixtureBuilder.swift        # 建 schema、WAL、恶意路径/损坏变体
    FakeAccessibilityClient.swift     # 状态机，不连 AXUIElement
    GoldenAssert.swift
  Fixtures/
    schemas/
      fixture-revision-N.sql          # synthetic Core Data-shaped revision；非真实 schema
      unknown-forward.sql             # 未知表/列或不支持 revision
      malformed.sql                   # 缺表、缺列、错误 type
    assets/
      generated-m4a/                  # 测试启动时生成的短静音 AAC
      generated-qta/                  # 测试启动时生成的最小 QuickTime 容器
    goldens/
      help/ json/ errors/
  VoiceMemosCLITests/
  VoiceMemosCLIIntegrationTests/      # 只接 fake ports 与 synthetic filesystem
  VoiceMemosCLIManualAcceptance/      # 不编入 CI；仅操作手册与签名二进制 harness
```

`FixtureFactory` 在每个 test case 的 `mkdtemp` 风格 `0700` 根目录创建文件；DB、WAL、资产和 export destination 都以 `0600` 创建，并在 `defer` 中删除。测试失败时仅保留随机 run ID 的临时目录，永不把 Title、Recording ID、音频 bytes 或绝对路径写入日志。

### synthetic schema 与资产

| fixture 类别 | 内容与生成方式 | 覆盖的结论 |
| --- | --- | --- |
| `fixture-revision-N` | `sqlite3`/Swift SQLite wrapper 在临时目录执行版本化 DDL；只保留 adapter 实际读取的 `ZCLOUDRECORDING`、`ZFOLDER`、必要 metadata 与代表性 `ANSCK*` 名称。每个 manifest 显式写 `provenance: synthetic`、`targetOsMajor: 15 | 26`；它只表示测试目标，绝不声称是该系统的真实 schema。插入固定的非语义 UUID（如 `11111111-...`），从不使用 `Z_PK` 作为 CLI ID。 | allowlist、列映射、ID opaque 性、current/previous schema adapter。 |
| revision fault | 缺 required column、改 type、unknown `schema_version`、同名 title、NULL/空 path、重复或无效 UUID。 | 只输出 `unsupported_schema`/结构错误；不猜列或按 title 选目标。 |
| static/WAL | factory 以 SQLite API（绝不手工伪造 sidecar）分别生成并在 manifest 记录 `journalState`、`reason` 和 directory entries：`clean-close-db-only`（所有连接正常 close/checkpoint）；`expected-wal-absent`（该 case 未产生 WAL，明确记录其生成原因，不能误诊为损坏）；`active-db-wal-shm`；`wal-truncated-or-corrupt`（故意截断/损坏，只能安全拒绝）；以及锁持有与持续写入。另包括「DB+WAL、无 `-shm`、source directory 不可写」：`mode=ro`/backup 失败关闭，且不得以 `immutable=1`/`nolock=1` 回退。 | 各 journal 判定原因、backup deadline/restart、`BUSY`、`LOCKED` fail-closed、清理与 source 无写入。 |
| `.m4a` | test support 用 `AVAssetWriter` 或同一 Swift 音频 fixture builder 在运行时写 100–250 ms 静音 AAC；只验证 header/复制/AVFoundation 可读时才启用相关断言。 | export 的 regular-file、size/hash、扩展名和命名，不依赖 Apple 录音内容。 |
| `.qta` | 默认只生成带 `ftypqt` 的最小非内容 QuickTime 容器，测试 extension、path guard 和 unsupported result；需要 AVFoundation 打开时，由 fixture builder 在测试时生成合法的短容器，否则该测试跳过并标记 capability。 | `.qta` 不被当作 `.m4a`，未知/不支持格式 fail-closed。 |
| iCloud/安全路径 | DB 行仅放 synthetic `ZPATH`：空值、缺文件、symlink、`../outside`、绝对外部路径、directory、FIFO 与改变中的普通文件。 | `asset_unavailable`、`path_outside_recordings_root`、`not_regular_file`，且不读取外部目标。 |

**工程推论：**fixture DDL 要刻意是 *Core Data-shaped*，不是声称复刻真实 `.mom`、CloudKit record 或加密字段。每个 revision 有 manifest：`provenance: synthetic`、`targetOsMajor`、schema token、required tables/columns、允许的 asset policy、生成器版本。adapter 仅接受 manifest 列出的组合；新 macOS 或新 schema 先进入 `unknown-forward`，不得让测试数据把未知真实 schema “测试通过”。

**需实机验证：**macOS 15/26 的真实 schema token、sidecar 行为、`.qta` 的完整媒体兼容性及 iCloud placeholder 的精确表现；验收只记录版本、状态和错误码，不能将真实库复制回 fixtures。

## 可测试的 ports 与 adapters

业务命令只能依赖以下 Swift protocols；私有 SQLite、filesystem、时钟、token 和 AX 均在边缘实现。这样 unit/integration test 可替换每个风险面。

```text
RecordingReadPort      list/show/search(snapshot) -> [RecordingSummary]
SnapshotPort           makeSnapshot(source) -> SnapshotHandle
AssetReadPort          resolveAndCopy(recordingID, destination) -> ExportResult
SchemaAdapter          detect(snapshot) -> SupportedSchema | unsupportedSchema
RecordingWritePort     issueTarget / dryRun / execute(request) -> MutationResult
AccessibilityClient    inspect / press / focusedWindow / appIdentity
Clock, TokenStore, FileSystem, ProcessIdentity
```

- `RecordingSummary` 只带 opaque `RecordingID`、稳定状态与经协议允许的显示字段；SQL row/`Z_PK`、Title 和 path 都不能逃逸为 mutation selector。
- `SchemaAdapter` 按 manifest dispatch，SQL 只在该 adapter 内；每个 fixture revision 对应一组 contract tests。unknown adapter 必须拒绝。
- `SnapshotPort` 使用源 `mode=ro` + `sqlite3_backup`；factory 让 source 和 destination 分离。每次测试保存 source DB、parent directory、`-wal`/`-shm` 的存在性与 metadata：主 DB 不得被修改；destination 的 spill/journal 只在 fixture root。source sidecar 的协调行为只记录并在隔离实机 gate 判定政策；唯独「DB+WAL、无 SHM、目录不可写」必须失败且 source directory entries/metadata 不变。
- `AssetReadPort` 先 canonicalize、再验证仍位于 recordings root、是 regular file，打开后以 FD copy，并在前后验证 size/mtime 或 hash；永不信任 SQL `ZPATH`。
- `RecordingWritePort` 是逻辑 write port，**没有** SQLite write method。production 仅由 AX adapter 实现；所有其它 tests 只注入 fake。

### AX seam 与 fake 状态机

`AccessibilityClient` 只暴露语义化 queries/action，例如 `locateVerifiedTarget(binding:)`、`rename(to:)`、`moveToRecentlyDeleted()`、`observePostcondition()`；production adapter 自己把这些映射到 AX roles/actions，业务层不保留 element index 或 AX object。

`FakeAccessibilityClient` 是确定性状态机：

```text
untrusted | appMissing | windowMissing | ambiguousTarget | modalOpen
  -> verified(tokenBinding) -> pressed -> postVerified
                           \-> focusDrift | timeout | cannotComplete | noPostcondition
```

每个 transition 记录无敏感 event ID。contract test 覆盖：precondition 失败不 press、press 后无法 post-verify 仍为失败、title/排序变化导致 binding 不唯一即停止、`delete` 只到 `recentlyDeleted` 状态。**需实机验证：**真实 AX hierarchy、语言、焦点/锁屏/SSH 行为与 TCC identity；fake 只验证项目协议，不能证明 App 可操作。

## 测试金字塔

| 层 | 运行位置 | 主要对象 | 必测项 |
| --- | --- | --- | --- |
| Unit（多数） | macOS CI | XCTest/Swift Testing：schema mapping、opaque ID、path validation、token store、exit mapping、JSON encoder、AX state-machine | 全部失败分支、无真实文件容器/AX 调用。 |
| Fixture contract | macOS CI | SQLiteFixtureBuilder + `SnapshotPort`/`SchemaAdapter`/`AssetReadPort` | revision、WAL/sidecar、backup 超时、Temp spill、路径/iCloud、`.m4a/.qta` policy。 |
| Fake integration | macOS CI | CLI command → ports → stdout/stderr/exit | JSON/golden、dry-run、token expiry/replay、batch partial、cleanup。 |
| Signed manual acceptance（最少） | 独立 macOS 用户 | 已签名/公证 artifact + disposable Voice Memos | FDA/AX/TCC、真实 schema/asset、UI 语义和回归探测。 |

测试固定随机数、clock、locale、timezone、home/tmp root 和 Voice Memos build token。golden 只比较稳定 JSON（键排序、路径替换为 `<fixture-root>`、token 替换为 `<token>`）；stdout 只含 JSON，stderr 只含诊断，exit code 是 contract。至少提交这些 golden：`--help`、空列表、单条 `show`、`unsupported_schema`、`asset_unavailable`、`path_outside_recordings_root`、`mutation_preflight_failed`、`token_expired`、`token_replayed`、`partial`。每个 code 都有 success/usage/operational/safety-failure 的稳定数值表；修改须显式 golden review，不能靠 snapshot 自动更新。

**证据：**Xcode 以 XCTest/XCUIAutomation 支持 unit、integration 和 UI test；此处只让 XCTest/Swift Testing 覆盖逻辑与 fixture，真实 UI automation 保留给人工 acceptance，以免测试 runner 变成 TCC/桌面状态的代理。[Adding tests to your Xcode project](https://developer.apple.com/documentation/xcode/adding-tests-to-your-xcode-project)、[XCUIApplication](https://developer.apple.com/documentation/xcuiautomation/xcuiapplication)

为避免并发测试偶发通过，`SQLiteFixtureBuilder` 还提供独立 writer worker + 双向 barrier，以及 test-only backup-step driver/fault injection。每个 `BUSY`、`LOCKED`、连续 restart、page-progress 上限和 deadline case 都强制到达对应分支；assert `sqlite3_backup_finish` 后 destination 不被消费、所有连接关闭、fixture cleanup 完成。dedicated read-only source 的 `LOCKED` 一律 fail-closed，绝不 retry；这实现既有 snapshot 策略的有界退避与终止要求。[SQLite snapshot 研究](sqlite-snapshot-strategy.md)

## 操作协议：dry-run、token 与 batch

| 场景 | deterministic test | 预期 |
| --- | --- | --- |
| `dry-run rename/delete` | fake 已 verified，执行 dry-run | 返回计划和绑定摘要；不调用 `press`、不消费可执行 token、不会生成 TCC/AX prompt。 |
| 发行 | 固定 clock 与随机源 | token 绑定 action、opaque ID、环境指纹、fresh verification nonce；Title、row ID、旧 AX element 均不能授权。 |
| expiry/replay/tamper | clock 前进、第二次提交、改 action/ID/environment | 分别 `token_expired`、`token_replayed`、`token_binding_mismatch`；均零 UI press。 |
| 单条 execute | fake `verified -> pressed -> postVerified` | 仅成功 postcondition 才 `completed`；异常/焦点漂移后 fail-closed。 |
| batch | 三项，第二项 postcondition 失败 | 严格串行，输出 `status: partial`、`completed`、`failed`、`notAttempted` 与稳定错误码；第三项不得被尝试。 |

这是对现有 token/serial/pre-post 要求的 test 化，而非新增产品承诺。[权限与自动化研究](macos-permissions-and-automation.md)

## current/previous macOS 与验收矩阵

当前项目基线为 Tahoe 26，前一主版本为 Sequoia 15；这两个版本都必须跑同一 source revision 的 synthetic suite。真实 App Intent、private schema 与 UI 不被视为跨版本 contract。[数据访问研究](voice-memos-data-access.md)、[Shortcuts bridge 研究](voice-memos-shortcuts-bridge.md)

CI 的 exact jobs 是 `macos-15`、`macos-15-intel`、`macos-26`、`macos-26-intel`。每个 job 固定一个已审阅且兼容其 OS 的 Xcode build（通过固定版本/`DEVELOPER_DIR`，不使用 `latest`），并在结果记录 Xcode build。任一指定 runner 或该 Xcode 不可用时，必须显式转入同 OS 的 self-hosted runner；若仍不可用，release gate 转为 signed manual gate 并标红待验收，**不得**静默 skip、降级到另一 OS 或宣称矩阵已通过。

| 能力/场景 | CI：15 | CI：26 | 签名人工：15/26 | 通过条件 |
| --- | --- | --- | --- |
| build、unit、golden、fake AX | 必须 | 必须 | 不适用 | deterministic 通过。 |
| supported/unknown schema、DB-only/WAL/SHM、`DB+WAL` 无 SHM 且目录不可写、busy/lock、backup cleanup/temp spill | 必须 | 必须 | 可抽样复核 | source DB 不变；缺 SHM case 无 source sidecar 改动且安全失败；上限后无残留敏感文件。 |
| `.m4a`/`.qta`、empty path、iCloud-unavailable、traversal/symlink | 必须 | 必须 | 必须 | 只能复制 root 内已本地化 regular asset；拒绝不泄露路径。 |
| FDA、TCC、AX UI、Voice Memos build/schema、Homebrew identity | 禁止 | 禁止 | 必须 | 明确授权后才测；只记录版本/状态/错误码。 |
| rename/delete pre/post、Recently Deleted、语言/窗口/modal/focus | fake only | fake only | 必须 | token/confirmation/unique target/postcondition 全部成立；否则无操作。 |
| iCloud sync、CloudKit、private store write、permanent delete | 禁止 | 禁止 | 禁止 | 不存在测试路径。 |

### 签名人工 acceptance 环境

仅为验证 production seam，创建 disposable macOS 用户；iCloud 保持关闭或使用无真实数据的独立 Apple Account；只录制短、非敏感、可丢弃音频。安装当前签名 artifact，记录 `sw_vers`、Voice Memos build、CLI signing identity、schema manifest 命中与结果码。先验证只读 snapshot/export，再验证单条 rename/delete 的 token、显式确认与 pre/post；每次失败立即停止，不尝试私有 SQL、XPC、System Events/JXA fallback 或回滚写入。结束后退出 App、删除 export/snapshot/temp/fixture 并销毁整个 disposable 用户；不得经 CLI、AX 或 UI 测试清空 Recently Deleted。iCloud 禁用时不得重新开启同步来“确认”结果。

**需实机验证：**该环境下 FDA、Accessibility、notarization/Homebrew 路径与 TCC identity 的实际组合，以及 macOS 15/26 UI 语义。它们是 release gate 的证据，不是 CI 成功的替代品。

## CI 禁止项与隐私清理

CI、unit、fixture 和 fake integration **绝不**：读取 `~/Library/Containers` 或 Voice Memos group container；启动/控制 Voice Memos、Shortcuts、`osascript` 或 `AXUIElement`；登录 iCloud；请求/重置 TCC/FDA/Accessibility；下载/上传媒体；使用 Apple/用户音频或数据库；连接私有 XPC；写 `CloudRecordings.db`、`ANSCK*`、asset 或 CloudKit；或触发 Permanent Delete。

CI 仅用 ephemeral macOS runner、fixture-local `TMPDIR`/`SQLITE_TMPDIR`、`0700` root 和 `0600` files。test teardown 关闭所有 SQLite/FD/AVFoundation handles 后递归删除 root；suite startup 只清扫带本项目随机 prefix、可证明无人使用且超过 TTL 的旧 fixture root。失败 artifact 只上传 sanitized JSON/golden diff、OS/SQLite/Xcode version 和 error code；不上传 DB/WAL/SHM、媒体、完整路径、token、Title、Recording ID 或 hash of real data。若清理失败，CI 失败并只报告 run ID。

## 实施顺序与完成标准

1. 先实现 ports、clock/random/filesystem injection 与 `SQLiteFixtureBuilder`，再实现任何真实 adapter。
2. 为每个 schema manifest 写 adapter contract + unknown-revision refusal；用 DB-only/WAL/sidecar/锁/持续写入 fixture 建立 `sqlite3_backup` 上限测试。
3. 加入 path/iCloud/asset policy 和 help/JSON/error/exit golden；随后加入 token/batch/AX fake state-machine。
4. 只有 CI 绿且 release artifact 已签名时，才执行隔离人工矩阵；任何新 schema/UI 差异先新增 synthetic revision 与 fail-closed test，再决定是否支持。

完成验收：两版 macOS CI 的全部 deterministic suite 通过；任意 fixture 均不能访问 fixture root 之外的文件；golden 覆盖安全失败；`git diff --check` 通过；手工 gate 只产生无敏感数据的版本/状态/结果记录。真实 Voice Memos 兼容性只能标为“已在某个隔离矩阵验证”，不能由 fixture 结果推导。
