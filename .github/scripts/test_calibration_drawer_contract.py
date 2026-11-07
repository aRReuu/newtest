#!/usr/bin/env python3
"""Flashcard layout regression: no embedded calibration; keep the canonical Settings route."""
from pathlib import Path
ROOT = Path(__file__).resolve().parents[2]
def source(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")
tabs = source("aReuImpress-iPhone/Base/ImTabBarViewController.swift")
scene = source("aReuImpress-iPhone/Base/SceneDelegate.swift")
review = source("aReuImpress-iPhone/VC/MainVCs/ImCardVC/ImpressV3ReviewViewController.swift")
cal = source("aReuImpress-iPhone/VC/MainVCs/ImCalibrationVC/ImpressCalibrationViewController.swift")
reminder = source("aReuImpress-iPhone/VC/MainVCs/ImCalibrationVC/ImpressCalibrationReminderCoordinator.swift")
assert 'self.viewControllers = [cardNav, notesNav, settingsNav]' in tabs
assert 'Item(title: "每日校准"' in review
assert "case .calibration:" in review
assert "ImpressCalibrationViewController(), animated: true" in review
assert 'Item(title: "AI 服务"' not in review
assert "case .aiService:" in review  # business route still exists
assert "view.addSubview(calibrationDrawer)" not in review
assert "calibrationDrawer.topAnchor.constraint(" not in review
assert "statusLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor" in review
assert "calibrationDrawer.isExpanded" not in review[:review.index("final class ImpressV3SettingsHubViewController")]
assert "cardStack.topAnchor.constraint(equalTo: statusLabel.bottomAnchor" in review
assert "nav.pushViewController(calibration, animated: false)" in scene
assert "nav.pushViewController(ImpressCalibrationViewController()" in reminder
assert "ImpressCalibrationChartProjector.project(" in cal
assert "CalibrationCartesianTrendRenderer.draw(" in cal
print("PASS: flashcard full-height layout, retained calibration entry/widget/notification and hidden AI cell")
