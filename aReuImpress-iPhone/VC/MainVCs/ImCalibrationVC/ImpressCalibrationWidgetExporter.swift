import Foundation
import WidgetKit
import ImpressReviewCore

/// A strictly one-way, privacy-reduced status export.
/// Only the canonical App actor writes checkins-v1.json; WidgetKit reads a derivative cache.
enum ImpressCalibrationWidgetExporter {
    static let groupID = "group.areu.impress"
    static let snapshotName = "calibration-widget-v1.json"
    static let kinds = ["impress.calibration.week",
                        "impress.calibration.month",
                        "impress.calibration.year"]
    private static let publisher = SnapshotPublisher()

    enum Availability: Equatable {
        case ready, missingAppGroup, missingSnapshot, invalidSnapshot
    }

    /// Shared App Group is a signing entitlement, not a mere source-code flag.
    /// An unsigned / improperly re-signed app cannot repair this in Swift.
    static func availability() -> Availability {
        guard let root = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: groupID) else { return .missingAppGroup }
        guard let bytes = try? Data(contentsOf: root.appendingPathComponent(snapshotName))
        else { return .missingSnapshot }
        guard let snapshot = try? JSONDecoder().decode(CalibrationWidgetSnapshot.self, from: bytes),
              CalibrationWidgetProjection.overview(from: snapshot, at: Date(),
                calendar: Calendar.current) != nil else { return .invalidSnapshot }
        return .ready
    }

    /// A successful App-side container write is not proof that the Widget
    /// extension can read it after signing or AltStore re-signing.
    static func verifiedWidgetReadbacks(at now: Date = Date()) -> Set<CalibrationWidgetPeriod> {
        guard let root = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: groupID),
              let data = try? Data(contentsOf: root.appendingPathComponent(snapshotName)),
              let snapshot = try? JSONDecoder().decode(CalibrationWidgetSnapshot.self, from: data),
              CalibrationWidgetProjection.overview(from: snapshot, at: now,
                                                   calendar: Calendar.current) != nil else {
            return []
        }
        return Set(CalibrationWidgetPeriod.allCases.filter { period in
            let url = root.appendingPathComponent(
                "calibration-widget-\(period.rawValue)-readback-v1.json")
            guard let bytes = try? Data(contentsOf: url),
                  let receipt = try? JSONDecoder().decode(
                      CalibrationWidgetReadReceipt.self, from: bytes) else { return false }
            return receipt.verifies(snapshot: snapshot, period: period, at: now)
        })
    }

    static func publishFromAuthoritativeStore() async {
        do {
            let entries = try await ImpressCalibrationLocalStore.shared.history()
            let snapshot = CalibrationWidgetProjection.snapshot(
                from: entries, at: Date(), calendar: Calendar.current)
            guard snapshot.isValid else { return }
            // Serialize the shared-file check and atomic write across coalesced App updates;
            // a slow older publish must never overwrite a newer validated snapshot.
            if try await publisher.publishIfNewer(snapshot) {
                for kind in kinds { WidgetCenter.shared.reloadTimelines(ofKind: kind) }
            }
        } catch {
            // App data is already durably saved. An absent App Group on an unsigned
            // or free-profile install cannot grant Widget write access to the source.
            NSLog("Calibration widget projection unavailable: %@", error.localizedDescription)
        }
    }

    // Debug-only isolated Widget-cache write path. This invokes the exact production
    // serialization and monotonic overwrite guard without touching App Group storage
    // or calling WidgetKit. Required for cold-backup-restore fault-injection QA.
    #if DEBUG
    static func testPublishFixtureSnapshot(
        _ snapshot: CalibrationWidgetSnapshot, into isolatedRoot: URL
    ) async throws -> Bool {
        try await publisher.publishIfNewer(snapshot, isolatedTestRoot: isolatedRoot)
    }
    #endif

    /// Serializes all producer tasks in this process, without touching the source ledger.
    private actor SnapshotPublisher {
        func publishIfNewer(
            _ snapshot: CalibrationWidgetSnapshot, isolatedTestRoot: URL? = nil
        ) throws -> Bool {
            guard let root = isolatedTestRoot ?? FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: ImpressCalibrationWidgetExporter.groupID)
            else {
                throw NSError(domain: "ImpressWidgetAppGroup", code: 1,
                    userInfo: [NSLocalizedDescriptionKey:
                        "App Group group.areu.impress is unavailable to this signed process"])
            }
            try FileManager.default.createDirectory(
                at: root, withIntermediateDirectories: true)
            let url = root.appendingPathComponent(
                ImpressCalibrationWidgetExporter.snapshotName)
            if let oldBytes = try? Data(contentsOf: url),
               let prior = try? JSONDecoder().decode(
                   CalibrationWidgetSnapshot.self, from: oldBytes), prior.isValid {
                if prior.generatedAt > snapshot.generatedAt { return false }
                // Do not invalidate a valid timeline receipt on repeated
                // foreground refresh within the same unchanged civil day.
                if prior.days == snapshot.days &&
                   prior.timeZoneID == snapshot.timeZoneID &&
                   prior.calendarID == snapshot.calendarID &&
                   Calendar.current.isDate(prior.generatedAt, inSameDayAs: snapshot.generatedAt) {
                    return false
                }
            }
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: url.path)
            let checked = try JSONDecoder().decode(
                CalibrationWidgetSnapshot.self, from: Data(contentsOf: url))
            guard checked == snapshot && checked.isValid else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return true
        }
    }
}
