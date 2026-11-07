#!/usr/bin/env python3
"""Scope-limited three-tab/drawer regression gates; not an iOS UI test."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

def source(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")

tabs = source("aReuImpress-iPhone/Base/ImTabBarViewController.swift")
scene = source("aReuImpress-iPhone/Base/SceneDelegate.swift")
reminders = source(
    "aReuImpress-iPhone/VC/MainVCs/ImCalibrationVC/"
    "ImpressCalibrationReminderCoordinator.swift"
)
cal = source(
    "aReuImpress-iPhone/VC/MainVCs/ImCalibrationVC/"
    "ImpressCalibrationViewController.swift"
)
review = source(
    "aReuImpress-iPhone/VC/MainVCs/ImCardVC/"
    "ImpressV3ReviewViewController.swift"
)
translations = source("aReuImpress-iPhone/Utils/Constansts/ImColorConstants.swift")

# Three root pages only, preserving all named existing destinations.
assert "navigation.count == 3" in tabs
assert 'let keys = ["闪卡", "笔记", "设置"]' in tabs
assert "self.viewControllers = [cardNav, notesNav, settingsNav]" in tabs
assert "calibrationNav" not in tabs
assert "ImpressV3SettingsHubViewController()" in tabs
assert 'Item(title: "每日校准"' in review
assert "case .calibration:" in review
assert "ImpressCalibrationViewController(), animated: true" in review

# A calendar/deep-link tap must still open exactly the canonical controller.
for label, source_code in (("Widget", scene), ("notification", reminders)):
    assert "ImpressV3SettingsHubViewController" in source_code, label
    assert "nav.pushViewController(ImpressCalibrationViewController()" in source_code or (
        "nav.pushViewController(calibration, animated: false)" in source_code
    ), label
    assert ".first is ImpressCalibrationViewController" not in source_code, label
assert "CalibrationWidgetPeriod(rawValue: key)" in scene
assert "calibration.selectWidgetPeriod(period)" in scene
assert "tabs.selectedIndex = index" in scene

# Both screens share one projection and one artist, with no new score math.
assert review.count("ImpressCalibrationChartProjector.project(") == 1
assert cal.count("ImpressCalibrationChartProjector.project(") == 1
assert "CalibrationScoreCore.dailyTrend(" in cal
assert "CalibrationScoreCore.monthlyTrend(" in cal
assert "final class ImpressCalibrationTrendChart: UIView" in cal
assert "CalibrationCartesianTrendRenderer.draw(" in cal
assert "private let chart = ImpressCalibrationTrendChart()" in review

# System large-title height, safe area and independent vertical gestures.
for token in (
    "navigationItem.largeTitleDisplayMode = .always",
    "navigation.navigationBar.convert(",
    "statusBarManager?.statusBarFrame.minY",
    "calibrationDrawer.topAnchor.constraint(",
    "equalTo: view.safeAreaLayoutGuide.topAnchor",
    "statusLabel.topAnchor.constraint(equalTo: calibrationDrawer.bottomAnchor",
    "calibrationDrawerHeight?.constant = expanded",
    "static let collapsedHeight: CGFloat = 28",
    "guard gesture.state == .ended else { return }",
    "pan.location(in: self).y <= periodControl.frame.maxY",
    "calibrationDrawer.onOpen =",
    "page.selectWidgetPeriod(selected)",
    "onOpen?(selectedPeriod)",
    "guard calibrationDrawer.isExpanded else { return }",
    "ImpressCalibrationLocalStore.shared.trendRecords()",
):
    assert token in review, f"Drawer contract lost: {token}"
assert "cardStack.topAnchor.constraint(equalTo: statusLabel.bottomAnchor" in review
assert "calibrationDrawer.addGestureRecognizer" not in review
assert "pan.cancelsTouchesInView = false" in review
assert "calibrationDrawer.isExpanded != expanded" in review
assert "self.calibrationDrawerRequestID == request" in review
assert "self.calibrationDrawer.selectedPeriod == selected" in review

# Day/month/year are 7/30/12 real calendar points; empty records are nil.
assert "let length = period == .week ? 6 : 29" in cal
assert "monthlyTrend(records, year: year)" in cal
assert "days.map { $0.netScore.map(Double.init) }" in cal
assert "last 7" not in cal.lower()  # No new alternative formula/approximation.

# The new controls must remain discoverable in UI tests and across languages.
for name in (
    "impress.review.calibration-drawer",
    "impress.review.calibration-drawer-handle",
    "impress.review.calibration-drawer-chart",
    "impress.review.calibration-drawer-period",
):
    assert name in review, name
for key in ("近7日", "近30日", "本年", "展开校准预览", "收起校准预览",
            "校准数据读取失败"):
    assert f'"{key}":' in translations

print("Three-tab navigation, chart sharing, drawer interaction and deep links: static PASS")
