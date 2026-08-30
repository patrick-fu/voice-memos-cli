# Voice Memos macOS 数据访问边界（v0.1 研究）

> **当前产品决策（2026-08-30）：** `voice-memos-cli` 当前是安全只读检索/导出 CLI，只支持 `list/search/show/export/doctor`；不支持 `rename/delete`，不要求也不使用 Accessibility、CGEvent、mutation token 或 Shortcuts 写后端。本文是研究/历史证据，记录既有调研与失败路径，不作为当前实现计划。

研究日期：2026-08-27。当前机器为 macOS 26.6.1（Darwin build 25G76）；按发行主版本，当前为 macOS Tahoe 26，前一主要版本为 macOS Sequoia 15。以下结论区分 Apple 公开 API、系统能力和对 Voice Memos 私有实现的实际探测；不读取录音音频、标题、转写或其他个人字段值。

## 结论先行

在当前 macOS 26/前一主要版本 macOS 15 及可核验的 Apple SDK/官方文档范围内，没有发现面向第三方的 Voice Memos 数据框架或 CLI API。`AVFoundation` 能解码导出的 `.m4a`，但不是 Voice Memos 记录 API。Voice Memos 确实随系统暴露 App Intents/Shortcuts 元数据；这与第三方 CLI 能按 identifier 直接调用实现或 datastore XPC 是两回事，后者目前没有证据。

v0.1 建议只实现：用户显式选择目录后的只读枚举、从 Voice Memos 的 SQLite schema 读取非内容元数据、把关联音频复制/导出到用户指定路径；默认拒绝 rename/delete 和直接数据库写入。若要稳定写操作，应通过用户在 Voice Memos UI 中完成，CLI 仅打开应用或提供 UI Automation 实验功能。

## 本机可复现证据（仅结构/元数据）

命令（不会读取个人字段）：

```sh
sw_vers
find "$HOME/Library/Group Containers/group.com.apple.VoiceMemos.shared" -maxdepth 3 -type d -print
sqlite3 "$HOME/Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings/CloudRecordings.db" '.tables'
sqlite3 "$HOME/Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings/CloudRecordings.db" \
  "SELECT name, type, sql FROM sqlite_master WHERE type IN ('table','index','trigger','view') ORDER BY type,name;"
sqlite3 "$HOME/Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings/CloudRecordings.db" \
  'PRAGMA user_version; PRAGMA schema_version; PRAGMA journal_mode; PRAGMA integrity_check;'
find "$HOME/Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings" -maxdepth 1 -type f -print0 | xargs -0 file
```

实测结果：共享容器为 `group.com.apple.VoiceMemos.shared/Recordings`，包含 `CloudRecordings.db`、SQLite `-wal/-shm`，以及 `.m4a` 和 `.qta` 文件。数据库当前 `journal_mode=wal`、`integrity_check=ok`、`schema_version=1326`、`user_version=0`。关键 Core Data 表为 `ZCLOUDRECORDING`（`ZPATH`, `ZUNIQUEID`, `ZDATE`, `ZDURATION`, `ZCUSTOMLABEL`, `ZENCRYPTEDTITLE`, `ZFOLDER` 等）、`ZFOLDER` 和旧/兼容的 `ZRECORDING`；CloudKit mirror 表（`ANSCK*`）同时存在。文件名是时间戳加 UUID 风格后缀；`.m4a` 被系统 `file` 识别为 ISO Media AAC/ALAC，`.qta` 为 QuickTime movie。这里仅记录列名和 MIME/容器类型，没有查询任何行值。

Voice Memos.app 的签名 entitlement（结构信息，不是用户数据）可复现：

```sh
codesign -d --entitlements :- '/System/Applications/VoiceMemos.app' 2>/dev/null
plutil -p '/System/Applications/VoiceMemos.app/Contents/Info.plist'
```

Apple 自带应用拥有 `com.apple.security.application-groups`（含上述 group）、私有 `com.apple.private.voicememod.client`、`com.apple.voicememod.xpc`/Cloud datastore Mach lookup、CloudKit 和特殊 TCC entitlement。第三方签名不能合法声明这些私有 entitlement。Voice Memos bundle 没有 `VoiceMemos.sdef`；对其执行 `osascript -e 'tell application "Voice Memos" to get properties'` 返回 `-1728`，所以不能把 AppleScript dictionary 当作受支持 API。

## 各操作的边界

