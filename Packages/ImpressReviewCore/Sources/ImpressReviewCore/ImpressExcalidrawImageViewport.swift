import Foundation

/// Excalidraw crop metadata is source-authored but never executable.
/// Cropping is a read-only viewport operation; image data is not copied to Chat.
public struct ImpressExcalidrawImageCrop: Codable, Sendable, Equatable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
    public let naturalWidth: Double
    public let naturalHeight: Double
}

/// Converts the author's crop/flip values into the local, clipped native viewport.
/// The same mathematical mapping is used by DiagramReader's inline SVG renderer.
public struct ImpressExcalidrawImageViewport: Sendable, Equatable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
    public let flipX: Double
    public let flipY: Double

    public static func placement(displayWidth: Double, displayHeight: Double,
                                 naturalWidth: Double, naturalHeight: Double,
                                 crop: ImpressExcalidrawImageCrop?,
                                 scale: [Double]?) -> Self? {
        guard [displayWidth, displayHeight, naturalWidth, naturalHeight].allSatisfy({
            $0.isFinite && $0 > 0
        }), displayWidth <= 12_000, displayHeight <= 12_000,
            naturalWidth <= 4_096, naturalHeight <= 4_096,
            naturalWidth * naturalHeight <= 4_000_000 else { return nil }
        let authoredFlip = scale ?? [1, 1]
        guard authoredFlip.count == 2,
              authoredFlip.allSatisfy({ $0 == 1 || $0 == -1 }) else { return nil }

        guard let crop else {
            return Self(x: 0, y: 0, width: displayWidth, height: displayHeight,
                        flipX: authoredFlip[0], flipY: authoredFlip[1])
        }
        let values = [crop.x, crop.y, crop.width, crop.height,
                      crop.naturalWidth, crop.naturalHeight]
        guard values.allSatisfy(\.isFinite),
              crop.x >= 0, crop.y >= 0, crop.width > 0, crop.height > 0,
              crop.naturalWidth == naturalWidth,
              crop.naturalHeight == naturalHeight,
              crop.x + crop.width <= naturalWidth + 1e-6,
              crop.y + crop.height <= naturalHeight + 1e-6 else { return nil }
        let ratioX = displayWidth / crop.width
        let ratioY = displayHeight / crop.height
        let imageWidth = naturalWidth * ratioX
        let imageHeight = naturalHeight * ratioY
        let imageX = -crop.x * ratioX
        let imageY = -crop.y * ratioY
        guard [imageX, imageY, imageWidth, imageHeight].allSatisfy(\.isFinite),
              imageWidth <= 60_000, imageHeight <= 60_000 else { return nil }
        return Self(x: imageX, y: imageY, width: imageWidth,
                    height: imageHeight, flipX: authoredFlip[0],
                    flipY: authoredFlip[1])
    }
}
