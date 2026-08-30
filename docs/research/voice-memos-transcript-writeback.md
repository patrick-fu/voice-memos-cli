# Voice Memos 系统转写的读取与安全回写可行性

> **当前产品决策（2026-08-30）：** `voice-memos-cli` 当前是安全只读检索/导出 CLI，只支持 `list/search/show/export/doctor`；不支持 `rename/delete`，不要求也不使用 Accessibility、CGEvent、mutation token 或 Shortcuts 写后端。本文是研究/历史证据，记录既有调研与失败路径，不作为当前实现计划。

研究日期：2026-08-27。目标是回答第三方 CLI 能否读取 macOS Voice Memos 的系统转写，并将更强模型生成的替代转写回写到 Voice Memos 供 App 展示。

本次检查**未读取录音内容、标题、转写、联系人或任何数据库记录**，也没有启动 Voice Memos、修改其容器或 iCloud 数据。下文的本机证据仅来自应用/守护进程二进制、签名、Core Data 模型、启动配置和目录存在性。

## 结论

| 问题 | 结论 | 置信度/状态 |
| --- | --- | --- |
| 用公开受支持能力读取 Voice Memos 系统转写 | **不能作为 CLI 功能实现。** Apple 文档只说明在 App 内查看、选择和复制；没有公开 API/CLI/脚本字典可按录音读取转写。 | 已证实（文档列出的能力）；“不存在任何 API”不能由一次搜索绝对证明，故仅限当前 macOS/SDK 调查范围。 |
| 用公开受支持能力写入或替换系统转写 | **不能。** 官方界面没有编辑/导入转写的操作；公开 Speech API 只对调用者提供的音频产生结果，不会写回 Voice Memos。 | 已证实。 |
| 通过内部存储读取 | **理论上可能，但不是产品接口。** 转写相关私有类型和存储服务存在；其准确路径、编码和访问授权在本机未对用户数据验证。 | 推断。 |
| 通过内部存储覆盖并让 App 稳定显示 | **预防性 production No-Go。** 当前没有公开支持路径，且存储、索引、Core Data/CloudKit 同步、版本和资产关联的写入一致性依赖未知。 | 已证实风险边界；具体字节格式及“某种写入必然失败”均未实验验证。 |
| 可做隔离、一次性逆向验证 | **Experimental only。** 只能在独立 macOS 用户/独立 Apple Account、可丢弃的测试录音、关闭 iCloud 同步并有离线备份的环境中进行；不得触碰真实库。 | 建议。 |

因此，`voice-memos-cli` 的可交付方向应是：由用户显式导出/选择音频后生成外部转写（可带时间戳），并保存为 CLI 自己拥有的副本；不要承诺读取、替换或驱动 Voice Memos 内置转写显示。

## 公开、受支持的能力

### 读取

