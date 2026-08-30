# macOS 权限与自动化约束（v0.1）

> **当前产品决策（2026-08-30）：** `voice-memos-cli` 当前是安全只读检索/导出 CLI，只支持 `list/search/show/export/doctor`；不支持 `rename/delete`，不要求也不使用 Accessibility、CGEvent、mutation token 或 Shortcuts 写后端。本文是研究/历史证据，记录既有调研与失败路径，不作为当前实现计划。后续还出现的 `doctor --ui`、AX/token/rename/delete 执行协议均属旧研究设计或未采纳方案，不代表当前 CLI 接口。

研究日期：2026-08-28。最初目标是为一个独立分发、可经 Homebrew 安装、使用 Developer ID 签名的 Swift CLI，研究两条能力的权限和运行边界：

- 只读访问 Voice Memos 的私有本地数据，以实现 `list/search/show/export`；
- 用 `AXUIElement` 驱动已验证的 Voice Memos UI mutation，而**不**写私有数据库。

本研究没有读取录音、标题、转写、数据库行或任何 Voice Memos 用户容器；本机检查只读系统 SDK、系统 app、签名元数据和 launchd plist。下文的“已证实”只表示引用资料或静态检查实际证明的事实；“推论”是据此作出的产品判断；“待实机验证”不得作为 v0.1 承诺。

## 已废止的早期 v0.1 决策

本节记录当时评估过但最终未采纳的 mutation 产品设计。当前有效结论只有只读 `list/search/show/export/doctor`；下表及后续 AX/token 执行协议不得用作当前接口或实现依据。

| 能力 | 决策 | 条件 |
| --- | --- | --- |
| `list/search/show/export` | **Blocked** | schema、state predicate 与资产语义尚未完成 disposable 验证；production read 保持 fail closed。FDA 不是已证明的最小或唯一可行授权。 |
| `rename/delete` | **已接线，当前 fail closed** | production coordinator 已要求 Accessibility、opaque-ID/UI tuple、持久 token、显式确认及逐条 fresh pre/post verification。已识别 build 1380 的虚拟化 `AXButton` 与 opaque custom-action token；`AXSetValue` search isolation 和 `AXPress` selection 已被 live probe 否证。干净单窗口下，AX frame/hit-test + native `CGEvent` double-click 可选择 exact item，选中后 raw `编辑标题` 可进入编辑并取消。是否接受 AX + input synthesis、以及 rename commit transition 尚未决策/验证，production 继续拒绝。 |
| 打开 Voice Memos、人工操作 | **Go（辅助路径）** | 可用于用户自行完成操作，但不是 `rename/delete` 命令的替代后端。 |
| System Events/JXA UI scripting | **No-Go（默认实现）** | 它增加 Apple Events/Automation 面；尚无证据证明它能免除 Accessibility。仅可作为单独、后续实验证明的兼容后备。 |
| 直接改 Voice Memos SQLite、资源或 CloudKit mirror | **No-Go** | FDA 只解决文件可读性，不提供 Core Data、`voicememod`、CloudKit 或 Recently Deleted 的一致性契约。 |
| 私有 XPC/framework | **No-Go** | 当前没有普通 Developer ID CLI 的公开协议、授权或兼容性契约。详见已有[私有 API 调研](private-api-community-survey.md)。 |

**旧架构（已废止）：**曾考虑让非沙盒、Developer ID 签名并公证的单一 CLI 同时承载只读 adapter 与 AX mutation adapter，并用一次性 token、显式确认和 fresh verification 约束 `rename/delete`。该架构没有进入当前产品；现有生产代码不包含 AX adapter、mutation token 或 write port。

早期设计曾把 `rename/delete` 视为 v0.1 命令；该决定已被 2026-08-30 的只读范围取代。当前 help 不注册这两个命令，调用时返回 usage error。

待 AX + native input synthesis 的产品边界、rename commit transition 与 action 后 postcondition 通过完整验证后，才考虑实际 token-confirmed 与无人值守执行。CLI 不根据“已解锁”“SSH”“后台”之类的 session 标签预判安全；只根据当下能否访问 Voice Memos UI、唯一证明目标并完成 fresh pre/post verification 决定执行。当前 production read 仅在 exact build gate 下启用；mutation 已接线但保持 fail closed。v0.1 不做 telemetry、网络请求或 crash upload，也不写 Voice Memos 的逻辑数据库、asset 或 CloudKit mirror。

## 权限矩阵

