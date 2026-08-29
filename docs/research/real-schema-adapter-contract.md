# 真实 Voice Memos 只读 schema adapter：允许表与阻断条件

研究日期：2026-08-29。对应 [issue #25](https://github.com/patrick-fu/voice-memos-cli/issues/25)（并延续 [issue #21](https://github.com/patrick-fu/voice-memos-cli/issues/21) 的语义边界）。本文件定义生产代码**可检测的结构**和必须拒绝的情况；它不把 Core Data 私有 SQLite 格式变成公开 API 合同。issue #27 已将本文件的 exact build-1380 metadata、29 列物理 schema、标题、状态和 asset 约束实现为只读 snapshot adapter；其他版本仍一律拒绝。

## 结论

**production 真实 read 仅在 exact macOS 26 build-1380 contract 下可用；mutation 仍 blocked。** macOS 26 的 bundle、store metadata、physical schema 与下列行级条件共同构成 fail-closed gate。

- 当前 build manifest 之外的 Title 语义，或 sorting/encrypted 两字段不一致时的 fallback；
- 哪些 `ZCLOUDRECORDING` 行处于正常资料库、Recently Deleted、云端占位或已驱逐状态；
- `ZPATH` 是否始终是相对路径、对应可导出的本地资产，或 `.qta` 的 export 语义。

当前 production contract 仅支持 **macOS 26 / Voice Memos build 1380 / VoiceMemos14** 的 exact identity、metadata 与 physical schema。`list`、`search`、`show` 和 `.m4a` `export` 只能通过安全临时 snapshot 进入该 contract；macOS 15 与任一其他 build 必须为 `unsupported_schema`。

这是有意收窄，不是由 synthetic fixture 推出真实兼容性。Apple 明确说明 Core Data 原生 SQLite store 格式是私有的，不应以 SQLite API 创建或修改该类 store；本项目只讨论受用户授权的只读 snapshot 检测，绝不写入。[“Persistent Store Types and Behaviors”](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/CoreData/PersistentStoreFeatures.html)

## 证据等级与边界

| 标记 | 含义 | 本文用途 |
| --- | --- | --- |
| **Apple metadata（观察）** | 本机已安装 Apple 签名 bundle、`.momd`、Info.plist、SDK header；只读、不启动 App、不读用户容器。 | 字段名、Core Data 类型、模型版本和 build gate。 |
| **Apple docs** | Apple 发布的 Core Data / Voice Memos 文档。 | metadata/model-hash 的正确用途、私有-store 边界。 |
| **Community code behavior** | 固定 commit 的公开源码实际做了什么。 | 仅作为候选实现与验证假设，不能提升为 Apple 语义。 |
| **非证据/待核验声明** | README、skill、issue 或作者的实测叙述，未逐行执行查询源码支持。 | 只记录风险或 validation 假设；不支持 gate、字段映射或语义结论。 |
| **Inference** | 为 fail-closed 产品行为作的设计选择。 | runtime gate、拒绝策略和安全路径策略。 |
| **Needs disposable-user validation** | 只能在隔离 macOS 用户、无真实 iCloud 数据的手动 matrix 验证。 | Title、state、placeholder、asset 与 macOS 15 支持。 |

本次验证使用了用户明确授权的 owner-only SQLite online backup、Apple bundle metadata 与 Voice Memos UI 状态；snapshot integrity ok，备份期间源 DB/WAL/SHM metadata 未变化。除两条专门创建的 disposable active sample 的脱敏字段关系外，不记录真实 title、ID、path，也没有读取录音、触发 TCC 权限提示或成功执行 UI mutation。

## 已观察的 macOS 26 Apple 元数据

### Build 与模型身份

**Apple metadata（观察）：** 当前主机是 macOS 26.6.1 (25G76)；`/System/Applications/VoiceMemos.app/Contents/Info.plist` 给出 `CFBundleIdentifier=com.apple.VoiceMemos`、`CFBundleShortVersionString=3.2`、`CFBundleVersion=1380`、`DTPlatformVersion=26.6`、`LSMinimumSystemVersion=26.6`。同一 build 的私有 framework 是：

```text
/System/iOSSupport/System/Library/PrivateFrameworks/VoiceMemos.framework
  /Versions/A/Resources/VoiceMemos.momd/VoiceMemos14.mom
  /Versions/A/Resources/VoiceMemos.momd/VersionInfo.plist
```

`VersionInfo.plist` 的 current model 是 `VoiceMemos14`；其 checksum 是
`f2VnefWShYEiB9Sc058A/GWR/33tzv6vFKYxARhArH0=`，`VoiceMemos14.mom` 的 SHA-256 是
`551215bc009cf2ca2282c3876fb8d454d526fb5c0158c5a2818a9c2243cbe052`。

可复现，不读取用户数据：

```sh
APP='/System/Applications/VoiceMemos.app'
MODEL='/System/iOSSupport/System/Library/PrivateFrameworks/VoiceMemos.framework/Versions/A/Resources/VoiceMemos.momd'
sw_vers
plutil -p "$APP/Contents/Info.plist"
plutil -p "$MODEL/VersionInfo.plist"
shasum -a 256 "$MODEL/VoiceMemos14.mom"
```

**Apple metadata（观察）：** `VersionInfo.plist` 内归档的 `NSManagedObjectModel_VersionHashes["VoiceMemos14"]` 如下。它是 bundle 内的归档数据，**不是**运行时 `NSManagedObjectModel.entityVersionHashesByName` 的同一 token；例如 `CloudRecording` 两者不同。因此它只能作为 bundle integrity/diagnostic evidence，不能放进 store-compatibility gate。

| entity | `VersionInfo.plist` archived hash |
| --- | --- |
| `CloudRecording` | `eDRSMKhHO1yeaP22HJ2TLfs1Mqv60ahZ6N80EotR8wM=` |
| `DatabaseProperty` | `DdeyItMrmgzYUVyA8NUAc8cS1Sr4LwwTo+KneZZrPBI=` |
| `EntityRevision` | `MCYSLwlQNrzkytEuk0Paa2vv7h+rbxnn3DWtIuHpxa0=` |
| `Folder` | `BTuJxZB4F1ci2UMqAPo0Fx2Oif08rXM0z+/UQoivHc0=` |
| `Migration` | `C9+RC8Owb0OTnIogkfdqVeaZV1hChUC6VuqvEwC0DUU=` |
| `Recording` | `l+6Nf+h4pgpvs9n/EqyKB5n5y0F2UwNh6/6d/evM+L8=` |

**Apple metadata（观察，runtime model）：** 将同一个 `VoiceMemos14.mom` 加入 `NSPersistentStoreCoordinator` 后，运行时 `entityVersionHashesByName["CloudRecording"]` 是 **`Q5vgte0JyNzGeRWTSQMvMe/yCVv4FqwlLinaPgrxQpw=`**，model-level `versionChecksum` 是 **`Rzot3jLpeh6rB1e94kW4C0J/n0J243OW8MgFMbjWzE4=`**。二者共同构成 bundle-loaded runtime model 的身份 fingerprint，但不与 snapshot store manifest 比较，也不可与 `VersionInfo.plist` 的 model checksum `f2V…` 混用。

| gate 角色 | runtime token | 用途 |
| --- | --- | --- |
| `CloudRecording` entity | `Q5vgte0JyNzGeRWTSQMvMe/yCVv4FqwlLinaPgrxQpw=` | 属于整份 runtime entity-hash dictionary 的一个值；只核验 bundle-loaded artifact identity。 |
| whole `VoiceMemos14` model | `Rzot3jLpeh6rB1e94kW4C0J/n0J243OW8MgFMbjWzE4=` | bundle-loaded runtime model fingerprint；不取代独立 observed store manifest gate。 |

可复现的纯 bundle/runtime-model dump（不打开 store）：

```sh
xcrun swift -e 'import Foundation; import CoreData
let u = URL(fileURLWithPath: "/System/iOSSupport/System/Library/PrivateFrameworks/VoiceMemos.framework/Versions/A/Resources/VoiceMemos.momd/VoiceMemos14.mom")
let m = NSManagedObjectModel(contentsOf: u)!
let c = NSPersistentStoreCoordinator(managedObjectModel: m) // 固化 model 后再取 checksum
for (name, hash) in m.entityVersionHashesByName.sorted(by: { $0.key < $1.key }) {
  print("entity.\(name)=\(hash.base64EncodedString())")
}
print("model.versionChecksum=\(m.versionChecksum)")
_ = c'
```

### 已观察的 build 1380 store manifest（脱敏）

**Observed fact（owner-only online backup）：** bundle 为 `com.apple.VoiceMemos` build `1380`，macOS `26.6.1`；store type `SQLite`，Core Data framework/max version `1526`，hash metadata version `3`，model version identifiers exact 为 `[""]`。实际 store 的 `CloudRecording` entity hash 为 `wzISBP+96pkUsBpdE2V3vJH08CnDBpBi8U/vSlVVosQ=`，store model checksum 为 `n+kk0f+uLXPDvdioHyMqmLay6VQ65HLL8r1c4DUtcII=`，store hashes digest 为 `8aTQVFaRoWcJjSrfUWGNhWxyl4H+gmCjrDT9k9CLVmm9OnpUALJH6sPZWbA1xKKrPOrD6x93sSkxLvIrC13PCA==`。其余五个 entity hash 与本文静态值一致；momd/optimized model 的 `CloudRecording` hash 为 `eDRSM…`（见上方归档表），runtime `.mom` hash 为 `Q5vg…`；所有 bundle model 版本均不与该 store exact 或 compatible。

这组值是当前唯一可放行的**独立 observed store manifest**，不是 Apple contract，也不是 runtime `.mom` 的替代品。旧版“store hashes 必须 exact 等于 static/runtime model，并且 `isConfiguration` 为 true”的 gate 已撤回；实测该假设会把已验证 store 错误判为 `unsupported_schema`。

**Physical schema observation（single build/store）：** `ZCLOUDRECORDING` 的 exact canonical schema（按 `cid` 排序的 `cid|name|type|notnull|default|pk`，共 29 列）以 SHA-256 `9f3c4d7a46bb8ef37028fefdaf30ef1da7d0e93b9494877e3871fdae40a9a511` 固化；声明类型观察到 `INTEGER`、`FLOAT`、`TIMESTAMP`、`VARCHAR`、`BLOB`。这只是 build 1380 的单一 store fingerprint，不是 Apple contract；不得据此推导 affinity、epoch、bit 意义或跨版本兼容性，也不得把未验证的其他表声明写入 gate。

**Issue #26 disposable evidence（两条、专门创建、脱敏）：** 在 build 1380 的两条 disposable 上，AX row 与选中的 title field 都没有可用的 AXIdentifier 或可回溯的 opaque DB ID。row 暴露 title/time description、duration、selection 与 native custom actions；选中的 title field 可 set。对 title field 调用 `AXSetValue` 后，再选择另一条唯一匹配的 disposable row 可以提交。两条样本均通过 fresh owner-only backup integrity 检查，且 backup 期间 source metadata 稳定。改名后的 UI title 与 `ZCUSTOMLABELFORSORTING`、`ZENCRYPTEDTITLE` **逐字相等**；`ZCUSTOMLABEL` 不等于新的 UI title。全文不记录真实 title、ID、path、时间或大小。

其中一条样本另做 owner-only `/tmp` copy 验收：source `lstat` 为 regular、非 symlink；destination 预先不存在；复制前后 source metadata 不变；source/destination SHA-256 相等；`file` 识别为 ISO Media Apple iTunes ALAC/AAC-LC `.M4A`（约 3 KB）。不记录文件名或内容 hash；该结果只证明本次样本的安全复制行为，不构成通用 asset/type 合同。

Computer Use edit action 不可用，未发生 rename；delete 未尝试。

Apple 将 runtime entity version hash 定义为持久化相关 entity/property 的 hash，且该信息会存进 store metadata；`NSStoreModelVersionHashesKey` 正是 metadata 中该信息的 key。[`NSEntityDescription.versionHash`](https://developer.apple.com/documentation/coredata/nsentitydescription/versionhash) [Store versions](https://developer.apple.com/documentation/coredata/store-versions) 这能识别 model 兼容性，**不**证明应用层 state 或字段内容语义未变。

### `CloudRecording` 模型属性 allowlist

**Apple metadata（观察）：** 以下来自 `VoiceMemos14.mom` 解码后的 `NSManagedObjectModel`。所有列出的属性均为 non-transient、optional；类型是 SDK `NSAttributeType`，不是对 SQLite `PRAGMA table_info` 声明的替代。SDK 枚举把 `700/900/500/300/800/1000/600/1800` 分别定义为 String/Date/Double/Int64/Boolean/BinaryData/Float/Transformable。[`NSAttributeType`](https://developer.apple.com/documentation/coredata/nsattributetype)

若需用本机 SDK 核验 raw value，使用随当前 Xcode 选择的 SDK 路径，而不是固定安装路径：

```sh
SDK=$(xcrun --sdk macosx --show-sdk-path)
rg -n 'NSStringAttributeType|NSDateAttributeType|NSDoubleAttributeType|NSInteger64AttributeType|NSBooleanAttributeType|NSBinaryDataAttributeType|NSFloatAttributeType|NSTransformableAttributeType' "$SDK/System/Library/Frameworks/CoreData.framework/Headers/NSAttributeDescription.h"
```

| Core Data entity/property | model type | 可对应的当前物理列（仅已观察 schema 名） | adapter 资格 |
| --- | --- | --- | --- |
| `CloudRecording.uniqueID` | String (700), optional | `ZCLOUDRECORDING.ZUNIQUEID` | 仅为 opaque candidate；非空 UTF-8、全 snapshot 唯一后才可成为 `RecordingID`。不得使用 `Z_PK`、Title 或 path。 |
| `CloudRecording.path` | String (700), optional | `ZCLOUDRECORDING.ZPATH` | 仅为 asset-reference candidate；不能直接信任或输出。 |
| `CloudRecording.customLabel` | String (700), optional | `ZCLOUDRECORDING.ZCUSTOMLABEL` | Title candidate；尚未可用。 |
| `CloudRecording.customLabelForSorting` | String (700), optional | `ZCLOUDRECORDING.ZCUSTOMLABELFORSORTING` | Title candidate；尚未可用。 |
| `CloudRecording.encryptedTitle` | String (700), optional | `ZCLOUDRECORDING.ZENCRYPTEDTITLE` | Title candidate；名称并不证明值可显示或优先级。 |
| `CloudRecording.date` | Date (900), optional | `ZCLOUDRECORDING.ZDATE` | metadata candidate；不用于 state 判定。 |
| `CloudRecording.duration`, `localDuration` | Double (500), optional | `ZDURATION`, `ZLOCALDURATION` | metadata candidate；零值/短时长不是 placeholder predicate。 |
| `CloudRecording.evictionDate` | Date (900), optional | `ZEVICTIONDATE` | 仅名称/类型观察；不得当作 deleted、iCloud 或本地化状态。 |
| `CloudRecording.flags`, `sharedFlags`, `audioFutureFlags` | Int64 (300), optional | `ZFLAGS`, `ZSHAREDFLAGS`, `ZAUDIOFUTUREFLAGS`（后两者尚未在既有 store note 中逐列观察） | bit 意义完全 unsupported。 |
| `CloudRecording.audioDigest` | BinaryData (1000), optional | `ZAUDIODIGEST` | 不读取、不输出，不作为资产完整性或 state 判定。 |
| `CloudRecording.folder` | to-one `Folder`, optional, delete rule 1 | `ZFOLDER`（既有 store note 已观察） | relationship 存在不定义 Recently Deleted 的 folder/NULL 语义。 |

当前系统 model 还定义 `audioFuture`、`audioFutureUUIDs`、`mtAudioFuture`、`mtLayerMix`、`versionedAudioFuture`（Binary/Transformable），以及 playback/studio/silence 相关属性；它们不在 read allowlist。`Folder` 有 `uuid`、`encryptedName`、`rank`、`countOfRecordings`；不为读取 recording 而 join `ZFOLDER`，直到 folder/state 语义被验证。

可复现的纯 bundle 检查（不会打开 store）：

```sh
xcrun swift -e 'import Foundation; import CoreData
let u = URL(fileURLWithPath: "/System/iOSSupport/System/Library/PrivateFrameworks/VoiceMemos.framework/Versions/A/Resources/VoiceMemos.momd/VoiceMemos14.mom")
let m = NSManagedObjectModel(contentsOf: u)!
for p in m.entitiesByName["CloudRecording"]!.properties.sorted(by: { $0.name < $1.name }) {
  if let a = p as? NSAttributeDescription { print(a.name, a.attributeType.rawValue, a.isOptional, a.isTransient, a.renamingIdentifier ?? "nil") }
}'
```

**限制：** Core Data model 名称和属性类型只描述 model；Apple 同时说明 model 在 entity/property 与底层持久化 schema 间映射，不能将其直接当作稳定的 SQLite ABI。[`NSManagedObjectModel`](https://developer.apple.com/documentation/coredata/nsmanagedobjectmodel) 当前 `ZCLOUDRECORDING`、`ZFOLDER` 和表列名来自本仓库的早期只读结构记录，而非这次读取：[`voice-memos-data-access.md`](voice-memos-data-access.md)。

## 提议的 macOS 26 识别 gate（尚不放行数据读取）

这是 **inference**，目标是把 private-store 漂移变成明确的 `unsupported_schema`，而不是冒险猜字段。所有检查均针对已经通过 `SnapshotPort` 得到的只读 snapshot；不可读取 live 主库或用 `immutable=1`/`nolock=1` 绕过 WAL 协调。snapshot 边界见 [`sqlite-snapshot-strategy.md`](sqlite-snapshot-strategy.md) 和 [`test-fixtures-and-integration-isolation.md`](test-fixtures-and-integration-isolation.md)。

1. `sw_vers` 主版本必须为 `26`；Voice Memos bundle 的 bundle ID 必须为 `com.apple.VoiceMemos`、`CFBundleVersion` 必须为 `1380`。任何 OS/build 偏差一律 `unsupported_schema`，包括 macOS 15。
2. 必须存在 Apple framework 的 `VoiceMemos14.mom` 和 `VersionInfo.plist`，并匹配 current-name、`VersionInfo` archived model checksum `f2V…`、`.mom` SHA-256 `551215…`；这些只确认 bundle artifact。再从该 `.mom` 实例化 runtime model，并核验 runtime `CloudRecording` hash `Q5vg…` 与 model checksum `Rzot…`，但**不得**要求它们等于 store manifest。
3. 用 Apple 的 persistent-store metadata API 从 snapshot 读取 metadata，并对独立 observed store manifest 做 exact match：`CloudRecording` hash `wzISBP+…`、store model checksum `n+kk0f+…`、digest `8aTQ…PCA==`、hash version `3`、framework/max `1526`、store type `SQLite`、model version identifiers `[""]`，以及其余五个 entity hash 的完整值。任何缺 key、额外 key、类型/长度/value mismatch 均为 `unsupported_schema`。`NSManagedObjectModel.isConfiguration(_:compatibleWithStoreMetadata:)` 仅作诊断，不是放行条件；其结果（包括与 bundle model 不 compatible）不得单独导致 fail-closed。Core Data metadata/version API 仍仅用于读取与诊断。[`NSManagedObjectModel`](https://developer.apple.com/documentation/coredata/nsmanagedobjectmodel) [`versionIdentifiers`](https://developer.apple.com/documentation/coredata/nsmanagedobjectmodel/versionidentifiers)
4. recognizer 只允许 exact 匹配上述独立 store manifest，命中后返回 `recognized_schema`。这只完成 identity/metadata gate；production 仍必须在同一 isolated snapshot 上通过 exact physical schema 与全表 row gate，之后才可投影或 export。
5. `PRAGMA schema_version=1326` 若出现，只可写入 diagnostic fingerprint，**绝不可**作为单独或决定性 token。它是 SQLite schema-cookie，不是 Apple model/version 合同；单独相同的 cookie 不能证明字段语义、model hash 或 app build 相同。

第 4 点只把上方 canonical `ZCLOUDRECORDING` fingerprint 作为 observed fact 保存，不把它误升格为 Apple 合同。下列断言仍为 **unsupported，不能写死进 production allowlist**：`ZDATE` 的具体 SQLite type/epoch、`ZDURATION` 的 declaration、`ZFLAGS` bit 宽度/意义、`ZFOLDER` 的 FK/NULL/ON DELETE 行为、`Z_METADATA` 的行数/列格式和 `Z_PLIST` 编码，以及任何 affinity→Core Data type mapping 或 row-value validation。把这些提升为 exact contract 前，必须完成下述 disposable-user matrix。

## Issue #21 的语义问题

### Opaque ID 与 AX locator

**Apple metadata（观察）：** `CloudRecording.uniqueID` 是 optional String；既有结构记录观察到 `ZUNIQUEID`。这是唯一可接受的 ID 候选。

**Inference：** 仅在 single snapshot 中 `ZUNIQUEID` 为 nonempty valid UTF-8、二进制不重复，且对应行已通过 future active-state validation 时，才构造 `RecordingID(value:)`。不要求 UUID 格式（Apple model 只说 String）；不得回退 `Z_PK`、`Z_ENT`、`Z_OPT`、title 或 path。重复/NULL/空值是 `unsupported_schema` 或逐行安全失败，不得合并。Issue #26 进一步证明 AXIdentifier 不是 DB ID 的可用替代：AX locator 必须以 opaque DB ID 与唯一、经验证的 UI tuple 建立映射；不得假设 `AXIdentifier == ID`。tuple 若匹配多条，立即按 ambiguous fail closed。

### Title precedence

**Apple metadata（观察）：** `customLabel`、`customLabelForSorting`、`encryptedTitle` 都是 optional String。没有 model-level computed property、default 或 precedence。

**Community code behavior：**

- [harryf/voice-memos, `7e38eda`](https://github.com/harryf/voice-memos/blob/7e38eda5e50d537e933dd67a4a3aeec473a90444/Sources/voice-memos/Database.swift#L222-L227) 选择 `ZENCRYPTEDTITLE → ZCUSTOMLABEL → "(untitled)"`。
- [polarity-dev/macos-voice-memos-export, `1f6e70f`](https://github.com/polarity-dev/macos-voice-memos-export/blob/1f6e70ffe7048a8d4fa12a8696626a1abc2367c1/Sources/Broker/VoiceMemosStore.swift#L119-L137) 选择 `ZCUSTOMLABELFORSORTING → ZENCRYPTEDTITLE → ZCUSTOMLABEL → "Untitled"`。

**非证据/待核验声明：** [cathrynlavery/voice-memo-organizer `SKILL.md`, `e0deb89`](https://github.com/cathrynlavery/voice-memo-organizer/blob/e0deb8949801f1684150b8647773a4f92d418834/SKILL.md#L177-L205) 声称在 macOS 26.5 观察到 `ZCUSTOMLABELFORSORTING` 是 UI title。它不是执行查询的 source code，不能与上述实现并列，更不支持任何 precedence；最多提示 disposable validation 要覆盖该字段。

**Issue #26 observed fact：** 对两条 disposable，改名后 UI title 与 `ZCUSTOMLABELFORSORTING`、`ZENCRYPTEDTITLE` 均 exact equal，且两字段均为 nonempty valid UTF-8；`ZCUSTOMLABEL` 不等于 UI title。

**结论（当前 build manifest）：** display title 仅可要求 `ZCUSTOMLABELFORSORTING` 与 `ZENCRYPTEDTITLE` 均 nonempty、valid UTF-8，并且二者 exact equal；满足时使用该共同值。不得定义更宽 fallback；任一 mismatch、NULL、空值或无效 UTF-8 一律 fail closed。该结论只适用于当前 build manifest，不能外推其他版本。

### Active / Recently Deleted / cloud placeholder / evicted

**Apple metadata（观察）：** `VoiceMemos14` 没有名为 `deleted`、`isDeleted`、`active`、`placeholder` 或 `recentlyDeleted` 的 `CloudRecording` attribute。`evictionDate` 是 optional Date，`flags`/`sharedFlags` 是 optional Int64；仅凭名称和类型没有状态语义。

Apple 用户指南确认 Voice Memos 的删除先进入 Recently Deleted，且可恢复/永久删除；该 UI 语义不能映射到 private columns。[删除录音](https://support.apple.com/en-ke/guide/voice-memos/vmc3c0776462/mac)

**Community code behavior：** 公开的 [harryf implementation](https://github.com/harryf/voice-memos/blob/7e38eda5e50d537e933dd67a4a3aeec473a90444/Sources/voice-memos/Database.swift#L64-L107) 动态取得列后按 `ZDATE` 排序；[polarity implementation](https://github.com/polarity-dev/macos-voice-memos-export/blob/1f6e70ffe7048a8d4fa12a8696626a1abc2367c1/Sources/Broker/VoiceMemosStore.swift#L9-L39) 要求 `ZPATH`。均没有可靠的 deleted/Recently Deleted predicate。未找到固定源码证明任何 `ZFLAGS` bit、`ZEVICTIONDATE IS NULL`、`ZFOLDER IS NULL`、`ZPATH IS NOT NULL` 或 duration 阈值意味着 Active。

**结论（round-trip 前）：** 下列启发式 predicate 全部禁止；delete、restore 及 active/Recently Deleted/cloud placeholder/evicted 的 state 语义当时未验证，production read/mutation 保持 blocked：

```sql
ZFLAGS = 0
ZEVICTIONDATE IS NULL
ZFOLDER IS NOT NULL
ZPATH IS NOT NULL
ZDURATION >= <threshold>
```

它们目前只能是将来 disposable validation 的候选观察，不能排除删除行/占位行，更不能把剩余行称为 Active。

**Issue #26 round-trip observed fact（build 1380）：** 一次在 Recently Deleted view 对 row 执行 Delete 显示 Permanent Delete 确认；已取消且未发生永久删除。因此 delete preflight 必须先验证 All Recordings view，永久删除/全部删除永不执行。对一条 disposable 完成 Recent → restore → Active snapshot → All view delete → Recent snapshot → restore → final snapshot：完整 29 列中，Active→Recent 仅 `ZEVICTIONDATE` 从 NULL 变为 non-NULL real 值且 `Z_OPT` 改变；Recent→restored 反向；final restored 与 initial active 仅 `Z_OPT` 不同。第二条 Recent disposable 同样为 non-NULL real `ZEVICTIONDATE`。UI folder counts 每次仅发生 ±1（不记录实际 count）。当前 settings 观察到 30 days 仅作 diagnostic，不作为 predicate。故当前 build manifest 的 state rule 为：Active=`ZEVICTIONDATE IS NULL`；Recently Deleted=`ZEVICTIONDATE` 为 non-NULL real 值；`Z_OPT` 不参与判定；未知类型一律 fail closed。标题已恢复，第一条为 active，第二条未突变；临时 snapshot/probe 已永久清理。全文不记录真实 title、ID、path、timestamp、count 或 audio。

### Asset path policy

**Apple metadata（观察）：** `path` 仅是 optional String；Voice Memos.app Info.plist 仅声明 `.qta` 为 `com.apple.quicktime-audio`，未声明 `ZPATH` 的相对性或外部 export 语义。

**Community code behavior：** [polarity-dev source](https://github.com/polarity-dev/macos-voice-memos-export/blob/1f6e70ffe7048a8d4fa12a8696626a1abc2367c1/Sources/Broker/VoiceMemosStore.swift#L158-L170) 对相对 `ZPATH` 先拼接 Recordings root；对绝对值也尝试构造 URL，随后 canonicalize 并限制 target 仍在 root 内、要求 regular `.m4a`。README 同时说明 iCloud-only 录音可能不能导出。[README](https://github.com/polarity-dev/macos-voice-memos-export/blob/1f6e70ffe7048a8d4fa12a8696626a1abc2367c1/README.md#L98-L115) 这是一种合理防御性实现，不是 Apple contract；其仅 `.m4a` 规则还与 Apple bundle 的 `.qta` type declaration 不同。

**Inference（未来 validation 通过后才启用）：** 本项目选择比该 community implementation 更严格：把 `ZPATH` 视为不可信 relative-reference，**额外拒绝绝对路径**，再 reject 空值、`..` escape、symlink escape、非 regular file、root 外 target、非本地/读取失败/复制期改变。允许扩展名集合必须按验证后的 manifest 明列（至少不能把 `.qta` 伪装为 `.m4a`）；用打开的 FD 复制并在复制前后校验 size/mtime 或 hash。文件存在/大小很小不能单独证明不是 placeholder。

## 必需的 isolated disposable-user validation

以下是 **needs disposable-user validation**，不是本研究执行步骤。环境必须是独立 macOS 用户、iCloud 关闭或专用空账号、只录制非敏感可丢弃样本；记录只保存 OS、Voice Memos build、model checksum、schema fingerprint 和结果码，不能把标题/路径/录音/DB 带回 CI。

| 验证问题 | 最小 matrix | 升格条件 |
| --- | --- | --- |
| macOS 26 exact DDL/metadata | build 1380 的 disposable store；仅 schema/metadata，不保存 rows | 固定 `Z_METADATA` decoding、table/column declaration/affinity、model hash 与 column fingerprint 一致；届时才可在新版本 manifest 中把经复现的 physical fingerprint 提升为 gate。 |
| Title precedence | App 创建/改名若干无敏感 sample，使三 title candidate 覆盖 NULL/不同值；比较 App UI | 当前 build 仅接受 sorting/encrypted 均 nonempty valid UTF-8 且 exact equal；mismatch/null fail closed，不定义更宽 fallback。 |
| Active / Recently Deleted | round-trip 覆盖 Active→Recent→restore→Active；All Recordings view 执行 delete；不执行 permanent/all delete | 当前 build 仅接受 Active=`ZEVICTIONDATE IS NULL`、Recently Deleted=non-NULL real `ZEVICTIONDATE`；`Z_OPT` 不参与；未知类型 fail closed。 |
| local / evicted / iCloud placeholder | 本地 sample、离线/未下载 sample、eviction-related state（只用官方 UI/系统流程） | 资产可用性可由 path + filesystem post-check 区分；禁止仅依据 DB column 或文件大小。 |
| `.m4a` / `.qta` export | 两种可出现的 sample、每种 asset availability | 每个被支持类型都有 FD-copy + AVFoundation/open verification；不支持者返回 `asset_unavailable` 或 `unsupported_asset_type`。 |
| macOS 15 | 15 的 isolated user、该系统 bundle/model/store | 独立 capture 出 build/model/metadata/column fingerprint，不能从 26 或 synthetic fixture 推导。 |

任何验证差异先新增真实-version manifest，再判断是否支持；不能通过扩大 fallback 或猜 flags 让它“兼容”。

## 实施顺序与验收

1. 保持现有 `SchemaAdapter` 的 synthetic-only 行为；不要把 `SyntheticSchemaFixture.Revision.macOS15/macOS26` 解释为真实 schema 支持。
2. `RealSchemaRecognizer` 只读取 snapshot header/schema metadata，并以本文件第 4 节 gate 返回 `unsupported_schema` 或 `recognized_schema`；`recognized_schema` 后仍需独立 physical/row adapter，recognizer 本身不得 SQL 投影用户行。
3. 为 recognizer 写 synthetic metadata contract tests：错 build、错 `.mom` hash、缺/多 manifest key、任一 hash 的任一 byte 改动（即使 `isConfiguration(_:compatibleWithStoreMetadata:)` 返回 true）、值非 32 bytes、metadata 不可读取、manifest version identifiers 非 `[""]`、仅 `schema_version=1326`、未知 OS，全部因 manifest mismatch fail closed。`isConfiguration` 返回 false 仅记录 diagnostic，不作为失败条件。另写不进入当前 gate 的 future physical-fingerprint tests：它们只在 disposable matrix 固定 exact DDL/column manifest 后，才可变成 row-reader 的升级测试；真实 DB/asset 不进入 tests。
4. 完成上节所有 macOS 26 matrix 后，才把验证结果（固定 build/model/DDL/state/title/asset manifest）加入 allowlist，并以新的 issue 决定是否实现 row reader。macOS 15 单独走相同流程。

**实现范围：** exact recognizer、physical/row gate、只读 snapshot list/search/show 与相对 `.m4a` export。**不可进入实现的范围：** production AX read/mutation、title fallback、其他版本、`.qta`、placeholder detection 与私有 store 写入。

## 参考来源

- Apple Core Data private SQLite boundary：[Persistent Store Types and Behaviors](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/CoreData/PersistentStoreFeatures.html)
- Apple model/metadata versioning：[Store versions](https://developer.apple.com/documentation/coredata/store-versions)、[`NSEntityDescription.versionHash`](https://developer.apple.com/documentation/coredata/nsentitydescription/versionhash)、[Understanding Versions](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/CoreDataVersioning/Articles/vmUnderstandingVersions.html)
- 已有本仓库结构与安全研究：[voice-memos-data-access.md](voice-memos-data-access.md)、[private-api-community-survey.md](private-api-community-survey.md)、[test-fixtures-and-integration-isolation.md](test-fixtures-and-integration-isolation.md)
- 固定 community implementation：[`harryf/voice-memos` Database.swift](https://github.com/harryf/voice-memos/blob/7e38eda5e50d537e933dd67a4a3aeec473a90444/Sources/voice-memos/Database.swift)、[`polarity-dev/macos-voice-memos-export` VoiceMemosStore.swift](https://github.com/polarity-dev/macos-voice-memos-export/blob/1f6e70ffe7048a8d4fa12a8696626a1abc2367c1/Sources/Broker/VoiceMemosStore.swift)
