# Permissions and Signing (macOS)

## Purpose

Explain which permissions are needed, how they map to Info.plist/entitlements, and how signing stability affects repeated system prompts.

## Required Permissions

### Screen Recording

Needed for ScreenCaptureKit to capture system audio.

- Usage string in `Sources/VoiceMemo/Info.plist`:
  - `NSScreenCaptureUsageDescription`
- Grant via:
  - System Settings → Privacy & Security → Screen Recording

### Microphone

Needed for local audio track.

- Usage string in `Sources/VoiceMemo/Info.plist`:
  - `NSMicrophoneUsageDescription`

## Entitlements

File: `VoiceMemo.entitlements`

Current keys:

- `com.apple.security.app-sandbox`
- `com.apple.security.device.audio-input`
- `com.apple.security.device.camera`
- `com.apple.security.files.downloads.read-write`
- `com.apple.security.files.user-selected.read-write`
- `com.apple.security.network.client`
- `com.apple.security.personal-information.photos-library`

Only add entitlements that are required by actual features; extra entitlements increase review and user trust risks.

## Bundle Identifier

The app identity is anchored by Bundle ID:

- `Info.plist` `CFBundleIdentifier`: `cn.mistbit.voicememo`
- Xcode target build setting `PRODUCT_BUNDLE_IDENTIFIER`: `cn.mistbit.voicememo`

If Bundle ID changes, macOS treats the app as a new identity and will re-prompt for privacy permissions.

## Signing Stability and Repeated Prompts

macOS privacy permission grants are tied to the app’s identity and signing.

For stable behavior during development:

- Keep Bundle ID stable.
- Use a stable development Team and automatic signing in Xcode.
- If you use the generated `VoiceMemo.xcodeproj`, re-run `generate_project.py` after dependency changes to keep package references in sync.
  - If Xcode shows `No such module` for a SwiftPM dependency, try `File > Packages > Reset Package Caches` and then clean the build folder.

Packaging script note:

- `package_app.sh` always builds a versioned `.app` plus a `.zip` archive in `dist/`.
- The script uses ad-hoc signing by default (`codesign --sign -`) and can switch to Developer ID signing when `SIGN_IDENTITY` is provided.
- If `VoiceMemo.entitlements` exists, the script signs with that entitlements file to match the Xcode target more closely.
- Ad-hoc signatures are not stable identities for repeated permission grants; repeated prompts are expected when running differently signed builds.

## GitHub Tag Releases

Workflow file: `.github/workflows/release.yml`

When you push a tag such as `v1.2.3`, the release workflow:

- runs `swift test`
- builds `dist/VoiceMemo.app`
- injects `CFBundleShortVersionString=1.2.3`
- injects `CFBundleVersion=<GitHub run number>`
- creates `dist/VoiceMemo-1.2.3-macos.zip`
- uploads the zip and `.sha256` file to GitHub Releases

### Release Secrets

For ad-hoc archive publishing, no extra secrets are required.

For Developer ID signing:

- `MACOS_CERTIFICATE_P12`
- `MACOS_CERTIFICATE_PASSWORD`
- `MACOS_SIGNING_IDENTITY`
- `MACOS_KEYCHAIN_PASSWORD` (optional)

For notarization:

- `APPLE_ID`
- `APPLE_APP_SPECIFIC_PASSWORD`
- `APPLE_TEAM_ID`

If the signing or notarization secrets are missing, the workflow still publishes an ad-hoc signed archive. That is useful for internal distribution, but external users may still hit Gatekeeper/quarantine warnings.

## Practical Recommendation

- Debug via Xcode with automatic signing and a fixed team.
- Use GitHub tag releases with Developer ID signing + notarization for public binary distribution.
- Use ad-hoc packaging only for quick local distribution/testing; expect permission prompts unless you switch to a stable signing identity.
