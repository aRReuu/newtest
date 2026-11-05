import Foundation

/// V3 is the sole live data source. Old files remain untouched on disk,
/// but no legacy database or screen is initialized for the current app.
enum ImpressV3ReviewEnvironment {
    // Kept as a compile-only compatibility surface for inactive legacy views.
    static var pilotEnabled: Bool {
        get { true }
        set { /* The old debug flag cannot switch back to legacy storage. */ }
    }

    static let databaseResult: Result<ReviewWCDBRepository, Swift.Error> = Result {
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        #if DEBUG
        if let fixture = ImpressV11UITestFixture.databaseURL {
            try FileManager.default.createDirectory(
                at: fixture.deletingLastPathComponent(), withIntermediateDirectories: true)
            return try ReviewWCDBRepository(databasePath: fixture.path,
                calculator: FSRS6ReviewCalculator())
        }
        #endif
        let path = root.appendingPathComponent("ImpressV3/ReviewV3.sqlite").path
        return try ReviewWCDBRepository(databasePath: path, calculator: FSRS6ReviewCalculator())
    }

    static func repository() throws -> ReviewWCDBRepository {
        try databaseResult.get()
    }
}
