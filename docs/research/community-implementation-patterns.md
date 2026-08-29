# 社区 Voice Memos 实现模式（源码核验）

研究日期：2026-08-30。工作目录 `/Volumes/WD/code/github/voice-memos-cli`。只读公开 GitHub/gist 源码；**未读取或修改本机 Voice Memos 用户数据**。版本一律用当时 default branch HEAD SHA 或 gist history 固定 revision。

本文不复述 [private-api-community-survey.md](private-api-community-survey.md) 的 XPC/entitlement 结论，也不复述 [voice-memos-mutation-alternatives.md](voice-memos-mutation-alternatives.md) 对本机 build 1380 的 AX/`CGEvent`/App Intents 否证。焦点是：**社区代码实际怎么定位、怎么写、怎么验、测了什么**。

证据口径：B = 固定 revision 源码；C = README/skill 作者声明，无实现则不当成产品路径。

## 结论先行

**没有项目同时做到：exact opaque-ID 定位 + sync-safe rename/delete + 真 Voice Memos 自动化测试。**

最接近的两条互不完整：

1. [zachlatta/personal-data-warehouse](https://github.com/zachlatta/personal-data-warehouse/blob/c35278273f65d9f54641c5765adc04c50f10df05/src/personal_data_warehouse_voice_memos/store_writer.py) 用 `uniqueID` + PyObjC `NSPersistentContainer.save` 改 `encryptedTitle`/`customLabelForSorting`/`flags`，并打开 persistent history。**只有 rename，没有 delete**；只改 auto-named；测试是自造 `CloudRecording` fixture，不是 Voice Memos.app / CloudKit。
2. [cathrynlavery/voice-memo-organizer](https://github.com/cathrynlavery/voice-memo-organizer/blob/e0deb8949801f1684150b8647773a4f92d418834/SKILL.md) 声称 UI rename 后 `ATRANSACTION`/`ACHANGE`/`ANSCKRECORDMETADATA` 前进、iPhone 可见。**仓库无 rename 代码**（C 级）；定位靠 title/date/duration/search，不是 opaque ID。

其余要么只读，要么 SQL 物理写（Pedram），要么 AX index/`AXPress`（ginqi7），要么“当前选中项”菜单导出（gloamy/Spillwave）。

## 必答七问

1. **有没有真正支持 rename/delete？** 源码级 rename：Pedram SQL、PDW Core Data。源码级 delete：Pedram SQL（unlink 音频）、ginqi7 `AXPress` toolbar `[3]`。cathryn/gloamy 的 rename/delete 不是可审计实现。
2. **定位用什么？** `ZUNIQUEID`（harryf/cider/polarity/PDW）；`Z_PK`（jwulff/exVMs/Pedram/cathryn 查询）；title 子串（polarity CLI、jwulff LIKE）；AX role-path index（ginqi7）；当前选中项（gloamy export）；entity/`RCRecordingEntity`：社区无人构造。
3. **写哪些列/文件，是否 quit/snapshot？** Pedram：quit 后 snapshot DB+WAL+SHM，`UPDATE ZENCRYPTEDTITLE/ZCUSTOMLABEL/ZCUSTOMLABELFORSORTING` 或 `DELETE ZCLOUDRECORDING` + 可选 `ANSCKRECORDMETADATA.ZNEEDSCLOUDDELETE` + unlink。PDW：**不 quit**（还要 `voicememod` 活着），直接对 live `CloudRecordings.db` 做 Core Data save。无人实现 Recently Deleted 语义的 delete。
4. **UI 自动化原语？** ginqi7：删除走 `AXUIElementPerformAction(kAXPressAction)`；另用 `CGEvent.postToPid` 发 Escape/Return，但没有鼠标定位或点击。gloamy/Spillwave 的脚本：System Events `click` File > Export + Save sheet，失败时发 `Shift+Cmd+E`；同仓库 skill/UI 文档却称没有 File > Export，且把该快捷键写作 Enhance Audio，源码与说明冲突。cathryn：Computer Use / 点详情 title + Cmd-A + 打字 + Return（无代码）。AppleScript dictionary：无人使用（D1DX/gloamy 都写明无 dictionary）。无社区用 `CGEvent` 鼠标事件精确选择录音。
5. **postcondition / rollback / 同步验证？** Pedram：只检查 `rowcount`，备份目录可手工回滚，无 sync 验证。PDW：save 前再读 `uniqueID`/`flags`，测试断言 `ATRANSACTIONSTRING` 含 author；无 UI、无 iPhone、无 rollback。cathryn skill：手写 SQL 查 `ACHANGE`/`ZLASTEXPORTEDTRANSACTIONNUMBER`/`ZNEEDSUPLOAD`（C）。ginqi7/gloamy：无。
6. **自动化测试是否覆盖真 Voice Memos？** **没有。** PDW/exVMs 用合成 store；jwulff/cider mock/parse；AppleMCP 只测 transcript parser；polarity CI 是 `make check` 构建。无人跑 Voice Memos.app。
7. **对本项目可借鉴 vs 不能：** 见文末。

## 模式矩阵

| 项目 / revision | list/search/export | rename | delete | 定位键 | 写原语 | quit/snapshot | 验证 | 测试 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Pedram gist `2feb9fb` | SQL list/`Z_PK` show；copy 音频 | SQL 三列 | SQL DELETE + unlink | `Z_PK` | raw SQLite | 必须 App 退出；copy DB/WAL/SHM | `rowcount` | 无 |
| PDW `c3527827` | 只读 ingest | Core Data save | 无 | `ZUNIQUEID` | PyObjC `CloudRecording` | 不 quit；要 daemon 活 | 再 fetch + history author | 合成 store |
| ginqi7 `ac6fb4b3` | AX 可见 button 枚举 | 无 | AXPress 行 + toolbar[3] | 可见 index | `kAXPressAction` | 否 | 无 | 无 |
| cathryn `e0deb894` | skill 教 `Z_PK` SELECT | C：Computer Use/UI | 无代码 | title/date/`Z_PK` 查询 | 无实现 | 建议 `.backup` | C：ACHANGE/ANSCK | 无 |
| gloamy=`Spillwave` `cecb1995`/`5f37bd4e` | 可选 sqlite 文档 | 无 | 文档 `Delete` key | 当前选中 | System Events 菜单 | 否 | Save sheet 出现 | 无 VM 测试 |
| polarity `1f6e70ff` | broker 只读 + title 查询导出 | 无 | 无 | store=`ZUNIQUEID`；CLI=title | 无写 | 只读 open，无 WAL snapshot | 路径沙盒 + 歧义退出 2 | CI 构建 |
| harryf `7e38eda5` | UUID/path list | 无 | 无 | `ZUNIQUEID` | 无 | `SQLITE_OPEN_READONLY`，无 snapshot | 无 | 无 |
| jwulff `f34437f5` | `Z_PK` + title LIKE；返回 path/base64 | 无 | 无 | `Z_PK` | 无 | live readonly，无 snapshot | 无 | mock sqlite |
| AppleMCP `eed97a3c` | snapshot 后 list/search/export | 无 | 无 | `Z_PK` | 无 | copy DB；WAL/SHM `try?` | 无 | transcript unit |
| exVMs `303b84c0` | schema 探测 + copy | 无 | 只读 `ZEVICTIONDATE` | 导出 id=`Z_PK`；可选读 `ZUNIQUEID` | 无 | 无 WAL snapshot | 拒绝非本地/非目录内 | 合成 DB |
| cider `fb2135cf` | sqlite3 list | 无 | 无 | `ZUNIQUEID`；`ZEVICTIONDATE IS NULL` | 无 | 打 live DB | 无 | parse unit |

## 深度核验（10）

### 1. Pedram gist — SQL mutation 样本，不是 sync 后端

固定 revision：[`voice_memos.py`](https://gist.githubusercontent.com/pedramamini/f4efacfe7080e07e18f54e13d8243dc1/raw/2feb9fb400be63386ddf5449a93e848a3c1b85ca/voice_memos.py)（gist history `2feb9fb400be63386ddf5449a93e848a3c1b85ca`，2026-04-24）。

- 定位：CLI `--id` = `Z_PK`。
- rename：`UPDATE ZCLOUDRECORDING SET ZENCRYPTEDTITLE=?, ZCUSTOMLABEL=COALESCE(ZCUSTOMLABEL, ?), ZCUSTOMLABELFORSORTING=? WHERE Z_PK=?`（sorting 列写成 `title.lower()`）。
- delete：读 `ZPATH` → snapshot 音频/waveform/composition → `DELETE FROM ZCLOUDRECORDING` → 可选 `ANSCKRECORDMETADATA.ZNEEDSCLOUDDELETE=1 WHERE ZENTITYPK=?` → `unlink`。不是 Recently Deleted。
- 写入前 `ensure_app_closed()` / `--quit-app` 只 `pgrep VoiceMemos`，**不检查 `voicememod`**。
- import 自己打印 CloudKit mirror 未写。无测试。

### 2. zachlatta/personal-data-warehouse — uniqueID Core Data rename

HEAD [`c35278273f65d9f54641c5765adc04c50f10df05`](https://github.com/zachlatta/personal-data-warehouse/tree/c35278273f65d9f54641c5765adc04c50f10df05)。

[`store_writer.py`](https://github.com/zachlatta/personal-data-warehouse/blob/c35278273f65d9f54641c5765adc04c50f10df05/src/personal_data_warehouse_voice_memos/store_writer.py)：从 `Z_MODELCACHE` 解 raw-DEFLATE keyed archive 得到 **store 自己的** MOM；`shouldMigrateStoreAutomatically=false`；打开 `NSPersistentHistoryTrackingKey` + remote-change notification；`predicate uniqueID == %@`；写 `encryptedTitle`、`customLabelForSorting`、清 `flags & ~0x1000`；一次 `context.save`。作者串 `com.zachlatta.pdw.voice-memo-writeback`。

限制（源码，不是 README）：

- 只 rename auto-named（`ZFLAGS & 0x1000` 或 `/New Recording \d+/`）；用户标题永不覆盖。
- **无 delete。**
- 打开的是 live `CloudRecordings.db`，merge policy `NSMergeByPropertyObjectTrumpMergePolicy`。
- [`voice_memos_app.py`](https://github.com/zachlatta/personal-data-warehouse/blob/c35278273f65d9f54641c5765adc04c50f10df05/src/personal_data_warehouse_voice_memos/voice_memos_app.py) 为了 ingest **故意 launch** `com.apple.VoiceMemos` / 依赖 `voicememod`，与 Pedram 的 quit-to-write 相反。
- [`test_apple_voice_memos_store_writer.py`](https://github.com/zachlatta/personal-data-warehouse/blob/c35278273f65d9f54641c5765adc04c50f10df05/tests/test_apple_voice_memos_store_writer.py) 自建 6 字段 `CloudRecording` entity + 自写 `Z_MODELCACHE`。证明“PyObjC save 会进 `ATRANSACTIONSTRING`”，**不证明** VoiceMemos14 模型、`encryptedTitle` 编码、CloudKit export、或与 `voicememod` 并发安全。

这是社区唯一 **exact opaque-ID + 走 Core Data history 的 rename**。它不是 CLI 产品，也未证明 sync-safe。

### 3. ginqi7/voice-memos-cli — AXPress + 可见 index

HEAD [`ac6fb4b366bd10a32727c544c2d404cbc1123666`](https://github.com/ginqi7/voice-memos-cli/blob/ac6fb4b366bd10a32727c544c2d404cbc1123666/Sources/VoiceMemos/VoiceMemos.swift)。

`list`/`delete` 都走 `withRoleLink: [.group ×6, .button]`。`delete(index:)`：对该 button `press()`（[`AXUIElement+Extension.swift`](https://github.com/ginqi7/voice-memos-cli/blob/ac6fb4b366bd10a32727c544c2d404cbc1123666/Sources/VoiceMemos/AXUIElement+Extension.swift) = `AXUIElementPerformAction(kAXPressAction)`），再 `toolbar.button[3] press`。同文件的 `CGEvent` 仅向进程发送 Escape/Return；`submit()` 未被 Voice Memos 命令调用。无 UUID、无 custom action token、无选中校验、无 rename。本仓库 build 1380 已否证 `AXPress` 选择；该路径也不检查 `ZEVICTIONDATE`，因此只能算未绑定、未验证的 UI delete。

### 4. cathrynlavery/voice-memo-organizer — C 级 UI rename runbook

HEAD [`e0deb8949801f1684150b8647773a4f92d418834`](https://github.com/cathrynlavery/voice-memo-organizer/blob/e0deb8949801f1684150b8647773a4f92d418834/SKILL.md)。仓库仅 `README.md`/`SKILL.md`/`CLAUDE.md`/`TROUBLESHOOTING.md`。

有价值的是**失败模式记录**（C，但具体）：raw SQL 改 title 后 Mac UI 可见、iPhone 不同步，因为没写 `ATRANSACTION`/`ACHANGE`/`ANSCK*`；`ZENCRYPTEDTITLE=NULL` 会 `NSFetchedResultsController` abort。建议 UI：选中 → 点详情 title → Cmd-A → 输入 → Return；再用只读 SQL 看 `ACHANGE.ZENTITYPK` 与 `ANSCKRECORDMETADATA.ZLASTEXPORTEDTRANSACTIONNUMBER`。定位是 title/`New Recording%`/`Z_PK` 查询，不是 CLI opaque ID。**无实现、无测试。**

### 5. gloamy = Spillwave automating-voice-memos — 选中项菜单导出

[`iBz-04/gloamy@cecb1995661ce05efca438bc27884349502c0742`](https://github.com/iBz-04/gloamy/blob/cecb1995661ce05efca438bc27884349502c0742/skills/automating-voice-memos/scripts/export_selected_recording_via_ui.applescript) 与 [`SpillwaveSolutions/automating-mac-apps-plugin@5f37bd4ecb1746fc86f3d618e8aa81fc6a61c486`](https://github.com/SpillwaveSolutions/automating-mac-apps-plugin/blob/5f37bd4ecb1746fc86f3d618e8aa81fc6a61c486/plugins/automating-mac-apps-plugin/skills/automating-voice-memos/scripts/export_selected_recording_via_ui.applescript) 的 `SKILL.md` 与 export 脚本 **内容相同**。

脚本（B）：`tell application "Voice Memos" to activate` + System Events `click menu item "Export…"` + 填 Save sheet；失败时发 `Shift+Cmd+E`。前置条件是**已经选中**。同 revision 的 `SKILL.md`（C）却写没有直接 File > Export；[`voice-memos-ui.md`](https://github.com/SpillwaveSolutions/automating-mac-apps-plugin/blob/5f37bd4ecb1746fc86f3d618e8aa81fc6a61c486/plugins/automating-mac-apps-plugin/skills/automating-voice-memos/references/voice-memos-ui.md)（C）把 `Shift+Cmd+E` 写作 Enhance Audio、把 Delete 写成 `keyCode 51`。因此只能确认脚本尝试了这些动作，不能确认它们在当前 Voice Memos 有效；所有路径都没有 target 绑定。data 文档写 `ZTRASHEDDATE`（与 exVMs/AppleMCP/cider 的 `ZEVICTIONDATE` 冲突，以带 schema 探测的源码为准）。无 Voice Memos 集成测试。

### 6. polarity-dev/macos-voice-memos-export — FDA broker + title 查询

HEAD [`1f6e70ffe7048a8d4fa12a8696626a1abc2367c1`](https://github.com/polarity-dev/macos-voice-memos-export/blob/1f6e70ffe7048a8d4fa12a8696626a1abc2367c1/Sources/Broker/VoiceMemosStore.swift)。

Broker：`sqlite3_open_v2(..., SQLITE_OPEN_READONLY)`；id = `ZUNIQUEID` 否则 `ZUUID`；`stage` 按 **id 精确匹配** copy `.m4a`，并校验 descendant + regular file。CLI 却只用 title `contains`/`exact`，歧义 exit 2；用户不能传 opaque ID。无 WAL snapshot。CI：macos-14 `make check`，仓库无 Tests。

可借鉴：权限主体拆成 `.app` broker、路径 containment、歧义 fail-closed。不能借鉴：title 当 export 主键。

### 7. harryf/voice-memos — 只读 uniqueID

HEAD [`7e38eda5e50d537e933dd67a4a3aeec473a90444`](https://github.com/harryf/voice-memos/blob/7e38eda5e50d537e933dd67a4a3aeec473a90444/Sources/voice-memos/Database.swift)。`findByUniqueID` / UUID prefix；列白名单含 `ZEVICTIONDATE`/`ZFLAGS`。`SQLITE_OPEN_READONLY`，无 snapshot、无 export copy、无 mutation、无测试。

### 8. jwulff/apple-voice-memo-mcp — Z_PK 只读 MCP

HEAD [`f34437f546f17c78989b6e1a248d452829e50754`](https://github.com/jwulff/apple-voice-memo-mcp/blob/f34437f546f17c78989b6e1a248d452829e50754/src/services/voice-memo-db.ts)。`better-sqlite3({readonly:true})`；对外 `id: row.Z_PK`；get 用 `WHERE Z_PK = ?`。无 rename/delete。测试 mock `better-sqlite3`，不打开真实库。

### 9. GodModeAI2025/AppleMCP — WAL 手工 copy（非 fail-closed）

HEAD [`eed97a3cc008c9c99a20e465ddbf9ddbc36494d0`](https://github.com/GodModeAI2025/AppleMCP/blob/eed97a3cc008c9c99a20e465ddbf9ddbc36494d0/Sources/M3MCPApp/Providers/VoiceMemosProvider.swift) `makeSnapshot`：0700 临时目录 copy DB；`-wal`/`-shm` 用 `try?`（失败吞掉）；副本 `SQLITE_OPEN_READWRITE` replay。list 主键 `Z_PK`；`ZEVICTIONDATE` → `recently_deleted`。无 mutation。sidecar copy 非原子、非 fail-closed。

### 10. iXerol/exVMs — Z_PK export + eviction 只读

HEAD [`303b84c08913276d0a5de1d1e0f2b79602bee9f0`](https://github.com/iXerol/exVMs/blob/303b84c08913276d0a5de1d1e0f2b79602bee9f0/src/db.rs)。`Recording.id: i64` = `Z_PK`；`unique_id` 只参与缺 title 时的显示。`is_deleted` = `ZEVICTIONDATE` 有值。export 拒绝目录外/非本地。测试合成 schema。无 rename/delete。

## 其余：无 mutation / 未核实 / 排除

| 候选 | revision | 判定 |
| --- | --- | --- |
| grmartin/macos-voice-memo-tools | `13fb40b3` | 只读浏览 + tsrp transcript；无 CRUD 写 |
| xyb/voicememowhisper | `1baa04e0` | 只读 sqlite 元数据 + 本地转写；`scripts/rename_transcripts.py` 不改 Voice Memos |
| thrashr888/cider | `fb2135cf` | [`voice_memos.rs`](https://github.com/thrashr888/cider/blob/fb2135cf29801af8d1e68fa8e70593da99bbecc5/src/sources/voice_memos.rs) 仅 sqlite3 list `ZUNIQUEID` + `ZEVICTIONDATE IS NULL`；shell 出 live DB；无 mutation |
| D1DX/apple-skill | `09255880` | 仅 README/SKILL；Voice Memos 段给 SELECT 模板，明确无 AppleScript；**无 rename/delete SQL 或代码**（C） |
| D1DX/apple-macos-skill | — | GitHub 重定向到 `D1DX/apple-skill`；不是独立实现 |
| 0xble/apple-voice-memos-pp-cli | — | GitHub 404；`0xble` 账号下列表无此仓库。排除 |
| RunMaestro/Maestro-Playbooks Voice-Journal | `57a5724e` | `assets/voice_memos.py` 与 Pedram gist `2feb9fb` **字节相同**；不另计实现 |
| SpillwaveSolutions/automating-mac-apps-plugin | `5f37bd4e` | 见 gloamy；无独立 VM 集成测试（calendar/excel 等 integration 不含 Voice Memos） |

## 对本项目：可借鉴 vs 不能

**可借鉴（只读/定位/验证形状）：**

- 对外 ID 用 `ZUNIQUEID`（harryf/cider/polarity/PDW），不要用 `Z_PK`（jwulff/exVMs/Pedram）。
- Active vs Recently Deleted：`ZEVICTIONDATE IS NULL`（cider/exVMs/AppleMCP），忽略 gloamy 的 `ZTRASHEDDATE` 文档。
- polarity：路径必须落在 recordings dir 内的 regular `.m4a`；查询歧义 fail-closed。
- cathryn/PDW 的 **history 检查清单**：mutation 后应能指出 `ATRANSACTION` 前进；缺 history 就不能声称 sync。
- AppleMCP 的动机（WAL 必须 replay）成立，但其 `try?` sidecar copy **不能抄**；本项目已有的 sqlite backup/fail-closed 更严。
- PDW 证明“社区也认为 raw SQL 不够、要 Core Data save 才可能进 persistent history”。这是研究线索，不是可分发默认后端。

**不能借鉴：**

- Pedram SQL rename/delete、`ZNEEDSCLOUDDELETE` 单 flag、quit-App-but-not-daemon。
- ginqi7 可见 index + `AXPress` + toolbar `[3]`。
- gloamy 选中项 File 菜单 / `keyCode 51`。
- cathryn Computer Use 当生产命令。
- polarity/jwulff 的 title/`Z_PK` 当用户目标键。
- PDW 的 live-store PyObjC writer：无 delete、无通用 rename、无 Voice Memos 真机测试、并发 merge 未证、不是 Developer ID CLI 合同。
- 任何 README“会同步到 iPhone”而没有对应自动化测试。

## 明确结论

社区 **没有** 解决 exact opaque-ID + sync-safe **rename 且 delete**。

- exact opaque-ID rename 的唯一源码：PDW `uniqueID` Core Data save。sync-safe **未被真机/CloudKit 测试证明**；delete 不存在。
- sync 语义最认真的操作说明：cathryn UI + ANSCK 手验，但无代码、无 opaque ID。
- 源码级 delete 只有 Pedram 物理删和 ginqi7 易碎 AXPress。前者不是 Recently Deleted；后者意图调用 App 的 UI delete，但没有 exact ID、`ZEVICTIONDATE` postcondition 或当前 build 的有效选择原语。

因此 v0.1 不能从社区“抄一个已完成的 mutation 后端”。只读 ID/state/export 防护可以吸收；mutation 仍须本仓库自己的 opaque-ID × 已验证 UI 原语（或显式保持 fail closed）。
