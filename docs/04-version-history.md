# 04 Version history

Version evolution record. Early Entries from History README Note, v2.4.0`develop-*`** Submission number is representative only** and is not exhaustive.

## Version Timeline

| Version/Phase | Time| Scope| Major changes|
| --- | --- | --- | --- |
| v2.0 (Historical description)| — | Update of root README records| Chat Markdown Renderer + UITextView Extension to Compatibility)|
| v2.1 (History Note)| — | Update of root README records| ** Underlined comment:Long Underline By Selected Word/Click to Remove, real-time rendering, database durability, anti-overlapping; integrated with in-message search|
| v2.3.0 | Before mergemain README historical description| main | Quote card mode + home page mindmap notebook|
| v2.4.0 (development-2.4.0 line)| 2025-09-25 ~ 2025-11-10 | Approximately 65 submissions| Anki Untie Migration:`ab882bb`Add AnkiWeb migrates to Web`e8f7492`Remove ANKI cards (a better solution was found for Oulu); underline + search bar`01b8378`;markdown rendering fixes`6128017`etc;ob-Vault path fixes`4e2f1b9`/`7e97367`/`37c436f`；**`7e97367`Modify database save path and removeWebDAV/WiFiTransfer source** (seedocs/03Historical description; WebView bullet window repair|
| v2.5.0 (development-2.5.0 line, 9 submissions)| 2026-01-15 ~ 2026-02-24 | 9 submissions| See the next section "V2.5.0 Submission of Details"|
| **main (current main line)**| 2026-09-08 | merge | `bb7a726`Merge development-2.5.0 into main (no conflict, first father ca0b659)|

## v2.5.0 Submission of detail (development-2.5.0 unique 9)

It's always morning to night.`git log origin/develop-2.4.0..origin/develop-2.5.0`）：

| Submit| Title| Meaning|
| --- | --- | --- |
| `28ee710` | The streamlining does not require logic, only a card review -- preview of random notes -- tags the local content of updated notes, a global query on Deepseek, which forms the overall closed loop| 2.5.0 Design main line: Condense as "card review → random notes →Tags/Update→DeepSeek Global Query 'Learning Closed Circle|
| `82de867` | New UI+ Logic Optimization| New UI and Logical ReconstructionChat/Card Related Page） |
| `6532c2d` | fix bugs | Bug Rehabilitation|
| `73fa229` | Add New Enhancement Tag Page| Add a new tag question (Tag) page: flashcard home page tag button + bagge → list of questions to start a dialogue with one click|
| `7b8258b` | fix bugs | Bug Rehabilitation|
| `ea296be` | fix bugs | Bug Rehabilitation|
| `2afa3da` | Fix Budge Show + Manual Sync Ob Folder| Fix homepage badge; add the Obsidian folder from iCloud Drive manually (docs/03） |
| `eb0cad0` | Six web-blowing windows| DeepSeek Web Window Repair|
| `5cc1013` | fix Syncob folder| Obsidian Synchronisation (v2.5.0 tip)|

> Notes:`develop-2.5.0`Relative`main`(pre-merger ca0b659,2025-09-25) The total number of submissions was 72, of which v2.4.0 was approximately 65 included in the line "v2.4.0" above and v2.5.0 was unique 9 as above.

## Merge records

- **2026-09-08**：`bb7a726 Merge develop-2.5.0 into main`
  - Merger:`--no-ff`(to preserve branch history); submitted by the father:`ca0b659`(former main)+`5cc1013`（develop-2.5.0 tip）。
  - Since main is a direct ancestor of the development-2.5.0, integration is not in conflict.
  - Result: Main obtains v2.4.0 + v2.5.0 all changes at one time (total of 370 document changes, net deletion of approximately 12,000 lines - mainly from removalWebDAV/WiFiTransfer source code and Floating Panel,Old prototype/Tool Files）。
  - `develop-2.5.0`Branch retained, not deleted.

## Remove Changes/Replace Key Item(v2.4.0 + v2.5.0 as a whole)

- Delete`Pods/FloatingPanel/`(Replaced with MarkdownKit + MarkdownView rendering).
- Delete`Utils/Public/ImWebDav/`、`Utils/Public/ImWifiTransfer/`（WebDAV/WiFiTransfer, see.docs/03）。
- Remove root directory`OB2Impress.py`、`ImpressTodoExtension.entitlements`、`.continue/`Configure, Empty`README`File, Phase UI prototype directory (HTML+ icon).
- App display name, bookle, version number, etc.docs/05）。
