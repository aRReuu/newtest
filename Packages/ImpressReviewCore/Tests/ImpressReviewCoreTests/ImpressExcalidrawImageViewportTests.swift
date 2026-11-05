import Foundation
import Testing
@testable import ImpressReviewCore

@Suite("Excalidraw native bitmap viewport bounds and authored mirror")
struct ImpressExcalidrawImageViewportTests {
    @Test func cropAndMirrorMatchAuthoredCoordinates() {
        let crop = ImpressExcalidrawImageCrop(
            x: 100, y: 50, width: 400, height: 300,
            naturalWidth: 800, naturalHeight: 600)
        let placement = ImpressExcalidrawImageViewport.placement(
            displayWidth: 200, displayHeight: 150,
            naturalWidth: 800, naturalHeight: 600,
            crop: crop, scale: [-1, 1])
        #expect(placement?.x == -50)
        #expect(placement?.y == -25)
        #expect(placement?.width == 400)
        #expect(placement?.height == 300)
        #expect(placement?.flipX == -1)
        #expect(placement?.flipY == 1)
    }

    @Test func unmodifiedImageAndIllegalCropFailClosed() {
        let ordinary = ImpressExcalidrawImageViewport.placement(
            displayWidth: 200, displayHeight: 150,
            naturalWidth: 800, naturalHeight: 600,
            crop: nil, scale: nil)
        #expect(ordinary?.x == 0)
        #expect(ordinary?.width == 200)
        let crop = ImpressExcalidrawImageCrop(
            x: 100, y: 50, width: 400, height: 300,
            naturalWidth: 800, naturalHeight: 600)
        #expect(ImpressExcalidrawImageViewport.placement(
            displayWidth: 200, displayHeight: 150,
            naturalWidth: 801, naturalHeight: 600,
            crop: crop, scale: [-1, 1]) == nil)
        #expect(ImpressExcalidrawImageViewport.placement(
            displayWidth: 200, displayHeight: 150,
            naturalWidth: 800, naturalHeight: 600,
            crop: crop, scale: [2, 1]) == nil)
        let invalid = ImpressExcalidrawImageCrop(
            x: 500, y: 50, width: 400, height: 300,
            naturalWidth: 800, naturalHeight: 600)
        #expect(ImpressExcalidrawImageViewport.placement(
            displayWidth: 200, displayHeight: 150,
            naturalWidth: 800, naturalHeight: 600,
            crop: invalid, scale: nil) == nil)
    }
}