| 操作 | 支持/可行路径 | v0.1 判定 |
|---|---|---|
| list/search | 只读扫描用户授权的 `Recordings`；SQLite `ZCLOUDRECORDING`/`ZFOLDER` schema；Spotlight 仅是系统索引，字段和可用性未承诺 | 可选实验；输出需标注 schema 版本，不能依赖固定列/标题解密 |
| show | 只读读取元数据；音频用 `AVAudioFile`/`AVAsset` 打开已授权文件；转码/播放不等于读取 Voice Memos 对象 | 可做单条只读查看/复制 |
| export | `FileManager` 复制原始 `.m4a`/`.qta` 到用户选择的目标；必要时 AVFoundation 转为标准音频 | 推荐支持；先处理 iCloud 未下载、临时文件和一致性 |
| rename | 直接改 `ZCUSTOMLABEL`/文件名会绕过 Core Data + CloudKit 变更历史；文件名不是稳定 ID | 直接私有 DB 写入 No-Go；Shortcuts 包装是否可支持待后续验证 |
| delete | 删除文件或 SQLite 行会造成 orphan、CloudKit tombstone/同步冲突；即使事务成功也没有公开恢复语义 | 直接私有 DB 写入 No-Go；Shortcuts 包装是否可支持待后续验证 |

## App Intents / Shortcuts（本机 macOS 26 证据）

Voice Memos.app 的 `Contents/Resources/Metadata.appintents/extract.actionsdata`（ASCII JSON 元数据，不含录音内容）声明了可发现 actions：`SearchRecordings`、`SelectRecording`、`DeleteRecording`、`DeleteFolder`、`CreateFolder`、`OpenFolder`、`RecordVoiceMemoIntent`、`PlaybackVoiceMemoIntent`、`StopRecording`、`ChangeRecordingPlaybackSetting`；实体 `RCRecordingEntity` 的属性为 `name`、`creationDate`、`duration`，`RCFolderEntity` 的属性为 `name`、`recordingCount`。

只读核验命令：

```sh
F='/System/Applications/VoiceMemos.app/Contents/Resources/Metadata.appintents/extract.actionsdata'
file "$F"
strings "$F" | rg 'SearchRecordings|SelectRecording|DeleteRecording|DeleteFolder|CreateFolder|OpenFolder|RecordVoiceMemoIntent|PlaybackVoiceMemoIntent|StopRecording|ChangeRecordingPlaybackSetting|RCRecordingEntity|RCFolderEntity|creationDate|duration|recordingCount'
```

