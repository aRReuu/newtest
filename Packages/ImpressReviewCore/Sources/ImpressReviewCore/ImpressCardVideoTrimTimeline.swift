#if os(iOS)
import UIKit

/// Two-thumb, time-based trimming control. A selection is always bounded by
/// the *actual* asset duration; no arbitrary 60-second or 10-minute ceiling.
@MainActor
public final class ImpressCardVideoTrimTimeline: UIControl {
    private enum Grip { case beginning, end }
    private var activeGrip: Grip?
    private let sideInset: CGFloat = 18
    private let gripRadius: CGFloat = 12
    public private(set) var totalDuration: Double = 0
    public private(set) var startSeconds: Double = 0
    public private(set) var endSeconds: Double = 0

    public var minimumClipSeconds: Double {
        min(0.10, max(0, totalDuration / 2))
    }

    public override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isAccessibilityElement = false
        accessibilityIdentifier = "impress.video.timeline"
        contentMode = .redraw
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        backgroundColor = .clear
        isAccessibilityElement = false
        contentMode = .redraw
    }

    /// No trimming by default; the user must opt into moving either endpoint.
    public func configure(duration: Double, start: Double = 0, end: Double? = nil) {
        guard duration.isFinite, duration > 0 else { return }
        totalDuration = duration
        let actualEnd = end ?? duration
        startSeconds = max(0, min(start.isFinite ? start : 0, duration - minimumClipSeconds))
        endSeconds = max(startSeconds + minimumClipSeconds,
                         min(actualEnd.isFinite ? actualEnd : duration, duration))
        setNeedsDisplay()
    }

    private var trackLength: CGFloat { max(1, bounds.width - 2 * sideInset) }

    private func x(_ seconds: Double) -> CGFloat {
        sideInset + trackLength * CGFloat(max(0, min(1, seconds / max(totalDuration, 0.000001))))
    }

    private func seconds(at point: CGPoint) -> Double {
        let fraction = max(0, min(1, (point.x - sideInset) / trackLength))
        return totalDuration * Double(fraction)
    }

    public override func draw(_ rect: CGRect) {
        guard totalDuration > 0 else { return }
        let center = bounds.midY
        let base = CGRect(x: sideInset, y: center - 3, width: trackLength, height: 6)
        UIColor.tertiarySystemFill.setFill()
        UIBezierPath(roundedRect: base, cornerRadius: 3).fill()
        let selected = CGRect(x: x(startSeconds), y: center - 3,
                              width: max(1, x(endSeconds) - x(startSeconds)), height: 6)
        tintColor.setFill()
        UIBezierPath(roundedRect: selected, cornerRadius: 3).fill()
        for time in [startSeconds, endSeconds] {
            let circle = CGRect(x: x(time) - gripRadius, y: center - gripRadius,
                                width: gripRadius * 2, height: gripRadius * 2)
            UIColor.systemBackground.setFill()
            UIBezierPath(ovalIn: circle).fill()
            tintColor.setStroke()
            let outline = UIBezierPath(ovalIn: circle.insetBy(dx: 1, dy: 1))
            outline.lineWidth = 2
            outline.stroke()
        }
    }

    public override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        guard totalDuration > 0 else { return false }
        let location = touch.location(in: self)
        activeGrip = abs(location.x - x(startSeconds)) <= abs(location.x - x(endSeconds))
            ? .beginning : .end
        return true
    }

    public override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        guard let activeGrip else { return false }
        let time = seconds(at: touch.location(in: self))
        switch activeGrip {
        case .beginning:
            startSeconds = min(max(0, time), endSeconds - minimumClipSeconds)
        case .end:
            endSeconds = max(min(totalDuration, time), startSeconds + minimumClipSeconds)
        }
        setNeedsDisplay()
        sendActions(for: .valueChanged)
        return true
    }

    public override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        activeGrip = nil
    }

    public override func cancelTracking(with event: UIEvent?) {
        activeGrip = nil
    }
}
#endif
