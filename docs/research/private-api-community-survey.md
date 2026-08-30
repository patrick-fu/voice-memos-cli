# macOS Voice Memos 私有 API 与社区实现调研

> **当前产品决策（2026-08-30）：** `voice-memos-cli` 当前是安全只读检索/导出 CLI，只支持 `list/search/show/export/doctor`；不支持 `rename/delete`，不要求也不使用 Accessibility、CGEvent、mutation token 或 Shortcuts 写后端。本文是研究/历史证据，记录既有调研与失败路径，不作为当前实现计划。

研究日期：2026-08-28；范围仅限 `list/search/show/export/rename/delete`。未读取或修改本机 Voice Memos 用户容器、未调用 XPC、未注入、未运行社区脚本。**转写不作为能力依据**，只在项目矩阵与 `.m4a/.qta` 资产格式风险中标明边界，不讨论转写或回写设计。

## 结论摘要

**没有证据表明仅依赖公开 SDK、普通 Developer ID 签名的 Swift CLI，能可靠调用 Voice Memos 私有 framework/XPC。** 当前系统确有 `com.apple.voicememod.xpc` 与 `com.apple.voicememod.datastore.Cloud`，也能从二进制看到 `SavedRecordingService`、`RCXPCStoreServer` 等 Objective-C 名称；但这只是实现线索。Voice Memos.app 自己声明 `com.apple.private.voicememod.client`、application group、私有 Mach lookup、CloudKit 和 TCC entitlement。Apple 说明 restricted entitlement 需由 Apple provisioning profile/信任链授权；本调查没有找到 Apple 为第三方 Developer ID CLI 授予这些 Voice Memos 私有 entitlement、header、protocol 或兼容性契约的公开路径。[Entitlements](https://developer.apple.com/documentation/bundleresources/entitlements) [Signing a daemon with a restricted entitlement](https://developer.apple.com/documentation/xcode/signing-a-daemon-with-a-restricted-entitlement) 因此静态证据**不能证明**第三方一定不会获授权；同样，即使某进程可 lookup service 名，也不证明 daemon 会接受连接、允许该 client 或可安全调用。**字符串/ObjC metadata 不等于第三方可连接、可构造参数、可获授权或可长期运行。**

实际路径分层如下：

| 层 | 能力 | 结论 |
| --- | --- | --- |
| Apple 支持的 UI | 用户在 Voice Memos 里搜索、分享/拖到 Finder、改名、删除；删除进入 Recently Deleted | 唯一稳定写路径；CLI 可指导/打开 UI。 |
| 私有 store 的只读快照 | 用 SQLite 读取 `CloudRecordings.db`，再复制本地 `.m4a`/`.qta` | 社区最常用；需要用户数据访问授权/FDA，schema 非契约，适合实验性 `list/search/show/export`。 |
| Accessibility UI automation | 驱动已打开 App 的界面 | 可做 opt-in 实验性 rename/delete/export；需要 Accessibility，易随语言、窗口层级和版本漂移。 |
| 私有 XPC/runtime | daemon 的内部服务/类 | Production No-Go。没有普通 CLI 的签名与协议入口。 |
| Shortcuts/App Intents | 用户手工安装的 shortcut 可由 `shortcuts run` 触发 | 不是按录音 ID 的数据 API；`SearchRecordings` 无声明结构化输出，rename 不在当前 action inventory。 |
| 直接 SQL/文件删除 | 改 `ZCLOUDRECORDING`、`ANSCK*`、音频/sidecar | 可做一次性逆向 PoC，不是默认产品能力；绕过 Core Data、daemon、CloudKit mirror 与 Recently Deleted 语义。 |

## 证据口径与本机静态核验

- **A（官方/当前系统静态）**：Apple 文档、系统 bundle、签名、launchd metadata；能说明“存在/受支持边界”，不能说明未运行的动态行为。
- **B（源码）**：固定 Git commit/gist revision 中实际实现；证明作者做了什么，**不**证明跨版本正确或安全。
- **C（作者声明/issue）**：README、issue、PR 的实测报告；保留为有用信号，并明确不是 Apple contract。

当前机器（Voice Memos 3.2 / 1380）只读检查到：launchd 声明两个 Mach service；App 的 entitlement 含 `com.apple.private.voicememod.client`、`group.com.apple.VoiceMemos.shared`、`com.apple.voicememod.xpc` 和 `.datastore.Cloud` 的 mach lookup。此处 App Intents inventory 是**本范围的静态筛选，不是完整清单**：同一 metadata 还有 hidden/non-discoverable `RCImportRecording`、`RCCombineRecordings`、`ToggleRecording` 等；它们不构成可被普通 CLI 调用的 API，且不改变本范围 CRUD 判断。列出的 `SearchRecordings`、`SelectRecording`、`DeleteRecording`、`CreateFolder`、`DeleteFolder`、`OpenFolder`、`PlaybackVoiceMemoIntent`、`RecordVoiceMemoIntent`、`StopRecording`，与 Apple 将 App Intents 定义为 app 向系统体验暴露 action 的模型一致，**不是**第三方可链接的 Voice Memos SDK。[App Intents](https://developer.apple.com/documentation/appintents/app-intents)

## 私有 surface inventory

| Surface / selector / service | 静态可见的可能操作 | 调用障碍 | 证据 |
| --- | --- | --- | --- |
| `com.apple.voicememod.xpc` | 主 daemon XPC 服务 | 私有 protocol/序列化、client authorization 和 lifecycle 未公开。App 有私有 entitlement；没有公开证据显示普通 Developer ID CLI 可获相应授权，service 名存在/可 lookup 也不证明 daemon 会接受连接。 | A：launchd + App entitlement |
| `com.apple.voicememod.datastore.Cloud` | Cloud datastore 服务 | 同上，且名称显示它关联 Cloud 数据层，不说明可发 CRUD RPC。 | A |
| `SavedRecordingService` | `fetchMetadataForRecordingWithUUID:includeAsset:`、`importRecordingWithSourceAudioURL:name:date:userInfo:importCompletionBlock:`、`prepareToExport…`、`endAccessSessionWithToken:`、Cloud import/export、orphan/recovery | 方法名来自二进制；connection acceptance/令牌/权限/对象类型未公开。selector 不能证明第三方可获授权、可调用或不会破坏 sync。 | A（strings） |
| `RCXPCStoreServer` | XPC-backed Core Data store server 线索 | 只有类名，未知 initializer/protocol/authorization，不能把它当 `NSPersistentStore` 公共替代。 | A（strings） |
| `RCSavedRecordingsController` | `cloudRecordings`、`fetchedObjects`、`setSearchPredicate:scope:performingFetch:` | App 内 UI controller；无公开 framework/header，也不提供外部 CLI 进程的实例。 | A（App strings） |
| `RCCloudRecording(CopyResources)` | `copyResourcesForSharingIntoDirectory:completion:`、内部 copy/rewrite/remove-title metadata | 看似接近 export，但 class/category 私有、对象来源与 completion queue 未知；没有可部署 ABI。 | A（strings） |
| Core Data model + CloudKit mirror | `ZCLOUDRECORDING`、`ZFOLDER`、`ANSCK*` 等本地实现存储 | schema/列、WAL 与 mirror 均非 API contract；直接 SQL 绕开 managed object context、persistent history、tombstone 与同步。 | A（本机 schema 既有研究）+ B |
| App Intents | 搜索/选择/播放/删除/文件夹等系统动作 | `RCRecordingEntity` 是私有 entity；第三方 CLI 无实体构造、稳定 ID 注入或 search results 输出。当前 inventory 无 rename action。 | A；[AppEntity](https://developer.apple.com/documentation/appintents/appentity) |
| Accessibility | 按键、菜单、AX element press/value | 必须授 Accessibility；焦点、语言、role/path/index、App UI 改版均会破坏；无事务/稳定回执。 | A（Apple 辅助功能 API）+ B |

Apple 用户指南明确支持 App 内改名、共享/拖到 Finder 及 Recently Deleted，而非第三方私有 CRUD；删除后可恢复，永久删除会同步影响同一 Apple Account 的设备。[编辑/重命名录音](https://support.apple.com/guide/voice-memos/edit-a-recording-vmac7e39c22e/3.2/mac/26) [共享录音](https://support.apple.com/guide/voice-memos/share-a-recording-vm05f9fa82d4/mac) [删除录音](https://support.apple.com/en-ke/guide/voice-memos/vmc3c0776462/mac)

## 社区项目矩阵（逐项源码核验）

版本为 2026-08-28 时 default branch/指定 revision；“测试”只指仓库中可见的自动化测试，非 macOS 真库集成验证。

| 项目（固定源码） | 实际操作与读写策略 | 版本/维护、测试、license | 权限与风险 |
| --- | --- | --- | --- |
| [harryf/voice-memos](https://github.com/harryf/voice-memos/tree/7e38eda5e50d537e933dd67a4a3aeec473a90444) | Swift：`list`、`info`、UUID/path lookup、读取 `tsrp`；SQLite `SQLITE_OPEN_READONLY` + `PRAGMA table_info`。没有 export/rename/delete。 | 2026-05 commit；未见 tests；README 称 MIT，但 GitHub API 未识别 SPDX。 | README 要求 FDA；live DB 未做 WAL snapshot，`ZPATH` lookup 假定 `.m4a`。 |
| [grmartin/macos-voice-memo-tools](https://github.com/grmartin/macos-voice-memo-tools/tree/13fb40b3d0820c1ca2a95eea3e27428be7802d60) | Node 交互浏览，只读 DB，导出嵌入式 transcript JSON/Markdown；不是 Voice Memos CRUD。 | 2026-08；无 tests；MIT。 | FDA；读取层使用 `ZCUSTOMLABELFORSORTING`，显示字段随版本变。 |
| [jwulff/apple-voice-memo-mcp](https://github.com/jwulff/apple-voice-memo-mcp/tree/f34437f546f17c78989b6e1a248d452829e50754) | MCP `list/get/get_audio`；`better-sqlite3({readonly:true})`，title LIKE 搜索，`Z_PK` lookup；无 rename/delete/export copy（可返回 path/base64）。 | 2026-01；有 Vitest service/tool tests；MIT。 | Sonoma+、FDA；未 snapshot WAL，`Z_PK` 非跨 store 稳定 ID，硬编码列。 |
| [robbyHuelsi/macOSVoiceMemosExporter](https://github.com/robbyHuelsi/macOSVoiceMemosExporter/tree/2a2aabc8f1d99c428961717503ded5ab9c131ac5) | 主分支只留 README；未合并 [PR #5 的 `main.py`](https://github.com/robbyHuelsi/macOSVoiceMemosExporter/blob/6f1dbb92e80bb04b5af92d0e4b8e4e68915c6c87/main.py) 用 `sqlite3.connect(db_file)` 后执行 `SELECT` 再复制音频。它**没有**强制 readonly open，不能作为安全只读实现参考。 | 主分支最后 commit 2019；PR #5 2025；无 tests；无 SPDX license。 | [issue #4](https://github.com/robbyHuelsi/macOSVoiceMemosExporter/issues/4) 的直接证据是 Sonoma/iOS 17 后标题加密说明及 FDA/读库 `authorization denied`；Group Container 与 `ZCUSTOMLABELFORSORTING` 是 PR #5/讨论中的兼容性改动，不能倒推为 issue 已独立证实。 |
| [ginqi7/voice-memos-cli](https://github.com/ginqi7/voice-memos-cli/tree/ac6fb4b366bd10a32727c544c2d404cbc1123666) | Swift `record/toggle/stop/list/delete`；全靠 `AXUIElement` 深层 role path，`delete(index:)` 先 press 某个 button，再 press toolbar buttons `[3]`。无稳定录音 ID、事务或 rename。 | 2025-05 初始 commit；无 tests；MIT。 | Accessibility；窗口/语言/侧栏都会改变 index，删除结果无法可靠关联 list 输出。 |
| [pedramamini gist](https://gist.github.com/pedramamini/f4efacfe7080e07e18f54e13d8243dc1/2feb9fb400be63386ddf5449a93e848a3c1b85ca) | Python `list/show/export/rename/delete/import`；只读时 URI `mode=ro`。写前退出 App/快照，但直接 SQL 与 `unlink`。 | 2026-04 revision；无 tests；gist 作者标 public domain。 | 详见下节：作者也明确 import **没有**写 CloudKit mirror；写仍不安全。 |
| [cathrynlavery/voice-memo-organizer](https://github.com/cathrynlavery/voice-memo-organizer/tree/e0deb8949801f1684150b8647773a4f92d418834) | README 声称读取 DB/复制音频做本地整理，optional rename 经 Mac Voice Memos UI。 | 2026-05；无 tests；无 SPDX license。 | **C 级作者声明**：没有可审计的 AX rename 实现或集成测试；README 警告 direct SQLite 改 title 可在 Mac 看似成功、却不可靠同步 iPhone，并建议 AX、单条测试、小批量。 |
| [GodModeAI2025/AppleMCP PR #1](https://github.com/GodModeAI2025/AppleMCP/pull/1) / [后续 provider](https://github.com/GodModeAI2025/AppleMCP/blob/eed97a3cc008c9c99a20e465ddbf9ddbc36494d0/Sources/M3MCPApp/Providers/VoiceMemosProvider.swift) | 只读 snapshot：建 `0700` 临时目录，复制 DB 与存在的 `-wal`/`-shm`，副本 read-write replay WAL；list/search/read/audio export。 | PR closed 未合并；后续 main 有 provider 与 transcript tests；Apache-2.0。 | 当前 copy 对 sidecar copy 用 `try?`，非 fail-closed；`defer` 只清理正常返回，崩溃会留临时副本，且三文件复制非原子。产品实现必须要求已存在 sidecar 全部复制成功、启动清扫残留、检测源变化后重试/失败。 |
| [iBz-04/gloamy](https://github.com/iBz-04/gloamy/tree/cecb1995661ce05efca438bc27884349502c0742/skills/automating-voice-memos) | JXA/System Events UI-first export，optional sqlite；脚本用 File > Export 和 Save sheet。 | 2026-08；仓库有 Rust tests，但 Voice Memos 脚本无可见集成测试；MIT。 | 作者明确 Catalyst/no dictionary；File 菜单、sheet、Accessibility 均脆弱，且其 reference 的 `ZTRASHEDDATE` 与其它项目 `ZEVICTIONDATE` 分歧。 |
| [rudrakabir/voice-memos-exporter](https://github.com/rudrakabir/voice-memos-exporter/tree/0f549f2c569983a93d826d60b8fdc77006f2e521) | Tk GUI，直接查询 `ZCLOUDRECORDING`，以 datetime+title 再查 `ZPATH`，复制 selected 音频。 | 2026-02；无 tests；无 SPDX license。 | FDA；[issue #2](https://github.com/rudrakabir/voice-memos-exporter/issues/2) 证明标题 `/` 未清理会取消导出；[issue #7](https://github.com/rudrakabir/voice-memos-exporter/issues/7) 报 item-not-found。datetime/title 不是唯一键。 |
| [iXerol/exVMs](https://github.com/iXerol/exVMs/tree/303b84c08913276d0a5de1d1e0f2b79602bee9f0) | Rust CLI/SwiftUI：探测 modern/legacy dirs 与 `CloudRecordings.db`/`Recordings.db`、schema；`view`，按 `Z_PK` export copy，避免覆盖/非本地文件。 | 2026-07；有 storage/filename/ViewModel tests、GitHub Actions；AGPL-3.0-or-later。 | FDA；测试用 synthetic DB，不等于真 CloudKit/WAL；README 也把 `Z_PK` 只称 active-store stable。 |
| [RunMaestro/Maestro-Playbooks Voice Journal](https://github.com/RunMaestro/Maestro-Playbooks/tree/57a5724e676327f25dc5dfbadab68bf5d9564af9/Assistants/Voice-Journal) | 随附同源 Pedram helper，做 list/show/export/rename/delete/import；journal 场景还会写文件/crontab（非本项目需要）。 | 2026-08；无 voice-memo tests；AGPL-3.0。 | 不应采纳其写 DB 或定时读真实库；它对 transcript 的 `.m4a/.qta` 容器处理只与本范围的 export 路径相关。 |

相关项目中的 transcript-only 行为未作为 CRUD 可行性证据；上述仅记录其数据访问方式。

## 两个写入样本：为什么不能推广

### Pedram Amini gist：写入确实存在，正确性没有被证明

固定 revision 的 [`voice_memos.py`](https://gist.githubusercontent.com/pedramamini/f4efacfe7080e07e18f54e13d8243dc1/raw/2feb9fb400be63386ddf5449a93e848a3c1b85ca/voice_memos.py) 在 `--quit-app` 或确认 App 未运行后复制 DB/WAL/SHM；这只能减小直接竞争，不能停止 `voicememod`/CloudKit。

- `rename`：`UPDATE ZCLOUDRECORDING SET ZENCRYPTEDTITLE=?, ZCUSTOMLABEL=COALESCE(ZCUSTOMLABEL, ?), ZCUSTOMLABELFORSORTING=? WHERE Z_PK=?`。它改三个本地显示/排序字段，却没有通过 Core Data context 或同步事务。
- `delete`：先读 `ZPATH`，快照 audio、waveform、composition；`DELETE FROM ZCLOUDRECORDING WHERE Z_PK=?`；可选 `UPDATE ANSCKRECORDMETADATA SET ZNEEDSCLOUDDELETE=1 WHERE ZENTITYPK=?`；然后 `unlink` 音频/waveform 并删 composition。
- `import`：插入本地 row 并复制 audio，但源码明确输出 “CloudKit mirror rows were NOT written; this record is local-first. Open Voice Memos to let it reconcile.”。这直接承认 mirror 不完整，不能把同一策略宣称为 sync-safe。

所以这是**逆向样本，不是可采纳后端**：snapshot 不含 daemon 状态、CloudKit server change、persistent history、asset manifest、Recently Deleted/tombstone 业务语义；`ZNEEDSCLOUDDELETE` 也只是一张 mirror 表中的一个 flag，不能证明产生完整远端删除交易。

### ginqi7：UI delete 样本，不是稳定自动化

[`VoiceMemos.swift`](https://github.com/ginqi7/voice-memos-cli/blob/ac6fb4b366bd10a32727c544c2d404cbc1123666/Sources/VoiceMemos/VoiceMemos.swift) 的 `list()` 输出深层 AX role path 找到的 buttons 的枚举 index；`delete(index:)` 再从同一路径取 index、press，最后固定点击 toolbar `buttons[3]`。没有录音 UUID、无 list→delete 事务、没有 rename，也没有在 UI 刷新/排序改变后重新校验 target。它要求 Accessibility 且依赖固定 hierarchy，因此只能作为“AX 可操作”的 B 级证据。

相比之下，[cathrynlavery README](https://github.com/cathrynlavery/voice-memo-organizer/blob/e0deb8949801f1684150b8647773a4f92d418834/README.md#7-optional-rename-the-memos-in-apples-voice-memos-app) 明说 direct SQLite rename 可能在 Mac 看似修改、却无法可靠同步 iPhone；其策略是 UI rename、先测一条、用户确认 iPhone、再小批量。这是合理的风险控制，但仍是 experimental UI automation，不是 API。

## 失败模式与版本漂移

| 风险 | 精确证据 | 对 v0.1 的含义 |
| --- | --- | --- |
| WAL/SHM snapshot | [AppleMCP PR #1](https://github.com/GodModeAI2025/AppleMCP/pull/1) 报告 WAL 可大于主库；其 [snapshot 实现](https://github.com/GodModeAI2025/AppleMCP/blob/b92dba6556836b3f277abef8a2265babefe503de/Sources/M3MCPApp/Support/SQLiteSnapshot.swift) 建 `0700` 目录、复制 sidecar、`defer` 删除，但 sidecar copy failure 被忽略，三文件复制也非原子。 | v0.1 应 fail-closed：存在的 DB/WAL/SHM 必须全部复制成功；启动清扫旧 `0700` snapshot（崩溃可残留），复制前后比较 source metadata/重试；不能把 snapshot 当一致性保证。 |
| Sonoma 字段/路径变化 | [robby issue #4](https://github.com/robbyHuelsi/macOSVoiceMemosExporter/issues/4) 直接报告 FDA/读库权限失败及标题加密说明；[PR #5](https://github.com/robbyHuelsi/macOSVoiceMemosExporter/pull/5) 提议 Group Container 与 `ZCUSTOMLABELFORSORTING`。 | 不把 issue 的权限报告扩大为已证实路径/字段迁移；运行时 schema 探测与版本白名单。 |
| Group Container 迁移 | [exVMs storage.rs](https://github.com/iXerol/exVMs/blob/303b84c08913276d0a5de1d1e0f2b79602bee9f0/src/storage.rs) 依次探测 Group Container、container legacy、Application Support；AppleMCP 也有三路径。 | 路径只是候选；禁止把任一路径当普遍 contract。 |
| iCloud 未下载/placeholder | [AppleMCP Voice Memos docs](https://github.com/GodModeAI2025/AppleMCP/blob/eed97a3cc008c9c99a20e465ddbf9ddbc36494d0/docs/VOICE_MEMOS.md) 把空 `ZPATH` 视作无本地音频；Apple 说明录音随同一账户设备同步。[Apple Guide](https://support.apple.com/en-ie/guide/voice-memos/vma6cc4d0571/mac) | list 可显示 unavailable；export 必须拒绝，提示用户在 Voice Memos 下载/播放，不能删 row。 |
| 标题含 `/` | [rudrakabir issue #2](https://github.com/rudrakabir/voice-memos-exporter/issues/2) | export filename 必须独立 sanitize、冲突去重；标题不是文件路径。 |
| `ZPATH` absolute/relative/missing | [AppleMCP provider](https://github.com/GodModeAI2025/AppleMCP/blob/eed97a3cc008c9c99a20e465ddbf9ddbc36494d0/Sources/M3MCPApp/Providers/VoiceMemosProvider.swift) 仅在 absolute 存在时用它，否则 basename 相对解析；Pedram 同时探测 `.m4a/.qta`。 | 只允许解析到 recordings dir 内的 existing regular file；不信任 DB path 直接访问任意位置。 |
| `.qta`、多轨/edited 资产 | [RunMaestro parser](https://github.com/RunMaestro/Maestro-Playbooks/blob/57a5724e676327f25dc5dfbadab68bf5d9564af9/Assistants/Voice-Journal/assets/voice_memos.py) 说明 `.qta` 的 metadata 布局不同；Apple 用户指南也记录 layered recordings 的 macOS 版本限制。[Apple Guide](https://support.apple.com/en-ie/guide/voice-memos/vma6cc4d0571/mac) | export 先按实际扩展名复制；不要假定 `.m4a`、单轨或可由简单 parser 处理。 |
| Recently Deleted / CloudKit 覆盖 | Apple UI delete 先进入 Recently Deleted；AppleMCP 对 `ZEVICTIONDATE` 的解释来自 PR live probing，和 gloamy 的 `ZTRASHEDDATE` 文档冲突。 | 不据内部列模拟 delete；直接 SQL 物理删会丢恢复语义，未来 sync/recovery 可覆盖本地变更。 |

## 各目标操作的路线矩阵

| 路线 | list/search/show/export | rename/delete | 可靠性 | agent-friendliness | 风险 | v0.1 建议 |
| --- | --- | --- | --- | --- | --- | --- |
| 支持 UI | 用户可完成全部 | UI 原生语义，含 Recently Deleted | 高（人工） | 低 | 低 | **Go**：CLI 打开/解释，用户确认。 |
| 只读 private store | 能做；export 为复制已本地化资产 | 不做 | 中低，版本锁定 | 中 | 中（隐私、权限、一致性） | **Go（实验性只读）**：schema/WAL/路径 preflight。 |
| direct SQL | 可做 | 技术上可改/删 | 低 | 高 | 极高 | **No-Go 默认**。 |
| UI automation | 可驱动选择/分享/导出 | 可尝试 | 低 | 中 | 高（误目标/焦点/TCC） | **Experimental opt-in**，尤其 destructive 前人工确认。 |
| private XPC/runtime | 未验证 | 未验证 | 不可评估 | 低 | 极高 | **No-Go**。 |
| Shortcuts | 用户 helper 可触发部分 UI/action | delete action 可见、rename 不可见 | 低至中 | 低 | 中高（实体选择/TCC/UI） | 仅手工 helper 的非破坏性实验；不是 JSON CRUD。 |

## 三种产品选择（保留决策权）

### A. 安全只读

提供 `list/search/show/export`，只读 snapshot、版本/schema 白名单、文件存在与稳定性检查；rename/delete 直接引导用户在 App 操作。优点是风险最低、边界诚实；代价是要 FDA/用户显式授权，且读取适配仍非 Apple contract。

### B. opt-in experimental UI automation

在 A 之外单独开关，要求 Accessibility、前台 Voice Memos、单条预演、目标/标题人工确认、超时与失败即停。优点是可借 App 的真实 CloudKit/Recently Deleted 语义；代价是不可无人值守，UI/locale/version 漂移和误操作风险高。

### C. explicit unsafe direct-SQL backend

若保留，必须独立命名（例如 `unsafe-local-store`），强确认，整库+WAL+SHM+关联 asset 备份，macOS/schema 白名单，iCloud 关闭，独立测试用户与可丢弃录音；禁止作为 public default。优点是自动化完整度表面最高；代价是没有完整 transaction/mirror/recovery 模型，**不建议作为公开默认能力**。

## 可复现只读检查与未验证项

以下命令只读系统 bundle/metadata，不读取用户录音或数据库：

```zsh
sw_vers
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  /System/Applications/VoiceMemos.app/Contents/Info.plist
plutil -p /System/Library/LaunchAgents/com.apple.voicememod.plist
codesign -d --entitlements :- /System/Applications/VoiceMemos.app 2>/dev/null
strings /System/iOSSupport/System/Library/PrivateFrameworks/VoiceMemos.framework/Support/voicememod | \
  rg 'com\.apple\.voicememod|SavedRecordingService|RCXPCStoreServer|RCCloudRecording|CloudKit'
strings /System/Applications/VoiceMemos.app/Contents/MacOS/VoiceMemos | \
  rg 'RCSavedRecordingsController|RCCloudRecording|CopyResources'
jq -r '.actions | keys[]' \
  /System/Applications/VoiceMemos.app/Contents/Resources/Metadata.appintents/extract.actionsdata
```

**未验证且不得由本报告推断为可用：**第三方连私有 XPC 的认证/协议；任何 selector 的调用；App Intents/Shortcuts 对给定 recording ID 的实体绑定、输出与 delete 确认；UI automation 在不同语言/窗口/锁屏下的成功率；私有 store 写入后 App、daemon、CloudKit、Recently Deleted 与其它设备的一致性。验证写操作需用户另行授权，并且只能在独立 macOS 用户、独立/未登录 iCloud、可丢弃录音的环境进行；不得拿真实库或同步库实验。

## 参考资料

1. [Apple：Voice Memos 同步与 layered recordings](https://support.apple.com/en-ie/guide/voice-memos/vma6cc4d0571/mac)
2. [Apple：编辑/重命名录音](https://support.apple.com/guide/voice-memos/edit-a-recording-vmac7e39c22e/3.2/mac/26)
3. [Apple：删除录音与 Recently Deleted](https://support.apple.com/en-ke/guide/voice-memos/vmc3c0776462/mac)
4. [Apple：共享录音](https://support.apple.com/guide/voice-memos/share-a-recording-vm05f9fa82d4/mac)
5. [Apple：Entitlements](https://developer.apple.com/documentation/bundleresources/entitlements)
6. [Apple：Signing a daemon with a restricted entitlement](https://developer.apple.com/documentation/xcode/signing-a-daemon-with-a-restricted-entitlement)
7. [Apple：TN3125 Provisioning Profiles](https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles)
8. [Apple：App Intents](https://developer.apple.com/documentation/appintents/app-intents)
9. [Apple：AppEntity](https://developer.apple.com/documentation/appintents/appentity)
10. [Apple：App Sandbox 文件访问](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox)
11. [harryf Database.swift](https://github.com/harryf/voice-memos/blob/7e38eda5e50d537e933dd67a4a3aeec473a90444/Sources/voice-memos/Database.swift)
12. [grmartin README](https://github.com/grmartin/macos-voice-memo-tools/blob/13fb40b3d0820c1ca2a95eea3e27428be7802d60/README.md)
13. [jwulff voice-memo-db.ts](https://github.com/jwulff/apple-voice-memo-mcp/blob/f34437f546f17c78989b6e1a248d452829e50754/src/services/voice-memo-db.ts)
14. [robbyHuelsi README](https://github.com/robbyHuelsi/macOSVoiceMemosExporter/blob/2a2aabc8f1d99c428961717503ded5ab9c131ac5/readme.md)
15. [robbyHuelsi PR #5 source](https://github.com/robbyHuelsi/macOSVoiceMemosExporter/blob/6f1dbb92e80bb04b5af92d0e4b8e4e68915c6c87/main.py)
16. [robbyHuelsi issue #4](https://github.com/robbyHuelsi/macOSVoiceMemosExporter/issues/4)
17. [robbyHuelsi PR #5](https://github.com/robbyHuelsi/macOSVoiceMemosExporter/pull/5)
18. [ginqi7 AX implementation](https://github.com/ginqi7/voice-memos-cli/blob/ac6fb4b366bd10a32727c544c2d404cbc1123666/Sources/VoiceMemos/VoiceMemos.swift)
19. [Pedram Amini helper source](https://gist.githubusercontent.com/pedramamini/f4efacfe7080e07e18f54e13d8243dc1/raw/2feb9fb400be63386ddf5449a93e848a3c1b85ca/voice_memos.py)
20. [cathrynlavery UI rename warning](https://github.com/cathrynlavery/voice-memo-organizer/blob/e0deb8949801f1684150b8647773a4f92d418834/README.md#7-optional-rename-the-memos-in-apples-voice-memos-app)
21. [GodModeAI2025 AppleMCP PR #1](https://github.com/GodModeAI2025/AppleMCP/pull/1)
22. [AppleMCP current Voice Memos docs](https://github.com/GodModeAI2025/AppleMCP/blob/eed97a3cc008c9c99a20e465ddbf9ddbc36494d0/docs/VOICE_MEMOS.md)
23. [iBz-04 Voice Memos skill](https://github.com/iBz-04/gloamy/blob/cecb1995661ce05efca438bc27884349502c0742/skills/automating-voice-memos/SKILL.md)
24. [rudrakabir exporter source](https://github.com/rudrakabir/voice-memos-exporter/blob/0f549f2c569983a93d826d60b8fdc77006f2e521/voice_memos_exporter.py)
25. [rudrakabir issue #2](https://github.com/rudrakabir/voice-memos-exporter/issues/2)
26. [rudrakabir issue #7](https://github.com/rudrakabir/voice-memos-exporter/issues/7)
27. [iXerol exVMs README](https://github.com/iXerol/exVMs/blob/303b84c08913276d0a5de1d1e0f2b79602bee9f0/README.md)
28. [iXerol store discovery/tests](https://github.com/iXerol/exVMs/blob/303b84c08913276d0a5de1d1e0f2b79602bee9f0/src/storage.rs)
29. [RunMaestro Voice Journal](https://github.com/RunMaestro/Maestro-Playbooks/blob/57a5724e676327f25dc5dfbadab68bf5d9564af9/Assistants/Voice-Journal/README.md)
30. [RunMaestro `.qta`/`tsrp` parser](https://github.com/RunMaestro/Maestro-Playbooks/blob/57a5724e676327f25dc5dfbadab68bf5d9564af9/Assistants/Voice-Journal/assets/voice_memos.py)
