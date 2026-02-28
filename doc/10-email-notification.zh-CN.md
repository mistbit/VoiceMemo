# 邮件通知集成

## 概述
本文档概述了使用 [FastMail Gateway](https://github.com/mistbit/fastmail) 集成自动邮件通知的功能。

## 功能描述
当处理流水线成功完成后，系统将自动生成会议的 Markdown 摘要，并通过邮件发送给配置的收件人（支持多个收件人）。

## 配置
用户可以在应用设置中配置邮件网关：

- **网关 URL (Gateway URL)**：部署的 FastMail 服务端点（例如 `http://localhost:8080`）。
- **认证令牌 (Authentication Token)**：用于访问网关的安全令牌。
- **收件人邮箱 (Recipient Emails)**：接收摘要的邮箱地址。支持多个邮箱，使用逗号分隔。

## 工作流程

1.  **流水线完成**：
    - `MeetingPipelineManager` 检测到转写和摘要任务已完成。
    - 如果启用了邮件通知，系统将开始生成 Markdown 文件。

2.  **Markdown 生成**：
    - 系统生成包含以下内容的 Markdown 文件：
        - 会议元数据（标题、日期、时长）
        - 摘要
        - 关键点
        - 待办事项
        - 完整转写文本

3.  **邮件分发**：
    - 系统构造一个 multipart HTTP POST 请求到配置的网关 URL。
    - 请求包含作为附件的 Markdown 文件。
    - 邮件将被发送到配置的收件人。

4.  **状态反馈**：
    - 流水线状态反映邮件发送过程的结果（成功/失败）。
    - 如果失败，用户可以在结果视图中手动重试发送邮件。

## 技术实现计划

### 1. 设置更新
- 扩展 `SettingsStore` 以包含 `fastmailUrl`、`fastmailToken` 和 `recipientEmail`。
- 更新 `SettingsView` 以提供这些配置的输入字段。

### 2. 服务层
- 创建 `EmailService` 以处理与 FastMail 网关的通信。
- 使用 `URLSession` 实现 `sendEmail(to:subject:body:attachments:)` 方法。

### 3. 流水线集成
- 引入新的流水线节点 `EmailNode`（或扩展 `MeetingPipelineManager` 逻辑）。
- 确保此步骤仅在之前步骤成功完成后运行。

### 4. UI 增强
- 在 `ResultView` 中添加“发送邮件”按钮以进行手动触发。
- 在流水线进度指示器中显示邮件发送状态。
