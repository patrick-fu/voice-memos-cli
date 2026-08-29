# Voice Memos rename/delete：input synthesis 之外的替代路线

研究日期：2026-08-30。目标：对公开分发的独立 macOS CLI，判断除「AXUIElement 语义校验 + CoreGraphics `CGEvent` 双击/键盘输入」外，是否还有可精确 rename/delete Voice Memos 的替代。

本次检查只读系统 app、SDK headers、launchd plist、App Intents metadata 与官方文档；**未启动 Voice Memos，未读取/输出任何真实录音、标题、转写、数据库行或用户容器内容**。下文「已证实」只覆盖本机静态事实或已引用的 Apple 一手资料；live UI 事实仅复述仓库已验证、且不包含用户数据的探针结论。

环境指纹：macOS 26.6.1（25G76）；Voice Memos 3.2 / `CFBundleVersion` 1380；SDK `/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.2.sdk`。

## 结论先行

**不存在**同时满足下列全部条件的替代：

1. **public**：只用公开 SDK / 官方文档合同，不伪造私有 entitlement、不依赖未文档化 XPC/schema；
2. **standalone**：独立 Developer ID CLI 即可完成，不要求用户预装 Shortcut、不把操作交给人工；
3. **exact**：用 CLI 的 opaque Recording ID 唯一对准一条录音，不靠 title/index；
4. **reliable**：版本/语言/窗口状态下可 fail-closed 验证；
5. **完全不使用 input synthesis**：不 `CGEventPost` / `CGEventPostToPid` / System Events `click`/`keystroke`/`key code`，也不用等价 HID 注入。

本机已验证的唯一 exact 选择原语，仍是 input synthesis：干净唯一 `AXStandardWindow` 下，exact AX frame + `AXUIElementCopyElementAtPosition` hit-test + 全局 `CGEvent` 双击可选中目标；选中后按钮 fresh raw Name `编辑标题` 进入编辑，取消不改 title。build 1380 列表项是虚拟 `AXButton`；`AXSearchField`/`AXTextField` 的 `SetValue` 不触发过滤；`AXPress` 不选择。生产 mutation 当前 fail closed。

| 路线 | 避开 CGEvent？ | exact opaque-ID？ | 权限 | 可公开分发 | 可靠性 | 结论 |
| --- | --- | --- | --- | --- | --- | --- |
| 1. AppleScript / System Events / JXA / NSAppleScript / ScriptingBridge | 对 Voice Memos 本体：无 dictionary。对 System Events：否（click/keystroke 即合成输入）；`perform`/`select` 仍是 UI scripting | 否。无 sdef，无 Recording ID 对象 | Automation（Apple Events）；System Events UI scripting 是否仍需 Accessibility：**未在本次实机证明** | 可以分发调用代码，但不能声称受支持 Voice Memos API | 无 dictionary 则不可用；UI scripting 随窗口/语言/虚拟列表变化 | **No-Go** 作为 rename/delete 后端 |
| 2. Shortcuts / App Intents | 是（不经 CGEvent） | **不能由 CLI 构造。** `DeleteRecording`/`SelectRecording` 要 `RCRecordingEntity`；metadata 无 ID 格式；无 `RenameRecording` | Shortcuts/Automation；动作本身的确认语义 **未运行** | CLI 可调用 `shortcuts run <用户库 shortcut>`；不能安装/注入 Voice Memos 实体 | delete 依赖 Voice Memos 自己的 entity query；rename 不存在 | **不能 standalone exact。** delete 最多是用户预装 helper + 动态 picker，不是 opaque-ID RPC |
| 3. 公开 AX：`AXSelected` / `AXPress` / custom action / menu | 是（纯 AX 不发 CGEvent） | AX 树没有 Recording ID；`AXIdentifier` 不得当作 ID | Accessibility；`AXIsProcessTrustedWithOptions` 检查当前进程 | 公开 HIServices API，可进 Developer ID CLI | 本机已否证 `AXPress` 选择与 search `SetValue` 过滤；custom action 只在选中后出现 | **选择 No-Go；选中后 custom action 可作后续 primitive，不能单独完成 exact target** |
| 4. CoreGraphics 变体（`CGEventPost` / `PostToPid` / keyboard） | **否。** 全是 input synthesis | 否。事件只打到坐标或 pid，exact 仍靠 AX 绑定 | 公开 API；接收键盘 tap 需 Accessibility（header 对 tap，不是对 post）。post 是否还要 AX：**未证** | 可分发；是否纳入产品需显式决策 | 本机全局双击在唯一窗口下已成功选择；多窗口/遮挡 fail closed | **不是「替代」，是当前唯一已验证选择手段的变体** |
| 5. NSWorkspace / URL scheme / Services / Share | 是 | 否。无 Voice Memos URL scheme，无 NSServices，Share 不接受 opaque ID | 启动 app 无额外 automation 权限 | 可分发 | 只能打开 app / 打开 `.qta` 类型，不能 rename/delete | **No-Go** |
| 6. 私有 VoiceMemos.framework / XPC / `voicememod` | 是 | 未知内部是否按 `uniqueID`；无公开协议 | 私有 entitlement：`com.apple.private.voicememod.client`、Mach lookup `com.apple.voicememod.xpc` 等 | **不可。** 第三方不能合法声明这些 entitlement | 无 ABI/协议合同 | **No-Go** |
| 7. 直接写 Core Data / SQLite / CloudKit | 是 | 模型有 `uniqueID`，但那是私有 store，不是 API | FDA 最多影响文件 open，不授予 CloudKit/XPC 语义 | 改别人的容器/镜像不是受支持分发功能 | 绕过 `voicememod` 与 CloudKit mirroring；Recently Deleted/`encryptedTitle` 无公开写入合同 | **No-Go** |
| 8. selected-only / 人工桥 | 是（CLI 不点选） | 仅当用户或另一条已验证路径先选中；CLI 不能凭 ID 选 | 打开 app 无额外权限；若再用 AX action 仍要 Accessibility | 可分发为辅助路径 | 依赖人工或 Shortcuts picker；不是 unattended exact | **辅助 Go；不能替代 token-confirmed mutation 后端** |
| 9. helper app vs CLI | 不创造新 mutation API | 同所选后端 | 改变 TCC identity（bundle vs 裸 Mach-O）；沙盒 helper 必须继承 host sandbox | 可公开分发 helper/CLI，但不获得私有 Voice Memos 能力 | 只改善权限声明/UI，不解决 exact 选择 | **包装选择，不是替代后端** |

