# · Functional overview (v2.5.0)

This document describes the achievement of App at v2.5.0 by** user functional domain**, indicating the functional entry and corresponding core code. See the code level structure.docs/02-module-documentation.md] (02-module document.md), for synchronization mechanism [docs/03-synchronization-and-transfer.md(03-Sync and transmission.md).

## Interface skeleton

The main interface is`ImTabBarViewController`（`aReuImpress-iPhone/Base/ImTabBarViewController.swift`Tab**:

| Tab | Title| Root controller|
| --- | --- | --- |
| 0 | Flash| `ImCardViewController`（icon: square.stack.3d.up） |
| 1 | Notes| `ImpressNoteListTableViewController`（icon: doc.text） |

The AI dialogue, tag questions, card lists, etc. pages are navigating from both pages and do not occupy Tab alone.

## Function Field

### 1. flashcard review (main interface Tab 0)
- ** Page**:`VC/MainVCs/ImCardVC/ImCardViewController.swift`(at the heart of the home page).
- ** Achieved**: SwipeCardStack Card Stack`Utils/Public/ImSwipQuickCard/`）Sliding Learning/Review；Navigator Bar Generation/Edit Card; bottom buttons: edit cards, Web Chat (DeepSeek page), tag problems (tag.fill, with unprocessed red board).
- ** Scheduled**:`ViewModel/ImCard/ImCardViewModel.swift`FSRS Scheduler(s)Difficulty/Stability/Status/Date dueIncludes FSRS-v4 default parameters, learning queue, slider update,Delete/Insert/Batch Insert。
- **card type**:`Model/ImCard/ImCardModel.swift`- Standards (question and answer), multiple selections, pictures;`chatLink`/`chatSessionId`binding cards to an AI session; countingCardLevel/CardState/CardType。
- ** Subpage**:`VC/MainVCs/ImCardVC/ImCardListVC/ImCardListViewController.swift`Card List (Select Mode)`isSelectionMode + chatSessionId`to bind a session to a card).
- ** Link**: flashcard page previews random notes (entry)`ImMarkdownViewController`,see function 3; review alarm notifications clicked by`ImpressRoute.pushToCardViewController()`Straight up to this page.
- ** Background music**:`Utils/Public/ImMusicPlay/ImMusicPlayer.swift`,to the page`startPlaying()`Leave.`stopPlaying()`Play`Documents/ImMusic`Catalogue audio (Alfabo).

