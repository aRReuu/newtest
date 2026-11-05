#if os(iOS)
import Foundation
import AVFoundation
import CryptoKit
import UIKit

/// App-local offline exporter. Output remains a temporary, uncommitted media pair.
/// The editor/repository owner must install it atomically and commit the WCDB
/// reference through content CAS; an export SUCCESS is never a card save.
public enum ImpressCardVideoAVFoundationExporter {
    public enum Failure: Swift.Error, LocalizedError {
        case invalidSource, protectedSource, noVideoTrack, incompatibleCodec
        case notEnoughSpace, outputTooLarge, invalidOutput, cancelled
        case coverFailed, mediaIntegrityFailed
        public var errorDescription: String? {
            switch self {
            case .invalidSource: return "视频无法读取或时间范围无效。"
            case .protectedSource: return "此视频受版权保护，无法离线导入。"
            case .noVideoTrack: return "文件不包含可读取的视频画面。"
            case .incompatibleCodec: return "设备不支持该视频的离线编码，请更换格式。"
            case .notEnoughSpace: return "临时空间不足，请释放空间后重试。"
            case .outputTooLarge: return "视频体积超出上限，请截取片段或降低清晰度。"
            case .invalidOutput: return "视频导出失败，请重试或更换格式。"
            case .cancelled: return "已取消视频处理。"
            case .coverFailed: return "无法生成视频封面。"
            case .mediaIntegrityFailed: return "视频或封面校验失败。"
            }
        }
    }

    public struct Request {
        public let sourceURL: URL
        public let cardID: UUID
        public let expectedContentRevision: Int
        public let trimStartSeconds: Double
        public let trimEndSeconds: Double?
        public let preference: ImpressCardVideoEncodingBudget.Preference
        public init(sourceURL: URL, cardID: UUID, expectedContentRevision: Int,
                    trimStartSeconds: Double = 0, trimEndSeconds: Double? = nil,
                    preference: ImpressCardVideoEncodingBudget.Preference = .balanced) {
            self.sourceURL = sourceURL
            self.cardID = cardID
            self.expectedContentRevision = expectedContentRevision
            self.trimStartSeconds = trimStartSeconds
            self.trimEndSeconds = trimEndSeconds
            self.preference = preference
        }
    }

    /// Only staged files, never a Photo Library URL or video bytes in a WCDB BLOB.
    public struct Staged: Sendable {
        public let reference: ImpressCardVideoReference
        public let movieURL: URL
        public let coverURL: URL
        public let directoryURL: URL
        public func discard() { try? FileManager.default.removeItem(at: directoryURL) }
    }

    public final class Job {
        private let lock = NSLock()
        private var session: AVAssetExportSession?
        private var cancelled = false
        private var finished = false

        public var progress: Float {
            lock.lock(); defer { lock.unlock() }
            return finished ? 1 : (session?.progress ?? 0)
        }
        public func cancel() {
            lock.lock()
            cancelled = true
            let export = session
            lock.unlock()
            export?.cancelExport()
        }
        fileprivate var isCancelled: Bool {
            lock.lock(); defer { lock.unlock() }
            return cancelled
        }
        fileprivate func attach(_ export: AVAssetExportSession) {
            lock.lock(); session = export; let shouldCancel = cancelled; lock.unlock()
            if shouldCancel { export.cancelExport() }
        }
        fileprivate func complete() {
            lock.lock(); finished = true; session = nil; lock.unlock()
        }
    }

