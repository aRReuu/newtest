#if os(iOS)
import UIKit
import PhotosUI
import UniformTypeIdentifiers
import AVFoundation

/// Isolates one Photos video selection and in-app trim/export. A provider URL
/// expires after its callback; it is copied before the editor is displayed.
/// The caller retains the staged pair until WCDB CAS + readback succeeds.
@MainActor
public final class ImpressCardVideoImportCoordinator {
    public enum Failure: Error, LocalizedError {
        case unsupportedVideo, sourceUnavailable, insufficientSpace, staleSelection
        public var errorDescription: String? {
            switch self {
            case .unsupportedVideo: return "选中的影片格式无法离线导入。"
            case .sourceUnavailable: return "影片无法读取，或 iCloud 尚未下载完成。"
            case .insufficientSpace: return "临时空间不足，请释放空间后重试。"
            case .staleSelection: return "已取消或替换此次影片选择。"
            }
        }
    }

    private var token: UUID?
    private var job: ImpressCardVideoAVFoundationExporter.Job?
    private var stagedSourceDirectory: URL?
    private var pollingTimer: Timer?
    private weak var presentedEditor: UINavigationController?

    public init() {}
    public var isProcessing: Bool { token != nil }

    /// Cancelling never mutates the saved card or a previously adopted draft.
    public func cancel() {
        token = nil
        pollingTimer?.invalidate()
        pollingTimer = nil
        job?.cancel()
        job = nil
        presentedEditor?.dismiss(animated: true)
        presentedEditor = nil
        if let stagedSourceDirectory {
            try? FileManager.default.removeItem(at: stagedSourceDirectory)
        }
        stagedSourceDirectory = nil
    }

    public func start(provider: NSItemProvider, cardID: UUID,
                      targetContentRevision: Int, presenter: UIViewController,
                      progress: @escaping (Float) -> Void,
                      completion: @escaping (Result<ImpressCardVideoAVFoundationExporter.Staged, Error>) -> Void) {
        cancel()
        guard targetContentRevision >= 0,
              let identifier = provider.registeredTypeIdentifiers.first(where: {
                  UTType($0)?.conforms(to: .movie) == true
              }), provider.hasItemConformingToTypeIdentifier(identifier) else {
            completion(.failure(Failure.unsupportedVideo))
            return
        }
        let ticket = UUID()
        token = ticket
        let ext = UTType(identifier)?.preferredFilenameExtension?.lowercased() ?? "mov"
        let safeExtension = ["mov", "mp4", "m4v"].contains(ext) ? ext : "mov"
        provider.loadFileRepresentation(forTypeIdentifier: identifier) { [weak self, weak presenter] ephemeral, _ in
            // Provider-owned ephemeral URLs must not escape the callback.
            let local: Result<(URL, URL), Error> = Result {
                guard let ephemeral, ephemeral.isFileURL else { throw Failure.sourceUnavailable }
                let fm = FileManager.default
                let attrs = try fm.attributesOfItem(atPath: ephemeral.path)
                let values = try ephemeral.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true,
                      (attrs[.type] as? FileAttributeType) == .typeRegular,
                      let bytes = (attrs[.size] as? NSNumber)?.uint64Value, bytes > 0 else {
                    throw Failure.sourceUnavailable
                }
                let available = (try fm.attributesOfFileSystem(forPath: fm.temporaryDirectory.path)[.systemFreeSize] as? NSNumber)?.uint64Value ?? 0
                let reserve = 2 * ImpressCardVideoReference.maximumBytes + 32 * 1_048_576
                guard bytes <= UInt64.max - reserve, available >= bytes + reserve else {
                    throw Failure.insufficientSpace
                }
                let directory = fm.temporaryDirectory.appendingPathComponent(
                    "impress-video-source-\(UUID().uuidString)", isDirectory: true)
                try fm.createDirectory(at: directory, withIntermediateDirectories: false,
                    attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
                do {
                    var mutable = directory
                    var resource = URLResourceValues()
                    resource.isExcludedFromBackup = true
                    try mutable.setResourceValues(resource)
                    let source = directory.appendingPathComponent("source.\(safeExtension)")
                    try fm.copyItem(at: ephemeral, to: source)
                    try fm.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                         ofItemAtPath: source.path)
                    return (source, directory)
                } catch {
                    try? fm.removeItem(at: directory)
                    throw error
                }
            }
            DispatchQueue.main.async { [weak self, weak presenter] in
                guard let self, self.token == ticket, let presenter else {
                    if case .success((_, let directory)) = local {
                        try? FileManager.default.removeItem(at: directory)
                    }
                    return
                }
                switch local {
                case .failure(let error):
                    self.end(ticket: ticket, result: .failure(error), completion: completion)
                case .success((let source, let directory)):
                    self.stagedSourceDirectory = directory
                    self.showTrimEditor(source: source, ticket: ticket, cardID: cardID,
                        revision: targetContentRevision, presenter: presenter,
                        progress: progress, completion: completion)
                }
            }
        }
    }