### 2. AI Interactive dialogue
- ** Page**:`VC/MainVCs/ImPollingChatVC/ImPollingChatViewController.swift`— Message List + Enter the container ()`View/ImPollingChat/`** Extract underlined.
- ** Data**`ViewModel/ImPollingChat/ImPollingChatViewModel.swift` —— Session Load/New Session/`sendMessage` Call Big Model/Try again/Save Draft and Backstage/Default ModelI don't know. Model Configuration From`Model/ImLLM/ImLLMModel.swift`(provider: GPT / Gemini / OpenRouter / Custom, apiKey, baseURL, temperature, IsDefault).
- **Network**:`NetWork/ImNetWorkRequest.swift`(URLSsession, OpenAI compatible)`/chat/completions`60s timeout);`ImNetWorkRequest+Mock.swift`Provides simulation switches (in settings).
- ** Note "Turn Up" **: Not a Long Round - a single time per statement; typing effect by`TypingIndicatorView`Simulation.
- **History session**:`VC/SubVCs/ImPollingChatListVC/ImPollingChatListViewController.swift`+`ViewModel/ImPollingChat/ImPollingChatList/`，Supporting deletion/Search, press a long spin card or bind a session to the card.
- **DeepSeek Web page**`VC/SubVCs/ImWebVC/ImWebViewController.swift`(WKWebView case, note "Show DeepSeek chat page and provide a review card"), by flashcard page and floating button (`Utils/Public/ImFloatingButtonManager/`Get in.
- ** Large model configuration**:`VC/SubVCs/ImLLMConfigVC/ImLLMConfigViewController.swift`(List) with`ImLLMDetailViewController.swift`(Details), navigated by dialogue page.

### 3. Note management (Main interface Tab 1)
- ** Page**:`VC/SubVCs/ImNoteListVC/ImpressNoteListTableViewController.swift`— Search, iCloud Import Entry (the top right corner folder icon), random review, note check entry.
- ** Data**`ViewModel/ImNotes/ImpressNotesViewModel.swift` —— Pull/Filter/Delete/Random ReviewCore`scanAndUpdateMarkdownFiles`Recursive Scan All`.md`Other Organiser
- ** Markdown reads **:`VC/SubVCs/ImNoteListVC/ImMarkdownVC/ImMarkdownViewController.swift`— MarkdownKitRenderer + extract, which supports text extracts and floating "Generating Cards" buttons, with the "More" menu "Saving (Sync Obsidian)" writing back vasult; the entry is also available on the flashcard page "Previewing Random Notes" in addition to the list of notes.
- **Book viewerDebug/Support）**：`VC/SubVCs/ImGridVC/ImGridViewController.swift`— Press NoteID to render the entire note with MarkdownView.
- ** Extracted text view**:`Utils/Public/ImExtractTextView/`(includes an interaction between search and underlined).

### 4. Tag Problem (Tag page)
- ** Page**:`VC/SubVCs/ImPreChatVC/ImPreChatListViewController.swift`(title "Stamp Problem") - i. e. 2.5.0 Submit`73fa229 "add 新增强Tag页面"`Landing page.
- **Entry**: flashcard page tag. fill button (`ImCardViewController`, with unprocessed tags red Budge).
- ** Data**`Model/ImPreChat/ImPreChatModel.swift`+`ViewModel/ImPreChatList/ImPreChatListViewModel.swift`(CRUD), the ViewModel simultaneously drives the header agular sign.
- **Contribution**: Context menu "Initiation of Dialogue" switch to AI Dialogue.

### 5. Settings and Configuration
- ** Setup page**:`VC/SubVCs/ImSettingVC/ImSettingsViewController.swift` + `ViewModel/ImSettings/ImSettingsViewModel.swift`(UserDefaults: notification alarm interval reminderMinutes, wallpaper switches, debugmock switches, system hint entry).
- **System alert**`VC/SubVCs/ImSettingVC/ImSystemPromptViewController.swift`— Feynman Learning System tip-editing (Real-time statistics/Save/Reset）。
- Common submission form:`VC/SubVCs/ImSubmit/ImSubmitViewController.swift` + `ImSubmitProtocol.swift`（New Card/Edit#FelmanSaving, SessionTalkingCardShare

### 6. Organisation
- `Utils/Public/ImNotification/ImNotificationHandler.swift`Read alert dispatch;notification click`Route/ImpressRoute.swift` `pushToCardViewController()`Open flashcard page.
- On Start`notificationShare.requestAuthorization()`Application for notice.

## Data stream (one chart)

```
iCloud Drive 笔记文件夹
   │ 手动导入（ImiCloudImportManager）
   ▼
沙盒 Documents/ImpressVault（Obsidian 镜像）
   │ fetchNotes：scanAndUpdateMarkdownFiles 扫描 .md
   ▼
WCDB 数据库 impress_notes（文件系统为源，DB 为索引）
   ▼
笔记列表 / 随机复习 / Markdown 阅读
   │ 摘录 / 标记问题 / 发起对话
   ▼
AI 问答（ImPollingChat，配置 LLM / DeepSeek Web）
   │ 会话绑定 / 转卡片 / 生成卡片（ImSubmit）
   ▼
卡片库 impress_card（FSRS 调度）── 复习提醒通知 ──► 闪卡页
```

## Page connection status (in honesty)

The following codes already exist but** the current version is unconnected** (no example of access) and attention is drawn to the following when planning access:

| Component| Status|
| --- | --- |
| `ImSettingsViewController`(Setting pages)| Achieved, currently no exemplifier|
| `Utils/Public/ImSliderVC/ImSliderViewController.swift`(side slide menu)| Achieved (inline session history list), currently no exemplifier|
| `Utils/Public/ImFileManager/ImBackupManager.swift`(GitHub private warehouse backup)| Achieved, currently no caller|
| `DataBase/ImpressDBHandler+NetworkShare.swift` | Empty space|
