# Testing

## Purpose

Explain the current test suite and how to run it safely without committing secrets.

## Test Targets

SwiftPM test target:

- `VoiceMemoTests`

Test files:

- `Tests/VoiceMemoTests/TingwuSignatureTests.swift`
- `Tests/VoiceMemoTests/TingwuCreateTaskTests.swift`
- `Tests/VoiceMemoTests/OSSUploadTests.swift`

## What Is Covered

- Tingwu request signing canonicalization and hash validation.
- Tingwu create task request body construction (feature toggles).
- OSS upload connectivity (requires real credentials).

## Running Tests

From repository root:

```bash
swift test
```

## Credentials Policy

Do not hardcode real credentials in the repository.

Tests that require credentials use placeholders and skip if not filled:

- `YOUR_ACCESS_KEY_ID`
- `YOUR_ACCESS_KEY_SECRET`
- `YOUR_TINGWU_APPKEY`
- `YOUR_PUBLIC_OSS_FILE_URL`
- `YOUR_BUCKET_NAME`

Recommended workflow:

- Keep placeholders in Git.
- During local testing, temporarily fill values, run tests, then revert the file before committing.