## 已验证本机 UI 事实（仓库既有探针，本次未复跑）

这些事实约束所有 UI 路线；它们不是新实验。

- build 1380 录音列表项是虚拟化 `AXButton`，不是带 `AXIdentifier == Recording ID` 的行。
- 对搜索框 `AXSetValue` 不触发过滤。
- `AXPress`（含先设 `AXFocused`）不选择录音；按 AX frame 单击与 `AXShowMenu` 也不是可靠选择。
- 额外 non-modal `AXDialog` 存在时，坐标探针失败。
- 干净、唯一 `AXStandardWindow` 下：exact AX item frame + `AXUIElementCopyElementAtPosition` hit-test + 全局 `CGEvent` 双击，成功把 detail title 绑到目标 description 前缀。
- 选中后列表按钮 custom action 集出现 fresh raw Name `编辑标题`；执行后进入可聚焦、可 set 的 title field；原生取消退出，title exact bytes 不变。
- 生产 coordinator 已接线 raw-token 保留/重读/执行，但 mutation safety gate 仍 fail closed；CGEvent 尚未进入生产。

公开 AX 常量与调用见：

- `kAXButtonRole`：[`AXRoleConstants.h:146`](/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.2.sdk/System/Library/Frameworks/ApplicationServices.framework/Versions/A/Frameworks/HIServices.framework/Versions/A/Headers/AXRoleConstants.h)
- `kAXStandardWindowSubrole`：同文件:414
- `kAXSearchFieldSubrole`：同文件:425（`AXSearchField`，不是独立 role）
- `kAXPressAction`：[`AXActionConstants.h:34-40`](/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.2.sdk/System/Library/Frameworks/ApplicationServices.framework/Versions/A/Frameworks/HIServices.framework/Versions/A/Headers/AXActionConstants.h)（注释写明「Simulate clicking」）
- `kAXShowMenuAction`：同文件:110-114
- `AXUIElementPerformAction` / `CopyElementAtPosition` / `SetAttributeValue`：[`AXUIElement.h:207-223, 315-353`](/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.2.sdk/System/Library/Frameworks/ApplicationServices.framework/Versions/A/Frameworks/HIServices.framework/Versions/A/Headers/AXUIElement.h)
- `kAXIdentifierAttribute`：[`AXAttributeConstants.h:1297`](/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.2.sdk/System/Library/Frameworks/ApplicationServices.framework/Versions/A/Frameworks/HIServices.framework/Versions/A/Headers/AXAttributeConstants.h)（无「等于业务 ID」合同）

