#if os(iOS)
import UIKit
import AVKit
import AVFoundation

/// App-owned editor sheet, not a new Tab. Caller supplies localized text and
/// owns the picker URL, export Job, cancellation and WCDB commit.
@MainActor
public final class ImpressCardVideoTrimViewController: UIViewController {
    public struct Labels {
        public let title: String
        public let keepFull: String
        public let trim: String
        public let balanced: String
        public let compact: String
        public let preview: String
        public let confirm: String
        public let cancel: String
        public let start: String
        public let end: String

        public init(title: String, keepFull: String, trim: String,
                    balanced: String, compact: String, preview: String,
                    confirm: String, cancel: String, start: String, end: String) {
            self.title = title; self.keepFull = keepFull; self.trim = trim
            self.balanced = balanced; self.compact = compact
            self.preview = preview; self.confirm = confirm; self.cancel = cancel
            self.start = start; self.end = end
        }
    }

    public struct Selection {
        public let trimStartSeconds: Double
        public let trimEndSeconds: Double
        public let preference: ImpressCardVideoEncodingBudget.Preference
    }

    public var onConfirm: ((Selection) -> Void)?
    public var onCancel: (() -> Void)?

    private let sourceURL: URL
    private let duration: Double
    private let labels: Labels
    private let poster = UIImageView()
    private let mode = UISegmentedControl()
    private let quality = UISegmentedControl()
    private let timeline = ImpressCardVideoTrimTimeline()
    private let rangeLabel = UILabel()
    private let previewButton = UIButton(type: .system)

    public init(sourceURL: URL, durationSeconds: Double, labels: Labels) {
        self.sourceURL = sourceURL
        self.duration = durationSeconds
        self.labels = labels
        super.init(nibName: nil, bundle: nil)
    }

    public required init?(coder: NSCoder) { fatalError("init(sourceURL:durationSeconds:labels:)") }

    public override func viewDidLoad() {
        super.viewDidLoad()
        title = labels.title
        view.backgroundColor = .systemBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: labels.cancel,
            style: .plain, target: self, action: #selector(cancel))
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "checkmark"), style: .plain,
            target: self, action: #selector(accept))
        navigationItem.rightBarButtonItem?.accessibilityLabel = labels.confirm

        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -20),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -20),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -40)
        ])

        poster.contentMode = .scaleAspectFit
        poster.backgroundColor = .secondarySystemBackground
        poster.layer.cornerRadius = 10
        poster.clipsToBounds = true
        poster.heightAnchor.constraint(equalToConstant: 210).isActive = true
        poster.accessibilityIdentifier = "impress.video.trim.cover"
        stack.addArrangedSubview(poster)
        buildPoster()

        previewButton.setTitle(labels.preview, for: .normal)
        previewButton.setImage(UIImage(systemName: "play.fill"), for: .normal)
        previewButton.addTarget(self, action: #selector(previewClip), for: .touchUpInside)
        previewButton.accessibilityIdentifier = "impress.video.trim.preview"
        previewButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        stack.addArrangedSubview(previewButton)

        mode.insertSegment(withTitle: labels.keepFull, at: 0, animated: false)
        mode.insertSegment(withTitle: labels.trim, at: 1, animated: false)
        mode.selectedSegmentIndex = 0
        mode.addTarget(self, action: #selector(modeChanged), for: .valueChanged)
        mode.accessibilityIdentifier = "impress.video.trim.mode"
        stack.addArrangedSubview(mode)

        timeline.configure(duration: duration)
        timeline.heightAnchor.constraint(equalToConstant: 56).isActive = true
        timeline.addTarget(self, action: #selector(updateRange), for: .valueChanged)
        timeline.isHidden = true
        stack.addArrangedSubview(timeline)

        rangeLabel.font = .preferredFont(forTextStyle: .subheadline)
        rangeLabel.textColor = .secondaryLabel
        rangeLabel.numberOfLines = 0
        rangeLabel.adjustsFontForContentSizeCategory = true
        stack.addArrangedSubview(rangeLabel)
        updateRange()

        quality.insertSegment(withTitle: labels.balanced, at: 0, animated: false)
        quality.insertSegment(withTitle: labels.compact, at: 1, animated: false)
        quality.selectedSegmentIndex = 0
        quality.accessibilityIdentifier = "impress.video.trim.quality"
        stack.addArrangedSubview(quality)
    }

    private func buildPoster() {
        guard sourceURL.isFileURL, duration.isFinite, duration > 0 else { return }
        // Small, bounded thumbnail; never load the whole video into UIImage.
        let url = sourceURL
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 640, height: 640)
            let time = CMTime(seconds: min(0.15, asset.duration.seconds / 2),
                              preferredTimescale: 600)
            let cg = try? generator.copyCGImage(at: time, actualTime: nil)
            DispatchQueue.main.async {
                guard let self, let cg else { return }
                self.poster.image = UIImage(cgImage: cg)
            }
        }
    }

    @objc private func modeChanged() {
        timeline.isHidden = mode.selectedSegmentIndex != 1
        updateRange()
    }

    @objc private func updateRange() {
        let isTrimmed = mode.selectedSegmentIndex == 1
        let start = isTrimmed ? timeline.startSeconds : 0
        let end = isTrimmed ? timeline.endSeconds : duration
        rangeLabel.text = String(format: "%@: %.2fs     %@: %.2fs     %.2fs",
            labels.start, start, labels.end, end, duration)
    }

    @objc private func previewClip() {
        guard sourceURL.isFileURL, duration.isFinite, duration > 0 else { return }
        let isTrimmed = mode.selectedSegmentIndex == 1
        let start = isTrimmed ? timeline.startSeconds : 0
        let end = isTrimmed ? timeline.endSeconds : duration
        let playerItem = AVPlayerItem(url: sourceURL)
        playerItem.forwardPlaybackEndTime = CMTime(seconds: end, preferredTimescale: 600)
        let player = AVPlayer(playerItem: playerItem)
        let vc = AVPlayerViewController()
        vc.player = player
        vc.modalPresentationStyle = .fullScreen
        present(vc, animated: true) {
            player.seek(to: CMTime(seconds: start, preferredTimescale: 600))
            player.play()
        }
    }

    @objc private func accept() {
        guard duration.isFinite, duration > 0 else { return }
        let trimmed = mode.selectedSegmentIndex == 1
        let start = trimmed ? timeline.startSeconds : 0
        let end = trimmed ? timeline.endSeconds : duration
        guard end > start, end <= duration else { return }
        navigationItem.rightBarButtonItem?.isEnabled = false
        onConfirm?(Selection(trimStartSeconds: start, trimEndSeconds: end,
            preference: quality.selectedSegmentIndex == 1 ? .compact : .balanced))
    }

    @objc private func cancel() { onCancel?() }
}
#endif
