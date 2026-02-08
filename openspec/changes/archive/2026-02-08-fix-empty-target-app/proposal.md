# Proposal: Fix Empty Target Application Name

## Why
Users are seeing an empty entry in the "Target Application" selection list. This is confusing and provides a poor user experience as selecting an unnamed application is likely unintended and non-functional.

## What Changes
- Filter out applications with empty strings as their `applicationName` in `AudioRecorder.swift` when populating `availableApps`.
- Ensure only valid, named applications are presented to the user.

## Capabilities

### New Capabilities
- `app-selection`: Defines how applications are discovered and selected for recording.

### Modified Capabilities


## Impact
- `Sources/VoiceMemo/AudioRecorder.swift`: `refreshAvailableApps` method.
