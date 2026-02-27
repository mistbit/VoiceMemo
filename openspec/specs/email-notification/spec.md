# Spec: Email Notification via FastMail Gateway

## Purpose
Automate the sending of meeting summaries (Markdown) via email upon successful pipeline completion, using the `fastmail` gateway.

## Context
Currently, users must manually export Markdown files after the pipeline finishes. This feature automates the delivery of the meeting summary to a designated recipient.

## Requirements

### Requirement: Email Gateway Configuration
The system SHALL support configuration for the `fastmail` gateway.

#### Scenario: User configures email settings
- **WHEN** the user navigates to the Settings view
- **THEN** the user MUST be able to input:
  - `FastMail Gateway URL` (e.g., `http://localhost:8080`)
  - `FastMail Token` (for authentication)
  - `Recipient Email` (the default "corresponding user" email)
- **AND** these settings MUST be persisted securely (Token in Keychain).

### Requirement: Automated Email Sending
The system SHALL automatically send an email with the meeting summary upon successful pipeline completion.

#### Scenario: Pipeline completes successfully
- **WHEN** the meeting pipeline reaches the `completed` state (after transcription and summarization)
- **AND** the `FastMail Gateway URL` and `Recipient Email` are configured
- **THEN** the system MUST generate the Markdown summary of the meeting
- **AND** the system MUST send a POST request to the configured gateway URL
  - **Endpoint**: `/api/v1/send` (based on `fastmail` API)
  - **Headers**: `Authorization: Bearer <token>`
  - **Body**:
    - `to`: `<Recipient Email>`
    - `subject`: `Meeting Summary: <Meeting Title>`
    - `body`: "Please find the attached meeting summary." (or the summary content itself if preferred)
    - `attachments`: The generated Markdown file
- **AND** the pipeline status MUST reflect the email sending result (e.g., log success or error).

#### Scenario: Pipeline fails or is incomplete
- **WHEN** the pipeline is in any state other than `completed`
- **THEN** the system MUST NOT attempt to send the email.

#### Scenario: Email sending fails
- **WHEN** the email gateway returns an error or is unreachable
- **THEN** the system MUST log the error
- **AND** the UI SHOULD indicate that the email failed to send (optional: allow retry).

### Requirement: Manual Trigger (Optional but recommended)
The system SHOULD allow manual triggering of the email if it failed or was skipped.

#### Scenario: User clicks "Send Email"
- **WHEN** the task is completed
- **THEN** the "Export Markdown" area SHOULD include an option to "Send via Email".

## API Integration Details
Based on `https://github.com/mistbit/fastmail`:
- **Method**: POST
- **Content-Type**: `multipart/form-data`
- **Fields**:
  - `to`: String (comma-separated emails)
  - `subject`: String
  - `body`: String (HTML supported)
  - `attachments`: File (Multipart)
