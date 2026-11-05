#!/usr/bin/env python3
"""Retired native-cloud-chat and credential exposure contract (no secret values printed)."""
from __future__ import annotations

from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "aReuImpress-iPhone"
TRACKED = set(filter(None, subprocess.check_output(
    ["git", "ls-files", "-z"], cwd=ROOT).decode().split("\0")))

# These modules were retired in favor of local review + explicit browser handoff.
BANNED_RELATIVE_PATHS = (
    "Model/ImLLM/", "Model/ImPollingChat/", "Model/ImPreChat/",
    "NetWork/ImNetWorkRequest", "NetWork/ImResponse/ImGeminiResponse.swift",
    "NetWork/ImResponse/ImpressResponse.swift",
    "Utils/Public/ImAutoGenerator/", "Utils/Public/ImFileManager/ImBackupManager.swift",
    "Utils/Public/ImSliderVC/",
    "VC/MainVCs/ImPollingChatVC/", "VC/SubVCs/ImPollingChatListVC/",
    "VC/SubVCs/ImPreChatVC/", "VC/SubVCs/ImLLMConfigVC/",
    "VC/SubVCs/ImSettingVC/ImSystemPromptViewController.swift",
    "View/ImLLM/", "View/ImPollingChat/",
    "ViewModel/ImPollingChat/", "ViewModel/ImPreChatList/",
    "ViewModel/ImSettings/ImSettingsViewModel.swift",
)
RETIRED_IDENTIFIERS = (
    "ImLLMModel", "ImPollingChat", "ImPreChat", "ImNetWorkRequest",
    "ImAutoGenerator", "ImBackupManager", "ImLLMConfigViewController",
    "ImSystemPromptViewController", "ImSettingsViewModel",
    "LLMModelDidChange", "didSelectChatSession",
)
SECRET_MARKERS = (
    re.compile(rb"-----BEGIN (?:RSA |EC |OPENSSH |ENCRYPTED )?PRIVATE KEY-----"),
    re.compile(rb"\b(?:gh[pousr]_[A-Za-z0-9]{28,}|github_pat_[A-Za-z0-9_]{20,})\b"),
    re.compile(rb"\bsk-(?:proj-|live-)?[A-Za-z0-9_-]{28,}\b"),
    re.compile(rb"\bAIza[A-Za-z0-9_-]{35}\b"),
)