**已证实：** Apple 的 [Voice Memos 用户指南：查看转写](https://support.apple.com/guide/voice-memos/view-a-transcription-of-a-recording-vm4a03609f0d/mac) 说明 macOS 15+、Apple silicon 上可在 App 内显示转写；录制完成后，用户可以选中文字并“Copy”，并可按标题或转写搜索。文档没有列出导出转写、自动化读取、转写文件 URL 或供第三方查询的 API。

**已证实：** 此机（macOS 26.6.1，Voice Memos 3.2/1380）对 `/System/Applications/VoiceMemos.app` 运行 `sdef` 返回 `error -192` 且没有 sdef；这排除了经典 AppleScript dictionary 作为受支持读取通道。

**已证实：** Voice Memos 确有 App Intents/Shortcuts 动作。Apple 的 [App Intents 文档](https://developer.apple.com/documentation/appintents/app-intents) 说明 App Intent 是 App 向 Siri、Shortcuts 等系统体验声明其能力的类型；Apple 的 [Shortcuts 更新记录](https://support.apple.com/en-al/101583) 也列出 Voice Memos 的 `Search Voice Memos`、打开/播放/创建/删除录音、文件夹和播放设置动作。

**本机 metadata inventory（只读、当前 App 版本）：** 主 App 的 action/type/performer 字符串可盘点出 `SearchRecordings`、`OpenFolder`、`CreateFolder`、`DeleteFolder`、`SelectRecording`、`PlayRecording`/`PlaybackVoiceMemoIntent`、`DeleteRecording`、`ChangeRecordingPlaybackSetting`、`CreateRecording`/`RecordVoiceMemoIntent`、`ToggleRecording`、`StopRecording`、`RCImportRecording`、`RCCombineRecordings` 和 `RCControlCenterToggleRecording`；extension 还暴露旧式 `RecordVoiceMemoIntentHandling` 与 `PlaybackVoiceMemoIntentHandling`。完整可复现清单由下方“可复现的只读检查”的 metadata 命令输出，而不是依赖人手筛选的临时文件。

**已证实的边界：** `SearchRecordings` 存在；它是把指定文本带入/打开 Voice Memos 的录音搜索界面（对应 App 内搜索），而不是向调用者返回转写正文。它不改变本结论：本机 inventory 中未发现名为 `Transcript` 或 `Transcription` 的 action，也未发现转写读取、导出、导入或写回 action。二进制里确有内部 `TranscriptionStorageService` 等字符串，但那不是 public App Intent。

**已证实：** [Speech 的 `SFSpeechURLRecognitionRequest`](https://developer.apple.com/documentation/speech/sfspeechurlrecognitionrequest) 可让开发者对自己拿到的音频 URL 识别语音，结果归调用者所有；它不是 Voice Memos 存储或转写回写 API。

**边界：** 用户手动在 App 中 Copy，再粘贴给 CLI，是可行的人机流程；用 Accessibility/模拟 UI 去复制则是脆弱的 UI 自动化，不是数据 API，且会受 TCC、焦点、语言和 App 版本影响。它不应成为默认实现或“无损读取”承诺。

### 写入、覆盖和展示

**已证实：** 同一份 Apple 用户指南只提供“view/copy”。[编辑录音指南](https://support.apple.com/guide/voice-memos/edit-a-recording-vmac7e39c22e/3.2/mac/26) 允许替换/修剪音频并选择覆盖原录音或另存副本，但没有编辑、导入或替换转写的操作。不能把“音频可覆盖”推导成“转写可覆盖”。

**已证实：** 公开 Speech API 的输出不会自动注册到 Voice Memos。Apple 的 API 以调用者给出的 `URL` 创建请求并返回识别结果；文档未提供向 Voice Memos 提交 `formattedString`、片段、时间戳或识别任务的接口。

**结论：** 没有 public supported 的“写回后由 Voice Memos 展示”路径，也就没有受支持的替换语义、冲突语义或回滚 API。

## 本机内部实现证据（不构成可依赖接口）

### 表示与所有权

**已证实：** App 二进制中包含 `TranscriptionData`、`TranscriptionUtterance`、`TranscriptionFragment`、`TranscriptionCodingContainer`、`TranscriptionStorageService`、`RCRecordingTranscriptionService`、`existingTranscription(recordingUUID:)`、`transcriptionStringForRecordingUUID:completionHandler:`、`rc_transcriptionDataForURL:` 和 `rc_updateFile:withTranscriptionData:error:` 等私有符号字符串。它还包含“failed to update file with transcription data”的错误字符串。

**推断：** 转写并非一个可安全替换的纯文本字段，而是至少有编码容器、话语/片段模型，并和录音 UUID、音频 URL 以及播放位置关联。Apple 的用户指南明确说明选中转写词时播放头跳到对应位置，进一步说明显示层需要时间对齐信息，而不只是文本。

**已证实：** `/System/iOSSupport/System/Library/PrivateFrameworks/VoiceMemos.framework/.../VoiceMemos14.mom` 的 Core Data 模型含 `RCCloudRecording`、`RCEntityRevision`、`audioDigest`、`versionedAudioFuture`、`encryptedTitle` 等属性，但本次只读模型字符串扫描未见 `transcript`/`transcription` 属性。此证据支持“转写不以该模型中的普通文本列直接存储”的判断；它**不**能单独证明转写一定嵌在音频文件中，也不能确定格式。

### 数据库、资产、CloudKit 与索引

**已证实：** Voice Memos App 具有 `com.apple.private.voicememod.client`、`com.apple.private.security.storage.VoiceMemos`、私有 Voice Memos app group、CloudKit 和私有 mach service 权限。其私有守护进程 `voicememod` 由 `/System/Library/LaunchAgents/com.apple.voicememod.plist` 启动，提供 `com.apple.voicememod.xpc` 与 `com.apple.voicememod.datastore.Cloud`。

**已证实：** `voicememod` 的本机字符串包含 Core Data persistent store/migration、`NSCloudKitMirroringDelegate`、私有 CloudKit database、`CKRecordID`、recording `uniqueID`、`ckAssetFiles`、资产下载/导出、持久历史、远端变更、同步 reset、orphan recovery、`AssetManifest.plist` 和 WAL。它还记录“actively modified recording”期间忽略 iCloud 变更的路径。

**推断：** 录音实体、音频资产、索引与 CloudKit 镜像是一个整体，不可将未知的转写 payload 当作孤立文件修改。即使局部文件暂时被 App 读取，守护进程、搜索索引或远端同步仍可重写/删除它。

**已证实：** [Apple 的同步说明](https://support.apple.com/en-ie/guide/voice-memos/vma6cc4d0571/mac) 表明启用 iCloud 后 Voice Memos 录音会自动出现在同一 Apple Account 的 Mac、iPhone、iPad 和 Apple Vision Pro。因此在已同步的真实库中，任何本地内部修改都存在远端最终写入者和冲突风险。

### hash、版本、时间戳与重建

| 项目 | 证据与判断 |
| --- | --- |
| 音频关联/摘要 | **已证实存在 `audioDigest` 属性。** 是否覆盖转写时必须更新它、它是否覆盖转写内容，**未知**。不能假造或忽略。 |
| 数据模型版本 | **已证实存在 `VoiceMemos.momd` 的多个版本（至 VoiceMemos14）以及 daemon 的 persistent-store migration。** 内部 schema 是版本敏感的。 |
| 实体修订 | **已证实模型有 `RCEntityRevision`，daemon 有持久历史/远端 change 处理。** 哪些 revision 需要随转写更新，**未知**。 |
| 转写时间戳 | **已证实 App 有 `lastTranscriptUpdateTime`，且 UI 将词映射到播放头。** 精确字段、单位、片段 offset 和生成规则，**未知**。 |
| 加密/签名 | **已证实 App/daemon 有 encrypted-title/CloudKit encrypted-field 迁移和受限存储权限。** 转写本身是否签名、加密、随资产 hash 校验，**未知**；不能据此宣称“无签名可写”。 |
| 重建/覆盖 | **已证实 daemon 有 orphan recovery、migration、remote-change/reset、search reload 和资产重新下载逻辑。** 具体何时会重建某份转写，**未知**；这构成生产写入的预防性风险，不是“已实验证明写入会失败”。 |

## 权限与并发边界

**已证实：** Voice Memos 是 sandboxed system app；其容器在此机为 `~/Library/Containers/com.apple.VoiceMemos`，权限为 `drwx------`。App 和 daemon 均具有普通第三方没有的私有 storage、app-group、XPC 与 CloudKit entitlement。

**已证实：** Apple 的 [App Sandbox 文档](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox) 说明访问其他 App 的容器受 sandbox、用户授权、POSIX ACL 和系统数据保护共同限制；macOS 15+ 的 [container protection 文档](https://developer.apple.com/documentation/xcode/protecting-local-app-data-using-containers) 还说明 app-data/app-group container 可受系统完整性保护。Full Disk Access 或用户授权可能影响“能否打开文件”，但不授予私有 XPC/CloudKit 协议、格式或一致性语义。

**风险：**

- Voice Memos 或 `voicememod` 运行时直接编辑底层文件，会与其串行操作队列、文件协调、SQLite WAL、Core Data context、资产访问会话及 CloudKit 同步并发竞争。
- 仅复制一个主数据库文件会漏掉 `-wal`/`-shm`、资产、manifest、索引及 CloudKit metadata；仅恢复一个 payload 也可能造成跨对象不一致。
- 关闭 App 不等于 `voicememod`、Spotlight/CloudKit 已停止；“文件写成功”不能作为展示成功、同步成功或可回滚的证据。
- 升级 macOS、迁移 store、打开其他设备或服务处理 orphan 都可能覆盖、删除或重新生成未受支持的改动。

**证据界限：** 本研究没有在真实数据或隔离测试数据上实施任何写入。因此，以上是“无当前公开支持路径 + 内部一致性依赖未知”所支持的预防性 production No-Go，**不是**某一写入方式必然失败、必然损坏或必然被覆盖的实验结论。要获得后者，必须完成下节所列、可丢弃环境中的受控实验。

## 安全且可逆的验证设计（不在真实数据上执行）

仅在获得专门授权后，按以下门槛做实验；本研究没有执行这些步骤。

1. 建立**独立 macOS 测试用户**，使用没有真实 Voice Memos 的独立 Apple Account，或完全不登录 iCloud；不要使用现有用户的容器副本。新建一条可丢弃、内容非敏感、已知短文本的测试录音。
2. 记录环境指纹：`sw_vers`、App/daemon bundle version、codesign entitlement、所有 store/asset/sidecar 的路径和 SHA-256、文件属性、SQLite schema 和 WAL 状态；转写内容只以测试固定样本保存。先以 App 正常 UI 触发一次系统转写，完成后关闭 App 并等待 daemon 空闲。
3. 先做**纯只读差分**：对“无转写/有系统转写/再次打开/搜索/重启服务”各状态拍摄完整容器与相关 app-group 的离线副本，比较文件集合、SQLite schema/metadata、二进制 blob 长度与 hash。不得对真实账户使用此步骤。
4. 只有明确解析出 payload、录音 UUID、时序片段、所有关联 revision/hash/index 以及本地不联网的一致性写入路径后，才在**完整离线副本**上进行单次候选修改。写前停止 App/daemon 和相关同步；写后先在断网测试环境打开 App 验证：显示、词到播放头映射、搜索、重启后保留、重新转写/编辑后的行为。
5. 恢复必须是**整套**离线快照（主 store、`-wal`、`-shm`、资产、manifest、索引/CloudKit support metadata），且先验证 App/daemon 都没有运行。恢复后断网启动验证，再决定是否丢弃测试用户。禁止把实验修改重新接入 iCloud；这不是生产回滚方案。

**停止条件：** 任一未解释的 store/asset 差分、SQLite/WAL 未清晰一致、daemon 重新生成/删除数据、UI 显示与搜索/播放不同步、或需要伪造未知 hash/revision/CloudKit 字段，即停止，不继续“猜字段写入”。

## 可复现的只读检查

以下命令针对本机系统二进制/元数据；它们不需要也不应打印用户录音、标题或转写。请在 macOS 更新后重新运行并记录版本。

```zsh
sw_vers
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  /System/Applications/VoiceMemos.app/Contents/Info.plist

# 是否有经典 AppleScript 字典（本机返回 error -192）
sdef /System/Applications/VoiceMemos.app

# App Intents metadata 完整盘点；只读取系统二进制，不读取用户容器或录音数据
for f in \
  /System/Applications/VoiceMemos.app/Contents/MacOS/VoiceMemos \
  /System/Applications/VoiceMemos.app/Contents/PlugIns/VoiceMemosIntentsExtension.appex/Contents/MacOS/VoiceMemosIntentsExtension
do
  printf 'FILE=%s\\n' "$f"
  strings "$f" | rg 'SearchRecordings|OpenFolder|CreateFolder|DeleteFolder|SelectRecording|PlayRecording|PlaybackVoiceMemoIntent|DeleteRecording|ChangeRecordingPlaybackSetting|CreateRecording|RecordVoiceMemoIntent|ToggleRecording|StopRecording|RCImportRecording|RCCombineRecordings|RCControlCenterToggleRecording|Transcript|Transcription'
done

# 系统转写/文件写入相关的私有实现线索；不读取用户容器
strings /System/Applications/VoiceMemos.app/Contents/MacOS/VoiceMemos \
  | rg 'TranscriptionData|TranscriptionUtterance|rc_transcriptionDataForURL|rc_updateFile'

# 模型属性与版本，验证非公开 Core Data schema
strings /System/iOSSupport/System/Library/PrivateFrameworks/VoiceMemos.framework/Versions/A/Resources/VoiceMemos.momd/VoiceMemos14.mom \
  | rg 'RCCloudRecording|RCEntityRevision|audioDigest|versionedAudioFuture|encryptedTitle'

# 私有 daemon 的协议/同步线索
plutil -p /System/Library/LaunchAgents/com.apple.voicememod.plist
strings /System/iOSSupport/System/Library/PrivateFrameworks/VoiceMemos.framework/Support/voicememod \
  | rg 'NSCloudKitMirroringDelegate|CKRecordID|AssetManifest.plist|RCSavedRecordingsChangeToken|orphan|persistent store'

# 证明 App 与 daemon 使用不同于普通 CLI 的受限能力
codesign -d --entitlements :- /System/Applications/VoiceMemos.app 2>/dev/null | plutil -p -
codesign -d --entitlements :- /System/iOSSupport/System/Library/PrivateFrameworks/VoiceMemos.framework/Support/voicememod 2>/dev/null | plutil -p -
```

## 决策记录

**Go：** 导出/用户选择音频 → 外部模型转写 → CLI 自有 `.json`/`.srt`/`.txt` 副本；明确标出其不是 Voice Memos 内置转写。可选地提供把用户手动复制的系统转写导入 CLI 进行比较。

**No-Go：** 以“把替代文本安全写回 Voice Memos、所有设备稳定显示”为产品承诺。这是基于“无当前公开支持路径 + 内部一致性依赖未知”的预防性 production No-Go，不声称已通过写入实验验证它必然失败；同样不得在任何真实 Voice Memos 数据、已同步库、客户数据上试写内部 store/asset。

**Experimental：** 仅依照上面的隔离设计，在一次性测试账户上调查格式和本地展示；即使得出可行 PoC，也必须标为 unsupported、版本锁定、默认关闭，且不得自动触及同步库。
