# Repository Guidelines

## Project Structure & Module Organization
`Sources/VoiceMemo` contains the macOS app code. Keep models in `Models`, business logic and integrations in `Services` (including `Services/Pipeline` and `Services/Storage`), SwiftUI screens in `Views`, and bundled assets in `Resources`. Tests live under `Tests/VoiceMemoTests`. Use `assets/` for README screenshots, `doc/` for design and operational docs, and `openspec/` for feature specs and change proposals.

## Build, Test, and Development Commands
Run `swift build` to compile the SwiftPM target used by CI. Run `swift test` to execute the `VoiceMemoTests` suite. Use `./package_app.sh` to produce a locally signed `VoiceMemo.app` for ScreenCaptureKit and microphone permission testing. For Xcode debugging, run `python3 generate_project.py` and then `xed VoiceMemo.xcodeproj`. CI currently mirrors `swift build -v` and `swift test -v` on macOS.

## Coding Style & Naming Conventions
Follow existing Swift conventions: 4-space indentation, `UpperCamelCase` for types, `lowerCamelCase` for properties and methods, and one primary type or view per file named after that type, such as `SettingsStore.swift` or `PipelineView.swift`. Prefer small focused extensions and `// MARK:` separators in larger files. There is no repo-wide SwiftLint or SwiftFormat config, so match the surrounding code and keep imports minimal.

## Testing Guidelines
Tests use `XCTest`. Place new coverage in `Tests/VoiceMemoTests` and name files `*Tests.swift`; test methods should start with `test`. Favor deterministic unit tests for parsing, pipeline state, and settings behavior. Credential-dependent integration tests already use placeholder values and `XCTSkip`; keep that pattern and never commit live OSS, ASR, MySQL, or email credentials.

## Commit & Pull Request Guidelines
Recent history follows concise Conventional Commit style with optional scopes, for example `feat(email): support multiple recipients` and `fix(storage): stabilize MySQL provider`. Keep subjects imperative and focused on one change. Pull requests should summarize behavior changes, note manual verification steps, link related issues, and include screenshots for UI updates. Call out any permission, signing, or configuration impact explicitly.

## Security & Configuration Tips
Secrets should stay in Keychain-backed settings or local developer overrides, not in source files. When changing capture, signing, or network-related behavior, update the relevant docs in `doc/` so contributors can reproduce the setup safely.
