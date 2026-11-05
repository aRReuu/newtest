import SwiftUI
import WidgetKit
import UIKit
import ImpressReviewCore

private enum WidgetWords {
    private static var traditional: Bool {
        let id = Locale.current.identifier.lowercased()
        return id.contains("hant") || id.contains("_tw") || id.contains("_hk") ||
            id.contains("-tw") || id.contains("-hk")
    }
    private static var chinese: Bool {
        Locale.current.language.languageCode?.identifier == "zh"
    }
    static func tr(_ simplified: String, _ traditional: String, _ english: String) -> String {
        chinese ? (self.traditional ? traditional : simplified) : english
    }
    static func title(_ period: CalibrationWidgetPeriod) -> String {
        switch period {
        case .week: return tr("近7日", "近7日", "Last 7 days")
        case .month: return tr("近30日", "近30日", "Last 30 days")
        case .year: return tr("本年度", "本年度", "This year")
        }
    }
    static var completed: String { tr("已评估", "已評估", "Assessed") }
    static var partial: String { tr("部分", "部分", "Partial") }
    static var unknown: String { tr("未记录", "未記錄", "Unrecorded") }
    static var today: String { tr("今日", "今日", "Today") }
    static var days: String { tr("天", "天", "days") }
    static func unavailable(_ reason: WidgetProjectionProblem?) -> String {
        switch reason {
        case .noGroup:
            return tr("Widget 无 App Group 权限；请检查 App 和扩展的签名",
                      "Widget 無 App Group 權限；請檢查 App 和擴充的簽署",
                      "Widget App Group access denied. Check both signatures.")
        case .noSnapshot, nil:
            return tr("共享快照未同步；打开 Impress 的校准器",
                      "共用快照未同步；開啟 Impress 的校準器",
                      "No shared snapshot. Open Impress > Calibration.")
        case .invalidSnapshot:
            return tr("快照版本或时区失效；请打开校准器重新同步",
                      "快照版本或時區失效；請開啟校準器重新同步",
                      "Snapshot invalid or timezone changed. Reopen Calibration.")
        }
    }
    static var widgetName: String { tr("校准器", "校準器", "Calibration") }
    static var lastUpdate: String { tr("快照", "快照", "Snapshot") }
}

private enum WidgetProjectionProblem {
    case noGroup, noSnapshot, invalidSnapshot
}

private struct CalibrationEntry: TimelineEntry {
    let date: Date
    let period: CalibrationWidgetPeriod
    let overview: CalibrationWidgetOverview?
    let plot: CalibrationWidgetCartesianPlot?
    let problem: WidgetProjectionProblem?
}

private struct CalibrationProvider: TimelineProvider {
    let period: CalibrationWidgetPeriod

    func placeholder(in context: Context) -> CalibrationEntry {
        CalibrationEntry(date: Date(), period: period, overview: nil, plot: nil,
                         problem: nil)
    }

    func getSnapshot(in context: Context,
                     completion: @escaping (CalibrationEntry) -> Void) {
        completion(makeEntry(at: Date()))
    }

    func getTimeline(in context: Context,
                     completion: @escaping (Timeline<CalibrationEntry>) -> Void) {
        let now = Date()
        let calendar = Calendar.current
        let nextMidnight = calendar.nextDate(
            after: now, matching: DateComponents(hour: 0, minute: 0, second: 0),
            matchingPolicy: .nextTime) ?? now.addingTimeInterval(86_400)
        completion(Timeline(entries: [makeEntry(at: now, recordReadback: true)], policy: .after(nextMidnight)))
    }

