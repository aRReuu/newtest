# 02 Module documents (code level)

Code-level structure description (v2.5.0, combined submission)`bb7a726`I'm not sure. This document absorbs and replaces the original`aReuImpress-iPhone/README.md`, amends the outdated description by actual code (the "3 Tab / ImNoteSystem Module / Note Version Control" of the original document does not exist in the code).

## Layers and Directorys

Source All in`aReuImpress-iPhone/`：

| Contents| Duties|
| --- | --- |
| `Base/` | Application entrances and subcategories: AppDelegate / Scene Delegate / ImTab BarViewController / ImNavigationViewController / ImBaseViewControll / ImBaseViewModel / ImBaseProtocol|
| `VC/` | Page controller`MainVCs/`Main interface,`SubVCs/`Subpage)|
| `ViewModel/` | Page logic and data drive, both of which match`*Protocol.swift` |
| `View/` | Custom View (Input Container, Message Cell, TypingIndicatorView, etc.)|
| `Model/` | WCDB TableCodable Data Model|
| `DataBase/` | Database Initialization and DAO (ImDBhandler)|
| `NetWork/` | URLsession Network Layer and Response Model|
| `Route/` | Route support (currently only → flashcard page)|
| `Utils/` | Constant / Extension / Generic components (document management, notification, music, card components, etc.)|

## Start Chain

```
AppDelegate(@main)
  └─ SceneDelegate
       ├─ initDB(): dbShare.createAllDB() + checkBackupReminder(72h iCloud 备份提醒)
       ├─ notificationShare.requestAuthorization()  （通知权限）
       ├─ IQKeyboardManager 等配置
       └─ initRootVC(): rootViewController = ImTabBarViewController
            ├─ Tab0 闪卡 = ImNavigationViewController(ImCardViewController)
            └─ Tab1 笔记 = ImNavigationViewController(ImpressNoteListTableViewController)
```

## Core class quick check

### Base
| Category| Annotations|
| --- | --- |
| `ImTabBarViewController` | Two Tab: flashcards/ Notes (see 01-Function Overview)|
| `ImNavigationViewController` | Unified navigation container (present)|
| `ImBaseViewController` / `ImBaseViewModel` / `ImBaseProtocol` | Base class and protocol (floating button, public constant, style)|

### VC（ViewController）
| Category| Contents| Annotations|
| --- | --- | --- |
| `ImCardViewController` | `VC/MainVCs/ImCardVC/` | Flashcard home page: SwideCardStackLearning/Review、Edit/Web Chat/Tag Problem ButtonBudge, random notes preview|
| `ImCardListViewController` | `VC/MainVCs/ImCardVC/ImCardListVC/` | card list;select mode to bind session to card|
| `ImPollingChatViewController` | `VC/MainVCs/ImPollingChatVC/` | AI Dialogue Page:Message List/Enter container/Pre-set issues/Search/Underlined extract |
| `ImpressNoteListTableViewController` | `VC/SubVCs/ImNoteListVC/` | Tab Home Page: Search, iCloud Import Entry, Random Review|
| `ImMarkdownViewController` | `VC/SubVCs/ImNoteListVC/ImMarkdownVC/` | Markdown Read + Extract + Generate Card + Write Back Obsidian|
| `ImGridViewController` | `VC/SubVCs/ImGridVC/` | This post is part of our special coverage Global Development 2011.Support/Debug） |
| `ImPollingChatListViewController` | `VC/SubVCs/ImPollingChatListVC/` | AI Question & Answer List of History SessionsLong spin card/Tie Session） |
| `ImPreChatListViewController` | `VC/SubVCs/ImPreChatVC/` | List of tag questions (Tag page)|
| `ImSettingsViewController` | `VC/SubVCs/ImSettingVC/` | Set pages (unconnected, see 01-Function Overview)|
| `ImSystemPromptViewController` | `VC/SubVCs/ImSettingVC/` | Feynman Learning System Tip Editor|
| `ImLLMConfigViewController` / `ImLLMDetailViewController` | `VC/SubVCs/ImLLMConfigVC/` | Large Model Configuration List/Details |
| `ImSubmitViewController` | `VC/SubVCs/ImSubmit/` | Comprehensive submission form (card editor, Feynman save, session transfer card)|
| `ImWebViewController` | `VC/SubVCs/ImWebVC/` | WKWebView Single Case (DeepSeek Chat Page + Generate Study Card)|
| `ImImagePreviewViewController` | `VC/SubVCs/ImImagePreview/` | Photo Preview (Scalp)|

