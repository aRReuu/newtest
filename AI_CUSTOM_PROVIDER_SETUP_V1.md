# Impress V1 . Do API Servicer and Custom Connection Receiving and Inspection Standard

> Status: Configuration and route code achieved; live machine and real pay account call not yet validated. This document does not claim to have finished production release or Obsidian writing back.
>
> Branch:`feature/impress-vault-device-write-qa`(Unique development branch). ** calibration machine, FSRS-6 Core Scheduler, external Obsidian writing back door not to change. **
>
> ** Data security**: API Key should not be kept in a public warehouse, CI, report or screenshot; private notes are sent only after the user has taken the initiative to select the chapter and confirm it. Third party API handles submissions under its service terms. In response to long-term public distribution, it is recommended that controlled backend agents manage the production of API keys; the individual BYOK iOS Keychain model does not guarantee the key against attacks on controlled equipment.

**2026-10-19 Harmonized product boundaries:** Model services are still available in this documentKeychain/Agreements/Costs/JSONPermission to do so; original Chat is a common sub-tool for cards, notes and selected content, not a new Tab. Lasting Session and Writing Proposal Press [T]KNOWLEDGE_LIFECYCLE_V1.md](KNOWLEDGE_LIFECYCLE_V1.mdG1-G4 step-by-step delivery; current code and simulation tests are not real billing or equipment validation for any model.

## 1. Configure Design

`设置 > AI 服务 > +`Optional presets or ** custom API** are not limited to only four service providers. Each connection is independent:
- User-defined connection name, Provider type, HTTPS Base URL;
- Keychain API Key Reference to support multiple service providers; actual key** unserialized** configuration JSON;
- Method of accreditation:`bearer`、`rawAuthorization`、`apiKeyHeader`、`googleAPIKeyHeader`、`customHeader`、`none`；
- Custom header (safe Header only, configuration e. g.`X-Custom-Token`); cannot cover protected heads such as Host, Cookie, Content-Type;
- Relative path:`models`、`chat/completions`、`responses`、`messages`, can be configured on a line-by-line basis, not to accept any complete URL,`..`Path, Query or URL encoded into;
- A connection can add multiple models, and automatic counting is only convenient,** and manual input of model ID** is not supported;
- ** Each model can independently select the API protocol** (adaptable hybrid gateway) and JSON processing mode (Native/Only hint bounds); JSON measurements that change the protocol or target connection must be reheard of without privacy;
- Problem generation and original Chat business model routes have been achieved;** The re-engineering of knowledge is still not operational** and its entry point should clearly indicate the need for additional security Gate. Configure routes does not equal the real API request already passed.

## 2. Preset Example (for ease only, manual changes are possible)

| Connection preset| Base URL (without operation suffix)| Default protocol| Default Authentication|
| --- | --- | --- | --- |
| OpenAI GPT | `https://api.openai.com/v1` | `responses` | Bearer |
| DeepSeek | `https://api.deepseek.com` | `chatCompletions` | Bearer |
| Claude / Anthropic | `https://api.anthropic.com/v1` | `anthropicMessages` | x-api-key |
| Google Gemini | `https://generativelanguage.googleapis.com/v1beta` | `geminiGenerateContent` | x-goog-api-key |
| GLM (domestic)| `https://open.bigmodel.cn/api/paas/v4` | `chatCompletions` | Bearer |
| GM / Z.AI (International)| `https://api.z.ai/api/paas/v4` | `chatCompletions` | Bearer |
| Command Code | `https://api.commandcode.ai/provider/v1` | `chatCompletions` | Bearer |
| OpenCode Console | `https://opencode.ai/inference` | `chatCompletions`+ Exclusive relative path| Bearer |
| OpenCode Go | `https://opencode.ai/zen/go/v1` | `chatCompletions` | Bearer |
| ** Custom API**| User 's own HTTPS root path| Optional Supported Agreements| Optional Support Method|

Note: OpenCodeis the client/Platform ecology; Zen, Go is an independent API product. Compand Code also provides CLI with Provider API. The intellectual clarity of the Web product does not need to be shared with the GM cloud API. ** Presets not as a substitute for login of web accounts; please use the corresponding service API access vouchers and valid amounts. **

Provider API for Compand Code`chat/completions` / `responses`And anthropic format`messages`: Different models may have to choose different protocols. This realization allows the appointment of a stand-alone protocol for each model in** a Command Code connection**; the protocol format does not determine the authentication method, and the Command Code Messages also uses Bearer.

OpenCode Zen/ Go also has a list of mixed protocols; this model supports an endpoint selection. Keep manual ID input when no model directory is available. Any third party OpenAI-compatible gateway does not need to add Swift entries or to reissue App only custom connection names, Base URLs, authentication, relative path and model ID.

Official document references:
- Command Code Provider API: `https://commandcode.ai/docs/provider`
- OpenCode Providers: `https://docs.opencode.ai/docs/providers/`
- OpenCode Go: `https://docs.opencode.ai/docs/go/`
- GLM Z.AI: `https://docs.z.ai/`


## 2.1 GLM Real Configuration and Common Problems (2026-10-19)

1. "Setting the AI service →" selection ** spectra GLM (domestic)** or ** GLM / Z.AI (international)**; use with you KeyOwn Account/Regionally consistent presetsI don't know. Base URL ** Fill in root path only** (domestic)`.../api/paas/v4`, do not repeat attachments`/chat/completions`。
2. Save key to Keychain in the connected "API Key" and authenticate **Beyer**; then pull the directory from the Model List, or the top right corner`+`Manually add a model ID for the actual open account console. Model list queries that are not supported by suppliers cannot be used to conclude that reasoning is not available; they can be filled in manually.
3. Click Model  ** Test Dialogue Connection**. A request for testing without a private content is sent only after the possible call costs have been identified. Checks the connection, model, protocol, rights and HTTP status when it fails, instead of showing the OpenCode FreeQA error in general.
4. Click "Model Zoom" as a dialogue model, or select this GLM model in the "Operational Default Model Zip dialogue". This is** an explicit choice** and will not automatically change back to QA by adding another free QA connection.
5. If you want to specify a question for Obsidian 's notes, then click "test JSON output" and then use it as the default model for "specify notes to make a question." The uploading of private notes is still prohibited without certification.
6. Reconfirms the deletion path: "API Connections" list with a left slide to delete individual items, or "Delet all API connections" at the end of the list; still keep "Delet Connections" on the details page. Deletes the connection model and business path, and only the Keychain references that are not shared with other connections.Or just delete/Replace current connection API Key。

**Constraint**: Free-QA White List only binds the OpenCode free model (test) connection of the visible selection; common users such as GLM, Z.AI, customised users connect to their own Provider, protocol, authentication and clearly selected models. CI only runs a simulated GLM request, which does not replace the actual authentication of the user account.

## 3. Tasks and security rules

`笔记详情 → 生成问题 → 默认5道综合题 → 选择章节 → 确认向当前 Provider 发送 → API → JSON/来源验证 → 候选池 → 编辑/删除/选择 → 明确确认 → WCDB V3 原子批量入库及 FSRS 初始化`。

- Model returns untrustworthy text: JSON decodes strictly and double-checks locally; enumeration model success, JSON probe PASS** does not equal the answers **.
- Rejects the candidacy for the selected SHA changes; users may not add cards or write to Obsidian if they cancel.
- Do not automatically cross theProvider switch; replacement route must be clearly configured by the user.
- API Connection/Modelling capability tests do not contain real personal notes.; only the specified session can be sent when the problem is triggered manually.
- Producing Vault writing back doorbar:`ImVaultGuardedWrite.productionWriteEnabled = false`There will be no change at this stage.
- Account numbers, quotas, protocol errors can only be sent back to readable errors and it is prohibited to record the response (possibly private) in the log.

## 4. Test and exit threshold

1. Core Test: ManyProvider/Multiple Models/MoreKey, mixed protocol, authentication method, custom headname security, Endpoint relative path interception, compatible old version configuration JSON.
2. iOS Native: old navigation and new "AI"Services/Problem Generation/Quick RecordThe contract is accepted and accepted at the same time; the old FSRS, backup, Obsidian and calibration examples are not deleted.
3. Truth or authorization to test account numbers: Verify at least one official Provider and a custom third-party gateway, independently confirm Keychain reading, JSON compatibility, actual selected document uploading borders and V3 atoms into the library.
4. The merger is discussed only after the entire green of the CI of the exact HEAD;** the simulator passes without implying iPhone 13 end to end**.
5. The problem pool already has a protected local snapshot restoration mechanism; the official card is only authoritatively based on V3 WCDB. The original notes must be rechecked at the time of recovery SHA-256.
6. CI with no real GLM API Key can only test the certificate with Keychain + local URLProtocolCheck Request Header/URL/Parsing** The user account GLM reasoning cannot be claimed to have been successful.

## 5. Non-target

This round will only restore AI services and pre-existing originalsChat/Question path;no automatic MarkdownRestructuring knowledge/Write back, does not modify calibraters, FSRS algorithms or private Vault, does not synchronize private warehouses, does not merge main.
