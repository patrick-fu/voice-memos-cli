# v0.1 macOS、签名与 Homebrew 分发兼容性矩阵

> **当前产品决策（2026-08-30）：** `voice-memos-cli` 当前是安全只读检索/导出 CLI，只支持 `list/search/show/export/doctor`；不支持 `rename/delete`，不要求也不使用 Accessibility、CGEvent、mutation token 或 Shortcuts 写后端。分发链条只需要覆盖只读产品所需的用户授权和安装路径，Accessibility/Apple Events 验证不属于当前产品分发范围；本文保留为历史/决策证据。

研究日期：2026-08-28。目标是为 `voice-memos-cli` 的 v0.1 选择可复现的 macOS、CPU、Swift 工具链、签名/公证、GitHub Releases 与 Homebrew 发布路径。本报告只读取公开一手资料和仓库静态文件；没有读取 Voice Memos 用户数据、凭据，也没有执行签名、公证、发布或 GitHub 写操作。

## 结论先行

| 维度 | v0.1 推荐 | 状态与边界 |
| --- | --- | --- |
| macOS | 支持当前 major **Tahoe 26** 与前一 major **Sequoia 15**；`MACOSX_DEPLOYMENT_TARGET=15.0`，在 15.6 与 26.x 实机验收 | 15/26 名称与可安装 Xcode 版本见 [Apple macOS 版本列表](https://support.apple.com/en-us/109033) 和 [Xcode 系统要求](https://developer.apple.com/xcode/system-requirements)。15.0 是产品选择，不是 Apple 对本项目的兼容承诺；须在 15.6+ 与 26.x 测试。 |
| CPU | 发布一个 **universal2（arm64 + x86_64）** CLI；CI 至少跑 arm64 与 x86_64 两个 job | Apple 说明 universal binary 需分别编译并用 `lipo` 合并，且每个 slice 独立签名。[Building a universal macOS binary](https://developer.apple.com/documentation/Apple-Silicon/building-a-universal-macos-binary)、[TN3126](https://developer.apple.com/documentation/technotes/tn3126-inside-code-signing-hashes) |
| Swift | SwiftPM；锁定 `// swift-tools-version: 6.0`（最低工具版本）；macOS 15 job 用 Xcode 26.2/Swift 6.2.x，macOS 26 job 用固定兼容 Xcode（例如 26.6/Swift 6.3），发布记录 Xcode、SDK、Swift 版本 | tools version 只声明 manifest 所需的最低编译器/解析版本；Swift 6.0 可使用 `.macOS(.v15)`，更新编译器仍可构建 6.0 manifest。[PackageDescription（tools version 与 platforms）](https://docs.swift.org/package-manager/PackageDescription/PackageDescription.html#setting-the-swift-tools-version)。Xcode 的系统/SDK/Swift 对照表以 [Apple Xcode 系统要求](https://developer.apple.com/xcode/system-requirements) 为准。Swiftly 只用于开发探索，不作为签名发布链。 |
| 直接下载 | **正式主产物为 signed flat PKG**：universal2 Mach-O 先 Developer ID Application 签名（Hardened Runtime + secure timestamp），再用 Developer ID Installer 签 PKG，notarize + staple PKG；ZIP 仅辅助下载，不能承诺裸 Mach-O 离线 stapling | Apple 明确 ZIP 不能直接签名；PKG/DMG 可直接 stapling，ZIP 需依赖在线 ticket，且裸 Mach-O ZIP 没有可装订的 bundle 外层。[Packaging Mac software for distribution](https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution) |
| Homebrew | **生产主路径：own-tap cask 指向已 notarized/stapled PKG**，以 `sha256` 固定；source formula 降为开发者/次要路径，明确其本地构建 binary 通常无 Developer ID identity、可能需重新授权 | Homebrew 当前 policy 说明 cask 可分发上游预编译文件，但 open-source CLI-only 通常属于 formula；第三方 tap 需显式信任。[Homebrew Security and Supply Chain](https://docs.brew.sh/Supply-Chain-Security)、[Acceptable Casks](https://docs.brew.sh/Acceptable-Casks)、[Tap Trust](https://docs.brew.sh/Tap-Trust) |
| source formula / bottle | source formula 从固定源码 + `sha256` 构建；bottle 仅作为开发/性能优化，不宣称 Developer ID 签名或 Apple notarization | Homebrew 将 formula 定义为源码构建，bottle 为预编译 keg；其供应链 checksum/attestation 不等于 Apple code signature。[Formula Cookbook](https://docs.brew.sh/Formula-Cookbook)、[Bottles](https://docs.brew.sh/Bottles) |
| TCC/升级 | 不承诺授权随 Terminal、Homebrew symlink、Cellar 版本目录或升级迁移；固定非 bundle CLI 的 `-i` code-signing identifier，记录实际可执行文件路径，并在 15/26、Intel/Apple Silicon、ZIP/Homebrew/升级后实测 | Apple 公开接口只说明可按 service + bundle ID 重置 TCC，未给出本项目“路径/版本升级后 identity 是否继承”的合同。[Resetting access to protected resources](https://developer.apple.com/documentation/xcode/resetting-access-to-protected-resources-in-macos)、[Creating distribution-signed code](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac/) |

**核心判断：**正式分发是“Developer ID Application 签名 payload → Developer ID Installer signed flat PKG → notarize → staple”，并通过 GitHub immutable Release 与 own-tap cask 复用同一 PKG。裸 Mach-O ZIP 只能作为在线-ticket 辅助下载，不能承诺 offline-safe。签名、公证、Homebrew SHA-256 和 GitHub immutable release 各自解决不同问题；它们都不授予 Full Disk Access 或其它 TCC 用户授权。当前只读产品不依赖 Accessibility/Automation，也不获取 Voice Memos 私有 entitlement。

## 1. macOS 与 CPU 矩阵

### 已证实

- Apple 当前版本列表同时列出 macOS Tahoe 26 与 Sequoia 15；因此“当前 + 前一 major”在本 ticket 中具体化为 **26/15**。[macOS 版本列表](https://support.apple.com/en-us/109033)
- Xcode 26 系列的宿主要求随 minor 变化：Xcode 26.2 可在 Sequoia 15.6–Tahoe 26.x，Xcode 26.6 仅支持 Tahoe 26.2–26.x；二者均带 macOS 26 SDK，但 Swift 编译器分别为 6.2.3 与 6.3。Deployment Target 范围远低于 15 只是编译能力，不代表 Voice Memos 私有数据路径或 TCC 行为在旧系统成立。[Xcode 系统要求](https://developer.apple.com/xcode/system-requirements)、[Xcode 26.6 release notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-26_6-release-notes)
- Apple 的 universal binary 流程是分别生成 arm64/x86_64 slice，再用 `lipo` 合并；Intel 机器不能运行 arm64 slice，Apple silicon 可在 Rosetta 下运行 x86_64 slice。[Building a universal macOS binary](https://developer.apple.com/documentation/Apple-Silicon/building-a-universal-macos-binary)

### 推论与推荐

1. `15.0` 作为 deployment target 能覆盖 15 与 26，同时避免把 v0.1 锁死在当前 minor（15.6/26.x）。代码若调用仅 26 可用 API，必须 `if #available` 并提供 15 的失败路径；不能仅因 SDK 可编译就宣称 15 支持。
2. 正式发布物使用一个 universal2 PKG，减少用户选择错误；ZIP 仅作在线-ticket 辅助下载。每个构建 job 仍独立运行测试，最终用 `lipo -archs` 和 `codesign -d -vv` 验证两个 slice。
3. Voice Memos 的私有容器/schema 与 TCC 是运行时风险，不能用 universal2 或 deployment target 推导“两个系统行为相同”。

### 需实机验证

在真实但不含敏感录音的测试账户中固定以下组合：macOS 15.6（Intel、Apple silicon 各一台，如硬件可得）、macOS 26.x（Apple silicon；Intel 机型是否可安装由 Apple 兼容列表决定）、同一 CLI 版本分别经 ZIP 和 Homebrew 安装。验收 `doctor/list/search/show/export` 的权限、WAL snapshot、`.m4a/.qta` 处理和失败码；不做数据库写入实验。

## 2. SwiftPM、Xcode 与工具链

### 推荐构建合同

```swift
// swift-tools-version: 6.0
```

`Package.swift` 设置 `.macOS(.v15)`；依赖版本固定在 `Package.resolved`，发布构建不解析 moving branch。SwiftPM 要求依赖 deployment target 不高于顶层 package；不满足时应在解析阶段失败。[PackageDescription](https://docs.swift.org/package-manager/PackageDescription/PackageDescription.html)

发布构建使用按 runner 固定且与宿主兼容的 Xcode 26.x（macOS 15.6 使用 Xcode 26.2；macOS 26.2+ 才能使用 Xcode 26.6），`xcode-select` 指向固定路径，并记录：

```zsh
xcode-select -p
xcodebuild -version
xcrun swift --version
xcrun --sdk macosx --show-sdk-version
swift package tools-version
swift package show-dependencies
```

Swift.org 说明 Apple 平台开发应优先使用 Xcode 内置、受 Apple 支持的 Swift；独立 Swift toolchain 适合尝试其他版本，且无 Xcode 时 SwiftPM 能力可能受限。[Install Swift on macOS](https://www.swift.org/install/macos/)、[macOS package installer](https://www.swift.org/install/macos/package_installer/)

### universal2 可复现命令

在 macOS + Xcode toolchain 上，先确认本版本 SwiftPM 是否公开 `--arch`：

```zsh
xcrun swift build --help | rg -- '--arch|--scratch-path'
```

若有 `--arch`，分开 scratch path 构建，避免跨架构缓存污染：

```zsh
export MACOSX_DEPLOYMENT_TARGET=15.0
xcrun swift build -c release --arch arm64   --scratch-path .build/arm64
xcrun swift build -c release --arch x86_64  --scratch-path .build/x86_64
mkdir -p dist/voice-memos-cli-0.1.0
lipo -create \
  .build/arm64/release/voice-memos-cli \
  .build/x86_64/release/voice-memos-cli \
  -output dist/voice-memos-cli-0.1.0/voice-memos-cli
lipo -archs dist/voice-memos-cli-0.1.0/voice-memos-cli
file dist/voice-memos-cli-0.1.0/voice-memos-cli
```

若当前 SwiftPM 不接受 `--arch`，使用 Xcode 生成的 package scheme，显式设置 `ARCHS="arm64 x86_64"`、`ONLY_ACTIVE_ARCH=NO`、`MACOSX_DEPLOYMENT_TARGET=15.0`，并以 `lipo -archs` 验收；不要把未经验证的 `--triple` 行为当作跨架构合同。Apple 的通用构建文档要求最终检查实际 Mach-O，而不是中间目录。[Building a universal macOS binary](https://developer.apple.com/documentation/Apple-Silicon/building-a-universal-macos-binary)

## 3. Developer ID、Hardened Runtime、公证与 stapling

### 已证实的要求

Apple 的公证要求适用于 command-line targets：所有 executable 有有效签名，使用 Developer ID，启用 Hardened Runtime，带 secure timestamp，不含 `com.apple.security.get-task-allow=true`，并使用 macOS 10.9+ SDK。[Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)

对非 bundle 的 CLI，Apple 要求由签名者选择 code-signing identifier（`-i`）；Developer ID Application、`--timestamp` 和 `-o runtime` 是独立分发的关键参数。[Creating distribution-signed code for macOS](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac/)

### 纯 CLI/PKG 的准确顺序（正式主路径）

1. 在干净 checkout、未签名产物目录中构建 arm64 与 x86_64，`lipo` 合并。
2. 对最终 universal Mach-O 签名；非 bundle 的 identifier 固定为项目值（示例 `com.patrickfu.voice-memos-cli`），签名身份使用证书 SHA-1 或完整 Developer ID Application 名称。不要 `sudo codesign`；Apple 明确指出它会改变钥匙串/用户上下文。[Creating distribution-signed code](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac/)
3. 验证签名、runtime、timestamp 和两个 slice：

```zsh
codesign --force --sign "Developer ID Application: <TEAM_NAME> (<TEAM_ID>)" \
  --timestamp --options runtime \
  --identifier com.patrickfu.voice-memos-cli \
  dist/voice-memos-cli-0.1.0/voice-memos-cli
codesign --verify --verbose=4 --strict dist/voice-memos-cli-0.1.0/voice-memos-cli
codesign -d -vv --arch arm64 dist/voice-memos-cli-0.1.0/voice-memos-cli
codesign -d -vv --arch x86_64 dist/voice-memos-cli-0.1.0/voice-memos-cli
spctl --assess --type execute --verbose=4 dist/voice-memos-cli-0.1.0/voice-memos-cli
```

4. 把已签名 Mach-O 放入 payload，构建并签 flat PKG。payload 仍是 Developer ID Application 签名；PKG 外层使用 Developer ID Installer 签名：

```zsh
pkgbuild --root payload \
  --identifier com.patrickfu.voice-memos-cli \
  --version 0.1.0 \
  --install-location /usr/local/bin \
  dist/voice-memos-cli-0.1.0-unsigned.pkg
productsign --sign "Developer ID Installer: <TEAM_NAME> (<TEAM_ID>)" \
  dist/voice-memos-cli-0.1.0-unsigned.pkg \
  dist/voice-memos-cli-0.1.0-macos-universal2.pkg
pkgutil --check-signature dist/voice-memos-cli-0.1.0-macos-universal2.pkg
```

5. 以 Xcode 14+ 的 `notarytool` 提交最终 PKG；`altool` 自 2023-11-01 起不再受理。凭据只能来自 CI secret/keychain profile，不能写进仓库或命令日志。[Customizing the notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)

```zsh
ditto -c -k --keepParent \
  dist/voice-memos-cli-0.1.0 \
  dist/voice-memos-cli-0.1.0-macos-universal2.zip
xcrun notarytool submit dist/voice-memos-cli-0.1.0-macos-universal2.pkg \
  --keychain-profile "notarytool-profile" --wait
xcrun stapler staple dist/voice-memos-cli-0.1.0-macos-universal2.pkg
xcrun stapler validate dist/voice-memos-cli-0.1.0-macos-universal2.pkg
spctl --assess --type install --verbose=4 \
  dist/voice-memos-cli-0.1.0-macos-universal2.pkg
```

6. PKG 公证成功后直接 `stapler staple`/`validate` 外层 PKG；这是正式 offline-safe 主产物。Apple 支持对 DMG、signed flat PKG 和 executable bundle 装订；**裸 Mach-O ZIP 不能 staple**。ZIP 可单独 notarize，但仅依赖在线 ticket，离线安装不在 v0.1 保证范围。[Packaging Mac software for distribution](https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution)、[Customizing the notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)
7. 最终重建 `SHA256SUMS`，再用另一台 Mac 从 PKG 安装路径运行 `spctl`、`codesign --verify`、`lipo -archs` 和 smoke tests。公证不是 TCC grant，也不替代 FDA 或其它用户授权。

可选 ZIP 只为脚本友好下载：对包含已签名 Mach-O 的 ZIP 运行 `notarytool submit ...zip --wait`，验证在线 ticket；**不要执行 `stapler staple`，不要作离线支持承诺**。

**纯 CLI 的容器选择：**v0.1 正式发布 PKG（payload 先 Developer ID Application，外层 Developer ID Installer，再 notarize + staple）。可另附裸 Mach-O ZIP 作为方便脚本下载，但明确“online ticket only / offline unsupported”；不能只签 PKG 而漏签 executable。

## 4. GitHub Releases 与供应链

GitHub Release 以 Git tag 为基础，可附 release notes 与资产；单资产上限 2 GiB、单 release 最多 1000 个资产。[About releases](https://docs.github.com/en/repositories/releasing-projects-on-github/about-releases)

推荐资产集合（PKG 为正式主产物，ZIP 为在线-ticket 辅助）：

```text
voice-memos-cli-0.1.0-macos-universal2.pkg
voice-memos-cli-0.1.0-macos-universal2.zip   # optional; offline unsupported
SHA256SUMS
```

tag 使用不可移动的 `v0.1.0`。**发布前必须在仓库设置启用 immutable releases**；启用后 tag 与资产发布后不可改，并自动生成 release attestation；消费者可用：

```zsh
gh release verify v0.1.0
gh release verify-asset v0.1.0 voice-memos-cli-0.1.0-macos-universal2.pkg
shasum -a 256 -c SHA256SUMS
```

这些命令验证 GitHub 发布完整性，不验证 Apple notarization；二者必须同时做。[Immutable releases](https://docs.github.com/en/code-security/concepts/supply-chain-security/immutable-releases)、[Verifying the integrity of a release](https://docs.github.com/en/code-security/how-tos/secure-your-supply-chain/secure-your-dependencies/verify-release-integrity)

失败发布不得覆盖同一 tag/资产：保留已发布版本，修复后递增 patch tag；回滚通过选择上一个 immutable tag/资产并重新计算 Homebrew formula checksum，而不是 force-push 或替换资产。

## 5. Homebrew：source formula 与预编译 artifact

| 路径 | Homebrew 语义 | 优点 | 代价/风险 | v0.1 判定 |
| --- | --- | --- | --- | --- |
| own-tap cask + signed PKG（推荐生产） | cask `url` 指向 GitHub immutable Release 的 stapled PKG，`sha256` 固定，`pkg` artifact 交给 Installer | 用户拿到与直链相同的 Developer ID Installer/notarized/stapled payload；安装路径可固定 | Homebrew cask policy 对 CLI-only 开源项目不是默认归类；第三方 tap 需显式 trust，Homebrew 不替代 Apple signature 验证 | **Go（正式主路径）**，需 Patrick 选择 own-tap cask |
| source formula（次要/开发） | `url` 指向固定 release source archive/tag，`sha256` 校验；在用户机器或 tap CI 中编译 | 符合 Homebrew 对 open-source CLI 的默认分类；可按本机架构编译 | 产物通常不是 Developer ID 签名/公证，路径与 code identity 不同；需要 FDA/AX/TCC 时可能重新授权 | **Go（次要路径）**，明确“unsigned local build” |
| Homebrew bottle | formula 构建出的预编译 keg，按 OS/架构分发并由 SHA-256 保护 | 安装快、可声明 `arm64_tahoe`/`tahoe` 等矩阵 | bottle 通常由 BrewTestBot 构建，不是项目 Developer ID Application 签名；跨安装方式的 identity 不同 | 仅优化 source formula，不是正式签名路径 |

Homebrew 当前安全/接受策略见 [Security and Supply Chain](https://docs.brew.sh/Supply-Chain-Security)、[Package Acceptance Policy](https://docs.brew.sh/Package-Acceptance-Policy)、[Acceptable Casks](https://docs.brew.sh/Acceptable-Casks)、[Acceptable Formulae](https://docs.brew.sh/Acceptable-Formulae) 与 [Tap Trust](https://docs.brew.sh/Tap-Trust)。固定 URL + checksum 是硬要求；moving branch/unchecksummed archive 不可接受。旧版安全审计仅作历史背景，不作为当前 policy 依据。

自有 tap 的最小流程（文档示例，不在本研究中执行）：

```zsh
brew tap-new patrick-fu/homebrew-voice-memos
brew audit --strict --online patrick-fu/voice-memos/voice-memos-cli
brew install --build-from-source patrick-fu/voice-memos/voice-memos-cli
brew test patrick-fu/voice-memos/voice-memos-cli
brew info --json=v2 patrick-fu/voice-memos/voice-memos-cli

# 生产 cask（先确认 own-tap 内容，再只信任目标 cask）
brew tap patrick-fu/voice-memos
brew trust --cask patrick-fu/voice-memos/voice-memos-cli
brew install --cask patrick-fu/voice-memos/voice-memos-cli
```

tap 更新由用户 `brew update` 获取，`brew upgrade` 执行升级；`brew pin` 可暂时阻止升级但会错过安全修复。需要长期保留旧版本时，`brew extract`/`brew version-install` 会把版本复制到个人 tap，维护责任转给 tap owner。[How to Create and Maintain a Tap](https://docs.brew.sh/How-to-Create-and-Maintain-a-Tap)、[Formulae Versions](https://docs.brew.sh/Versions)

source formula 只在能够用 Swift tools 6.0+、deployment target 15.0 的固定 Xcode/SDK 构建时标为支持；若 tap 构建环境只能提供 macOS 15.6 SDK，则将其兼容下限明确写为 15.6，不把未验证的 15.0 作为承诺。

## 6. 安装路径、升级与 TCC identity 风险

### 已证实

- Homebrew prefix 通常是 Apple silicon 的 `/opt/homebrew`、Intel 的 `/usr/local`；formula keg 在 `Cellar/<name>/<version>`，active `opt`/prefix symlink 指向当前 keg。[Formula Cookbook](https://docs.brew.sh/Formula-Cookbook)
- Apple 的 `tccutil reset <service> [BUNDLE_ID]` 以 service 与 bundle ID 为参数；Accessibility、AppleEvents、`SystemPolicyAllFiles` 等是独立 service。[Resetting access to protected resources](https://developer.apple.com/documentation/xcode/resetting-access-to-protected-resources-in-macos)
- 非 bundle CLI 的 code-signing identifier 可由 signer 通过 `-i` 指定；因此不能把 Unix 路径、Homebrew formula 名或证书名称互相当作同一 identity。[Creating distribution-signed code](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac/)
- Homebrew FAQ 记录：cask 升级可能采用卸载/重装或原位替换；若无 App Management/FDA，macOS 可能清掉旧 app 的权限元数据。[Homebrew FAQ](https://docs.brew.sh/FAQ)

### 推论（不得当作 Apple 合同）

1. Formula 从 `Cellar/name/version` 升级到新版本、ZIP 用户把 binary 移到 `~/.local/bin`、或 cask/PKG 升级/重装，均可能改变 TCC 看到的 executable/code identity 上下文。Apple 未公开承诺这些迁移保留 Voice Memos 只读访问所需的 FDA/用户授权。
2. v0.1 让 doctor 记录实际 executable 的路径、`codesign -d -vv` 的 Identifier/TeamIdentifier、架构、版本和安装渠道；遇到权限失败应提示用户重新授权，而不是猜测 Terminal 授权可继承。
3. 正式 PKG 固定安装路径（例如 `/usr/local/bin/voice-memos-cli`，需管理员确认）；ZIP 辅助下载建议用户固定到 `~/.local/bin/voice-memos-cli`，但仍需测试路径变化；Homebrew 用户必须知道 active symlink 不是稳定的 TCC 合同。

建议验收命令（不会重置权限，也不读取录音）：

```zsh
command -v voice-memos-cli
realpath "$(command -v voice-memos-cli)"
codesign -d -vv "$(realpath "$(command -v voice-memos-cli)")" 2>&1 | rg 'Identifier|TeamIdentifier|Authority|Format'
spctl --assess --type execute --verbose=4 "$(realpath "$(command -v voice-memos-cli)")"
tccutil reset SystemPolicyAllFiles com.patrickfu.voice-memos-cli
# 当前只读产品不使用 Accessibility/Apple Events；如未来研究需要隔离测试，再单独评估。
```

## 7. CI 分层：无凭据与有凭据 release gates

### 无凭据 CI（每个 PR/push）

GitHub-hosted runner 官方标签精确为：arm64 的 `macos-15`、`macos-26`，Intel 的 `macos-15-intel`、`macos-26-intel`；Xcode 版本必须在 job 中固定，不能依赖 `macos-latest`。[GitHub-hosted runners reference](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)

无凭据 job 只做：

- `swift-format`/lint、`swift test`、静态 schema/路径单元测试（synthetic fixtures，不访问用户 Voice Memos）；
- macOS 15/26 的 arm64/x86_64 编译、`lipo`、`codesign --verify`（可用 ad hoc/development 仅验证 Mach-O，不称为发布签名）；
- 生成 unsigned PKG/ZIP（仅测试容器）、`shasum -a 256`、SBOM/依赖锁定、artifact retention；
- GitHub Actions 最小 `permissions`，不使用 Apple 私钥、App Store Connect 密码、notarytool profile、PAT；不运行真实 Voice Memos、TCC 授权或 AX UI。

GitHub artifact attestations 可在无 Apple 凭据条件下建立构建 provenance，但需要 workflow `id-token: write`；它不是 Apple notarization。[Using artifact attestations](https://docs.github.com/en/actions/how-tos/secure-your-work/use-artifact-attestations/use-artifact-attestations)

### 有凭据 release gate（仅受保护 tag/environment）

1. 由人工批准的 `workflow_dispatch` 或受保护 `v*` tag 触发；先下载并验证无凭据 CI 产物的 commit、checksum、测试结果。
2. 使用最小权限的 Apple Developer ID Application 证书/私钥与 notarytool keychain profile；secret 只在 release environment 注入。GitHub environment required reviewers 在批准前不会向 job 提供 environment secrets。[Deployments and environments](https://docs.github.com/en/actions/reference/workflows-and-actions/deployments-and-environments)
3. 在 macOS runner 运行签名、`notarytool submit --wait`、PKG staple、`spctl`/`codesign`/`lipo` 验收，生成最终 `SHA256SUMS`。
4. 在仓库 Settings → Releases **发布前启用 release immutability**；创建 draft GitHub Release，上传全部资产后发布 immutable release；失败时停止，不修改已发布 tag/资产。[Preventing release changes](https://docs.github.com/en/code-security/how-tos/secure-your-supply-chain/establish-provenance-and-integrity/prevent-release-changes)、[Immutable releases](https://docs.github.com/en/code-security/concepts/supply-chain-security/immutable-releases)
5. 单独更新 tap formula 的 source URL/checksum（或经 Patrick 决策的 cask URL/checksum），在干净 runner 上 `brew audit`/`brew test`；Homebrew tap token 不应与 Apple signing secret 共用。

Apple 私钥泄露、notarytool 拒绝、staple/spctl 失败、checksum 不一致、immutable release 无法创建，均是 release **失败**，不能降级为“未签名但可用”。

## 8. v0.1 release checklist

- [ ] `Package.swift` 的 tools version/platform target 固定；`Package.resolved` 无 moving dependency。
- [ ] macOS 15.6 与 26.x、arm64 与 x86_64 编译/测试记录齐全；universal2 `lipo -archs` 通过。
- [ ] 仅最终 Mach-O 使用 Developer ID Application；`--options runtime --timestamp`、identifier、Team ID 和 entitlements 已审阅。
- [ ] `codesign --verify --strict`、`spctl`、两个 slice 检查通过；未含 `get-task-allow=true`。
- [ ] `pkgbuild`/`productsign` 生成 signed flat PKG；PKG checksum 在 stapling 后计算。
- [ ] `notarytool` 对最终 PKG 成功；`stapler staple`/`validate` 通过；离线 Mac PKG 安装 smoke test 通过。
- [ ] 可选 ZIP 仅记录在线 ticket；不声称裸 Mach-O ZIP 可 offline staple。
- [ ] 仓库在创建 release 前已启用 immutable；新 semver tag、PKG/ZIP（如有）和 `SHA256SUMS` 一次上传；`gh release verify`/`verify-asset` 通过。
- [ ] own-tap cask 的 PKG URL 是 immutable release、`sha256` 正确；`brew audit`/安装测试通过。source formula 仅在固定 Swift/Xcode 环境下 `brew audit --strict --online`、source build、test 通过。
- [ ] PKG/cask、ZIP 辅助、formula source build 分别在 15/26、Intel/Apple silicon 上做 TCC/doctor 验收；报告路径变化和重新授权结果。
- [ ] Release notes 明确：source formula 是 unsigned local build；签名公证不授 FDA/AX/Automation。

## 9. 已确认的 v0.1 分发决策

1. **Homebrew 正式渠道：**维护 own tap，以 cask 安装与直链下载完全相同的 signed/stapled PKG。source formula 只作为开发者/次要路径。
2. **部署下限：**`macOS 15.0`，覆盖当前 major Tahoe 26 与前一 major Sequoia 15；发布前必须完成对应架构与系统矩阵验证。
3. **正式发布门槛：**公开 PKG 必须同时满足 Developer ID Application payload、Developer ID Installer、Hardened Runtime、secure timestamp、notarization、stapling、checksum 与 immutable GitHub Release。可选 ZIP 只标 online-ticket 辅助下载，不进入 offline 安装承诺。
4. **开源许可：**MIT。

这些是 release contract，不授权当前规划阶段创建 tap、上传 release、生成签名产物或读取 Apple/GitHub 凭据；实际发布要等实现、测试和 release gate 全部就绪。

## 参考资料

- [Apple：macOS 版本与兼容性](https://support.apple.com/en-us/109033)
- [Apple：Xcode 系统要求](https://developer.apple.com/xcode/system-requirements)
- [Apple：构建 universal macOS binary](https://developer.apple.com/documentation/Apple-Silicon/building-a-universal-macos-binary)
- [Apple：Swift 安装与 Xcode toolchain](https://www.swift.org/install/macos/)
- [SwiftPM：PackageDescription 与 deployment target](https://docs.swift.org/package-manager/PackageDescription/PackageDescription.html)
- [SwiftPM：swift-tools-version](https://docs.swift.org/package-manager/PackageDescription/PackageDescription.html#setting-the-swift-tools-version)
- [Apple：Creating distribution-signed code](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac/)
- [Apple：Notarizing macOS software](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- [Apple：Customizing notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)
- [Apple：Packaging Mac software](https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution)
- [Apple：TCC reset](https://developer.apple.com/documentation/xcode/resetting-access-to-protected-resources-in-macos)
- [Homebrew：Security and Supply Chain](https://docs.brew.sh/Supply-Chain-Security)
- [Homebrew：Package Acceptance Policy](https://docs.brew.sh/Package-Acceptance-Policy)
- [Homebrew：Formula Cookbook](https://docs.brew.sh/Formula-Cookbook)
- [Homebrew：Bottles](https://docs.brew.sh/Bottles)
- [Homebrew：Acceptable Formulae](https://docs.brew.sh/Acceptable-Formulae)
- [Homebrew：Acceptable Casks](https://docs.brew.sh/Acceptable-Casks)
- [Homebrew：Tap Trust](https://docs.brew.sh/Tap-Trust)
- [Homebrew：Create and Maintain a Tap](https://docs.brew.sh/How-to-Create-and-Maintain-a-Tap)
- [Homebrew：Formulae Versions](https://docs.brew.sh/Versions)
- [Homebrew：FAQ（cask upgrade permissions）](https://docs.brew.sh/FAQ)
- [GitHub：About releases](https://docs.github.com/en/repositories/releasing-projects-on-github/about-releases)
- [GitHub：Immutable releases](https://docs.github.com/en/code-security/concepts/supply-chain-security/immutable-releases)
- [GitHub：Verify release integrity](https://docs.github.com/en/code-security/how-tos/secure-your-supply-chain/secure-your-dependencies/verify-release-integrity)
- [GitHub：Hosted runners](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)
- [GitHub：Artifact attestations](https://docs.github.com/en/actions/how-tos/secure-your-work/use-artifact-attestations/use-artifact-attestations)
- [GitHub：Deployments and environments](https://docs.github.com/en/actions/reference/workflows-and-actions/deployments-and-environments)
