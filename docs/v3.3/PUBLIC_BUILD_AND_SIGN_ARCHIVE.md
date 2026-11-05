# BUILD_AND_SIGN — Impress V3.2 public feature branch

## Current executable workflow
For active V3.2 use `feature/impress-v3-r04-2-build` and `.github/workflows/r04-2-privacy-retirement-validation.yml`. Other older R03/main or calibration-v01 workflows have different trigger rules and must not be treated as sign-off of the active branch.

GitHub Actions installs pinned CocoaPods, runs all portable Swift Core tests (including calibration), audits retired native Chat and public Git history for credentials, compiles the Simulator app, runs full UIKit XCTest, compiles the `aReuImpress-iPhone-AltStore` iPhoneOS ARM64 app with `CODE_SIGNING_ALLOWED=NO`, verifies executable, unsigned state, ZIP and SHA-256, and uploads the testing Artifact.

## Explicitly incomplete original App Icon
Public source intentionally includes seven unchanged original iPhone AppIcon PNGs but lacks byte-identical `AppIcon.appiconset/icon_1024.png` (expected Git blob `f5a0edd2f317c7104441ee8798fb0fbf00cff9e5`). No image is generated or scaled to replace it.
The native-qa CI modifies `Contents.json` **only inside its ephemeral runner** to omit the unavailable App Store marketing slot. An artifact whose IPA name includes `7icon-INCOMPLETE-unsigned` is thus a development candidate, never a Release PASS. `.github/scripts/verify_public_mirror.py` intentionally continues to fail the full eight-icon release gate until the owner explicitly supplies the authentic binary. Do not turn the gate off.

## Validation commands
On a trusted Mac with matching Xcode/CocoaPods:

```bash
swift test --package-path Packages/ImpressReviewCore --parallel
python3 .github/scripts/verify_retired_native_chat.py
python3 .github/scripts/check_git_history_secrets.py
pod install --repo-update
xcodebuild -workspace aReuImpress-iPhone.xcworkspace -scheme aReuImpress-iPhone -configuration Debug -destination 'generic/platform=iOS Simulator' IPHONEOS_DEPLOYMENT_TARGET=26.0 CODE_SIGNING_ALLOWED=NO build
xcodebuild -workspace aReuImpress-iPhone.xcworkspace -scheme aReuImpress-iPhone-AltStore -configuration Debug -sdk iphoneos -destination 'generic/platform=iOS' IPHONEOS_DEPLOYMENT_TARGET=26.0 CODE_SIGNING_ALLOWED=NO CODE_SIGN_ENTITLEMENTS= ENABLE_DEBUG_DYLIB=NO build
```

The full XCTest requires a real available iPhone Simulator destination and the project's shared XCTest scheme; consult CI rather than substituting a build-only command for the test result. New acceptance requires regression of live System/Light/Dark switching, three persisted UI languages, stale-safe understanding edits with historical revisions, native Notes grouped-list style and read-only Markdown document presentation. Do not run the six non-icon placeholder generator on original icons.

## User signing and iCloud limitations
The IPA is unsigned and must be signed with the user's own Apple identity/provisioning on a compatible tool. A free Personal Team can restrict iCloud and App Groups entitlements; removing entitlement requests may allow installation **but does not certify iCloud Files Provider access**. iCloud backup folder selection, security-scoped bookmarks, notification delivery after reboot, time-zone changes and dark/light UI require iPhone 13 physical QA.

## Provenance
Use GitHub Actions Artifact URL from the exact target SHA, SHA256SUMS / IPA_SHA256, Xcode job logs, and the application's bundle ID. `SOURCE_MANIFEST.json` preserves historical mirror provenance but its historical blob digests are not a claim that current V3.2 files are byte-identical to that snapshot. Never declare a Release, or modify private/main branches, without separate authorization.

## iOS 26 deployment migration
App and XCTest targets now require iOS 26.0. CocoaPods and all CI compiler overrides match the same minimum. The native packaging job verifies the built app's `MinimumOSVersion` is exactly `26.0` in addition to ARM64, unsigned status and SHA-256. This is strictly a platform-floor change: STT, new Markdown rendering and full iPhone 13 voice acceptance remain separate pending work. Keep original App Icon release blockade and all data safety gates intact.

## iOS 26 native STT candidate
The iOS 26 branch adds Apple-only `SpeechAnalyzer` voice input, a new Settings page, isolated editor accessory and microphone-use reason. CI uses `.github/scripts/verify_apple_stt_contract.py` for static privacy/route checks and UIKit regression tests for transcription buffer and insertion rules. The unsigned candidate name uses `Impress-V3.3-<HEAD>-7icon-INCOMPLETE-unsigned.ipa` and is not directly installable. A green simulator test cannot prove microphone, available Apple models or cloud-independent recognition on iPhone 13; do not describe them as device-PASS.
