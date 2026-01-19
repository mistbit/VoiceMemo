# WeChatVoiceRecorder 使用指南

这是一个基于 macOS 原生 ScreenCaptureKit 的音频录制工具，专为捕获微信实时语音通话设计。

## 功能
- **应用选择**：自动检测并过滤运行中的应用（优先选中微信）。
- **原生录制**：使用 ScreenCaptureKit 录制系统高保真音频。
- **自动保存**：录音文件自动保存至 `Downloads/WeChatRecordings`。
- **原生 UI**：简洁的 SwiftUI 界面。

## 运行环境要求
- macOS 12.3 或更高版本。
- Xcode 13+ (用于编译和签名)。

## 如何运行

由于 ScreenCaptureKit 需要应用拥有**屏幕录制权限**，且必须经过**代码签名**才能正常请求权限，因此**不能直接通过命令行 `swift run` 运行**（除非手动签名二进制）。

### 推荐方式：使用 Xcode 打开

1. 打开终端，进入项目目录：
   ```bash
   cd /Users/masamiyui/OpenSoureProjects/wechat-voice-ai-record/WeChatVoiceRecorder
   ```

2. 双击 `Package.swift` 文件，或者运行：
   ```bash
   xed .
   ```
   这将在 Xcode 中打开项目。

3. **配置签名**：
   - 在 Xcode 左侧导航栏点击项目根节点 `WeChatVoiceRecorder`。
   - 在 `Targets` 列表中选择 `WeChatVoiceRecorder`。
   - 进入 `Signing & Capabilities` 标签页。
   - 在 `Signing` 部分，选择你的 `Team`（如果没有，可选择 Personal Team）。
   - **重要**：确保 `Bundle Identifier` 是唯一的。
   - 添加 `Hardened Runtime` 能力（如果是为了发布），或者在 `Signing` 中选择 `Sign to Run Locally`。

4. **添加权限描述（Info.plist）**：
   虽然 SwiftPM 可执行文件通常没有 Info.plist，但为了请求权限，你可能需要确保 Xcode 自动生成的 Info.plist 包含 `NSDesktopFolderUsageDescription` 或 `NSScreenCaptureUsageDescription`（通常 SCK 不需要 Info.plist 里的特定 key，但在运行时系统会弹窗提示“允许终端/应用录制屏幕”）。
   
   *注意*：如果是通过 Xcode 运行，系统会提示“Xcode 想要录制屏幕”或类似权限请求。

5. **运行**：
   - 点击 Xcode 顶部的 Run 按钮 (或 Cmd+R)。
   - App 启动后，选择“微信”作为录制对象。
   - 点击“Start Recording”。
   - **首次运行时，macOS 会弹出“屏幕录制权限”请求，请务必点击“允许”并前往系统设置中勾选。**
   - 如果权限被拒绝，请在“系统设置 -> 隐私与安全性 -> 屏幕录制”中移除该应用并重试。

### 注意事项
- 录音文件格式为 `.wav` (32-bit Float PCM)，保存在 `Downloads/WeChatRecordings`。
- 录制时请确保微信正在通话或播放声音。
- 目前仅实现了录制和保存，**语音识别（ASR）** 将在后续步骤中接入阿里云 API。

## 故障排除
- **看不到应用列表？** 检查是否授予了屏幕录制权限。
- **录不到声音？** 确保微信输出设备是默认设备，且系统静音未开启。
- **无法编译？** 确保 Xcode 版本支持 Swift 5.9+ 和 macOS 12 SDK。