## 1. AppleScript / System Events / JXA / NSAppleScript / ScriptingBridge

**已证实（本机）：**

- 无 `VoiceMemos.sdef`；`sdef /System/Applications/VoiceMemos.app` 返回 `error -192`。
- Info.plist 无 `NSAppleScriptEnabled`、无 `OSAScriptingDefinition`。
- ScriptingBridge 公开工厂要求 OSA-compliant scripting interface，否则返回 `nil`。[`SBApplication.h:125-132, 153-156, 175-178`](/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.2.sdk/System/Library/Frameworks/ScriptingBridge.framework/Versions/A/Headers/SBApplication.h)
- 内嵌执行入口是 `NSAppleScript` `initWithSource:` / `executeAndReturnError:`。[`NSAppleScript.h:32, 44`](/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.2.sdk/System/Library/Frameworks/Foundation.framework/Versions/C/Headers/NSAppleScript.h)
- System Events 有 Processes Suite：`click`（含全局坐标）、`key code`、`keystroke`、`perform`（对 UI action）、`select`（set selected）。[`SystemEvents.sdef:948-987, 1236-1260`](/System/Library/CoreServices/System%20Events.app/Contents/Resources/SystemEvents.sdef)

**推论：**对 Voice Memos 不能 `tell application "Voice Memos"` 做 rename/delete。JXA/`osascript`/`NSAppleScript`/ScriptingBridge 只能改打 System Events。`click`/`keystroke` 是 input synthesis；`perform`/`select` 是 AX UI scripting 的 Apple Event 包装，不提供 Recording ID，也不能绕过 build 1380 上已被否证的 `AXPress` 选择语义。

**权限：**跨进程 Apple Events 走 Automation TCC。外部 `/usr/bin/osascript` 的 sender 是 `osascript`，不是本 CLI。System Events UI scripting 是否仍要 Accessibility：公开 sdef 未写明，本次未测，不得假设已免除。

**公开分发：**可以。无受支持 dictionary 则没有可承诺的对象模型。

**结论：No-Go。** 不能 exact，不能当作静默 fallback。

## 2. Shortcuts / App Intents

