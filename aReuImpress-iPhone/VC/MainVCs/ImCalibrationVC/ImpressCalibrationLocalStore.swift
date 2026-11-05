import Foundation
import ImpressReviewCore

enum ImpressCalibrationStoreError: Error {
    case conflictingDaySnapshot
    case closedDayImmutable
    case unsupportedVersion
    case durabilityFailure
    case invalidArchive
}

/// Actor-backed, private, atomic JSON ledger. This never writes Obsidian or FSRS.
actor ImpressCalibrationLocalStore {
    static let shared = ImpressCalibrationLocalStore()
    static let didChange = Notification.Name("impress.calibration.store.didChange")

    private struct Ledger: Codable {
        var version: Int = 1
        var goals: CalibrationGoals = CalibrationGoals()
        var days: [String: CalibrationDayCheckIn] = [:]
    }

    private let storageURL: URL

    init(storageURL: URL? = nil) {
        if let storageURL {
            self.storageURL = storageURL
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                                in: .userDomainMask).first!
            self.storageURL = base.appendingPathComponent("ImpressCalibration", isDirectory: true)
                                  .appendingPathComponent("checkins-v1.json")
        }
    }

    func goals() throws -> CalibrationGoals { try load().goals }

    func setGoals(_ value: CalibrationGoals) throws {
        try value.validate()
        var state = try load()
        state.goals = value
        let todayID = CalibrationDayCheckIn.dayID(for: Date(), calendar: Calendar.current)
        if var today = state.days[todayID],
           !today.isComplete, !today.isLegacyDay {
            try today.replaceGoalsForOpenDay(value)
            state.days[todayID] = today
        }
        try persist(state)
    }

    /// Absence of a row is never interpreted as a failure. Draft created only in memory.
    func checkIn(on date: Date = Date(),
                 calendar: Calendar = .current) throws -> CalibrationDayCheckIn {
        let state = try load()
        let dayID = CalibrationDayCheckIn.dayID(for: date, calendar: calendar)
        if let stored = state.days[dayID] {
            let todayID = CalibrationDayCheckIn.dayID(for: Date(), calendar: calendar)
            return stored.isLegacyDay && !stored.isComplete && dayID == todayID
                ? try stored.migratedToReading(goals: state.goals) : stored
        }
        return try CalibrationDayCheckIn(dayID: dayID, goals: state.goals)
    }

    func save(_ checkIn: CalibrationDayCheckIn) throws {
        // Validation rejects malformed dates, duplicate outcomes, and invalid moods.
        _ = try checkIn.finalizedScore()
        var state = try load()
        // The persisted record is authoritative, not a mutable UI snapshot.
        // Identical retries are idempotent; every different CLOSED record
        // (including adjustments, mood and legacy migration) is immutable.
        if let old = state.days[checkIn.dayID], old.isComplete {
            guard old == checkIn else {
                throw ImpressCalibrationStoreError.closedDayImmutable
            }
            return
        }
        if let old = state.days[checkIn.dayID],
           old.goalsSnapshot != checkIn.goalsSnapshot {
            let todayID = CalibrationDayCheckIn.dayID(for: Date())
            // Evaluate the throwing migration independently of the
            // short-circuit Boolean expression; no implicit throwing RHS.
            let migratedSnapshot = try old.migratedToReading(goals: state.goals).goalsSnapshot
            let migrationAllowed = old.isLegacyDay && !checkIn.isLegacyDay &&
                checkIn.dayID == todayID &&
                migratedSnapshot == checkIn.goalsSnapshot &&
                checkIn.retiredCustomAssessment == old.assessments.first(where: {
                    $0.taskID == CalibrationIndicator.custom.rawValue
                })
            guard migrationAllowed else {
                throw ImpressCalibrationStoreError.conflictingDaySnapshot
            }
        }
        state.days[checkIn.dayID] = checkIn
        try persist(state)
    }

    func completedDayIDs() throws -> Set<String> {
        Set(try load().days.values.filter { $0.isComplete }.map(\.dayID))
    }

    func history() throws -> [CalibrationDayCheckIn] {
        try load().days.values.sorted { $0.dayID < $1.dayID }
    }

    /// Historical legacy days retain their old mood-closeout scoring gate;
    /// live days close after all four behaviors are explicitly assessed.
    func trendRecords() throws -> [CalibrationDailyRecord] {
        try history().map { entry in
            if entry.isComplete { return entry.rawRecord }
            return CalibrationDailyRecord(
                dayID: entry.dayID,
                assessments: [CalibrationTaskAssessment(
                    taskID: "pending.checkin", outcome: .unrecorded)])
        }
    }

    /// A local V3.2 archive owns a complete, independently validated ledger.
    /// An absent ledger becomes a valid empty snapshot; it is never a zero score.
    static func canonicalURL() -> URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        return root.appendingPathComponent("ImpressCalibration", isDirectory: true)
            .appendingPathComponent("checkins-v1.json")
    }

    static func validateArchiveData(_ bytes: Data) throws -> Int {
        let state = try JSONDecoder().decode(Ledger.self, from: bytes)
        guard state.version == 1 else { throw ImpressCalibrationStoreError.unsupportedVersion }
        try state.goals.validate()
        for (dayID, checkIn) in state.days {
            guard dayID == checkIn.dayID,
                  (Set(checkIn.assessments.map(\.taskID)) ==
                       Set(CalibrationIndicator.behaviorIndicators.map(\.rawValue)) ||
                   Set(checkIn.assessments.map(\.taskID)) ==
                       Set(CalibrationIndicator.legacyBehaviorIndicators.map(\.rawValue))),
                  checkIn.assessments.count == 4 else {
                throw ImpressCalibrationStoreError.invalidArchive
            }
            try checkIn.goalsSnapshot.validate()
            _ = try checkIn.finalizedScore()
        }
        return state.days.count
    }

    func archiveData() throws -> Data {
        let bytes: Data
        if FileManager.default.fileExists(atPath: storageURL.path) {
            bytes = try Data(contentsOf: storageURL)
        } else {
            bytes = try JSONEncoder().encode(Ledger())
        }
        _ = try Self.validateArchiveData(bytes)
        return bytes
    }

    private func load() throws -> Ledger {
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return Ledger() }
        let data = try Data(contentsOf: storageURL)
        let state = try JSONDecoder().decode(Ledger.self, from: data)
        guard state.version == 1 else { throw ImpressCalibrationStoreError.unsupportedVersion }
        return state
    }

    private func persist(_ state: Ledger) throws {
        try FileManager.default.createDirectory(
            at: storageURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(state)
        try data.write(to: storageURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: storageURL.path)
        // Report a successful update only after a valid, equal round-trip.
        let verified = try JSONDecoder().decode(
            Ledger.self, from: Data(contentsOf: storageURL))
        guard verified.version == state.version,
              verified.goals == state.goals,
              verified.days == state.days else {
            throw ImpressCalibrationStoreError.durabilityFailure
        }
        // Only committed updates participate in the existing V3 backup cadence.
        ImpressV3BackupCoordinator.markDataChanged()
        NotificationCenter.default.post(name: Self.didChange, object: nil)
        // Only canonical durable saves publish shared widget status; QA fixtures never do.
        if storageURL.standardizedFileURL == Self.canonicalURL().standardizedFileURL {
            Task(priority: .utility) {
                await ImpressCalibrationWidgetExporter.publishFromAuthoritativeStore()
            }
        }
        Task { @MainActor in
            ImpressCalibrationReminderCoordinator.shared.requestReconciliation()
        }
    }
}
