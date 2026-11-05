# 03 Synchronization and transmission (data landing and backup)

Note v2.5.0 Data Storage Layout, iCloudImport/Sync & Backup MechanismI don't know. **Note: WebDAV synchronized with WiFi transport code, which existed on the early development line, was removed from the V2.4.0 phase (see the end of the text, "History Note" ), and these two capabilities are not included in the current version.

## Local Storage Layouts (Sharebox Documents)

| Path| Contents| Constant Position|
| --- | --- | --- |
| `Documents/ImpressVault` | Local Obsidian vault mirrors (catalogue level pic.twitter.com/VoJ)`ImpressVault`Name`ObsidianFolderName`） | `Utils/Constansts/ImConstants.swift` |
| `Documents/ImpressDB/impressdata.db` | WCDB database (5 tables, seedocs/02） | Same Left|
| `Documents/ImMusic` | Audio directory for background music (Alfabo)| Same Left|

## iCloud Drive Folder Import (CoreSync Entry)

**Use**: Import App Sandboxes from iClaud Drive selects the entire Obsidian Notebin folder (e. g. vasult of Obsidian)Move across equipment notes/Synchronization。

- **Accomplishment category**:`Utils/Public/ImFileManager/ImiCloudImportManager.swift` —— `ImiCloudImportManager`Individual cases, follow`UIDocumentPickerDelegate`。
- **Entry**`VC/SubVCs/ImNoteListVC/ImpressNoteListTableViewController.swift`(Right upper corner folder button)
- ** Process**: confirmation`performManualImport`Popup Folder Selector (iOS 14+)`UTType.folder`) security-scoped access`Documents/ImpressVault`Post-overwrite copy (import or overwhelm)`refreshNotes()`Trigger Scan ()`ImpressNotesViewModel.fetchNotes`) Refresh list.
- ** Boundaries Process**: check iClaud Drive usability, folders do not exist, permissions fail,Network timeout/File Error, confirm a hint before import; error handling contains a TrollStore-related hint.
- This capability is v2.5.0`2afa3da "修复badge显示 + 手动同步OB文件夹"`with`5cc1013 "fix 同步ob文件夹"`The function of landing.

## Obsidian Document Reading, Writing and Directory Management

- `Utils/Public/ImFileManager/ImObsidianManager.swift`：Positioning/Self-buildVault Directory`withVaultURL`）、`readMarkdownFile`、`writeMarkdownFile`(Booking by relative path, automatic father directory, UTF-8 atom writing); Skip while scanning`.obsidian`、`attachments`Equal Directory`ImConstants`Medium`ignoreDirectory`Configure).
- ** Saveback**:`ImMarkdownViewController`"More → Save (Sync Obsidian)" by`directoryPath + title.md`Write back vault.

## Sync Direction and Index Policy

- File system from** source**, WCDB`impress_notes`Yes** Cache Index**:`scanAndUpdateMarkdownFiles`Compared to (heading set, relative directory, modificationDate), onlyinsert/update; localvault removes files without reverse deletion of database records, and manual changes within DB do not return files (unless you go " save " actions).

## Backup

| Mechanisms| Category| Behaviour| Status|
| --- | --- | --- | --- |
| iCloud Drive backup| `ImiCloudBackupManager`（`Utils/Public/ImFileManager/`） | Put`Documents/ImpressDB`Copy to the directory selected by iCloud Drive user (`ImpressDB_Backup_时间戳`About 72h reminder| Other Organiser`ImDBHandler.checkBackupReminder` → `checkAndNotifyIfNeeded` |
| GitHub private warehouse backup| `ImBackupManager`(Same table of contents)| PUT after database directory zip to private warehouse`aRReuu/ImpressDBBackup`(token save Keychain), approximately 24h interval| Class achieved,** current no caller**|

## Competencies and competencies

- entitlements（`aReuImpress-iPhone.entitlements`with`aReuImpress-iPhoneDebug.entitlements`It's the same: iClaud ubiquitty container`iCloud.$(CFBundleIdentifier)`、ubiquity kvstore、App Group `group.areu.impress`。
- Info.plist about:`NSDocumentsFolderUsageDescription`("Need access to Obsidian's notebook for content analysis")`UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace`（File Sharing/Open in situ.）、`UIBackgroundModes = [fetch, processing]`（Backstage./Process）。

## Historical description (significant error)

- Warehouse history **WebDAV Sync** (`Utils/Public/ImWebDav/`HamWebDAV.swiftAbout 559 rows, SWXMLHash about 1112 rows for the analysis of WebDAV 207 more states XML and **WiFi transfer**`Utils/Public/ImWifiTransfer/`，GCDWebServer/GCDWebDAVServer/GCDWebUploader.bundleWait, about 22 million lines) 2 sets of local source code and introduced local popspec()`Pods/Local Podspecs/ImWebDav.podspec.json`、`ImWifiTransfer.podspec.json`, all 0.01, git is empty, Podfile never quoted).
- Both sets of capabilities are being submitted`7e97367 "修改数据库保存路径"`(Phase 2025-09-27, v. 2.4.0) deleted from the entire catalogue**. Therefore, current Main (with 2.5.0)** does not containWebDAV/WiFiTransfer**;`Pods/Local Podspecs/`. The following document is historical and is not built.