| 路径 | 最小权限/机制 | 授权主体与运行约束 | 失败关闭策略 |
| --- | --- | --- | --- |
| 读取 Voice Memos app/group container、SQLite snapshot、已本地化 asset | **推荐 FDA（`SystemPolicyAllFiles`）** 作为稳定宽授权；也可能受 `SystemPolicyAppData`、POSIX ACL、MAC/SIP/容器保护、iCloud 占位和文件锁限制 | Apple 明示 FDA 必须由用户在系统设置授予，不能用 entitlement 或代码自动取得；FDA 可访问其他 app 的数据。它不是本研究证明的最小或唯一授权。当前系统的 Voice Memos 是 sandboxed，且拥有自己的 app group/私有 storage entitlement。 | 任何 `EACCES`/`EPERM`、未知路径/schema、snapshot 不一致、源变动或 asset 未下载：不读、不降级为写入，返回可操作诊断；不要把错误精确归因为某一个 TCC service。 |
| 原生 `AXUIElement` 读取/按压 Voice Memos UI | **Accessibility**，调用 `AXIsProcessTrustedWithOptions` 检查当前进程 | API 返回的是“当前进程”是否为 trusted accessibility client；提醒可异步显示，返回值不会等待授权。CLI 运行时验证目标 app、窗口、元素和焦点，不按锁屏、SSH、launchd/headless 标签建立静态 allowlist 或 denylist。 | 不受信任、找不到目标 PID/window、元素歧义、`kAXErrorCannotComplete`、超时或 UI 状态改变：不重试，不猜测元素 index，返回机器可读 `mutation_preflight_failed`。 |
| 外部 `/usr/bin/osascript`（JXA/AppleScript）→ System Events | **Apple Events/Automation**；System Events 是否还依赖 Accessibility 待实测 | 实际 Apple Event sender 是外部 `osascript` 进程；本 CLI 的 `Info.plist`/entitlement 不会自动附着到它。TCC 归属、System Events/调用方的 Accessibility 需要单独实测。 | Automation 拒绝、System Events/Voice Memos 未响应或 UI 不匹配：停在人工操作，不回退到 AX 或私有 store 写入。 |
| 内嵌 OSA 或本 CLI 直接 Apple Event API → System Events | **Apple Events/Automation**；System Events 的 Accessibility 依赖待实测 | 发件者是本 CLI/其 app host。若该发件者作为 app 使用发送 Apple Events API，须提供 `NSAppleEventsUsageDescription`；Hardened Runtime app 还须有 `com.apple.security.automation.apple-events` 才能提示。 | Automation 拒绝、usage string/entitlement 缺失、System Events/Voice Memos 未响应或 UI 不匹配：停在人工操作，不回退到 AX 或私有 store 写入。 |
| 启动 Voice Memos、人工操作 | 无额外 CLI automation 权限 | 仅交互式；用户决定是否继续。 | 打不开、前台状态不确定或用户取消：返回取消，不模拟点击。 |