    /// Completion always occurs on the main queue. Caller owns the Job for
    /// progress/cancel. No automatic retries, provider calls, or UI mutation.
    @discardableResult
    public static func export(_ request: Request,
                              completion: @escaping (Result<Staged, Swift.Error>) -> Void) -> Job {
        let job = Job()
        DispatchQueue.global(qos: .userInitiated).async {
            let fileManager = FileManager.default
            let directory = fileManager.temporaryDirectory
                .appendingPathComponent("impress-card-video-\(UUID().uuidString)", isDirectory: true)
            func finish(_ result: Result<Staged, Swift.Error>) {
                if case .failure = result { try? fileManager.removeItem(at: directory) }
                job.complete()
                DispatchQueue.main.async { completion(result) }
            }
            do {
                guard !job.isCancelled else { throw Failure.cancelled }
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.protectionKey:
                                                    FileProtectionType.completeUntilFirstUserAuthentication])
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                var mutableDirectory = directory
                try mutableDirectory.setResourceValues(values)

                let setup = try makeSession(request: request, directory: directory)
                guard !job.isCancelled else { throw Failure.cancelled }
                // A device can advertise HEVC preset support but still fail at
                // encode time. Retry precisely once with a compatible H.264
                // preset. Never retry cancellations or silently trim duration.
                func run(_ attempt: Setup, mayFallback: Bool) {
                    job.attach(attempt.session)
                    attempt.session.exportAsynchronously {
                        DispatchQueue.global(qos: .userInitiated).async {
                            do {
                                guard !job.isCancelled else { throw Failure.cancelled }
                                if attempt.session.status != .completed {
                                    if mayFallback && attempt.plan.codec == .hevc {
                                        // A failed encoder can leave a partial MP4.
                                        // Remove it before constructing the next session.
                                        if fileManager.fileExists(atPath: attempt.outputURL.path) {
                                            try fileManager.removeItem(at: attempt.outputURL)
                                        }
                                        let alternate = try makeSession(
                                            request: request, directory: directory, preferH264: true)
                                        guard !job.isCancelled else { throw Failure.cancelled }
                                        run(alternate, mayFallback: false)
                                        return
                                    }
                                    throw attempt.session.error ?? Failure.invalidOutput
                                }
                                let staged = try verifyAndMakeCover(
                                    request: request, plan: attempt.plan,
                                    asset: attempt.asset, outputURL: attempt.outputURL,
                                    directory: directory, job: job)
                                guard !job.isCancelled else { throw Failure.cancelled }
                                finish(.success(staged))
                            } catch {
                                finish(.failure(error))
                            }
                        }
                    }
                }
                run(setup, mayFallback: true)
            } catch { finish(.failure(error)) }
        }
        return job
    }

    private struct Setup {
        let asset: AVURLAsset
        let plan: ImpressCardVideoEncodingBudget.Plan
        let session: AVAssetExportSession
        let outputURL: URL
    }

    private static func makeSession(request: Request, directory: URL,
                                    preferH264: Bool = false) throws -> Setup {
        guard request.sourceURL.isFileURL, request.expectedContentRevision >= 0,
              FileManager.default.fileExists(atPath: request.sourceURL.path) else {
            throw Failure.invalidSource
        }
        let asset = AVURLAsset(url: request.sourceURL)
        guard !asset.hasProtectedContent else { throw Failure.protectedSource }
        guard let track = asset.tracks(withMediaType: .video).first else {
            throw Failure.noVideoTrack
        }
        let duration = asset.duration.seconds
        guard duration.isFinite, duration > 0 else { throw Failure.invalidSource }
        let end = request.trimEndSeconds ?? duration
        let rect = CGRect(origin: .zero, size: track.naturalSize)
            .applying(track.preferredTransform).standardized
        guard rect.minX.isFinite, rect.minY.isFinite else {
            throw Failure.invalidSource
        }
        let dimensions: (width: Int, height: Int)
        do {
            dimensions = try ImpressCardVideoEncodingBudget.validatedSourceDimensions(
                widthPixels: Double(rect.width), heightPixels: Double(rect.height))
        } catch {
            throw Failure.invalidSource
        }
        let width = dimensions.width
        let height = dimensions.height
        let compatible = AVAssetExportSession.exportPresets(compatibleWith: asset)
        let hevcPreset = AVAssetExportPresetHEVC1920x1080
        let h264Presets = [AVAssetExportPreset1280x720,
                           AVAssetExportPreset960x540, AVAssetExportPreset640x480]
        let hevc = !preferH264 && compatible.contains(hevcPreset)
        let h264 = compatible.contains(where: h264Presets.contains)
        guard hevc || h264 else { throw Failure.incompatibleCodec }
        let filesystem = try FileManager.default.attributesOfFileSystem(forPath: directory.path)
        let free = filesystem[.systemFreeSize] as? NSNumber
        let available = free?.uint64Value ?? 0
        let plan: ImpressCardVideoEncodingBudget.Plan
        do {
            plan = try ImpressCardVideoEncodingBudget.propose(.init(
                durationSeconds: duration, width: width, height: height,
                hasAudio: !asset.tracks(withMediaType: .audio).isEmpty,
                trimStartSeconds: request.trimStartSeconds, trimEndSeconds: end,
                availableTemporaryBytes: available, canEncodeHEVC: hevc,
                canEncodeH264: h264, preference: request.preference))
        } catch ImpressCardVideoEncodingBudget.Error.notEnoughTemporarySpace {
            throw Failure.notEnoughSpace
        } catch ImpressCardVideoEncodingBudget.Error.needsShorterClipOrLowerQuality {
            throw Failure.outputTooLarge
        }
        // Preset exporters do not honor the planner's estimated bitrate. Reserve
        // the actual hard ceiling for the encoded file and its transient copy.
        let worstCaseReserve = 2 * ImpressCardVideoReference.maximumBytes + 16 * 1_048_576
        guard available >= max(plan.requiredTemporaryBytes, worstCaseReserve) else {
            throw Failure.notEnoughSpace
        }
        let preset: String
        if plan.codec == .hevc {
            preset = hevcPreset
        } else {
            let longEdge = max(plan.targetWidth, plan.targetHeight)
            let preferences = longEdge <= 640
                ? [AVAssetExportPreset640x480, AVAssetExportPreset960x540, AVAssetExportPreset1280x720]
                : longEdge <= 960
                ? [AVAssetExportPreset960x540, AVAssetExportPreset640x480, AVAssetExportPreset1280x720]
                : h264Presets
            guard let selected = preferences.first(where: compatible.contains) else {
                throw Failure.incompatibleCodec
            }
            preset = selected
        }
        guard let session = AVAssetExportSession(asset: asset, presetName: preset),
              session.supportedFileTypes.contains(.mp4) else {
            throw Failure.incompatibleCodec
        }
        // Always force the editor-selected display size: a HEVC preset alone
        // otherwise keeps up to 1080p and can defeat compact-size planning.
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: asset.duration)
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        let sx = CGFloat(plan.targetWidth) / max(1, rect.width)
        let sy = CGFloat(plan.targetHeight) / max(1, rect.height)
        let transform = track.preferredTransform
            .concatenating(CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
            .concatenating(CGAffineTransform(scaleX: sx, y: sy))
        layer.setTransform(transform, at: .zero)
        instruction.layerInstructions = [layer]
        let composition = AVMutableVideoComposition()
        composition.instructions = [instruction]
        composition.renderSize = CGSize(width: plan.targetWidth, height: plan.targetHeight)
        let nominalFPS = track.nominalFrameRate
        let fps = ImpressCardVideoEncodingBudget.safeNominalFrameRate(Double(nominalFPS))
        composition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(1, fps)))
        session.videoComposition = composition
        session.timeRange = CMTimeRange(start: CMTime(seconds: plan.trimStartSeconds, preferredTimescale: 600),
                                        duration: CMTime(seconds: plan.durationSeconds, preferredTimescale: 600))
        let outputURL = directory.appendingPathComponent("compressed.mp4")
        session.outputURL = outputURL
        session.outputFileType = .mp4
        session.fileLengthLimit = Int64(ImpressCardVideoReference.maximumBytes)
        session.shouldOptimizeForNetworkUse = false
        return Setup(asset: asset, plan: plan, session: session, outputURL: outputURL)
    }

    private static func verifyAndMakeCover(request: Request,
                                           plan: ImpressCardVideoEncodingBudget.Plan,
                                           asset: AVURLAsset, outputURL: URL,
                                           directory: URL, job: Job) throws -> Staged {
        guard !job.isCancelled else { throw Failure.cancelled }
        let output = AVURLAsset(url: outputURL)
        guard let track = output.tracks(withMediaType: .video).first,
              track.naturalSize.width > 0, track.naturalSize.height > 0,
              output.duration.seconds.isFinite, output.duration.seconds > 0,
              abs(output.duration.seconds - plan.durationSeconds) <= 0.50 else {
            throw Failure.invalidOutput
        }
        if !asset.tracks(withMediaType: .audio).isEmpty,
           output.tracks(withMediaType: .audio).isEmpty { throw Failure.invalidOutput }
        let generator = AVAssetImageGenerator(asset: output)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 640)
        let seek = CMTime(seconds: min(0.15, output.duration.seconds / 2), preferredTimescale: 600)
        guard let image = try? generator.copyCGImage(at: seek, actualTime: nil) else {
            throw Failure.coverFailed
        }
        guard let jpeg = UIImage(cgImage: image).jpegData(compressionQuality: 0.68),
              !jpeg.isEmpty, jpeg.count <= Int(ImpressCardVideoReference.maximumCoverBytes) else {
            throw Failure.coverFailed
        }
        let coverURL = directory.appendingPathComponent("cover.jpg")
        try jpeg.write(to: coverURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        let (videoBytes, videoHash) = try hashFile(outputURL,
            maximum: ImpressCardVideoReference.maximumBytes, job: job)
        let (coverBytes, coverHash) = try hashFile(coverURL,
            maximum: ImpressCardVideoReference.maximumCoverBytes, job: job)
        guard videoBytes > 0, coverBytes > 0 else { throw Failure.mediaIntegrityFailed }
        let reference = try ImpressCardVideoReference(
            mediaID: UUID(), cardID: request.cardID,
            contentRevision: request.expectedContentRevision,
            durationSeconds: asset.duration.seconds,
            trimStartSeconds: plan.trimStartSeconds, trimEndSeconds: plan.trimEndSeconds,
            codec: plan.codec, videoBytes: videoBytes, videoSHA256: videoHash,
            coverBytes: coverBytes, coverSHA256: coverHash)
        return Staged(reference: reference, movieURL: outputURL,
                      coverURL: coverURL, directoryURL: directory)
    }

    private static func hashFile(_ url: URL, maximum: UInt64, job: Job) throws -> (UInt64, String) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { handle.closeFile() }
        var hasher = SHA256()
        var count: UInt64 = 0
        while true {
            guard !job.isCancelled else { throw Failure.cancelled }
            let chunk = handle.readData(ofLength: 256 * 1024)
            if chunk.isEmpty { break }
            let (next, overflow) = count.addingReportingOverflow(UInt64(chunk.count))
            guard !overflow, next <= maximum else { throw Failure.outputTooLarge }
            count = next
            hasher.update(data: chunk)
        }
        return (count, hasher.finalize().map { String(format: "%02x", $0) }.joined())
    }
}
#endif
