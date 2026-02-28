# Design: Email Notification via FastMail Gateway

## Architecture
The email notification feature will be integrated into the existing `MeetingPipelineManager` workflow as a new step (Node) or a post-processing action.

### Components

1.  **SettingsStore**:
    - Add `fastmailUrl` (String)
    - Add `fastmailToken` (String, Secure)
    - Add `recipientEmail` (String)
    - Add `enableEmailNotification` (Bool)

2.  **EmailService**:
    - Responsible for constructing the multipart request to the FastMail gateway.
    - Handles authentication (Bearer Token).
    - Handles attachment upload.

3.  **PipelineNode (New: `EmailNode`)**:
    - Step: `.sendingEmail` (New status?) or part of `.completed` post-processing.
    - Logic:
        - Check if email is enabled and configured.
        - Generate Markdown content.
        - Call `EmailService.send()`.
        - Update task status or log result.

4.  **MeetingTask**:
    - Add `emailStatus` (Enum: .none, .sending, .sent, .failed)
    - Add `emailError` (String?)

### Workflow

1.  **Configuration**: User enters FastMail details in Settings.
2.  **Pipeline Execution**:
    - After `PollingNode` completes successfully (Status: `.completed`), the pipeline manager checks if `enableEmailNotification` is true.
    - If true, it triggers the email sending logic.
    - **Option A**: Add `EmailNode` to the end of the chain.
    - **Option B**: Handle it in `MeetingPipelineManager.executeChain` after the loop finishes.
    - *Decision*: Option A is cleaner and fits the "Pipeline" pattern. We can add a new status `.sendingEmail` -> `.emailSent`.

### UI Changes

1.  **SettingsView**:
    - Add a section for "Email Notification".
    - Fields: Gateway URL, Token, Recipient Email.
    - "Test Connection" button.

2.  **ResultView**:
    - Add "Send Email" button (manual trigger) if task is completed.
    - Show email status (e.g., "Email Sent" or "Sending Failed").

## Data Flow

`MeetingTask` -> `MeetingPipelineManager` -> `EmailNode` -> `EmailService` -> `FastMail Gateway`

## Security
- `fastmailToken` stored in Keychain via `KeychainHelper`.
- HTTPS recommended for Gateway URL.