**已证实：**Apple 将 Full Disk Access、Accessibility 和 Automation (Apple events) 列为独立的用户授权项；前者允许访问全机文件（包括其他 app 数据），后两者分别是控制 Mac 和控制其他 app 的能力。[Platform Security：控制 app 文件访问](https://support.apple.com/guide/security/secddd1d86a6/web)；[系统设置说明](https://support.apple.com/en-ie/guide/mac-help/mchl211c911f/mac)。所以 FDA 既不自动授 AX，也不自动授 Apple Events。

## 只读数据访问：FDA、容器与沙盒

### 已证实

- App Sandbox 只赋予 app 自己 container 的不受限访问；即使 sandbox 允许某路径，POSIX ACL 或 macOS 强制访问控制仍可拒绝。[Accessing files from the macOS App Sandbox](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox)
- Apple 明确：app **不能**靠 entitlement 或代码自动获得 FDA；用户必须在 **System Settings → Privacy & Security** 授予。[同上](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox)
- 本机 macOS 26.6.1、Voice Memos 3.2 (1380) 静态检查到 Voice Memos 带 `com.apple.security.app-sandbox`、application groups、`com.apple.private.security.storage.VoiceMemos`、`com.apple.private.voicememod.client` 和私有 Mach lookup entitlement；`com.apple.voicememod.xpc`/`.datastore.Cloud` 是 `voicememod` launch agent 声明的 Mach services。这些是系统 app 能力线索，不是第三方 API 或可取得的 entitlement。
- Mac App Store 分发必须启用 App Sandbox；Apple 的 sandbox 限制明确把 assistive app 的 Accessibility API 使用和向任意 app 发送 Apple Events 列为不兼容活动。[Protecting user data with App Sandbox](https://developer.apple.com/documentation/security/protecting-user-data-with-app-sandbox)

### 推论与设计

1. 这个 Developer ID CLI 不应启用 App Sandbox。它的功能是读取另一 app 的受保护 private container；用户选择文件夹获得 security-scoped URL 的沙盒模型，并不能稳定代表或替代对 Voice Memos group container 的访问。
2. FDA 是推荐的稳定宽授权安装说明，但不是已证明的最小或唯一条件；它仍只让文件 open **有机会**成功，不授权私有 XPC、解密未公开字段、下载 iCloud asset，也不解决 SQLite/CloudKit 一致性。
3. 只读 adapter 默认从 source read-only SQLite handle 使用 SQLite-native `sqlite3_backup` 生成 snapshot，**不**手工复制 sidecar。`-wal` 与 `-shm` 均不存在是 SQLite clean-close 的正常状态，不能因此拒绝读取或强制要求 `-shm`。仅在人工 quiescent 诊断 fallback 中，可复制 DB 加上当时存在的 WAL；绝不复制 live `-shm`，由副本 SQLite 自行重建。source read-only handle 是否会因 VFS/journal state 创建或更新协调 sidecar，仍是待隔离验证/产品政策边界；无论结果如何，CLI 绝不写逻辑数据库或 asset。详见[数据访问研究](voice-memos-data-access.md)与[社区/私有 API 调研](private-api-community-survey.md)。
4. 不读取实际 recording 前也可做结构 preflight：OS/Voice Memos build、候选目录是否可 traverse、DB 是否可读、可见 journal state、schema version/allowlist。preflight 输出不得包含标题、路径中可识别的 recording 信息或内容。

## AXUIElement：权限、身份和可靠性

### 已证实

- `AXIsProcessTrustedWithOptions` 返回**当前进程**是否为受信任的 Accessibility client；`kAXTrustedCheckOptionPrompt: true` 只会异步通知用户，不能把 `false` 变为同步成功。[Apple API 文档](https://developer.apple.com/documentation/applicationservices/1459186-axisprocesstrustedwithoptions)
- 本机 Xcode 26.2 SDK 的 `AXUIElement.h` 对该函数的声明与上述一致；同一 header 说明 `AXUIElementCreateApplication(pid)` 只创建目标 app 的顶层 accessibility object，且 messaging failure 可返回 `kAXErrorCannotComplete`。这没有给 UI tree、role、title 或 action 一个稳定合同。
- Apple 支持文档说明第三方 app 请求通过 Accessibility 控制 Mac 时，用户需在 Privacy & Security 中明确允许或拒绝。[Allow accessibility apps to access your Mac](https://support.apple.com/en-euro/guide/mac-help/-mh43185/mac)

### Issue #26 disposable AX evidence（脱敏）

在 build 1380 的两条 disposable 上，AX row 与选中的 title field 均无可用 AXIdentifier 或 opaque DB ID。row 暴露 title/time description、duration、selection 与 native custom actions；选中的 title field 可 set。对 title field 调用 `AXSetValue` 后，选择另一条唯一匹配的 disposable row 可以提交。两条样本均通过 fresh owner-only backup integrity 检查，且 backup 期间 source metadata 稳定。改名后 UI title 与 `ZCUSTOMLABELFORSORTING`、`ZENCRYPTEDTITLE` exact equal；`ZCUSTOMLABEL` 不等于新的 UI title。证据不记录真实 title、ID、path、时间或大小。

**定位约束：** 不得假设 `AXIdentifier == ID`。实现必须用 opaque DB ID + 唯一、validated UI tuple 建立 fail-closed 映射；同 tuple 匹配多条即 ambiguous。build 1380 production read 已由 exact schema gate 启用；mutation 仍 fail closed。delete/restore state rule 见下方 round-trip 证据。

**Round-trip state evidence（同一 issue，脱敏）：** 在 Recently Deleted view 对 row 执行 Delete 曾出现 Permanent Delete 确认；操作已取消且未永久删除。故 delete preflight 必须验证 All Recordings view；永久删除与全部删除永不执行。对一条 disposable 完成 Recent→restore→Active snapshot→All view delete→Recent snapshot→restore→final snapshot：完整 29 列中 Active→Recent 仅 `ZEVICTIONDATE` 由 NULL 变为 non-NULL real 值并伴随 `Z_OPT` 改变，Recent→restored 反向，final restored 与 initial active 仅 `Z_OPT` 不同；第二条 Recent disposable 也为 non-NULL real `ZEVICTIONDATE`。UI folder counts 每次仅 ±1，不记录实际 count。settings 的 30 days 仅作 diagnostic，不作为 predicate。当前 build state rule：Active=`ZEVICTIONDATE IS NULL`；Recently Deleted=`ZEVICTIONDATE` 为 non-NULL real 值；`Z_OPT` 不参与；未知类型 fail closed。标题已恢复，第一条 active，第二条未突变；临时 snapshot/probe 已永久清理。证据不记录真实 title、ID、path、timestamp、count 或 audio。

### Issue #28 原生 AX 结构证据（脱敏）

2026-08-30 对已运行的 build 1380、`zh-Hans` Voice Memos 做了只读 `AXUIElement` 探针。探针只输出 role/action/attribute 形状与布尔关系；title 仅在进程内按 UTF-8 exact bytes 与只读 DB projection 比对，没有输出 title、ID、path、时间、数量或音频。

- 可见录音项是 `AXButton`，不是 `AXRow`；没有可依赖的 `AXTable`/`AXList`。可见项只是 Active DB projection 的严格子集，因此不能把当前树当成完整列表。
- 每个列表按钮的 `AXDescription` 以 exact title 加 `", "` 开头。目标匹配应使用 resolver 已证明唯一的完整 title 前缀；禁止从 description 反解析任意 title。
- 列表按钮暴露 `AXPress` 与 `个人收藏`、`删除`、`移动` custom actions；选中详情的另一 `AXButton` 暴露 `重新命名`、`删除`。后者不等于已证明 rename edit/commit 协议。
- `AXUIElementCopyActionNames` 返回的 custom action 是多行 opaque token，例如首行 `Name:删除` 后还有桥接字段。语义识别可读取首行 label，但 `AXUIElementPerformAction` 必须使用 fresh tree 返回的完整原始 token。畸形、重复、未知与永久/批量删除类 label 全部 fail closed。
- 窗口内有唯一、当前为空且 `AXValue` settable 的 `AXSearchField`，以及唯一承载列表按钮的可滚动 `AXGroup`。后续写入探针证明 `AXSetValue` 只改变 accessibility value，并不会可靠触发 Voice Memos 的实际过滤；`AXCancel` 能可靠清空。controlled search isolation 因此不可作为生产定位方案。

同一次获授权的可逆 UI 探针还证明：对列表 `AXButton` 执行 `AXPress`、先设 `AXFocused` 再 `AXPress`、按 AX frame 定向发送单击，以及 `AXShowMenu`，都不能作为 standalone CLI 的可靠选择语义。Computer Use 在 fresh tree 上双击可选中目标，选中项随后暴露“编辑标题”；执行后出现 focused、settable title field，Escape 可取消，且取消后 title exact bytes 不变、search 为空、菜单关闭。

进一步将 Voice Memos 重启为干净、唯一 `AXStandardWindow` 后，standalone probe 以 exact AX item frame 做 `AXUIElementCopyElementAtPosition` hit-test，再发送 native `CGEvent` double-click，成功让 detail title 与目标 description 前缀绑定。选中列表按钮的 custom action 集新增 `编辑标题`；执行其 fresh raw token 后，原有 detail title field 获得焦点，native cancel 退出且没有写 title。此前失败的 coordinate probe 发生在额外 non-modal `AXDialog` 存在时；生产若采纳该路线必须继续要求唯一 standard window，任何额外 window fail closed。该证据证明 selection/edit/cancel primitive 可实现，不等于已验证设置新 title 与 commit。

生产实现已支持 raw custom-action token 的保留、fresh 重读与原样执行，但仍保留 `rowsFullyRealized: false` 和 mutation safety gate。CGEvent input synthesis 尚未进入生产；分页扫描的可恢复性、rename commit、Recently Deleted 定位和 action 后 postcondition 在 live 验证完成前均不得启用。搜索隔离已从候选方案中移除。

### 进程身份：必须保守处理

**已证实：**AX API 的检查对象是“current process”；`tccutil reset` 允许按 service 和 bundle ID 重置授权。[重置受保护资源授权](https://developer.apple.com/documentation/xcode/resetting-access-to-protected-resources-in-macos)

**待实机验证：**Apple 的公开资料没有在本研究范围内说明下列场景的 TCC identity 归属或继承规则：用户从 Terminal 直接执行独立 CLI、`sudo`、Homebrew 链接/升级后的二进制、由 LaunchAgent/launchd 调用、SSH 会话，或由一个 GUI host app 嵌入 helper。不得假设“给 Terminal 授权”会自动等于“CLI 已授权”，也不得假设 host app 的授权会自动传给独立子进程。

**产品要求：**doctor 和每个 `rename/delete` action 都由实际执行该调用的 binary 自检 `AXIsProcessTrustedWithOptions(nil)`；日志记录不含用户数据的 executable path、Team ID/signing identifier、版本、UID、是否有 `CGSession`，而不是根据 Terminal 设置猜测。若将来改为 sandboxed app 内 helper，Apple 明确要求 helper 继承 host sandbox 配置，不能把它当作绕过边界的办法。[Embedding a helper tool in a sandboxed app](https://developer.apple.com/documentation/xcode/embedding-a-helper-tool-in-a-sandboxed-app)

### GUI、锁屏与后台

**推论：**AX mutation 的实际对象是正在运行的 Voice Memos UI，因而前台窗口、焦点、modal sheet、语言、窗口层级和目标元素唯一性都是操作前条件，而不是 UI 细节。`AXUIElementCreateApplication(pid)` 的存在只证明可按 PID 建立入口，不保证元素可见、可操作或语义正确。

Apple 没有承诺锁屏、无 console GUI login、SSH、CI、LaunchDaemon 或后台 LaunchAgent 能可靠完成目标 UI 操作；这意味着它们不能获得静态成功承诺，不意味着 CLI 必须在 preflight 前按标签拒绝。v0.1 直接尝试建立可验证的 Voice Memos UI 状态：能唯一定位并完成 fresh pre/post verification 就允许无人值守执行；`kAXErrorCannotComplete`、目标 app 无响应、窗口/元素缺失、焦点漂移或超时才视为不可安全完成。

## 为什么不用 System Events/JXA 作为默认

### 已证实

- JXA 经外部 `/usr/bin/osascript -l JavaScript` 运行 Open Scripting Architecture 脚本；使用 System Events 需向另一个进程发送 Apple Events。Apple 的自动化文档将 AppleScript/JavaScript 的跨进程控制建立在 Apple Event Manager 上，并把 System Events 描述为可脚本化后台 app。[How Mac scripting works](https://developer.apple.com/library/archive/documentation/LanguagesUtilities/Conceptual/MacAutomationScriptingGuide/HowMacScriptingWorks.html)
- 使用发送 Apple Events API 的 **app** 必须提供 `NSAppleEventsUsageDescription`；Apple 特别指出这可能间接访问本不能直接读取的敏感数据。[NSAppleEventsUsageDescription](https://developer.apple.com/documentation/bundleresources/information-property-list/nsappleeventsusagedescription)
- 对启用 Hardened Runtime 的 **app**，`com.apple.security.automation.apple-events` 是让该 app 可提示用户取得发送 Apple Events 权限的 entitlement；同 Team ID/self 通信例外不适用于独立第三方发件者 → System Events → Voice Memos 的路径。[Apple Events entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.automation.apple-events)

### 结论

原生 AX 路径只需证明**本进程**已获 Accessibility，并直接使用公开 C API；它不向 System Events 发送 Apple Event，因此不引入 Automation target、Apple Events usage string 或该 Hardened Runtime entitlement。这是更小的权限面。

外部 `/usr/bin/osascript` 与内嵌 OSA/本 CLI 的 Apple Event API 必须分开：前者的 sender 是 `osascript`，不能把本 CLI 的 `Info.plist` 或 entitlement 自动归给它；后者才由本 CLI/host app 的 usage string、entitlement 和 TCC identity 负责。两条路径下 System Events UI scripting 是否仍需 Accessibility、授权记在哪个进程上都必须专门实测；没有证据能证明它消除了 Accessibility 要求。它也没有让 Voice Memos 获得稳定 AppleScript dictionary。本机静态检查还确认 Voice Memos 没有 `VoiceMemos.sdef`，`sdef /System/Applications/VoiceMemos.app` 返回 `error -192`。因此 System Events/JXA 保持 `rename/delete` 的默认 No-Go，且不能成为静默 fallback。

## 签名、公证与 sandbox 的最小配置

| 配置 | v0.1 结论 | 理由 |
| --- | --- | --- |
| Developer ID Application 签名、secure timestamp、Hardened Runtime | **需要** | Apple 要求公证的所有 executable 使用有效 Developer ID、签名、secure timestamp 和 Hardened Runtime，且明确包含 command-line targets。[Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution) |
| 公证 | **需要（分发质量门槛）** | 公证让 Gatekeeper 能识别经 Apple 扫描的 Developer ID 分发软件；它不是 App Review，也不授予 TCC/FDA/AX 权限。[同上](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution) |
| App Sandbox | **不要** | 对独立 Developer ID 分发不是 Apple 所述必需项；本项目的 container 读取和 AX assistive app 模式与沙盒边界冲突。这是基于 Apple sandbox 限制的设计推论。 |
| Apple Events entitlement / usage string | **默认不要** | 原生 AX 不需要。只有单独 shipping System Events/JXA backend 时才加，且需重新做 Automation 授权测试。 |
| 私有 Voice Memos entitlement、private Mach lookup | **绝不申请/伪造** | 系统 app 静态拥有它们不构成第三方部署许可；无公开协议或产品合同。 |

**待实机验证：**通过 Homebrew 的具体安装形式（bottle、formula from source、链接路径变化）是否影响 TCC 持久授权；将签名标识、绝对 executable path、版本和安装方式作为 test matrix，而不是把 Developer ID/公证误称为 TCC grant。

## `rename/delete` 执行协议（v0.1 contract）

`rename` 和 `delete` 当前约定的唯一写后端是原生 `AXUIElement`；它们不是私有 SQLite/asset/CloudKit 写入，也不允许 System Events/JXA 或 Computer Use 作为 silent fallback。是否将公开 CoreGraphics input synthesis 纳入同一受验证 UI backend，需要显式产品决策。协调器使用持久化、跨进程原子消费的 30 秒 token；记录只保留 request/source/AX/environment 的 SHA-256，根目录为 `~/Library/Application Support/vmemo/mutation-authorizations`，只在 mutation 首次尝试时惰性创建。session lock 覆盖 fresh resolver snapshot、AX verification、consume、action 与 DB/AX postcondition；action 或任一 postcondition 不确定后 token 仍不可重放。synthetic manifest、typed actions 和 opaque raw-token handling 已实现；该决策与 rename commit 验证完成前 production preflight fail closed，不触发 action。

**Store 信任边界：**0700 root、0600 records 和 `O_NOFOLLOW` 验证可拒绝 symlink、hardlink、FIFO、损坏记录等 hostile path node；跨进程 exactly-once 针对正常或竞争进程。它信任同 UID 进程及父目录：能替换整个 0700 root 的同 UID 恶意代码不在此威胁模型内，不能宣称 token/session store 可抵御该情形。

1. 命令先对每个请求的 Recording 建立一次性、短时有效的 opaque target token；token 绑定本次动作、目标的 fresh UI verification 和环境指纹，不能从 Title、列表 index 或旧 UI element 推导。
2. mutation 必须提供该 token 和显式确认。交互模式可要求用户输入确认；`--json`/非交互模式必须显式传入确认参数，且**不得**调用 `AXIsProcessTrustedWithOptions` 的 prompt option、显示确认窗口或任何 TCC 授权 UI。权限未满足时返回机器可读拒绝，留给用户在系统设置完成授权后重试。
3. 每条 action 都在按压前 fresh pre-verification：重新定位 Voice Memos、窗口和唯一目标，验证 token 仍匹配、焦点/模态状态符合预期；按压后做 fresh post-verification。无法证明预期状态转变即返回失败，不能以“未报错”视为成功。
4. v0.1 只提供 flat 的单 Recording 命令；不接受 batch 输入或返回 partial result。
5. `delete` 只在已验证的 **All Recordings** view 按原生 Voice Memos UI 的 **Delete** 语义把 Active Recording 移入 Recently Deleted；若当前 view 是 Recently Deleted，必须拒绝，避免触发 Permanent Delete 确认。Permanent Delete、全部删除、清空 Recently Deleted 和任何不可恢复删除均在 v0.1 scope 外，命令永不调用或模拟这些 UI action。

**后续条件：**若接受 AX + CGEvent，需把唯一窗口、exact frame hit-test、double-click 后 detail binding、scope-specific action allowlist、分页定位恢复和 rename commit 编码为 fail-closed contract；若不接受，则 mutation 保持不可用。之后才可实际执行 token-confirmed mutation 并评估非交互或无人值守调用。虚拟列表永不要求“完整实现”，search isolation 不再作为候选。CLI 不额外要求用户证明屏幕处于解锁状态；JSON 模式仍不得弹窗、请求 TCC 授权或绕过任一 preflight。

## Doctor、拒绝处理与失败关闭

### `doctor`（只诊断，不请求 mutation）

1. 输出 OS、Voice Memos build、CLI version、签名/Team ID/signing identifier、Hardened Runtime 与公证评估结果；不输出 Voice Memos 用户数据。
2. 分别检查文件 adapter 的候选目录可 traverse、DB 可读、schema allowlist、SQLite-native backup 的 source/destination 可用性和 asset 可用性；`-wal` 与 `-shm` 均不存在记为 `clean_close_no_sidecars`，不是错误。记录可见 journal state，但不要求或手工复制 sidecar；source read-only handle 的协调 sidecar 行为标为 `requires-isolated-vfs-validation`。对 `EACCES`/`EPERM` 同时给出可能相关的 FDA（`SystemPolicyAllFiles`）、其他 app data protection（`SystemPolicyAppData`）及 POSIX/MAC/容器保护诊断类别，但返回 `access_denied_unattributed`，不声称能准确归因。
3. 只有用户传 `doctor --ui` 时调用 `AXIsProcessTrustedWithOptions(nil)`；`false` 显示 System Settings 的 Accessibility 指引。普通 doctor 不设置 `kAXTrustedCheckOptionPrompt`，避免隐式弹窗；JSON doctor 也不得请求授权。
4. 仅当编译了**内嵌 OSA/直接 Apple Event API** backend 时检查本 CLI/host 的签名 entitlement 和 `NSAppleEventsUsageDescription`；外部 `osascript` backend 单独报告 `external_osascript_identity_unverified`，不能用 CLI metadata 替代其检查。不要通过发送测试 event 诊断，因为那会改变 TCC 状态/出现 UI。
5. 把“不能判断”明确输出为 `requires-interactive-test`：Terminal/host identity、lock screen、SSH、launchd、System Events 的 AX identity、外部 `osascript` 的 TCC identity、Voice Memos UI tree 是否适配当前语言/版本。

### 授权重置与支持流程

**已证实：**Apple 支持 `tccutil reset <service> [bundle-id]` 重置当前用户的受保护资源选择，服务包括 `Accessibility`、`AppleEvents` 和 `SystemPolicyAllFiles`；`sudo` 会影响所有用户。[重置受保护资源授权](https://developer.apple.com/documentation/xcode/resetting-access-to-protected-resources-in-macos)

支持文档可给出以下**用户显式执行**的开发/测试命令模板；不能由 CLI 自行执行，也不能把重置当作修复：

```zsh
# 把 <bundle-identifier-or-verified-cli-identity> 替换为实际、已核验的 identity。
tccutil reset Accessibility <bundle-identifier-or-verified-cli-identity>
tccutil reset AppleEvents <bundle-identifier-or-verified-cli-identity>
tccutil reset SystemPolicyAllFiles <bundle-identifier-or-verified-cli-identity>
```

standalone executable 是否可由 `tccutil` 的 identity 参数精确匹配仍待实测；doctor 必须显示这个未知项并要求用户用 UI 重新授权，不得假定可匹配。不得尝试修改 TCC database、使用 `sudo` 绕过授权或建议关闭 SIP。

### 统一 fail-closed 规则

- 只读：权限、schema、snapshot 一致性、资产本地化任一失败即不输出部分/陈旧结果；绝不为了“修复”写数据库或启动 UI automation。
- mutation：权限、GUI session、App/窗口、唯一目标、token、显式确认、预期 action、fresh pre/post verification 任一失败即不执行；不按 element index 猜目标，不回退 System Events/私有 SQL。v0.1 不支持 batch。
- 日志：只记录 capability state、错误域/码、版本和签名 identity；不记录 Recording ID、Title、路径、音频、转写或数据库值。

## 验收测试清单（只在隔离账户/可丢弃录音中执行）

以下是未来实现测试，**本研究没有执行**。与真实 Voice Memos 库、同步库或用户 Shortcut 无关的静态检查可随 CI 运行；涉及 TCC、UI 或容器的项目只能手工、隔离执行。

| 场景 | 期望 |
| --- | --- |
| FDA 未授予 / 授予 / 被撤销，以及可能的 app-data / POSIX/MAC 拒绝 | doctor 输出 `SystemPolicyAllFiles`、`SystemPolicyAppData`、POSIX/MAC 的候选诊断类别但不精确归因；`list/export` 在拒绝时无部分结果、无写入。 |
| 容器可达但 schema 未知、source 变化、iCloud asset 未下载 | 拒绝本次读取；不假定主库足够，不生成不完整 export。 |
| `-wal`/`-shm` 均不存在、任一存在、source handle 的协调 sidecar 行为 | 默认 `sqlite3_backup` 不手工复制 sidecar；两者均不存在按 clean-close 正常读取。仅人工 quiescent fallback 复制 DB+WAL、不复制 live `-shm`，由副本 SQLite 重建；source handle sidecar 行为须在隔离环境验证后才形成政策。 |
| Accessibility 首次、Allow、Deny、设置中撤销、`tccutil reset Accessibility` 后 | `AXIsProcessTrustedWithOptions(nil)` 与命令结果一致；prompt 异步，不把一次调用视为授权完成。 |
| 实际 CLI 直接运行、Terminal、Homebrew 安装、LaunchAgent、SSH | 分别记录 actual process identity 和 AX 结果；未证实的模式均不进入支持矩阵。 |
| 前台、锁屏、无 GUI login、Voice Memos 未运行/有 modal/无响应 | 不按 session 标签预先判定；逐项运行 UI 可达性与完整 token + fresh pre/post verification。能证明目标与结果才执行，否则安全停止，不尝试唤醒、解锁或绕过系统边界。 |
| System Events/JXA（若以后实现）Automation Allow/Deny/reset | 验证调用者 identity、usage string、entitlement、System Events/AX 归属和取消码；结果不满足可机器判定即移除 backend。 |
| AX rename/delete 单条、同名/排序变更/语言变更/UI 改版 | 操作前后按 token 绑定的受验证属性重新定位；显式确认后，歧义、元素变化、结果不可核验均停止。删除只验证原生 Recently Deleted UI 语义；Permanent Delete 不在 scope 内。 |
| 签名、公证、升级/Homebrew reinstall | `codesign`/`spctl` 检查通过；重新验证 TCC identity，而不是假定旧 grant 延续。 |

## 可复现的无用户数据静态检查

```zsh
sw_vers
xcrun --sdk macosx --show-sdk-version
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  /System/Applications/VoiceMemos.app/Contents/Info.plist

# AX API contract in the installed SDK; does not inspect any user container.
sdk="$(xcrun --sdk macosx --show-sdk-path)"
sed -n '43,70p' \
  "$sdk/System/Library/Frameworks/ApplicationServices.framework/Versions/A/Frameworks/HIServices.framework/Versions/A/Headers/AXUIElement.h"

# System app/daemon capability evidence only.
codesign -d --entitlements :- /System/Applications/VoiceMemos.app 2>&1 | \
  sed -n '/<?xml version=/,/<\/plist>/p' | plutil -p -
plutil -extract MachServices xml1 -o - \
  /System/Library/LaunchAgents/com.apple.voicememod.plist | plutil -p -

# Confirms no supported Voice Memos AppleScript dictionary on this system.
test ! -e /System/Applications/VoiceMemos.app/Contents/Resources/VoiceMemos.sdef
sdef /System/Applications/VoiceMemos.app

# Read usage only. Do not run reset without explicit test authorization.
tccutil
```

## 参考资料

1. Apple：[Accessing files from the macOS App Sandbox](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox)
2. Apple Platform Security：[Controlling app access to files in macOS](https://support.apple.com/guide/security/secddd1d86a6/web)
3. Apple：[AXIsProcessTrustedWithOptions](https://developer.apple.com/documentation/applicationservices/1459186-axisprocesstrustedwithoptions)
4. Apple：[Allow accessibility apps to access your Mac](https://support.apple.com/en-euro/guide/mac-help/-mh43185/mac)
5. Apple：[NSAppleEventsUsageDescription](https://developer.apple.com/documentation/bundleresources/information-property-list/nsappleeventsusagedescription)
6. Apple：[Apple Events entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.automation.apple-events)
7. Apple：[Protecting user data with App Sandbox](https://developer.apple.com/documentation/security/protecting-user-data-with-app-sandbox)
8. Apple：[Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
9. Apple：[Resetting access to protected resources in macOS](https://developer.apple.com/documentation/xcode/resetting-access-to-protected-resources-in-macos)
10. Apple：[How Mac scripting works](https://developer.apple.com/library/archive/documentation/LanguagesUtilities/Conceptual/MacAutomationScriptingGuide/HowMacScriptingWorks.html)