    private func makeEntry(at now: Date, recordReadback: Bool = false) -> CalibrationEntry {
        guard let root = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: "group.areu.impress") else {
            return CalibrationEntry(date: now, period: period, overview: nil, plot: nil,
                                    problem: .noGroup)
        }
        guard let data = try? Data(contentsOf: root.appendingPathComponent(
                "calibration-widget-v1.json")) else {
            return CalibrationEntry(date: now, period: period, overview: nil, plot: nil,
                                    problem: .noSnapshot)
        }
        guard let snapshot = try? JSONDecoder().decode(
                CalibrationWidgetSnapshot.self, from: data),
              let overview = CalibrationWidgetProjection.overview(
                from: snapshot, at: now, calendar: Calendar.current) else {
            return CalibrationEntry(date: now, period: period, overview: nil, plot: nil,
                                    problem: .invalidSnapshot)
        }
        let plot = CalibrationWidgetProjection.cartesianPlot(
            from: snapshot, period: period, at: now, calendar: Calendar.current)
        // Gallery snapshots never claim that a live timeline has loaded.
        // Best-effort readback contains no private scores or note contents.
        if recordReadback, plot != nil {
            let receipt = CalibrationWidgetReadReceipt(
                period: period, snapshotGeneratedAt: snapshot.generatedAt, observedAt: now)
            do {
                try JSONEncoder().encode(receipt).write(
                    to: root.appendingPathComponent(receipt.fileName), options: .atomic)
            } catch {
                NSLog("Calibration Widget readback unavailable: %@", error.localizedDescription)
            }
        }
        return CalibrationEntry(date: now, period: period, overview: overview, plot: plot,
                                problem: nil)
    }
}

/// SwiftUI only embeds a snapshot produced by the SAME UIKit/CoreGraphics
/// renderer invoked in ImpressCalibrationTrendChart.draw().
private struct SharedCartesianChart: View {
    @Environment(\.colorScheme) private var scheme
    let plot: CalibrationWidgetCartesianPlot
    let period: CalibrationWidgetPeriod

    private var localizedLabels: [String] {
        period == .year ? plot.tickLabels.map {
            $0.replacingOccurrences(of: "月",
                with: WidgetWords.tr("月", "月", ""))
        } : plot.tickLabels
    }