公开 App Intents 合同是「应用作者实现并暴露给系统体验」，不是第三方按 identifier 直调。[Creating your first app intent](https://developer.apple.com/documentation/appintents/creating-your-first-app-intent)。`AppEntity` 必须由所属 app 提供 `defaultQuery`；`EntityQuery.entities(for:)` 在实现方进程内解析 ID。[`AppIntents.swiftinterface:521-526, 4182-4184`](/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.2.sdk/System/Library/Frameworks/AppIntents.framework/Versions/A/Modules/AppIntents.swiftmodule/arm64e-apple-macos.swiftinterface)。公开 macOS SDK **没有** `VoiceMemos` framework 或 `RCRecordingEntity` 类型。

**已证实（本机 metadata）** `/System/Applications/VoiceMemos.app/Contents/Resources/Metadata.appintents/extract.actionsdata`（`version.json` toolsVersion `17E6107`）：

| action | discoverable | openAppWhenRun | 参数 | rename/delete 含义 |
| --- | --- | --- | --- | --- |
| `DeleteRecording` | 是 | 否 | `entities: [RCRecordingEntity]` | 破坏性；无结构化回执。是否 Recently Deleted：**未运行** |
| `SelectRecording` | 是 | 是 | `target: RCRecordingEntity` | 打开 UI，不是 rename |
| `SearchRecordings` | 是 | 是 | `searchPhrase: String` | `outputFlags=0`，无结果类型 |
| `CreateFolder` / `DeleteFolder` / `OpenFolder` | 是 | 见 metadata | 文件夹实体 | 与单条录音 rename 无关 |
| `RecordVoiceMemoIntent` / `PlaybackVoiceMemoIntent` / `StopRecording` | 是 | 见 metadata | 录制/播放 | 非 v0.1 mutation |
| `RCImportRecording` | **否** | 否 | `audioFile`, 可选 `title` | 非 discoverable；`title` 不是 rename 已有录音 |
| 全表 14 个 action | — | — | — | **没有 `RenameRecording` / `RenameFolder`** |

`RCRecordingEntity` 可见属性只有 `name`、`creationDate`、`duration`；default query `VoiceMemos.RCRecordingEntityStringQuery`，无 metadata 参数。系统 `DeleteIntent` 形状是 `entities: [Entity]`（[`AppIntents.swiftinterface:1566-1568`](/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.2.sdk/System/Library/Frameworks/AppIntents.framework/Versions/A/Modules/AppIntents.swiftmodule/arm64e-apple-macos.swiftinterface)），与 `DeleteRecording` 参数吻合，这只说明 Voice Memos 自己实现了删除 intent，不把该类型交给外部 CLI。

旧 Intents extension `VoiceMemosIntentsExtension.appex` 的 `IntentsSupported` **只有** `RecordVoiceMemoIntent`，无 delete/rename。

`/usr/bin/shortcuts` 子命令仅 `run` / `list` / `view` / `sign`。`run` 的参数是**用户快捷指令库**的 name/identifier，不是 `VoiceMemos.DeleteRecording`。无 generate/install 子命令。Shortcuts Events dictionary 可 `run` 一个 `shortcut`，可选 `with input`。[`Shortcuts.sdef:27-78`](/System/Library/CoreServices/Shortcuts%20Events.app/Contents/Resources/Shortcuts.sdef)

用户指南只提供 App 内编辑/重命名与删除到 Recently Deleted，没有 Shortcut rename 动作。[编辑录音](https://support.apple.com/guide/voice-memos/edit-a-recording-vmac7e39c22e/3.2/mac/26)

**结论：**可避开 CGEvent，但不能 standalone exact。无 rename action。delete 若走用户手工安装的 Shortcut，实体解析权在 Voice Memos query，CLI 不能注入 opaque Recording ID。不得把 Shortcuts 当静默后端。

## 3. 公开 AX APIs（非 CGEvent）

公开可变接口就是：读/写 attribute（`AXUIElementSetAttributeValue`）、列举/执行 action（`AXUIElementCopyActionNames` / `PerformAction`）、命中测试（`CopyElementAtPosition`）。自定义 action 没有单独 API，只是 element 报告的 `CFString` name，再原样交给 `PerformAction`。

与「不合成输入就能选中」相关的标准手段：

- `kAXPressAction`：header 定义为模拟 click。本机对虚拟 `AXButton` **不选择**。
- `kAXSelectedAttribute` / `kAXSelectedChildrenAttribute`：后者在「没有其他方式改变选择」时才建议可写。[`AXAttributeConstants.h:535-552, 1037`](/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.2.sdk/System/Library/Frameworks/ApplicationServices.framework/Versions/A/Frameworks/HIServices.framework/Versions/A/Headers/AXAttributeConstants.h)。build 1380 列表不是带 selected-children 合同的 outline/table；不得假设可写 `AXSelected` 等于选中录音。
- `kAXShowMenuAction`：本机不是可靠选择。
- search `SetValue`：本机不触发过滤。
- custom action：`删除`/`重新命名`/`编辑标题` 是本地化 raw token。`编辑标题` 只在选中后出现；它证明 **post-selection** primitive，不证明 selection。

权限：`AXIsProcessTrustedWithOptions` 返回**当前进程**是否 trusted；prompt 异步，不影响返回值。[`AXUIElement.h:54-64`](/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.2.sdk/System/Library/Frameworks/ApplicationServices.framework/Versions/A/Frameworks/HIServices.framework/Versions/A/Headers/AXUIElement.h)

**结论：**纯公开 AX 在 1380 上不能 exact 选择。可公开分发，但不能替代已验证的双击选择。若产品接受「先选中再用 raw `编辑标题`」，那仍依赖路线 4 或人工选择。

## 4. CoreGraphics 变体

公开 API：

- `CGEventCreateMouseEvent` / `CGEventCreateKeyboardEvent`：[ `CGEvent.h:57-82`](/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.2.sdk/System/Library/Frameworks/CoreGraphics.framework/Versions/A/Headers/CGEvent.h)
- `CGEventPost(tap, event)`：注入到 `kCGHIDEventTap` / `kCGSessionEventTap` / `kCGAnnotatedSessionEventTap`。同文件:347-354；位置枚举 [`CGEventTypes.h:402-405`](/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.2.sdk/System/Library/Frameworks/CoreGraphics.framework/Versions/A/Headers/CGEventTypes.h)
- `CGEventPostToPid(pid, event)`：把事件投给指定进程。`CGEvent.h:356-374`。Apple developer 文档页本次抓取失败，以 SDK header 为准。
- `CGEventPostToPSN`：deprecated，改用 `PostToPid`。

键盘 event tap 的接收需要 assistive access（header:269-276）。**这描述的是 tap 监控，不是 post。** 本次未证明 `CGEventPost`/`PostToPid` 在本系统是否还要 Accessibility。

`PostToPid` 相对全局 HID post 的产品差异：可能减少打到错误 app 的概率，但 **仍然是 input synthesis**，仍然要靠 AX frame/hit-test 决定点哪里，仍然不能编码 opaque Recording ID。键盘输入同理：它只覆盖 rename commit/cancel，不覆盖列表选择。

**结论：**这是当前已验证选择路径的变体，不是避开 input synthesis 的替代。若生产采纳，必须继续唯一窗口 + exact frame hit-test + fail closed。`PostToPid` vs 全局 post 的可靠性差异 **未在本次比较实测**。

## 5. NSWorkspace / URL scheme / Services / Share

**已证实（本机 Info.plist）：**

- 无 `CFBundleURLTypes`。
- 无 `NSServices`。
- 无 `CFBundleDocumentTypes`。
- 唯一 `UTExportedTypeDeclarations`：`com.apple.quicktime-audio` / `.qta`。不是 mutation URL。

公开启动 API：`NSWorkspace.openURL` / `openApplicationAtURL`。[`NSWorkspace.h:36-46`](/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.2.sdk/System/Library/Frameworks/AppKit.framework/Versions/C/Headers/NSWorkspace.h)

`NSSharingService` 是**本进程**发起的分享服务（Mail/Messages/AirDrop/CloudSharing 等），不是 Voice Memos 的 rename/delete 入口。[`NSSharingService.h:25-56, 111, 137`](/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.2.sdk/System/Library/Frameworks/AppKit.framework/Versions/C/Headers/NSSharingService.h)

Voice Memos 自己的 Mach lookup 含 `com.apple.UIKit.ShareUI*`，那是系统 app 的私有分享 UI，不是第三方 CLI 合同。

**结论：No-Go。** 最多打开 app，供路线 8 使用。

## 6. 私有 VoiceMemos.framework / XPC / voicememod

**已证实：**

- 公开 SDK 无 `VoiceMemos.framework`。
- 系统实现在 `/System/iOSSupport/System/Library/PrivateFrameworks/VoiceMemos.framework/`；本机该 bundle 对第三方可见的是 Resources/`VoiceMemos.momd` 与 signature，不是 public headers。
- LaunchAgent `/System/Library/LaunchAgents/com.apple.voicememod.plist`：`Program`=`.../Support/voicememod`；MachServices：`com.apple.voicememod.xpc`、`com.apple.voicememod.datastore.Cloud`、`com.apple.aps.voicememod`。
- App entitlement 含 `com.apple.private.voicememod.client`、`com.apple.private.security.storage.VoiceMemos`、`com.apple.security.temporary-exception.mach-lookup.global-name` 列出 `com.apple.voicememod.xpc` 与 `.datastore.Cloud`。
- `voicememod` entitlement 含 `com.apple.VoiceMemosContainer` CloudKit container、`com.apple.private.cloudkit.*`、app group `group.com.apple.VoiceMemos.shared`。

公开 `NSXPCConnection initWithMachServiceName:` 可以**构造**本地对象，header 明确「不表示 service 合法或已启动」。[`NSXPCConnection.h:51-56`](/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.2.sdk/System/Library/Frameworks/Foundation.framework/Versions/C/Headers/NSXPCConnection.h)。没有公开 XPC 接口定义、没有第三方 lookup entitlement。

Hardened Runtime / Developer ID 不能合法嵌入 `com.apple.private.*`。即使连上，也没有版本化协议。

**结论：No-Go。** 不可公开分发。

## 7. 直接 Core Data / SQLite / CloudKit 写

**已证实：**

- 当前模型版本 `VoiceMemos14`（`VersionInfo.plist` `NSManagedObjectModel_CurrentVersionName`）。
- `VoiceMemos14.mom` 字符串含 `RCCloudRecording`、`uniqueID`、`customLabel`、`encryptedTitle`、`evictionDate`、`path`、`audioDigest`、`RCEntityRevision`。这是私有 schema 线索，不是写入 API。
- 公开 `NSPersistentCloudKitContainer` 管理**本应用 entitlements 里的** CloudKit 容器，默认用「应用程序 entitlements 中的第一个 CloudKit container」。[`NSPersistentCloudKitContainer.h:31-47`](/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.2.sdk/System/Library/Frameworks/CoreData.framework/Versions/A/Headers/NSPersistentCloudKitContainer.h)。第三方没有 `com.apple.VoiceMemosContainer`。
- App 数据容器受 sandbox / 系统保护。[Protecting local app data using containers](https://developer.apple.com/documentation/xcode/protecting-local-app-data-using-containers)

FDA 只影响能否 open 文件，不提供 Core Data 历史、CloudKit mirror、Recently Deleted 或 `encryptedTitle` 的一致性语义。直接改 `customLabel`/`evictionDate` 会与 `voicememod` 并发、WAL 和远端同步竞争。

**结论：No-Go。** 即使 CLI 能打开 DB，也不是可公开承诺的 mutation 后端。

## 8. selected-only / 人工桥

两条不合成输入的弱路径：

1. **人工：**`NSWorkspace` 打开 Voice Memos，用户在 UI 完成 rename/delete。CLI 可事后用只读 snapshot 核对。无 exact 自动化。
2. **已选中再 AX：**若 Verifiable UI Session 里目标已选中，fresh 重读 custom action token 再 `PerformAction`。选择本身仍不是这条路径提供的。`SelectRecording` Shortcut 把选择交给 Voice Memos entity picker，不是 opaque-ID。

**结论：**辅助 Go。不能作为 standalone exact unattended 后端，也不能让生产从 fail closed 自动升级。

## 9. helper app vs CLI

公开文档：嵌入沙盒 app 的 helper **必须继承 host 的 sandbox**，不能当逃逸舱。[Embedding a helper tool in a sandboxed app](https://developer.apple.com/documentation/xcode/embedding-a-helper-tool-in-a-sandboxed-app)

对 v0.1 非沙盒 Developer ID CLI：

- helper/.app bundle 可以带 `Info.plist`、`NSAppleEventsUsageDescription`、独立 TCC identity；
- 不能因此获得 Voice Memos 私有 entitlement、sdef、URL scheme 或 `RCRecordingEntity` 构造器；
- 「给 Terminal 授权」≠「给 CLI 授权」仍成立；host app 授权也不自动传给独立子进程（既有权限研究；本次未做新的 TCC 继承实测）。

**结论：**只改变包装与 TCC 主体，不改变第 1–7 条的能力边界。若 mutation 最终需要 Accessibility + CGEvent，bundle helper 可能让授权 UX 更清晰，但仍是同一后端。

## 总判定

| 需求 | 现状 |
| --- | --- |
| 完全避开 input synthesis 的 exact rename | **没有。** 无 rename App Intent，无 sdef，纯 AX 不能选择 |
| 完全避开 input synthesis 的 exact delete | **没有 standalone 路径。** `DeleteRecording` 存在但不能从 CLI 构造 `RCRecordingEntity`；SQL/XPC 不可分发 |
| 已验证 exact 选择 | 唯一窗口 + AX frame/hit-test + `CGEvent` 双击（input synthesis） |
| 已验证 post-selection rename 进入/取消 | raw `编辑标题` + 原生取消；**commit 未验证** |
| 生产 | fail closed |

因此：要公开、独立、精确、可靠地 rename/delete，当前证据下必须要么接受受约束的 AX + input synthesis，要么放弃自动化 mutation、改走人工/用户安装 Shortcuts。不存在第三条同时满足全部约束的路。

## 未证（不阻塞本文件结论）

- `CGEventPost` vs `CGEventPostToPid` 在 1380 上的选择成功率差异。
- System Events `perform`/`select` 是否仍要 Accessibility，以及它是否复现 `AXPress` 失败。
- `DeleteRecording` 是否 Recently Deleted 语义、有无确认 UI。
- 用户 Shortcut 能否把任意字符串当成 `RCRecordingEntity` ID 传入。
- rename commit（新 title + 确认）的 AX/CGEvent 状态机。
- Apple `CGEventPostToPid` 开发者文档页本次 HTTP 抓取失败。
