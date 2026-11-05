# Impress V1 OpenCode Free Model + Obsidian Real Acceptance

> Application:`feature/impress-vault-device-write-qa`, which does not apply to official publication. ** The OpenCode Free White List of this document only binds the OpenCode Free Model (test) connection that was added by the user overtly.** It does not block other independently configured GLM / Z.AI/ Custom connection. CI does not use a charge model to make a real call; a user must confirm that an API cost may arise before initiating a probe on a non-QA connection on a device. The official Obsidian production is still closed.
>
> Current OpenCode Console official model directory:`https://opencode.ai/inference/v1/models`；
> CHAT COMPLEMENTS Endpoint:`https://opencode.ai/inference/openai/v1/chat/completions`。
> This QA allows only four types of OpenCode official price tables that are clearly listed as Free and are publicly available:`mimo-v2.6-flash-free`、`longcat-2.5-preview-free`、`nemotron-3.5-lightning-free`、`space-bunny-free`I don't know. Do not accept self-entry unknown`-free`ID came around the white list.

**2026-10-19 Entry update:** Notes have become Level 1 Tab and test material entry is "Notes Connect to Obsidian Vault". Complete daily calibration is in the settings. The current Free Model List is only a historical QA snapshot; official pricing and account costs must be re-checked before every real call. New Chatt test notes are still not checked through real-to-end devices,** production doors are closed**. For the uniform rules see [. ]KNOWLEDGE_LIFECYCLE_V1.md](KNOWLEDGE_LIFECYCLE_V1.md)。

## A. Connectivity and API Key (no personal notes)

1. Open`设置 → AI 服务 → + → OpenCode 免费模型（测试）`I don't know. This entry creates or updates the existing free QA connection and does not clear the authorized Keychain key; the default model is`mimo-v2.6-flash-free`, select the remaining three Free models.
2. Prefer to keep **noAuthentity** (no API Key required), from model list point`测试免费对话`Only send one without user data`ping`Request.
3. Official documents allow for anonymous, free chats, but in [GitHub Hosted Runner test #39201745545]https://github.com/aRReuu/Impress-iphone-public-build/actions/runs/39201745545Four new Free models exist in directories (GET 200) and are actually anonymous POST all HTTP 403. This doesn't mean that there's an iPhone request with Key that will fail, or that there's a Key that will succeed.
4. If the phone also indicates 403, click the free connection.`API Key`, save your regenerated ** key into iOS Keychain. The original anonymous free connection with the explicitly recorded automatic switch to`bearer`I don't know. Click Again`测试免费对话`; model IDs, interfaces and quantitative limitations in the request remain free of charge.
5. Recommended to click from the model operation menu`免费 API 全链路验收`I don't know. User confirmed if saved`oc_sk_`The service account, Key, will call the official with the same Keychain.`GET https://opencode.ai/console/api/v2/config`(Check HTTP only, do not read or record account configuration) and then perform the first Chat, second round with history Chat, JSON parsing, simulation chapter synthesis + validation of candidate pool evidence. Anonymous mode skips service account recognition. The four reasonings are all true HTTP success to mark the model`jsonVerified`and enable the default path for Chat / problem making. The button** does not upload personal notes or write official cards**. If either link fails, the service provider, model ID, protocol, HTTP state and cause of failure must be examined; another model, which is still Free, is sufficient and does not refund the fee model.
   - Yes.`设置 → AI 服务 → 默认对话提示词`You can choose to use the custom template in the existing "tips" library, with the default still being "first principle + occam razor". The hint template can jump from the entry to the original hint editing page; only visible clicks send to the service provider.
6. **`-free`The suffix is not guaranteed for permanent free. ** Free pricing for OpenCode is in current status and some are time-limited activities. Before testing, it is necessary to reconfirm the model's free pricing and current account billing settings in Console. If a full zero billing risk is required, the anonymous request may be given priority; the account number Key is to be entered, cancelled and replaced by the user on its own in the device Keychain and not stored in the warehouse or CI.

## B. Obsidian read-only, issue-only and candidate pool

1. New in iPhone 'file 'App`Impress-Write-Test-Vault`(** Must be an independent and discarded copy of the test**).
2. Download [Impress QA knowledge sample] from this repositoryTests/Fixtures/Obsidian/Impress_QA_Knowledge.md), copy the folder. Do not authorize private Vault, which is being used, or change the name of the daily Vault to a test directory.
3. Open`笔记 → 连接 Obsidian Vault`, select the test folder in the System File Selector to confirm that the sample book is readable and the original is not modified.
4. Enter the details of the sample, select the `generated problem', tick the target section and set the number of questions to 5; confirm clearly ** only upload the test information** to the current free model. The result will only enter the candidate pool and will not automatically enter the library.
5. Candidate pool check for drying, reference answers and evidence, and edit or delete invalid entries. The candidate pool saves the existing Vault private data directory with an atomic snapshot; after closing the application, reopening the " Generating the Consolidated Problem" portal of the same note can choose to restore. If the original note SHA-256 has changed, the direct resumption of import is prohibited and can only be regenerated. Active confirmation before writing V3 WCDB and starting FSRS; cancellation or API failure cannot change database.
6. Even if the Chat test is successful, it will be necessary to confirm separately the JSON probe and the issue of Schema. The referencing ID does not automatically prove the semantic correctness of the resulting answer.

## C. Obsidian controlled writeback and conflict protection

1. Yes.`Impress-Write-Test-Vault`in which to open the test Markdown, do "edit an independent draft", and change a few words.
2. Save a stand-alone draft to see complete discrepancies; confirm and execute`测试副本写回`。
3. Reopen the original in the "document" App to confirm that the byte content has actually changed; compare the original content with an App Private Recovery copy. When using iCloud Drive, verify cloud synchronisation at the second location,** this script has been successful ** cloud synchronisation **.
4. After a draft, modify the same source document from Obsidian or from a file App and return to Impress retry; the version must conflict and the draft must be kept and external changes cannot be overridden.
5. In the normal Vault root directory, the writing back button must always be unavailable.
6. `Release`Configure all such devices QA source files to continue to close.

## D. Credible outcome boundaries

- GitHub Swift/XCTest/ARM64The green light can only prove the corresponding automation,** not the actual iPhone Keychain, OpenCode account, iClaud File Provider has PASS**. New Simulation Network Test Validation Normal Text, Multiple Cycle Responses and HTTP401/403/404/429But they cannot be a substitute for real-time calls.
- Free model connection tests should show actual Provider, Model ID, Chat Rules and successful HTTP status;Failed also shows the model/Agreements andWrong categories such as 401, 403 or 429. The payment model is not automatically selected.
- For External Services HTTP401/403, format is not supported, permission limits are limited, and to report an actual error, a fee model cannot be automatically tried; do not print Key or request in the open CI.
- Original Chat is a temporary session and does not automatically write to Obsidian or understand history. ** Knowledge re-constructing and official Vault writing back remains independent of subsequent Gate. **
- Open warehouse maintenance`main`+ a development branch; this task does not operate a private warehouse.
- OpenCode Key, which you made explicit in your chat, should** be withdrawn and rotated**; please enter the new Key only iPhone Keychain.
