import Foundation

/// Pure, deterministic sizing decisions shared by the editor and the offline
/// AVFoundation exporter. This is an estimate, NEVER proof of encoded bytes.
/// The exporter must measure the final file and enforce `maximumBytes` again.
public enum ImpressCardVideoEncodingBudget {
    public enum Error: Swift.Error, Equatable {
        case invalidSource, invalidTrim, codecUnavailable
        case needsShorterClipOrLowerQuality, notEnoughTemporarySpace
    }

    public enum Preference: String, Codable, Sendable { case balanced, compact }

    public struct Source: Equatable, Sendable {
        public let durationSeconds: Double
        public let width: Int
        public let height: Int
        public let hasAudio: Bool
        public let trimStartSeconds: Double
        public let trimEndSeconds: Double
        public let availableTemporaryBytes: UInt64
        public let canEncodeHEVC: Bool
        public let canEncodeH264: Bool
        public let preference: Preference

        public init(durationSeconds: Double, width: Int, height: Int, hasAudio: Bool,
                    trimStartSeconds: Double, trimEndSeconds: Double,
                    availableTemporaryBytes: UInt64,
                    canEncodeHEVC: Bool, canEncodeH264: Bool,
                    preference: Preference = .balanced) {
            self.durationSeconds = durationSeconds
            self.width = width
            self.height = height
            self.hasAudio = hasAudio
            self.trimStartSeconds = trimStartSeconds
            self.trimEndSeconds = trimEndSeconds
            self.availableTemporaryBytes = availableTemporaryBytes
            self.canEncodeHEVC = canEncodeHEVC
            self.canEncodeH264 = canEncodeH264
            self.preference = preference
        }
    }

    public struct Plan: Equatable, Sendable {
        public let codec: ImpressCardVideoReference.Codec
        public let durationSeconds: Double
        public let trimStartSeconds: Double
        public let trimEndSeconds: Double
        public let targetWidth: Int
        public let targetHeight: Int
        public let videoBitrate: Int
        public let audioBitrate: Int
        public let estimatedBytes: UInt64
        public let requiredTemporaryBytes: UInt64
        public let exceedsPreferredSize: Bool
    }

    private static let mebibyte: UInt64 = 1_048_576

    /// AVAssetTrack naturalSize / preferredTransform can be corrupt or
    /// non-finite. Bound the raster before converting it to Int; otherwise a
    /// malformed movie can trap the exporter instead of reporting an error.
    static func validatedSourceDimensions(widthPixels: Double,
                                          heightPixels: Double) throws -> (width: Int, height: Int) {
        let width = widthPixels.rounded()
        let height = heightPixels.rounded()
        guard width.isFinite, height.isFinite,
              (64.0...16_384.0).contains(width),
              (64.0...16_384.0).contains(height) else {
            throw Error.invalidSource
        }
        return (Int(width), Int(height))
    }

    /// AVFoundation can report malformed, finite-but-enormous nominal FPS.
    /// Clamp *before* Int conversion to avoid a Swift runtime trap.
    static func safeNominalFrameRate(_ nominalFPS: Double) -> Int {
        guard nominalFPS.isFinite, nominalFPS > 0 else { return 30 }
        return max(1, Int(min(30.0, nominalFPS.rounded())))
    }

    /// Preserve exact source trim endpoints; do not introduce a duration limit.
    /// Encode quality/space decisions are provisional and must be validated
    /// against the real iPhone 13 / MP4 exporter before product constants freeze.
    public static func propose(_ source: Source) throws -> Plan {
        guard source.durationSeconds.isFinite, source.durationSeconds > 0,
              (64...16384).contains(source.width), (64...16384).contains(source.height) else {
            throw Error.invalidSource
        }
        guard source.trimStartSeconds.isFinite, source.trimEndSeconds.isFinite,
              source.trimStartSeconds >= 0,
              source.trimEndSeconds > source.trimStartSeconds,
              source.trimEndSeconds <= source.durationSeconds else {
            throw Error.invalidTrim
        }
        guard source.canEncodeHEVC || source.canEncodeH264 else {
            throw Error.codecUnavailable
        }
        let codec: ImpressCardVideoReference.Codec = source.canEncodeHEVC ? .hevc : .h264
        let duration = source.trimEndSeconds - source.trimStartSeconds
        let longEdge = max(source.width, source.height)
        let preferredEdge: Int
        switch duration {
        case ...300: preferredEdge = 1280
        case ...1200: preferredEdge = 960
        default: preferredEdge = 720
        }
        let maximumEdge = source.preference == .compact ? min(720, preferredEdge) : preferredEdge
        let outputEdge = min(longEdge, maximumEdge)
        // Preserve aspect ratio without upscaling. Both dimensions must be even
        // for commonly available H.264/HEVC 4:2:0 hardware pipelines.
        let scale = Double(outputEdge) / Double(longEdge)
        func evenDimension(_ input: Int) -> Int {
            max(2, Int((Double(input) * scale / 2).rounded(.down)) * 2)
        }
        let width = evenDimension(source.width)
        let height = evenDimension(source.height)
        let pixels = Double(width) * Double(height)
        let minVideoBitrate = max(codec == .hevc ? 240_000 : 360_000,
                                  Int(pixels * (codec == .hevc ? 0.55 : 0.78)))
        let maxVideoBitrate = codec == .hevc ? 2_000_000 : 2_800_000
        let audioBitrate = source.hasAudio ? 64_000 : 0
        let preferred = source.preference == .compact
            ? ImpressCardVideoReference.preferredBytes / 2
            : ImpressCardVideoReference.preferredBytes
        // A conservative 10% mux/metadata safety margin is *only* an estimate.
        let budgetVideoBitrate = ((Double(preferred) * 8.0 / 1.10 / duration) - Double(audioBitrate))
        guard budgetVideoBitrate.isFinite else {
            throw Error.needsShorterClipOrLowerQuality
        }
        let videoBitrate = Int(max(Double(minVideoBitrate),
                                   min(Double(maxVideoBitrate), budgetVideoBitrate)))
        let estimated = Double(videoBitrate + audioBitrate) * duration / 8.0 * 1.10
        guard estimated.isFinite, estimated > 0,
              estimated <= Double(ImpressCardVideoReference.maximumBytes) else {
            throw Error.needsShorterClipOrLowerQuality
        }
        let estimatedBytes = UInt64(estimated.rounded(.up))
        // Reserve for encoded .partial, another transient generation/atomic swap,
        // plus a fixed container/thumbnail allowance. Do not silently reclaim
        // the original source file or depend on purgeable iCloud availability.
        let (twice, overflows) = estimatedBytes.multipliedReportingOverflow(by: 2)
        guard !overflows else { throw Error.notEnoughTemporarySpace }
        let (required, overflow) = twice.addingReportingOverflow(16 * mebibyte)
        guard !overflow, source.availableTemporaryBytes >= required else {
            throw Error.notEnoughTemporarySpace
        }
        return Plan(codec: codec, durationSeconds: duration,
                    trimStartSeconds: source.trimStartSeconds,
                    trimEndSeconds: source.trimEndSeconds,
                    targetWidth: width, targetHeight: height,
                    videoBitrate: videoBitrate, audioBitrate: audioBitrate,
                    estimatedBytes: estimatedBytes,
                    requiredTemporaryBytes: required,
                    exceedsPreferredSize: estimatedBytes > preferred)
    }
}
