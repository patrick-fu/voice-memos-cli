# Voice Memos 的 Shortcuts 桥接可行性（v0.1 研究）

> **当前产品决策（2026-08-30）：** `voice-memos-cli` 当前是安全只读检索/导出 CLI，只支持 `list/search/show/export/doctor`；不支持 `rename/delete`，不要求也不使用 Accessibility、CGEvent、mutation token 或 Shortcuts 写后端。本文是研究/历史证据，记录既有调研与失败路径，不作为当前实现计划。

研究日期：2026-08-27。检查环境为 macOS 26.6.1（25G76）、Voice Memos 3.2（1380）。本研究只读取系统 bundle/metadata、SDK interface、`/usr/bin/shortcuts --help`、系统 `sdef` 和 Apple 官方网页；**没有**读取快捷指令库、录音、标题、转写或数据库，也没有创建、导入、运行、删除任何 Shortcut 或 Voice Memos 数据。

## 结论

**Production No-Go：不要把“生成/安装/调用 Shortcut，从而让 CLI 无交互、按录音 ID、结构化且稳定地控制 Voice Memos”作为 v0.1 能力。**

**Experimental only：**用户可在 Shortcuts.app 中手工制作、检查并安装一个固定的 helper Shortcut；CLI 可用 `/usr/bin/shortcuts run <该快捷指令的名字或库 identifier>`，或用 AppleScript/ScriptingBridge tell `Shortcuts Events` 来触发它。这个路径只能用于用户接受隐私/Automation 授权、实体选择、可能的前台 UI 和版本漂移的单次工作流，不能承诺目标录音的确定性、删除确认、返回值或无人值守。

依据如下：