### ViewModel
| Category| Driver Page| Annotations|
| --- | --- | --- |
| `ImCardViewModel` | flashcard homepage| FRSS Movement Control, Learning Queue, Slide Update,CRUD/Batch Insert |
| `ImCardListViewModel` | Card List| CardCRUD/Search/Filter |
| `ImpressNotesViewModel` | Notes Tab| Take notes./Filter/Delete/Random Review/vaultScan Sync|
| `ImPollingChatViewModel` | Dialogue Page| Sessions, send messages, try again, extracts, preset questions, draft background save|
| `ImPollingChatListViewModel` | Session history| History SessionCRUD/Search/`checkChatSessionExists` |
| `ImPreChatListViewModel` | Tag Problem + First Page Angle| Tag Problem CRUD|
| `ImSettingsViewModel` | Settings/System Hint | UserDefaults（Synchronising folder/Wallpaper/mock/Feynman Template） |

### Model and Database
- Framework:WCDB.swift(Detailed)docs/05I'm not sure. Model Average`TableCodable`。
- Library file: Sandbox`Documents/ImpressDB/impressdata.db`by`DataBase/ImDBHandler.swift`(single cases)`share`I'm in charge of watch and walk.CRUD/Random queries。
- List of tables`DataBase/ImDBTableType.swift`,5 sheets:

| Table| Model| Elements|
| --- | --- | --- |
| `impress_notes` | `ImNoteModel` | Notes:Title/markdown Text/Directory Level Path/Modified |
| `impress_card` | `ImCardModel` | Card:Questions and answers/Multiple Selection/Images、chatLink/chatSessionId, FSRS field (difficulty/stability/state/dueDate/reviewCount…） |
| `impress_polling_chat` | `ImPollingChatModel` | Dialogue sessions: Titles, message arrays (including underlined slots)`UnderlineRange`) Excerpt text|
| `impress_llm_model` | `ImLLMModel` | LLM configuration:provider/apiKey/baseURL/temperature/isDefault |
| `impress_chat` | `ImPreChatModel` | Marking problems (issue of a note map)|

## Key processes

### 1. Obsidian vault scan sync
`ImpressNotesViewModel.fetchNotes`Read DB first.`scanAndUpdateMarkdownFiles`Recursive list`Documents/ImpressVault`All`.md`, compared to database (file name set = title, relative directory = directoryPath, modificationDate): changeText/Modified), add the insert. ** In the direction of file system source, DB index**, without reverse deletion. For further details [T]docs/03-synchronization-and-transfer.md(03-Sync and transmission.md).

### 2. Session.
Dialog Page / Session History Page`ImSubmitViewController`Generate a card, or bind a session to an existing card (`chatSessionId`"Dialogue is a study material."

### 3. Underlined extract
The interview message and the extracts of the notes support Twitter reading underlined:`ImPollingChatModel`Can not open message`UnderlineRange`Other`extractedTexts`Excerpts a collection; add by long selected text area, click on the underlined area to remove; and last in the database. Interactive realization in`Utils/Public/ImExtractTextView/`。

### 4. Reread the alarm.
`ImNotificationHandler`（`Utils/Public/ImNotification/`) Schedule Notification → Click back →`ImpressRoute.pushToCardViewController()`（`Route/ImpressRoute.swift`Model`ImNavigationViewController`Package flashcard page.

## Description and error (relative to old)aReuImpress-iPhone/README.md）
- Actual **Tab is 2**Flashcards/Notes), the AI dialogue page is navigated instead of independent Tab.
- Name does not exist`ImNoteSystem` Category/Contents;written capacity distributed over`Model/ImNote`、`ViewModel/ImNotes`、`VC/.../ImNoteListVC`、`Utils/Public/ImFileManager`。
- Note version control not achieved; cross-equipment capability = iCloud Drive folder import (seedocs/03）。
