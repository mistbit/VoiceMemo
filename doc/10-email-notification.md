# Email Notification Integration

## Overview
This document outlines the integration of automated email notifications using the [FastMail Gateway](https://github.com/mistbit/fastmail).

## Feature Description
The system will automatically generate a Markdown summary of the meeting and send it via email to configured recipients (supports multiple recipients) upon successful completion of the processing pipeline.

## Configuration
Users can configure the email gateway in the application settings:

- **Gateway URL**: The endpoint of the deployed FastMail service (e.g., `http://localhost:8080`).
- **Authentication Token**: The secure token for accessing the gateway.
- **Recipient Emails**: The email addresses where the summary should be sent. Separate multiple emails with commas.

## Workflow

1.  **Pipeline Completion**:
    - The `MeetingPipelineManager` detects that the transcription and summarization tasks are complete.
    - If email notification is enabled, the system proceeds to generate the Markdown file.

2.  **Attachment Preparation**:
    - The system prepares attachments based on user settings:
        - **Summary**: Markdown file with metadata, summary, key points, and action items.
        - **Audio**: Original audio recording file (local or downloaded).
        - **Transcript**: Full transcript text file.
        - **Raw Data**: Raw JSON response from the ASR provider.

3.  **Email Dispatch**:
    - The system constructs a multipart HTTP POST request to the configured Gateway URL.
    - The request includes the selected files as attachments.
    - The email is sent to the configured recipients.

4.  **Status Feedback**:
    - The pipeline status reflects the outcome of the email sending process (Success/Failure).
    - In case of failure, users can retry sending the email manually from the Result View.

## Technical Implementation Plan

### 1. Settings Update
- Extend `SettingsStore` to include `fastmailUrl`, `fastmailToken`, and `recipientEmail`.
- Update `SettingsView` to provide input fields for these configurations.

### 2. Service Layer
- Create `EmailService` to handle communication with the FastMail gateway.
- Implement `sendEmail(to:subject:body:attachments:)` method using `URLSession`.

### 3. Pipeline Integration
- Introduce a new pipeline node `EmailNode` (or extend `MeetingPipelineManager` logic).
- Ensure this step runs only after successful completion of previous steps.

### 4. UI Enhancements
- Add a "Send Email" button in `ResultView` for manual triggering.
- Display email sending status in the pipeline progress indicator.