    private func showTrimEditor(source: URL, ticket: UUID, cardID: UUID,
                                revision: Int, presenter: UIViewController,
                                progress: @escaping (Float) -> Void,
                                completion: @escaping (Result<ImpressCardVideoAVFoundationExporter.Staged, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self, weak presenter] in
            let asset = AVURLAsset(url: source)
            let duration = asset.duration.seconds
            let valid = duration.isFinite && duration > 0 && !asset.hasProtectedContent &&
                !asset.tracks(withMediaType: .video).isEmpty
            DispatchQueue.main.async { [weak self, weak presenter] in
                guard let self, self.token == ticket, let presenter else { return }
                guard valid else {
                    self.end(ticket: ticket, result: .failure(Failure.unsupportedVideo), completion: completion)
                    return
                }
                let labels = ImpressCardVideoTrimViewController.Labels(
                    title: "视频", keepFull: "保留完整视频", trim: "截取片段",
                    balanced: "清晰", compact: "更小体积", preview: "预览",
                    confirm: "压缩视频", cancel: "取消", start: "开始", end: "结束")
                let editor = ImpressCardVideoTrimViewController(
                    sourceURL: source, durationSeconds: duration, labels: labels)
                editor.onCancel = { [weak self] in
                    guard let self, self.token == ticket else { return }
                    self.cancel()
                    completion(.failure(Failure.staleSelection))
                }
                editor.onConfirm = { [weak self] selection in
                    guard let self, self.token == ticket else { return }
                    self.presentedEditor?.dismiss(animated: true)
                    self.presentedEditor = nil
                    progress(0)
                    let request = ImpressCardVideoAVFoundationExporter.Request(
                        sourceURL: source, cardID: cardID,
                        expectedContentRevision: revision,
                        trimStartSeconds: selection.trimStartSeconds,
                        trimEndSeconds: selection.trimEndSeconds,
                        preference: selection.preference)
                    self.job = ImpressCardVideoAVFoundationExporter.export(request) { [weak self] result in
                        guard let self, self.token == ticket else {
                            if case .success(let staged) = result { staged.discard() }
                            return
                        }
                        self.end(ticket: ticket, result: result, completion: completion)
                    }
                    self.pollingTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] timer in
                        Task { @MainActor [weak self] in
                            guard let self, self.token == ticket, let job = self.job else {
                                timer.invalidate()
                                return
                            }
                            progress(job.progress)
                        }
                    }
                }
                let nav = UINavigationController(rootViewController: editor)
                nav.modalPresentationStyle = .pageSheet
                // Swipe dismissal must not bypass the coordinator's explicit
                // cancellation and leave an orphaned temporary movie.
                nav.isModalInPresentation = true
                self.presentedEditor = nav
                presenter.present(nav, animated: true)
            }
        }
    }

    private func end(ticket: UUID,
                     result: Result<ImpressCardVideoAVFoundationExporter.Staged, Error>,
                     completion: (Result<ImpressCardVideoAVFoundationExporter.Staged, Error>) -> Void) {
        guard token == ticket else { return }
        token = nil
        job = nil
        pollingTimer?.invalidate()
        pollingTimer = nil
        if let stagedSourceDirectory { try? FileManager.default.removeItem(at: stagedSourceDirectory) }
        stagedSourceDirectory = nil
        completion(result)
    }
}
#endif
