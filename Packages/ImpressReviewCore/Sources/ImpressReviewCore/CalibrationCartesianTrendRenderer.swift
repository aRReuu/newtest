#if canImport(UIKit)
import UIKit

/// The only Cartesian calibration painter used by both the in-App UIKit chart
/// and WidgetKit's SwiftUI image. Geometry, ticks, gaps and strokes are identical.
/// No score calculation or private journal access takes place in this renderer.
public struct CalibrationCartesianPalette {
    public let axis: UIColor
    public let secondary: UIColor
    public let accent: UIColor

    public init(axis: UIColor, secondary: UIColor, accent: UIColor) {
        self.axis = axis
        self.secondary = secondary
        self.accent = accent
    }

    /// Mirrors ImpressV3Appearance: separator / secondaryLabel / systemBlue.
    public static let semantic = CalibrationCartesianPalette(
        axis: .separator, secondary: .secondaryLabel, accent: .systemBlue)
}

public enum CalibrationCartesianTrendRenderer {
    public static func draw(in rect: CGRect,
                            context: CGContext,
                            values: [Double?],
                            smooth: [Double?],
                            tickLabels: [String],
                            palette: CalibrationCartesianPalette,
                            font: UIFont,
                            traitCollection: UITraitCollection) {
        let box = CGRect(x: 32, y: 12, width: max(1, rect.width - 44),
                         height: max(1, rect.height - 40))
        // W13: use the fixed product axis -5 / 0 / +5. Auto-scaling
        // according to each day's extrema would make a +2 score appear
        // at the same height as +5 on another day, breaking App/Widget parity.
        let ceiling = 5.0
        let y: (Double) -> CGFloat = { value in
            box.midY - CGFloat(value / ceiling) * box.height * 0.46
        }
        let axis = palette.axis.resolvedColor(with: traitCollection)
        let muted = palette.secondary.resolvedColor(with: traitCollection)
        let textAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: muted
        ]
        // Explicit Cartesian axes and simple positive/zero/negative y ticks.
        context.setLineWidth(1)
        context.setStrokeColor(axis.cgColor)
        context.move(to: CGPoint(x: box.minX, y: box.minY))
        context.addLine(to: CGPoint(x: box.minX, y: box.maxY))
        context.addLine(to: CGPoint(x: box.maxX, y: box.maxY))
        context.strokePath()
        for number in [-ceiling, 0, ceiling] {
            let lineY = y(number)
            context.setStrokeColor(axis.withAlphaComponent(number == 0 ? 0.8 : 0.4).cgColor)
            context.move(to: CGPoint(x: box.minX, y: lineY))
            context.addLine(to: CGPoint(x: box.maxX, y: lineY))
            context.strokePath()
            let string = String(format: "%+.0f", number) as NSString
            string.draw(at: CGPoint(x: 0, y: lineY - 7), withAttributes: textAttributes)
        }
        if !tickLabels.isEmpty {
            let candidates = Array(Set([0, tickLabels.count/2, tickLabels.count-1])).sorted()
            for index in candidates {
                let value = tickLabels[index] as NSString
                let size = value.size(withAttributes: textAttributes)
                let x = box.minX + box.width * CGFloat(index) /
                    CGFloat(max(1, tickLabels.count-1))
                let origin = CGPoint(x: min(rect.width - size.width, max(0, x - size.width/2)),
                                     y: box.maxY + 5)
                value.draw(at: origin, withAttributes: textAttributes)
            }
        }
        func plot(_ data: [Double?], color: UIColor, width: CGFloat) {
            let ink = color.resolvedColor(with: traitCollection)
            context.setStrokeColor(ink.cgColor)
            context.setLineWidth(width)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.beginPath()
            var continuing = false
            for index in data.indices {
                guard let value = data[index] else { continuing = false; continue }
                let x = box.minX + box.width * CGFloat(index) /
                    CGFloat(max(1, data.count - 1))
                let point = CGPoint(x: x, y: y(value))
                if continuing { context.addLine(to: point) }
                else { context.move(to: point) }
                continuing = true
            }
            context.strokePath()
            // Stroked lines cannot render a single sample in a gap-delimited run.
            // Mark ALL isolated real values in each series, never invented zeros.
            for index in data.indices {
                guard let value = data[index] else { continue }
                let hasPrevious = index > 0 && data[index - 1] != nil
                let hasNext = index + 1 < data.count && data[index + 1] != nil
                guard !hasPrevious && !hasNext else { continue }
                let x = box.minX + box.width * CGFloat(index) /
                    CGFloat(max(1, data.count - 1))
                let diameter = max(4, width * 2)
                context.setFillColor(ink.cgColor)
                context.fillEllipse(in: CGRect(
                    x: x - diameter / 2, y: y(value) - diameter / 2,
                    width: diameter, height: diameter))
            }
        }
        plot(values, color: palette.secondary, width: 1.4)
        plot(smooth, color: palette.accent, width: 2.8)
    }

    /// Shared VoiceOver facts for the App chart and the Widget image.
    /// Nil is missing data, never a zero score. The most recent real point
    /// and average are announced without exposing private notes or journal text.
    public static func accessibilitySummary(
        values: [Double?], smooth: [Double?], tickLabels: [String],
        scoreWord: String, averageWord: String, emptyWord: String
    ) -> String {
        let actual = values.enumerated().compactMap { index, score -> (Int, Double)? in
            guard let score, score.isFinite else { return nil }
            return (index, score)
        }
        guard let latest = actual.last else { return emptyWord }
        let day = latest.0 < tickLabels.count ? tickLabels[latest.0] :
            String(latest.0 + 1)
        let coverage = scoreWord + " " + String(actual.count) + "/" +
            String(values.count)
        let lastScore = day + " " + String(format: "%+.1f", latest.1)
        let lastAverage = smooth.reversed().compactMap { $0 }
            .first(where: { $0.isFinite })
        if let lastAverage {
            return coverage + "；" + lastScore + "；" + averageWord + " " +
                String(format: "%+.1f", lastAverage)
        }
        return coverage + "；" + lastScore
    }

    /// WidgetKit must use this exact draw() path, not a second Swift Charts
    /// coordinate system that would silently drift from the native controller.
    public static func image(size: CGSize,
                             values: [Double?],
                             smooth: [Double?],
                             tickLabels: [String],
                             palette: CalibrationCartesianPalette = .semantic,
                             font: UIFont = .preferredFont(forTextStyle: .caption2),
                             traitCollection: UITraitCollection) -> UIImage {
        guard size.width >= 1, size.height >= 1 else { return UIImage() }
        return UIGraphicsImageRenderer(size: size).image { renderer in
            draw(in: CGRect(origin: .zero, size: size),
                 context: renderer.cgContext,
                 values: values, smooth: smooth, tickLabels: tickLabels,
                 palette: palette, font: font, traitCollection: traitCollection)
        }
    }
}
#endif