def assert_clean() -> None:
    for name in TRACKED:
        if name.startswith("aReuImpress-iPhone/"):
            short = name[len("aReuImpress-iPhone/"):]
            assert not any(short.startswith(b) for b in BANNED_RELATIVE_PATHS), (
                "RETIRED_NATIVE_CHAT_SOURCE_STILL_TRACKED", name)
    swift = sorted(APP.rglob("*.swift"))
    # Prefix check catches suffixed model/controller references left in unrelated
    # features after removal (e.g. ImPollingChatListViewController in old UI).
    retired_prefixes = (
        "ImPollingChat", "ImPreChat", "ImLLM", "ImNetWorkRequest",
        "ImAutoGenerator", "ImBackupManager", "ImSliderViewController",
        "ImSettingsViewModel",
    )
    for path in swift:
        data = path.read_text()
        for prefix in retired_prefixes:
            assert not re.search(r"\b" + re.escape(prefix) + r"[A-Za-z0-9_]*\b", data), (
                "RETIRED_TYPE_REFERENCE", str(path.relative_to(ROOT)), prefix)
    project = (ROOT / "aReuImpress-iPhone.xcodeproj/project.pbxproj").read_text()
    for identifier in RETIRED_IDENTIFIERS:
        for p in swift:
            assert not re.search(r"\b" + re.escape(identifier) + r"\b", p.read_text()), (
                "RETIRED_NATIVE_CHAT_REFERENCE", str(p.relative_to(ROOT)), identifier)
        assert identifier not in project, ("RETIRED_PROJECT_REFERENCE", identifier)
    forbidden_suffix = (".p8", ".p12", ".pem", ".mobileprovision", ".key", ".env")
    for name in TRACKED:
        if name.startswith(("Docs/", "docs/", "Pods/")):
            continue  # The private source authority may retain internal documentation/deps.
        path = ROOT / name
        if not path.is_file():
            continue
        if name.lower().endswith(forbidden_suffix):
            raise AssertionError(("UNAUTHORIZED_SECRET_FILE", name))
        if not name.lower().endswith((".swift", ".py", ".sh", ".yml", ".yaml",
                                       ".json", ".plist", ".md", ".txt", ".pbxproj")):
            continue
        data = path.read_bytes()
        if len(data) > 3_000_000:
            continue
        for pattern in SECRET_MARKERS:
            assert not pattern.search(data), ("CREDENTIAL_LITERAL_IN_SOURCE", name)
    db = (APP / "DataBase/ImDBHandler.swift").read_text()
    assert "purgeRetiredChatTables()" in db
    for table in ("impress_llm_model", "impress_polling_chat", "impress_chat"):
        assert table in db, ("MISSING_LEGACY_PURGE", table)
    assert "imDatabase.drop(table: table)" in db
    assert "printSqlText()" not in db, "SQL_TRACE_MUST_NOT_LOG_PRIVATE_DATA"
    tab = (APP / "Base/ImTabBarViewController.swift").read_text()
    # 2026-10-19 authority: exactly three primary tabs. The explicit +
    # creates a card, not a knowledge log; no duplicated global Notes action.
    assert "ImpressV3ReviewViewController()" in tab
    assert "ImpressNoteListTableViewController()" in tab
    assert "ImpressV3SettingsHubViewController()" in tab
    assert "self.viewControllers = [cardNav, notesNav, settingsNav]" in tab
    assert "calibrationNav" not in tab
    review = (APP / "VC/MainVCs/ImCardVC/ImpressV3ReviewViewController.swift").read_text()
    assert 'target: self, action: #selector(createCard))' in review
    assert 'navigationItem.leftBarButtonItem?.accessibilityLabel = V3L("新增卡片")' in review
    assert "navigationItem.rightBarButtonItems = [cardCollection]" in review
    assert "navigationItem.rightBarButtonItems = [notes, cardCollection]" not in review
    assert 'cardCollection.accessibilityLabel = V3L("卡片集")' in review
    assert 'cardCollection.accessibilityIdentifier = "impress.review.card-collection"' in review
    assert 'Item(title: "每日校准"' in review
    assert 'ImpressCalibrationViewController()' in review
    assert 'calibrationWeek.accessibilityIdentifier = "impress.review.calibration-week"' in review
    assert 'calibrationWeek.addTarget(self, action: #selector(openCalibrationDetail),' in review
    # Chat must never replace complete local history with a bounded HTTP window.
    # Its editor/draft persists only through the existing V3 source-ID database.
    native_chat = (APP / "Utils/Public/ImAI/ImpressAINativeChatViewController.swift").read_text()
    assert "private var history: [WCDBV3ChatMessage] = []" in native_chat
    assert "private let sourceCardID: UUID?" in native_chat
    assert "private func persistLocal() async -> Bool" in native_chat
    assert "sourceCardID.map" in native_chat
    assert "history = Array(history.suffix(" not in native_chat
    assert "try await repository.saveChatSession(" in native_chat
    assert "ImpressAIHTTPClient.shared.converse(" in native_chat
    assert "selectedModelID" in native_chat

    # Safeguards below still reject retired chat code, secrets and production writes.
    config = (APP / "Utils/Constansts/ImColorConstants.swift").read_text()
    assert 'enum ImpressV3Language: String, CaseIterable' in config
    # A duplicate Swift dictionary literal crashes at launch, even when its
    # values are identical. Fail this inexpensive contract before XCTest.
    dictionary = config.split("private static let translations:", 1)[1]
    dictionary = dictionary.split("\n    ]", 1)[0]
    seen_keys: set[str] = set()
    for line in dictionary.splitlines():
        match = re.match(r'^\s*"([^"]+)"\s*:', line)
        if not match:
            continue
        key = match.group(1)
        assert key not in seen_keys, ("DUPLICATE_V3_LOCALIZATION_KEY", key)
        seen_keys.add(key)
    assert len(seen_keys) > 100, "MISSING_V3_LOCALIZATION_DICTIONARY"
    for language in ('"zh-Hans"', '"zh-Hant"', '"en"'):
        assert language in config, ("MISSING_INTERFACE_LANGUAGE", language)
    assert 'case system, light, dark' in config
    vault = (APP / "Utils/Public/ImFileManager/ImObsidianManager.swift").read_text()
    assert re.search(r"productionWriteEnabled\s*=\s*false\b", vault)
    app = (APP / "Base/AppDelegate.swift").read_text()
    assert "SecItemDelete(query as CFDictionary)" in app
    assert '"com.impress.github.token"' in app
    web = (APP / "VC/SubVCs/ImWebVC/ImWebViewController.swift").read_text()
    assert "https://chat.deepseek.com/" in web
    assert "UIPasteboard.general.string" in web
    assert "forReviewHandoff" in web
    assert "evaluateJavaScript" not in web, "WEB_HANDOFF_MUST_NOT_AUTOSEND"
    print("RETIRED_NATIVE_CHAT_AND_USER_KEYS_GUARD_PASS")
    print("OBSIDIAN_READONLY_AND_EXPLICIT_WEB_HANDOFF_PASS")
    print("NO_TRACKED_LLM_OR_GITHUB_BACKUP_SECRET_SIGNATURE_PASS")

if __name__ == "__main__":
    assert_clean()
