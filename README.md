# Impress iOS — Public Source Mirror

This repository contains a **sanitized, English-documented source-code snapshot** of the Impress iOS application.

## Publication scope

The mirror is source-oriented, not an archive of the private development repository. In particular, it does **not** include:

- Images, photographs, screenshots, app icons, illustrations, image fixtures, or other graphic assets (including assets bundled with dependencies).
- Private Git commit history, internal synchronization ledgers, personal Xcode workspace state, credentials, signing identities, or provisioning files.
- Original branded artwork or proprietary visual resources.

Chinese-language explanatory documentation is translated into English before inclusion. Application localization strings and test fixtures may retain Chinese as functional data rather than documentation.

## Building

The original Xcode project and source code are retained where safe to publish. Because image/icon assets and some private or generated files are deliberately absent, this source snapshot is **not guaranteed to build or ship without additional project-specific assets and dependency setup**. Supply your own legally authorized icons and artwork if you intend to build a distributable application.

**No production release, signed IPA, or physical-device verification is implied by this mirror.**

## Provenance and safety

The public repository uses an independent Git history. Before publication, files are screened for common secret formats and prohibited media paths. Dependency and source licenses remain with their respective files.

## Translation fidelity

English documentation was produced using an **offline machine-translation model** and checked for remaining Chinese explanatory prose. These automated checks do not guarantee exact preservation of nuanced technical or acceptance language. Source-code identifiers, user-facing localization strings, and functional test data were not translated. Refer to the source revision recorded in [PUBLIC_SOURCE_MANIFEST.json](PUBLIC_SOURCE_MANIFEST.json) when traceability matters.

## Licensing

Third-party notices and acknowledgements are retained where available. Publishing this mirror does not, by itself, grant a new license to the original first-party source code.
