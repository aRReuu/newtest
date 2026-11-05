# AltStore Classic · Minimal-Signing iPhoneOS Candidate

This branch is a packaging-only candidate for the private-account 7-day AltStore Classic sideload workflow. It changes **no Impress application, database, FSRS, Obsidian or UI source files** relative to public main commit a1e03e8926b0abb6606486f34569b0fcc87017e4.

## Packaging changes

- Builds with a new application-only shared Xcode scheme `aReuImpress-iPhone-AltStore` to exclude the XCTest target and XCTest/Testing runtime bundles.
- Overrides `CODE_SIGN_ENTITLEMENTS=` and `CODE_SIGNING_ALLOWED=NO` for this candidate only. Does **not** claim iCloud containers or App Groups.
- Uses `ENABLE_DEBUG_DYLIB=NO` to avoid an Xcode Debug app-host stub / separate debug dylib.
- Uses existing Debug configuration including `IMPRESS_V3_CANDIDATE`, preserving the initial V3.1 entry.
- Regenerates license-neutral placeholder images, and leaves the private project and published original IPA intact.
- Enforces absence of XCTest/Testing frameworks, XCTest plug-ins and developer signing profiles.
- Stores only unsigned IPA + hash + build logs, publishes a separate experimental GitHub Release after verification.

## Expected iCloud/Obsidian behavior

The user-initiated `UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)` requires the user's Files provider grant, but **does not require** the app's own provisioned iCloud container entitlement. Authorized file-folder access, Security-Scoped Bookmark restoration and file-provider behavior have not yet been verified on a physical iPhone. This variant does not enable private iCloud container or App Groups functionality, and must not be described as a complete two-way iCloud synchronization client. `productionWriteEnabled=false` is preserved.

## Limitations

The IPA remains UNSIGNED; AltStore/AltServer must register an App ID, obtain a matching provisioning profile for your Apple ID/device and sign the IPA. This variant removes known app-side incompatibilities but **does not guarantee** that the specific AltStore error will disappear. If `Could not find matching provisioning profile` remains, check AltStore / AltServer versions, signing Apple ID and error code (often 2015), and try another known-working sideloadable IPA to distinguish AltStore account issues.

No private credentials or provisioning profiles should be uploaded to GitHub.
