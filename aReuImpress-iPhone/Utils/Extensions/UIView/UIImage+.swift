import UIKit

extension UIImage {
    func resized(withPercentage percentage: CGFloat) -> UIImage? {
        let newSize = CGSize(width: size.width * percentage, height: size.height * percentage)
        return resized(to: newSize)
    }

    func resized(toWidth width: CGFloat) -> UIImage? {
        let newSize = CGSize(width: width, height: CGFloat(ceil(width / size.width * size.height)))
        return resized(to: newSize)
    }

    private func resized(to newSize: CGSize) -> UIImage? {
        UIGraphicsBeginImageContextWithOptions(newSize, false, 0.0)
        draw(in: CGRect(origin: .zero, size: newSize))
        let newImage = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return newImage
    }

    /// 根据目标尺寸缩放图片，保持宽高比
    func scaled(to targetSize: CGSize) -> UIImage {
        let widthRatio = targetSize.width / size.width
        let heightRatio = targetSize.height / size.height
        let scaleFactor = min(widthRatio, heightRatio)

        let scaledSize = CGSize(width: size.width * scaleFactor, height: size.height * scaleFactor)

        UIGraphicsBeginImageContextWithOptions(scaledSize, false, scale)
        draw(in: CGRect(origin: .zero, size: scaledSize))
        let scaledImage = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()

        return scaledImage ?? self
    }

    /// 获取图片的内存大小（字节）
    var memorySize: Int {
        guard let cgImage = cgImage else { return 0 }
        return cgImage.bytesPerRow * cgImage.height
    }

    /// 检查图片是否有效
    var isValid: Bool {
        return size.width > 0 && size.height > 0 && cgImage != nil
    }
}


// MARK: - P1 · Photos picker image optimization
// Dimensions are actual pixels (not view points); never persist a full-size
// Photos original to the V3 WCDB BLOB. Files in Photos remain untouched.
enum ImpressImageOptimizationError: LocalizedError {
    case invalidImage, cannotEncode, exceedsLimit
    var errorDescription: String? {
        switch self {
        case .invalidImage: return "无法读取图片像素。"
        case .cannotEncode: return "图片编码失败，请选择另一张图片。"
        case .exceedsLimit: return "图片超出存储上限，请选择较小的图片。"
        }
    }
}

enum ImpressImageOptimizer {
    enum ContentKind { case photo, document }
    static let maximumEncodedBytes = 650 * 1024

    static func optimize(_ original: UIImage, kind: ContentKind = .photo,
                         maxBytes: Int = maximumEncodedBytes) throws -> Data {
        guard maxBytes >= 32 * 1024,
              original.size.width.isFinite, original.size.height.isFinite,
              original.size.width > 0, original.size.height > 0,
              original.cgImage != nil || original.ciImage != nil else {
            throw ImpressImageOptimizationError.invalidImage
        }

        let pixelsWide = CGFloat(original.cgImage?.width ?? Int(original.size.width * original.scale))
        let pixelsHigh = CGFloat(original.cgImage?.height ?? Int(original.size.height * original.scale))
        guard pixelsWide > 0, pixelsHigh > 0 else {
            throw ImpressImageOptimizationError.invalidImage
        }
        // Per-capture storage targets: thumbnails and simple photos should
        // ordinarily be under 240KB; legible text/document images have 480KB.
        // Both are stricter than the hard 650KB safety ceiling.
        let targetBytes = min(maxBytes, kind == .photo ? 240 * 1024 : 480 * 1024)
        let cap: CGFloat = (kind == .photo) ? 1280 : 2000
        let initialScale = min(1.0, cap / max(pixelsWide, pixelsHigh))
        var width = max(1, floor(pixelsWide * initialScale))
        var height = max(1, floor(pixelsHigh * initialScale))

        // Explicit renderer scale=1 creates width×height actual pixels,
        // independently of iPhone screen scale (which can be 2×/3×).
        for _ in 0..<6 {
            let config = UIGraphicsImageRendererFormat()
            config.scale = 1
            config.opaque = true
            let renderer = UIGraphicsImageRenderer(
                size: CGSize(width: width, height: height), format: config)
            let normalized = renderer.image { _ in
                UIColor.white.setFill()
                UIRectFill(CGRect(x: 0, y: 0, width: width, height: height))
                original.draw(in: CGRect(x: 0, y: 0, width: width, height: height))
            }
            let qualities: [CGFloat] = kind == .photo
                ? [0.26, 0.21, 0.16, 0.12]
                : [0.60, 0.48, 0.36, 0.27, 0.20]
            for quality in qualities {
                guard let data = normalized.jpegData(compressionQuality: quality) else {
                    throw ImpressImageOptimizationError.cannotEncode
                }
                if data.count <= targetBytes,
                   let decoded = UIImage(data: data), decoded.cgImage != nil {
                    return data
                }
            }
            // Bounded retries prevent unlimited CPU and memory consumption.
            width = max(1, floor(width * 0.80))
            height = max(1, floor(height * 0.80))
        }
        throw ImpressImageOptimizationError.exceedsLimit
    }
}
