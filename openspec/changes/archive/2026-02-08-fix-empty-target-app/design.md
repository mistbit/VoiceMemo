# Design: Filter Empty Target Application

## Context
Currently, the `AudioRecorder` fetches all running applications using `SCShareableContent`. This list includes applications with empty names, which are displayed in the "Target Application" dropdown, causing confusion.

## Goals / Non-Goals

**Goals:**
- Modify `refreshAvailableApps` in `AudioRecorder.swift` to filter out applications where `applicationName` is empty or whitespace only.
- Ensure the filtered list is sorted alphabetically.

**Non-Goals:**
- Changing the underlying `ScreenCaptureKit` fetching mechanism.
- Filtering by other criteria (e.g., bundle ID) unless necessary for the empty name issue.

## Decisions
- **Filter at Source**: Filter the list immediately after fetching from `SCShareableContent` and before sorting/assigning to `availableApps`.
- **Whitespace Trimming**: Use `trimmingCharacters(in: .whitespacesAndNewlines)` to ensure names that are just spaces are also excluded.

## Risks / Trade-offs
- **Risk**: Valid apps might have empty names (highly unlikely for GUI apps users want to record).
  - **Mitigation**: Users can still use "Mixed Mode" or select other apps. This risk is acceptable as unnamed apps are usually system daemons not suitable for recording via this UI.
