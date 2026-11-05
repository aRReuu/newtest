# SMOKE_TEST_MATRIX — Impress V3.2 acceptance evidence

## Current evidence boundary
The last verified V3.2 baseline is `58987edfe550f9ccd4f7b7168b12c1f83c98b920`, [CI #39093765853](https://github.com/aRReuu/Impress-iphone-public-build/actions/runs/39093765853): 90/90 native UIKit XCTest, 17/17 portable Swift tests, Simulator and unsigned ARM64 candidate. The new theme, three-language UI, editable understanding and Notes redesign **require fresh CI on their own final HEAD**; no prior run is proof of these new edits. Simulator does not certify iPhone 13.

## Native Simulator / automation
| Area | Required actual gate |
| --- | --- |
| Branch / privacy | Public feature HEAD, no private/main changes, credential and source privacy checks |
| Core | All `ImpressReviewCore` tests including five-indicator scoring, calendar, mood skip, extras, trends and reminder plan |
| Navigation | Practically three tabs ordered / calibrated, with localized labels and distillable video notes and right-header actions; Notes Pushes the exciting read-onlyVault list without changing the review session|
| Appearance & locale | System/Light/Dark persistent window overrides, System fallback; three independent language modes (zh-Hans, zh-Hant, en), immediate native navigation refresh, no mutation of personal content or persisted reviews |
| Understanding edit | Detail exposes explicit editor; successful CAS updates answer and appends previous revision to learning journal; invalid/blank/stale edits fail without changing data; ID, question, original AI feedback and FSRS remain stable |
| Flashcards | Show Answer, four swipes, exactly-one FSRS event, card CRUD/pagination/content CAS and V3 schema upgrade |
| Cards/media | Text QA, image BLOB, single/multiple choice, search, import, stale-save rejection |
| Obsidian | Native inset-grouped Notes table, central font/color/spacing tokens, restrained Markdown reader, external read-only Vault index, bounded 128-note enumeration progress, verified-scope provisional cache, folder/path search, 120-item list paging, local attachments and iCloud-not-downloaded error; no automatic original writes |
| Calibration check-ins | All five evaluated, unknown remains unknown, mood not scored, mutable current goals, immutable historic snapshots, manual +/- boundaries |
| Calibration UI/chart | Week 7 days, month 30 days, year monthly daily mean, axes, missing-day gaps, readable Dynamic Type |
| Notifications | Calibration IDs separate from FSRS, permissions, duplicate reconciliation, pending-day cancellation and click route |
| Backup V1 | Legacy 3-data-member ZIP remains readable; does not delete calibration ledger |
| Backup V2 | SQLite, JSON learning history, prompts, image BLOB, FSRS events and checkins all survive CRC/SHA/semantic validation |
| Restore | User confirmation, recovery preview, durable pre-image of SQLite/WAL, learning history, prompts and calibration; process-death recovery before WCDB opens; fault-injected rollback |
| Backup mutation race | Opaque mutation generations prevent concurrent writes clearing Dirty and reject mixed-era ZIP publication |
| Device build | iPhoneOS ARM64 unsigned app, no embedded XCTest, IPA ZIP integrity and SHA-256 Artifact |

## Device-only gates (not passed by Simulator)
- iPhone 13 unsigned-IPA signing and actual launch; installation and retention after free seven-day re-signing.
- iCloud Drive folder picker, stale bookmark after app restart, Files-provider local write versus server upload, offline retry.
- Recovery from ZIP on a fresh device and app termination between staged restore and next cold start; no partial SQLite/JSON/prompt/calibration restore.
- Local alert delivery at 20:00/22:00 across sleep/reboot, permission denial, Focus mode, timezone change, badges and FSRS coexistence.
- UIKit appearance, Dynamic Type, Safe Area and Y-axis readability on iPhone 13; manually switch System/Light/Dark and zh-Hans/zh-Hant/en while navigating Flashcards, Calibration, Settings, Vault and understanding editor. Check text truncation, keyboard layout, saved editor revisions and theme persistence across relaunch. Original iPhone icon visual and missing marketing 1024 icon remain a release gate.
- External Obsidian Vault remains read-only by design, including iCloud placeholders, images and safe path resolution.

## Mandatory evidence format
Record final Git SHA, Actions run URL, each job conclusion, **total native XCTest passed/failed**, portable Swift tests and unsigned IPA SHA-256. A compiled source file is not a test result, and a CI artifact is not proof of phone-level Files/iCloud entitlement.

## iOS 26 platform migration gate
| Gate | Verifiable requirement | Current evidence type |
| --- | --- | --- |
| Deployment settings | Six Xcode app/test deployment values, Podfile and generated Pods floor, three native build overrides all 26.0 | New static audit in CI |
| Binary | Signed state unchanged; unsigned ARM64 QA .app reports `MinimumOSVersion=26.0`, IPA ZIP/SHA valid | New native packaging assertion; pending CI |
| iPhone 13 | iOS 26 installation and SpeechTranscriber hardware/locale/download checks; old-system support intentionally dropped | **Device PENDING** |
| Global STT/Markdown | Apple SpeechAnalyzer and unified renderer/voice UI not yet implemented | **Development PENDING** |

## V3.3 speech gate
| Gate | Required evidence |
| --- | --- |
| Speech code | Real iOS 26 compilation against Apple Speech; no SFSpeechRecognizer, no third-party STT and no private audio log/disk path |
| Voice settings | Three independent recognition locales, engine availability, manual Apple model installation and microphone permissions displayed |
| Text insertion | UTF-16 selection replacement, cancel leaves source unchanged, stale edit rejected, final-only commit, single editor-change callback |
| Editor routing | Question, answer, options, batch import, understanding capture/edit, prompt inputs and Markdown **private drafts** provide one mic accessory; source Obsidian reader remains read-only |
| Real device | iPhone 13 microphone and interrupted session; per-locale model availability, first-download permission, latency, accuracy, background cancellation and VoiceOver **PENDING** |
| Markdown overhaul | One AST-backed parser and unified rendering pipeline **PENDING**; no old or external Vault document discarded |