- **已证实：**Voice Memos 当前暴露 App Intents，Apple 也明确列出其 Shortcuts 动作；这说明“系统 Shortcuts 能驱动 Voice Memos”，不是第三方拥有 Voice Memos API。[Apple 的 Shortcuts 更新记录](https://support.apple.com/en-us/101583)、[App Intents](https://developer.apple.com/documentation/appintents/app-intents)
- **已证实：**当前 `/usr/bin/shortcuts` 只有 `run`、`list`、`view`、`sign`；没有 `create`、`import` 或 `export` 子命令。`sign` 仅对已有 `.shortcut` 文件签名，且会向 Apple 发送副本以验证。[从命令行运行快捷指令](https://support.apple.com/en-ca/guide/shortcuts-mac/apd455c82f02/mac)
- **已证实：**官方的创建/导入入口是 GUI：`shortcuts://create-shortcut` 打开新建编辑器，`.shortcut` 文件要双击或拖进 Shortcuts.app。它们不是无交互安装 API。[用 URL 方案打开/创建快捷指令](https://support.apple.com/ja-jp/guide/shortcuts-mac/apda283236d7/mac)、[导入快捷指令](https://support.apple.com/zh-cn/guide/shortcuts-mac/apd02bffbaac/mac)
- **已证实：**另一条受支持的**交互式**安装路径是 iCloud share link：接收者点击链接，核对说明后点 Get Shortcut，Shortcut 才被加入其库。该页面也说明共享/签名为防篡改会把副本交给 Apple 验证；它不是 CLI install API。[在 Mac 上共享快捷指令](https://support.apple.com/ja-jp/guide/shortcuts-mac/apdf01f8c054/mac)
- **已证实：**`shortcuts run` 的 name/identifier 指的是**用户快捷指令库中的 Shortcut**，不是 `VoiceMemos.SearchRecordings` 等 App Intent identifier；help 只承诺这一层的选择。`list --show-identifiers` 能发现库 ID，但本研究按边界未运行它。重名时选哪个、名称归一化、identifier 跨设备/重装稳定性均为**未知**。
- **已证实：**Shortcuts.app 和 `/System/Library/CoreServices/Shortcuts Events.app` 的 AppleScript dictionary 都声明了 application 的 `shortcut` elements（name/id 访问器）；每个 shortcut 可只读 `name`、`id`、`accepts input`、`action count`，并有 `run` command：直接参数是 shortcut，可选 `with input`，结果是 `any`。dictionary 明示：要后台运行、且不打开 Shortcuts.app，应 tell `Shortcuts Events`。Apple 的 WWDC21 也给出了 name 运行和 Swift `ScriptingBridge` 到 bundle ID `com.apple.shortcuts.events` 的示例。[系统 dictionary（下方复现命令）](#可复现的只读检查)、[Meet Shortcuts for macOS，25:39](https://developer.apple.com/videos/play/wwdc2021/10232/?time=1539)
- **已证实：**当前 Voice Memos metadata 中，`SearchRecordings` `openAppWhenRun=true`、`outputFlags=0`、没有 `outputType`；因此它**不会向后续快捷指令动作或 CLI 声明结构化搜索结果**。它确实以搜索系统协议注册，但“会进入哪个 UI 状态、会不会显示匹配列表”在本研究边界内未实际运行，故为**未知**。不能把它实现为 `search → JSON records`。
- **已证实：**录音/文件夹是私有 `AppEntity`；metadata 只给出显示属性和私有 `EntityStringQuery` 名称，不给 ID 格式或外部构造器。Swift 的公开 `AppEntity`/`EntityQuery` 协议要求由实体所属 app 实现 `entities(for:)`、`suggestedEntities()` 和字符串匹配；Voice Memos 的具体类型不在公开 macOS SDK 中。外部 Swift CLI 不能调用这些 query 来按 UUID 建立 `RCRecordingEntity`。[`AppEntity`](https://developer.apple.com/documentation/appintents/appentity)、[`EntityStringQuery`](https://developer.apple.com/documentation/appintents/entitystringquery)

这条链路应严格区分：

```text
Voice Memos App Intents 可被 Shortcuts.app 发现
                 !=
Swift CLI 可创建并安装有这些动作的 Shortcut
                 !=
Swift CLI 可为动作注入任意录音 ID、无提示执行并收 JSON
```

## 当前 macOS 26 / Voice Memos 3.2 元数据

证据等级：下表的字段均为**已证实（本机静态 metadata）**，不是 Apple 对第三方的长期 API 保证。`mode`/`auth` 是文件中的原始数值；不要把数值反推出未文档化的执行或确认语义。`D` 为 `isDiscoverable`，`Open` 为 `openAppWhenRun`，`Out` 为声明的输出类型。

| action key / identifier | D / Open / auth / mode | 参数 | Out | 直接含义与桥接限制 |
| --- | --- | --- | --- | --- |
| `ChangeRecordingPlaybackSetting` | 是 / 是 / 0 / 4 | `changeOperation: ChangeOperation`、`setting: RecordingSettingType`（均必填） | 无 | 设置类、前台可继续；不是录音 CRUD。 |
| `CreateFolder` | 是 / 否 / 0 / 1 | `name: String?` | `RCFolderEntity` | 唯一声明实体输出的公开动作之一；CLI 是否可把该 entity 序列化到 stdout，**未知**。 |
| `DeleteFolder` | 是 / 否 / 0 / 1 | `entities: [RCFolderEntity]` | 无 | 破坏性；必须先由 Shortcuts 解析实体。 |
| `DeleteRecording` | 是 / 否 / 0 / 1 | `entities: [RCRecordingEntity]` | 无 | 破坏性；没有结构化确认/回执声明。 |
| `OpenFolder` | 是 / 是 / 0 / 4 | `target: RCFolderEntity` | 无 | 打开 UI，不是列出文件夹。 |
| `PlaybackVoiceMemoIntent`（类型为 `VoiceMemos.PlayRecording`） | 是 / 否 / 2 / 1 | `playbackType: PlaybackType` 必填（默认 `mostRecent`）；`entity: RCRecordingEntity?` | 无 | metadata 明示认证策略值 `2` 且显式设定；实际认证提示时机需实验。 |
| `RCCombineRecordings` | 否 / 否 / 0 / 1 | `firstRecording?`、`secondRecording?` | `RCRecordingEntity` | 非 discoverable 内部动作，不可作为 v0.1 依赖。 |
| `RCControlCenterToggleRecording` | 否 / 是 / 0 / 2 | `value: Bool` | 无 | 非 discoverable Control Center 内部动作。 |
| `RCImportRecording` | 否 / 否 / 0 / 1 | `audioFile` 必填、`title: String?` | `RCRecordingEntity` | 非 discoverable 内部动作；`audioFile` 的 metadata type 为 Intents type 12，不能据此承诺任意文件导入。 |
| `RecordVoiceMemoIntent`（类型为 `VoiceMemos.CreateRecording`） | 是 / 否 / 0 / 1 | `name: String?` | 无 | 会涉及麦克风/录制状态，超出 v0.1。 |
| `SearchRecordings` | 是 / 是 / 0 / 2 | `searchPhrase: String` | **无** | 仅有 search protocol 和前台标记；不是 results API。 |
| `SelectRecording` | 是 / 是 / 0 / 2 | `target: RCRecordingEntity` | 无 | 打开选定实体的 UI；CLI 无法构造 target。 |
| `StopRecording` | 是 / 否 / 0 / 1 | 无 | 改变全局录制状态，非 v0.1。 |
| `ToggleRecording` | 否 / 否 / 0 / 1 | 无 | 非 discoverable 内部动作。 |

枚举同样为**已证实（本机 metadata）**：

- `RecordingSettingType`: `enhanceRecording`、`skipSilence`、`studioVoice`。
- `PlaybackType`: `mostRecent`、`specific`。
- 系统 `ChangeOperation`: `disable`、`enable`、`toggle`。

实体和查询：

| entity | 可见属性 | 默认 query | 关键限制 |
| --- | --- | --- | --- |
| `RCRecordingEntity` | `name: String`、`creationDate: Date`、`duration: Swift.Duration` | `VoiceMemos.RCRecordingEntityStringQuery` | 有 `AppEntity` 身份但 metadata 不披露其 `id` 类型/格式；名字、时间和时长不保证唯一，不能把名字当稳定 selector。`duration` 只在 macOS 26+ metadata 标为可用。 |
| `RCFolderEntity` | `name: String`、`recordingCount: Int` | `VoiceMemos.RCFolderEntityStringQuery` | 同样不披露 ID；`name` 也不能当稳定 selector。 |

两个 query 均无 metadata 参数、`capabilities=70`、无排序声明。**推断：**Shortcuts 编辑器会用 Voice Memos 自己的 dynamic entity picker/query 来解析动作参数；这可解释 UI 选择实体，但不能替代外部 CLI 的枚举和精确绑定。若相同名称、相近时间或本地/iCloud 状态导致歧义，系统如何提问或挑选是**未知**，必须在隔离账户验证后才可描述。

### rename、Recently Deleted 与 delete

- **已证实：**当前完整 action inventory 没有 `RenameRecording` 或 `RenameFolder`。Apple 用户指南确认两者可以在 Voice Memos UI 中改名，不能推导出 Shortcut/CLI 动作存在。[编辑/重命名录音](https://support.apple.com/guide/voice-memos/edit-a-recording-vmac7e39c22e/3.2/mac/26)、[管理文件夹](https://support.apple.com/guide/voice-memos/organize-recordings-vmef955050b0/mac)
- **已证实（UI 语义）：**从 Voice Memos UI 删除的录音会先进入 Recently Deleted；删除文件夹也会将其录音移动到 Recently Deleted；之后可恢复或 `Delete Forever`，且永久删除会影响同一 Apple Account 的设备。[删除录音](https://support.apple.com/en-ke/guide/voice-memos/vmc3c0776462/mac)、[管理文件夹](https://support.apple.com/guide/voice-memos/organize-recordings-vmef955050b0/mac)
- **推断：**`DeleteRecording`/`DeleteFolder` App Intent 会沿用同一业务语义，而不是立即物理删除；未运行实证，不能把 Recently Deleted 当成 CLI 的回滚承诺。动作 inventory 中也没有 recover、empty-recently-deleted 或 delete-forever 动作。

## `/usr/bin/shortcuts`：已支持和缺失的能力

| 需求 | 只读验证结果 | 产品含义 |
| --- | --- | --- |
| 生成 Shortcut | **没有 CLI 子命令。**官方 URL 只能打开新建编辑器。 | No-Go：不能由 Swift CLI 受支持地构造 Voice Memos action graph。 |
| 安装/导入 Shortcut | **没有 CLI 子命令。**官方文档要求 Finder/Shortcuts.app GUI 导入。 | 只能用户手工安装；签名不是安装。 |
| 导出 Shortcut | **没有 CLI 子命令。** | CLI 不能通过公开命令取得或校验库中 helper 的内容；本研究也禁止读取现有 Shortcut。 |
| 签名 `.shortcut` | `shortcuts sign --input --output [--mode]` 可自动签名**已有**文件。 | 不是 create/import/export/install；签名/分享验证会把副本发给 Apple，须评估 helper 内的隐私内容。 |
| 调用 | `shortcuts run <shortcut-name-or-identifier> [-i path] [-o path] [--output-type UTI]`。 | 可以调用**已经在用户库中**的 helper，不是调用 Voice Memos action ID。 |
| 输入 | CLI 可用 `-i` 传文件路径；管道传入的路径按文本处理。Shortcut 作者也可手工把 Shortcut Input、Text、Ask for Input 或变量绑定到动作参数。 | 当前 Voice Memos metadata 的参数都 `isInput=false`，但这不排除 editor 手工绑定；`searchPhrase` 或 entity 参数的解析、同名歧义、询问/确认和失败语义都**未知**，不得称为稳定参数 API。 |
| 输出 | 末动作/Stop and Output 产生 text、image、file 等时可用 `-o` 或 stdout；成功退出 0、失败 1。 | Voice Memos 的 search/select/delete/play/record 皆未声明输出，不能得到录音 JSON。只有 create folder/内部动作声明 entity 输出，CLI 序列化方式仍**未知**。 |
| `list`/`view` | 都存在；`list --show-identifiers` 可显示用户库 ID，`view` 以 name 打开编辑器。 | 本研究没有调用，避免读取个人快捷指令；也不能用于无交互 preflight。 |

Apple 明示命令行中出现 alert 或需要输入时，进程会暂停；最有效的命令行快捷指令是不显示 alert 或索要输入的那些。[从命令行运行快捷指令](https://support.apple.com/en-ca/guide/shortcuts-mac/apd455c82f02/mac) 这正与 Voice Memos 的实体选择、权限和可能前台执行相冲突。

`shortcuts://run-shortcut` 与 x-callback URL 也只能按**已保存的 shortcut name**运行；URL 模式只支持 text/clipboard 输入，x-callback 只返回文本 `result` 或错误，不能解决实体 ID 或安装问题。[用 URL 方案运行快捷指令](https://support.apple.com/en-gb/guide/shortcuts-mac/apd624386f42/mac)、[x-callback URL](https://support.apple.com/ja-jp/guide/shortcuts-mac/apdcd7f20a6f/mac)

### AppleScript / Shortcuts Events 的补充通道

**已证实（系统 dictionary）：**可以按 name 或 `id` 从 `Shortcuts Events` 的 `shortcuts` element 中取一个**已在用户库中存在**的 helper，并执行：

```applescript
tell application "Shortcuts Events"
    set helper to first shortcut whose id is "<user-library-shortcut-id>"
    set resultValue to run helper with input "<text-or-file-value>"
end tell
```

这比 `/usr/bin/shortcuts run` 多出 dictionary 所声明的 `any` result 通道，也可由 Swift 的 `ScriptingBridge` 调用；但不改变边界：它不能创建或编辑 shortcut action graph，不能从外部构造 `RCRecordingEntity`，不能把 `SearchRecordings` 变成 records 输出，也没有声明删除确认或稳定的错误/取消语义。引用 `shortcuts`、`name`、`id`、`accepts input` 或 `action count` 会读取用户库，故本研究没有运行这些脚本。

**已证实（权限边界）：**这是 Apple Events 自动化，不是普通子进程调用。Apple 要求发送 Apple events 的 app 提供 `NSAppleEventsUsageDescription`；采用 Hardened Runtime 的 app 还需 Apple Events entitlement 才能请求用户授权。Apple 的 Shortcuts macOS session 进一步说明：sandbox app 要用 ScriptingBridge 访问 Shortcuts Events 的 list/run，应配置 scripting target `com.apple.shortcuts.run`。因此生产 CLI/宿主必须处理 Automation/TCC 拒绝；具体何时弹窗、Terminal/非 sandbox tool 的授权主体以及 error code 的稳定性仍为**未知**。[Apple Events entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.automation.apple-events)、[`NSAppleEventsUsageDescription`](https://developer.apple.com/documentation/bundleresources/information-property-list/nsappleeventsusagedescription)、[Meet Shortcuts for macOS](https://developer.apple.com/videos/play/wwdc2021/10232/?time=1539)

## 交互、TCC/Automation 与版本边界

- **已证实：**Shortcuts 会按快捷指令请求必要数据访问；用户可选 Allow Once、Always Allow 或 Don’t Allow，且可在该 Shortcut 的 Privacy 设置中撤销。因而 `shortcuts run` 不等于无提示或拥有 Voice Memos 数据权限。[Shortcuts 隐私设置](https://support.apple.com/guide/shortcuts-mac/adjust-privacy-settings-apd961a4fc65/mac)
- **已证实：**App Intents 可声明 background/foreground 执行模式，系统可在条件允许时把 app 切到前台；metadata 的 `openAppWhenRun` 和 `supportedModes` 恰是实施方的运行时选择，CLI 不能覆盖。[`supportedModes`](https://developer.apple.com/documentation/appintents/appintent/supportedmodes)
- **已证实：**Voice Memos bundle 不带 `.sdef`，`sdef /System/Applications/VoiceMemos.app` 当前报 `error -192`。所以没有受支持的 AppleScript dictionary 可绕过 Shortcut 的交互层。
- **未知：**在当前/Sequoia 上，各动作在 Terminal 触发时是否弹出确认、认证、麦克风、Shortcuts 隐私或 Automation 提示；是否可在锁屏、无 GUI session、后台 agent、焦点切换时完成；失败码是否能稳定区分取消/无权限/实体歧义。这些都不能从静态 metadata 或 `--help` 得到。
- **已证实：**Apple 在 macOS 15.0 release notes 中记录过 Shortcuts editor 曾展示“尚未可用”的新动作，保存后可能需要未来更新修正。这是 action availability 的直接版本风险证据。[macOS Sequoia 15 release notes](https://developer.apple.com/documentation/macos-release-notes/macos-15-release-notes)
- **已证实：**Apple 在 iOS/iPadOS 16.0 的更新记录首次列出 Voice Memos 的 Search/Open/Delete/Play/Create/Setting 等九类动作；当前 macOS 26 metadata 仍含其对应动作。对前一主版本 macOS 15，Apple 的 Voice Memos 用户指南可选 Sequoia 15 版本，且 App Intents 的公开协议自 macOS 13 起可用；但本机没有 macOS 15 bundle，Apple 也没有在这次找到一份逐 action、逐 minor-version 的 macOS 15 contract。因此“该九项在 macOS 15 仍可用”是**强推断，不是本机实证**；内部 key、参数、输出、认证与实体 ID 更不能承诺一致。[Shortcuts 更新记录](https://support.apple.com/en-us/101583)、[Voice Memos User Guide（含 Sequoia 版本选择）](https://support.apple.com/en-ae/guide/voice-memos/vm4a03609f0d/mac)

Apple 官方将 App Intents 定义为 app 将其动作提供给系统体验的类型；这不是向另一个第三方 app 导出可链接的 Swift module 或 RPC。[App Intents](https://developer.apple.com/documentation/appintents/app-intents) 因此 `VoiceMemos.*` metadata identifier、`RCRecordingEntity`、`RCFolderEntity`、metadata `mode/auth` 数值和 action 文件格式必须视为**实现/发现数据**：升级、语言、地区、iCloud 状态、实体索引和 Shortcuts 运行时均可能改变行为。

## v0.1 命令边界

| 命令/能力 | 判定 | 理由 |
| --- | --- | --- |
| 读取用户显式导出的音频并做 CLI 自有处理 | **Go** | 不需要控制 Voice Memos；遵循现有数据访问研究的只读边界。 |
| `open` Voice Memos 或说明手工操作 | **Go** | 人工确认路径，不伪装为 API。 |
| `/usr/bin/shortcuts run` 或 AppleScript/`Shortcuts Events` 运行用户手工安装的、无实体参数、非破坏性 helper | **Experimental** | 前者有 CLI 输入/输出通道，后者有 Apple Events 的 `with input`/result 通道；两者仍可能提示、遇到 TCC/Automation、前台或版本变化，且不得承诺 Voice Memos 结构化结果。 |
| 按 CLI 给定 recording UUID/name 精确 search/select/play/delete/rename | **No-Go** | 无公开 entity 构造/ID 查询/参数注入桥；名称有歧义。 |
| `search` 返回列表、转写或 JSON | **No-Go** | `SearchRecordings` 无声明输出。 |
| 自动 create/import/export/sign 并安装 helper | **No-Go** | 没有公开 CLI create/import/export；sign 可处理已有文件但不等于 install，且会提交副本验证。 |
| iCloud share link → 用户点 Get Shortcut 安装预构建 helper | **Go（交互式分发）** | Apple 支持的人工确认安装路径；不是 CLI 或无人值守安装，仍需用户检查内容与权限。 |
| create folder / import audio / record / stop / delete / change playback setting | **No-Go（v0.1）** | 影响用户数据、权限或全局状态；动作可发现不等于可无人值守安全执行。 |
| rename recording/folder | **No-Go** | UI 支持，但当前 metadata 没有对应 action。 |

## 若要升级为实验，先取得的授权与隔离门槛

本研究**未执行**以下操作。只有用户明确授权，才可在独立 macOS 测试用户、独立/未登录 iCloud Apple Account、可丢弃测试录音和手工创建的测试 Shortcut 上进行：

1. 用 GUI 手工创建每个候选 helper，或让用户通过 iCloud share link 点击 Get Shortcut 安装预构建 helper；由用户目视确认其 action、参数、Privacy 权限和删除语义。不得复制或读取现有个人 Shortcut。
2. 对单一非敏感测试录音分别验证：无匹配、单一匹配、同名多条、Recently Deleted、离线/iCloud 未下载、锁屏和拒绝权限。记录只含状态/退出码，绝不采集真实标题、音频或转写。
3. 分别测 `/usr/bin/shortcuts run` 和 AppleScript/`Shortcuts Events` 的 name 与 user-library identifier 行为、text/file 输入、`-o`/stdout 或 AppleScript result、超时、取消、Automation/TCC 拒绝及前台窗口变化；验证是否有可机器读取的返回值。
4. 对 macOS 15 和 26 分别固定 OS、Voice Memos、Shortcuts 版本并重新盘点 metadata；任何 identifier、参数、输出或提示差异都使该 helper 版本锁定且默认关闭。

若上述实证未得到“可无 UI、可注入唯一实体、可区分失败且可收结构化输出”的结果，保持 Production No-Go，不以 UI 自动化、私有 Shortcut 文件格式、私有 Voice Memos XPC 或数据库写入补洞。

## 可复现的只读检查

以下命令均不读取快捷指令库或 Voice Memos 用户数据：

```zsh
sw_vers
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  /System/Applications/VoiceMemos.app/Contents/Info.plist
/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' \
  /System/Applications/VoiceMemos.app/Contents/Info.plist

/usr/bin/shortcuts --help
/usr/bin/shortcuts run --help
/usr/bin/shortcuts list --help
/usr/bin/shortcuts view --help
/usr/bin/shortcuts sign --help

# 只读取系统 scripting dictionary；不会枚举用户的 shortcuts。
sdef /System/Applications/Shortcuts.app | \
  rg 'element type="shortcut"|property name="(name|id|accepts input|action count)"|<command name="run"|with input|the result of the shortcut|Shortcuts Events'
sdef '/System/Library/CoreServices/Shortcuts Events.app' | \
  rg 'element type="shortcut"|property name="(name|id|accepts input|action count)"|<command name="run"|with input|the result of the shortcut|Shortcuts Events'
/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
  '/System/Library/CoreServices/Shortcuts Events.app/Contents/Info.plist'

meta=/System/Applications/VoiceMemos.app/Contents/Resources/Metadata.appintents/extract.actionsdata
file "$meta"
jq -r '.actions | keys[]' "$meta"
jq -c '.actions | to_entries[] | {
  key: .key, id: .value.identifier, discoverable: .value.isDiscoverable,
  opensApp: .value.openAppWhenRun, auth: .value.authenticationPolicy,
  mode: .value.supportedModes, parameters: .value.parameters,
  outputType: .value.outputType
}' "$meta"
jq -c '.entities | to_entries[] | {
  key: .key, query: .value.defaultQueryIdentifier, properties: .value.properties
}' "$meta"

test ! -e /System/Applications/VoiceMemos.app/Contents/Resources/VoiceMemos.sdef
sdef /System/Applications/VoiceMemos.app  # 当前：error -192
```

不要把 `shortcuts list`、`view` 或任何 `run` 加进自动检查：它们会访问/打开/执行用户的真实 Shortcut，超出本研究的只读边界。