    var body: some View {
        GeometryReader { geometry in
            if geometry.size.width >= 48 && geometry.size.height >= 48 {
                Image(uiImage: CalibrationCartesianTrendRenderer.image(
                    size: geometry.size, values: plot.values,
                    smooth: plot.smooth, tickLabels: localizedLabels,
                    palette: .semantic,
                    font: UIFont.preferredFont(forTextStyle: .caption2),
                    traitCollection: UITraitCollection(
                        userInterfaceStyle: scheme == .dark ? .dark : .light)))
                    .resizable()
                    .frame(width: geometry.size.width, height: geometry.size.height)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(WidgetWords.tr(
            "二维净分趋势，固定纵轴负五、零、正五；空白日期没有分数",
            "二維淨分趨勢，固定縱軸負五、零、正五；空白日期沒有分數",
            "Cartesian score trend, fixed vertical axis minus five, zero, plus five; gaps are unscored"))
        .accessibilityValue(Text(CalibrationCartesianTrendRenderer.accessibilitySummary(
            values: plot.values, smooth: plot.smooth, tickLabels: localizedLabels,
            scoreWord: WidgetWords.tr("有效记录", "有效紀錄", "Recorded"),
            averageWord: WidgetWords.tr("最近均线", "最近均線", "Latest average"),
            emptyWord: WidgetWords.tr("暂无有效记录", "暫無有效紀錄", "No scored records"))))
    }
}

private struct CalibrationWidgetView: View {
    @Environment(\.widgetFamily) private var family
    // Relative semantic sizes preserve the original Small/Medium proportions
    // while actually following the user's Dynamic Type setting.
    @ScaledMetric(relativeTo: .title3) private var smallCoverageSize: CGFloat = 18
    @ScaledMetric(relativeTo: .title2) private var mediumCoverageSize: CGFloat = 22
    @ScaledMetric(relativeTo: .caption2) private var smallFooterSize: CGFloat = 9
    @ScaledMetric(relativeTo: .caption) private var mediumFooterSize: CGFloat = 11
    let entry: CalibrationEntry

    private var small: Bool { family == .systemSmall }
    private var coverageFont: Font {
        .system(size: small ? smallCoverageSize : mediumCoverageSize,
                weight: .semibold)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: small ? 3 : 5) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(WidgetWords.widgetName)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 2)
                Text(WidgetWords.title(entry.period))
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            if let overview = entry.overview, let plot = entry.plot {
                primaryAssessment(overview)
                SharedCartesianChart(plot: plot, period: entry.period)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .layoutPriority(1)
                HStack(spacing: 4) {
                    Text("\(WidgetWords.completed) \(finalized(overview))")
                    Spacer(minLength: 2)
                    Text("\(WidgetWords.partial) \(partial(overview))")
                }
                .font(.system(size: small ? smallFooterSize : mediumFooterSize))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            } else {
                Spacer(minLength: 2)
                Text(WidgetWords.unavailable(entry.problem))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
            }
        }
        .padding(small ? 9 : 13)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(for: .widget) {
            Color(uiColor: .systemGroupedBackground)
        }
        .widgetURL(URL(string: "impress://calibration/\(entry.period.rawValue)"))
    }

    @ViewBuilder
    private func primaryAssessment(_ overview: CalibrationWidgetOverview) -> some View {
        switch entry.period {
        case .week:
            let today = overview.weekDays.last
            // Coverage stays primary even on a fully assessed or all-excused day.
            // Replacing 5/5 with a generic "assessed" label hides the B metric.
            Text("\(WidgetWords.today) \(today?.assessedCount ?? 0)/4")
                .font(coverageFont)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        case .month:
            Text("\(CalibrationWidgetOverview.assessedDays(overview.monthDays))/30 \(WidgetWords.days)")
                .font(coverageFont)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        case .year:
            let assessed = overview.yearMonths.reduce(0) { $0 + $1.assessedDays }
            Text("\(assessed) \(WidgetWords.days)")
                .font(coverageFont)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
    }

    private func finalized(_ overview: CalibrationWidgetOverview) -> Int {
        switch entry.period {
        case .week: return CalibrationWidgetOverview.finalizedDays(overview.weekDays)
        case .month: return CalibrationWidgetOverview.finalizedDays(overview.monthDays)
        case .year: return overview.yearMonths.reduce(0) { $0 + $1.finalizedDays }
        }
    }

    private func partial(_ overview: CalibrationWidgetOverview) -> Int {
        switch entry.period {
        case .week: return CalibrationWidgetOverview.partialDays(overview.weekDays)
        case .month: return CalibrationWidgetOverview.partialDays(overview.monthDays)
        case .year: return overview.yearMonths.reduce(0) { $0 + $1.partialDays }
        }
    }
}

private struct CalibrationPeriodWidget: Widget {
    let period: CalibrationWidgetPeriod

    // Xcode 27 / WidgetKit requires Widget.init() even for multi-kind bundles.
    // The bundle explicitly selects .week / .month / .year via init(period:).
    init() { self.period = .week }
    init(period: CalibrationWidgetPeriod) { self.period = period }

    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: "impress.calibration.\(period.rawValue)",
            provider: CalibrationProvider(period: period)
        ) { entry in
            CalibrationWidgetView(entry: entry)
        }
        .configurationDisplayName(WidgetWords.widgetName + " · " + WidgetWords.title(period))
        .description(WidgetWords.tr(
            "以行为评估与记录覆盖为主", "以行為評估與記錄覆蓋為主",
            "Assessment coverage, not a scorecard"))
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct ImpressCalibrationWidgetBundle: WidgetBundle {
    var body: some Widget {
        CalibrationPeriodWidget(period: .week)
        CalibrationPeriodWidget(period: .month)
        CalibrationPeriodWidget(period: .year)
    }
}