这证明系统可把 actions/entities 暴露给 Shortcuts/Siri 等系统体验，不证明第三方 CLI 有公开调用入口、可链接的 Swift 类型、授权流程或稳定 identifier RPC。Apple 文档说明 App Intents 是“由应用作者实现并暴露”的桥梁（[App Intents](https://developer.apple.com/documentation/appintents)、[Creating your first app intent](https://developer.apple.com/documentation/appintents/creating-your-first-app-intent)）；因此 `DeleteRecording`/`DeleteFolder` 等是否能由 CLI 通过 Shortcuts 包装安全支持，列为后续决策与实测。

## 存储、同步和一致性风险

`CloudRecordings.db` 是 Voice Memos 私有 Core Data/CloudKit mirror 数据库，不是 API contract；`-wal` 表明应用可能正在写入。只读访问也应使用 SQLite snapshot/只读 URI，避免在 WAL checkpoint 或 Voice Memos/`voicememod` 写入时观察到不一致。不要复制单个主库而忽略 `-wal/-shm`，也不要持有写锁。

`ZPATH` 与 `ZUNIQUEID` 关联音频，但它们是实现细节；CloudKit 记录可能有本地占位符、延迟下载、被驱逐的音频（`ZEVICTIONDATE`）或分层录音 `.qta`。Apple 用户指南确认：同一 Apple Account 开启 iCloud 后，录音自动出现在 Mac/iPhone/iPad 等设备；并明确 macOS 15.1 或更早版本不显示支持机型录制的 layered recordings（[Apple Voice Memos User Guide](https://support.apple.com/en-ie/guide/voice-memos/vma6cc4d0571/mac)）。因此 Tahoe 26 与 Sequoia 15 的文件集合和分层支持不能假设相同；每次操作都应检查文件存在、稳定大小/mtime，并在复制前后校验大小或 hash（不把音频内容写入日志）。

## 权限、TCC、Sandbox

Apple 文档说明 App Sandbox 默认只允许自身容器；用户通过 `NSOpenPanel`/`NSSavePanel` 选择文件夹后才获得 security-scoped URL，需在后续运行保存 bookmark 并调用 `startAccessingSecurityScopedResource()`（[Accessing files from the macOS App Sandbox](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox)、[Configuring the macOS App Sandbox](https://developer.apple.com/documentation/xcode/configuring-the-macos-app-sandbox)）。Voice Memos group container 不是 Music/Movies 等标准 entitlement 目录，不能靠普通 sandbox entitlement 访问。

Full Disk Access 不是代码或 entitlement 自动取得的；用户必须在 System Settings > Privacy & Security 中授予，且失败必须处理（同一 Apple 文档）。macOS 15+ 对 app group/container 增加 SIP 保护，非成员访问会触发授权提示或失败（[Protecting local app data using containers](https://developer.apple.com/documentation/xcode/protecting-local-app-data-using-containers)）。因此非沙盒 Swift CLI 可能在本机、已授权/已 FDA 时可读，但不能把“路径存在”当作可部署保证；Mac App Store 沙盒版本应以用户选择目录为唯一入口。TCC、POSIX ACL、SIP、文件锁和 iCloud 下载状态都可能产生 `EACCES`/`EPERM` 或短暂缺失。

## UI Automation / Apple Events

未发现 Voice Memos AppleScript dictionary；但 App Intents/Shortcuts 是另一条系统暴露路径。Accessibility UI scripting 可模拟点击和菜单，但依赖窗口层级、语言、版本及用户授予 Automation/Accessibility 权限，后台/锁屏不可靠，且不能提供事务语义。沙盒应用还受到 Apple 文档列出的 Apple Events/Accessibility 限制（[Protecting user data with App Sandbox](https://developer.apple.com/documentation/security/protecting-user-data-with-app-sandbox)）。可把“打开 Voice Memos，让用户确认删除/改名”作为人工兜底；不要在 v0.1 自动化破坏性操作。

## Apple 官方分享/导出与 CLI 私有文件复制的区别

Apple Voice Memos 用户指南支持通过 Share 菜单导出/发送录音，或将录音拖到 Finder；这是由 Voice Memos 负责解析对象、下载 iCloud 资产并生成用户选择的导出副本。CLI 直接复制 `Recordings` 下的私有 `.m4a`/`.qta` 则绕过该流程，只在用户授权目录、文件已落地且快照一致时作为实验性只读路径；两者不能宣称等价。目标文件应使用 `NSSavePanel`/security-scoped URL（[Accessing files from the macOS App Sandbox](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox)）。

## 版本和拒绝路径

在 macOS 26 Tahoe 与 macOS 15 Sequoia 上运行时，启动阶段检查：Voice Memos bundle ID、group container 是否存在、数据库 schema/必需列、SQLite WAL 状态、文件扩展名和可读性。未知 schema、无 FDA/用户授权、数据库被锁、音频占位/未下载、正在同步或发现 `.qta` 但解析器不支持时，应返回明确的“不可安全完成”错误，绝不回退到直接 SQL 写入。Apple 的公开 App Intents 框架描述“应用作者暴露的 actions/entities”，本机元数据已证实 Voice Memos 暴露上述 actions/entities；但仍没有证据表明第三方 CLI 可按 identifier 直调这些实现或获得其 datastore 访问（[App Intents](https://developer.apple.com/documentation/appintents)）。

### 推荐 v0.1 边界

1. 非破坏性 `list/search/show/export`，默认只读；目录由用户显式选择并保存 security-scoped bookmark。
2. 记录稳定的 `ZUNIQUEID`（若可读）和相对路径，不输出标题、转写正文或其他个人字段；`ZCUSTOMLABEL` 与 App Intent entity 的 `name` 同样视为敏感，默认不得进入日志、telemetry、error message 或外部模型。字段 allowlist 和显式 `show` 输出需单独规划；不依赖 `Z_PK`。
3. 复制前后做元数据快照和文件大小/hash 一致性检查；检测 WAL/同步变化后重试或失败。
4. `rename/delete` 命令默认不存在或明确拒绝，提示用户在 Voice Memos.app 完成；不直接改 DB、CloudKit mirror 或删除文件。
5. 将私有 schema 适配器隔离并带 macOS 主版本/schema-version 白名单；升级后需重新实测，不能承诺跨版本兼容。
