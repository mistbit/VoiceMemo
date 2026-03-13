# 权限与签名（macOS）

## 文档目的

说明应用需要哪些权限、它们如何映射到 Info.plist/entitlements，以及“签名与身份不稳定”为什么会导致重复弹窗。

## 必要权限

### 屏幕录制

ScreenCaptureKit 采集系统音频需要屏幕录制权限。

- `Sources/VoiceMemo/Info.plist` 中的说明文案：
  - `NSScreenCaptureUsageDescription`
- 授权路径：
  - 系统设置 → 隐私与安全性 → 屏幕录制

### 麦克风

采集本地麦克风需要麦克风权限。

- `Sources/VoiceMemo/Info.plist`：
  - `NSMicrophoneUsageDescription`

## Entitlements

文件：`VoiceMemo.entitlements`

当前包含：

- `com.apple.security.app-sandbox`
- `com.apple.security.device.audio-input`
- `com.apple.security.device.camera`
- `com.apple.security.files.downloads.read-write`
- `com.apple.security.files.user-selected.read-write`
- `com.apple.security.network.client`
- `com.apple.security.personal-information.photos-library`

仅添加真实功能需要的 entitlement，避免扩大权限面导致不必要的风险与用户不信任。

## Bundle Identifier

应用身份的核心是 Bundle ID：

- `Info.plist` 的 `CFBundleIdentifier`：`cn.mistbit.voicememo`
- Xcode target 的 `PRODUCT_BUNDLE_IDENTIFIER`：`cn.mistbit.voicememo`

Bundle ID 变化会被 macOS 视为新应用身份，从而重新弹窗授权。

## 签名稳定性与重复弹窗

macOS 隐私权限授权与“应用身份 + 签名”绑定。

要让授权稳定复用：

- Bundle ID 固定不变
- Xcode 中固定 Team，并使用 Automatic signing
- 如果使用生成的 `VoiceMemo.xcodeproj`，在依赖变更后请重新运行 `generate_project.py`，保证 SwiftPM 依赖引用一致
  - 若 Xcode 出现 `No such module`，可尝试 `File > Packages > Reset Package Caches`，再 Clean Build Folder

打包脚本说明：

- `package_app.sh` 会在 `dist/` 下输出带版本号的 `.app` 和 `.zip` 包
- 脚本默认使用 ad-hoc 签名（`codesign --sign -`），如果提供 `SIGN_IDENTITY` 则会切换为 Developer ID 签名
- 如果仓库中存在 `VoiceMemo.entitlements`，脚本会在签名时显式带上它，尽量与 Xcode target 的行为保持一致
- ad-hoc 签名不具备稳定身份，换一种方式运行/签名后重复弹窗是预期现象

## GitHub Tag 发布

工作流文件：`.github/workflows/release.yml`

当你推送 `v1.2.3` 这样的 tag 时，发布 workflow 会自动：

- 执行 `swift test`
- 构建 `dist/VoiceMemo.app`
- 注入 `CFBundleShortVersionString=1.2.3`
- 注入 `CFBundleVersion=<GitHub run number>`
- 生成 `dist/VoiceMemo-1.2.3-macos.zip`
- 将 zip 和 `.sha256` 文件上传到 GitHub Release

### 发布所需 Secrets

如果只是发布 ad-hoc 归档，不需要额外 secrets。

如果要做 Developer ID 签名，需要：

- `MACOS_CERTIFICATE_P12`
- `MACOS_CERTIFICATE_PASSWORD`
- `MACOS_SIGNING_IDENTITY`
- `MACOS_KEYCHAIN_PASSWORD`（可选）

如果要做 notarization，还需要：

- `APPLE_ID`
- `APPLE_APP_SPECIFIC_PASSWORD`
- `APPLE_TEAM_ID`

如果签名或公证所需 secrets 缺失，workflow 仍然会发布 ad-hoc 签名的归档。这适合内部测试，但对外分发时用户仍可能遇到 Gatekeeper 或 quarantine 提示。

## 实践建议

- 调试：优先使用 Xcode + 自动签名 + 固定 Team。
- 对外二进制发布：优先使用 GitHub tag release + Developer ID 签名 + notarization。
- ad-hoc 打包：适合快速本地运行/分发测试；若要减少弹窗，需要改为稳定签名策略。
