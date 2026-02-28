# Email Notification Integration

## Overview
This document outlines the integration of automated email notifications using the [FastMail Gateway](https://github.com/mistbit/fastmail).

## Feature Description
The system will automatically generate a Markdown summary of the meeting and send it via email to a configured recipient upon successful completion of the processing pipeline.

## Configuration
Users can configure the email gateway in the application settings:

- **Gateway URL**: The endpoint of the deployed FastMail service (e.g., `http://localhost:8080`).
- **Authentication Token**: The secure token for accessing the gateway.
- **Recipient Email**: The email address where the summary should be sent.

## Workflow

1.  **Pipeline Completion**:
    - The `MeetingPipelineManager` detects that the transcription and summarization tasks are complete.
    - If email notification is enabled, the system proceeds to generate the Markdown file.

2.  **Markdown Generation**:
    - The system generates a Markdown file containing:
        - Meeting Metadata (Title, Date, Duration)
        - Summary
        - Key Points
        - Action Items
        - Full Transcript

3.  **Email Dispatch**:
    - The system constructs a multipart HTTP POST request to the configured Gateway URL.
    - The request includes the Markdown file as an attachment.
    - The email is sent to the configured recipient.

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
