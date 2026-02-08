# Spec: App Selection

## Purpose
Defines how applications are discovered and selected for recording.

## Requirements

### Requirement: Filter Empty App Names
The system SHALL exclude applications with empty or whitespace-only names from the selectable application list.

#### Scenario: App list contains empty names
- **WHEN** the system queries for running applications
- **AND** the result contains applications with empty names
- **THEN** the `availableApps` list MUST NOT contain any application with an empty name
- **AND** the "Target Application" dropdown MUST display only applications with valid names

#### Scenario: App list contains valid names
- **WHEN** the system queries for running applications
- **AND** the result contains applications with valid names
- **THEN** the `availableApps` list MUST contain these applications
