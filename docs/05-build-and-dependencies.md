# · Construction and dependency

Project configuration, relying list and packing (v2.5.0, submitted together)`bb7a726`）。

## Environmental requirements

| Item| Value|
| --- | --- |
| Project target| `aReuImpress-iPhone`(+ test target`aReuImpress-iPhoneTests`） |
| Deployment Version| `IPHONEOS_DEPLOYMENT_TARGET = 14.0`(pbxproj actual value;Podfile declaration`platform :ios, '13.0'`） |
| CocoaPods | 1.11.3 (Podfile.lock lock)|
| Dependency Method| `use_frameworks!`(Dynamic framework),`inhibit_all_warnings!` |

## Reliance List

`Podfile`External pod:

```ruby
platform :ios, '13.0'
target 'aReuImpress-iPhone' do
  use_frameworks!
  pod 'WCDB.swift'
  pod 'MarkdownKit'
  pod 'IQKeyboardManagerSwift', '~> 6.4.2'
  pod 'MarkdownView'
  # pod 'SwiftDate', '~> 6.3.1'   # 已注释
end
```

`Podfile.lock`Lock version:

| Pod | Version| Purpose|
| --- | --- | --- |
| WCDB.swift | 1.1.0 | Local database ORM (dependent on SQLiteRepairKit ~ > 1.3.0, WCDBoptimized SQLCipher ~ > 1.3.0)|
| SQLiteRepairKit | 1.3.0 | WCDB Dependence|
| WCDBOptimizedSQLCipher | 1.3.0 | WCDB Dependence|
| MarkdownKit | 1.7.1 | Chat/Note.Markdown Parsing Renderer|
| MarkdownView | 1.9.1 | Whole Note Rendering (`ImGridViewController`Wait|
| IQKeyboardManagerSwift | 6.4.2 | Keyboard Processing|

> **History residue (do not confuse)**:`Pods/Local Podspecs/`Here we go.`ImPressableButton.podspec.json`、`ImSwipQuickCard.podspec.json`、`ImWebDav.podspec.json`、`ImWifiTransfer.podspec.json`(all 0.01 / iOS 10.0, source is empty or pointed locally). **Podfile and Podfile.lock are not quoted** and have never been built through CocoaPods; ImPressableButton (3D press button), ImSwipQuickCard (Sliding Card Component) names correspond to earlier local components.ImWebDav/ImWifiTransferCorresponds to deletedWebDAV/WiFiTransfer (seedocs/03）。

## Project marking

| Item| Value|
| --- | --- |
| Bundle ID | `com.areu2.iphone` |
| Display Name| `miemie`（Info.plist `CFBundleDisplayName`） |
| Version| pbxproj `MARKETING_VERSION = 1.0`；Info.plist `CFBundleShortVersionString = $(MARKETING_VERSION).2.1`(Current entry into force: "1.0.2.1");`CFBundleVersion = $(CURRENT_PROJECT_VERSION)`（= 1） |
| URL scheme | `impress` |
| Query scheme| `deepseek`, `myapp`, `eudic`, `eudic-ting`（`LSApplicationQueriesSchemes`） |

## Info.plist Key Configuration

- Permission Usage Case:`NSDocumentsFolderUsageDescription`("Need access to Obsidian's notebook for content analysis")`NSRemindersUsageDescription`。
- `UIBackgroundModes = [fetch, processing]`（Backstage./Process）。
- `UIFileSharingEnabled` / `LSSupportsOpeningDocumentsInPlace = true`(iTunes file sharing, opening documents in situ).
- Custom document type:`public.database`、`net.daringfireball.markdown`、`folder`。
- `NSAppTransportSecurity`Allows any load (development time configuration).
- There's another project.`Pods-ImpressTodoExtension*`Old xcconfig reference residue, but no corresponding target** (dead reference) in the project.

## entitlements（iCloud / App Group）

`aReuImpress-iPhone.entitlements`with`aReuImpress-iPhoneDebug.entitlements`Convergence:

- iCloud ubiquity container：`iCloud.$(CFBundleIdentifier)`
- iCloud ubiquity kvstore
- App Group：`group.areu.impress`

The real machine is run in Xcode to open iCloud and AppGroup capabilities for the developer Team.

## Build Steps

```bash
pod install                      # 安装/更新依赖（CocoaPods ≥ 1.11.3）
open aReuImpress-iPhone.xcworkspace
```

Select scheme in Xcode`aReuImpress-iPhone` Run/Archive。

### Pack ScriptimpressBuild.sh

Root Directory`impressBuild.sh`(hard encoded macOS path for individual authors):

1. `xcodebuild clean + archive`（scheme/configFixed`aReuImpress-iPhone` / Release，workspace `./aReuImpress-iPhone.xcworkspace`，`CODE_SIGNING_ALLOWED=NO`) The product is exported to`/Users/pro/Desktop/ImpressIPA/output/...xcarchive`。
2. Reads the version number with PlastBuddy and press the watch →minor → major input.
3. Will`.app`Pack as`yin<版本>.ipa`Move to`~/Library/Mobile Documents/com~apple~CloudDocs/Downloads`(iClaud Drive download directory).

## Data Directory (Run-time Sandbox)

| Contents| Contents|
| --- | --- |
| `Documents/ImpressVault` | Obsidian vault mirror (import target, seedocs/03） |
| `Documents/ImpressDB/impressdata.db` | WCDB Database|
| `Documents/ImMusic` | Background Music (Alfabo) Directory|

Path constant concentrated`aReuImpress-iPhone/Utils/Constansts/ImConstants.swift`。
