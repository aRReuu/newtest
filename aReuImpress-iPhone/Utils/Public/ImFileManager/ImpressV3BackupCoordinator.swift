import Foundation
import CryptoKit
import WCDBSwift
import ImpressReviewCore

/// Recovered totals reflect the archive, not the device's active database.
struct ImpressV3BackupInspection {
    let manifest: ImpressV3BackupManifest
    let cardCount: Int
    let reviewCount: Int
    let learningCount: Int
    /// Nil for V1 archives: do not erase existing calibration data.
    let calibrationCount: Int?
}

/// File-provider access uses an explicit, user-selected Files folder. The
/// application never sends data to an HTTP endpoint or stores API credentials.
actor ImpressV3BackupCoordinator {
    static let shared = ImpressV3BackupCoordinator()

    static let bookmarkKey = "ImpressV3BackupCloudFolderBookmark"
    static let dirtyKey = "ImpressV3BackupNeedsSnapshot"
    static let localDateKey = "ImpressV3BackupLocalDate"
    static let cloudDateKey = "ImpressV3BackupCloudCopiedDate"
    static let failureKey = "ImpressV3BackupLastError"
    private static let mutationGenerationKey = "ImpressV3LastMutationGeneration"
    static let recoveryBlockKey = "ImpressV3RestoreRecoveryBlocked"
    private static let mutationLock = NSLock()
    private static let pendingCloudFileKey = "ImpressV3PendingCloudFile"

    private var active: Task<URL, any Swift.Error>?
    private var pendingDebouncedBackup: Task<Void, Never>?
    // Actor methods may re-enter at createBackup/extract awaits. A second
    // explicit recovery must not stage against the same pre-restore snapshot.
    private var stagingRecovery = false

    private func withExclusiveRestoreStage<T>(
        _ operation: () async throws -> T
    ) async throws -> T {
        guard !stagingRecovery else {
            throw ImpressV3BackupFailure.restoreAlreadyPending
        }
        stagingRecovery = true
        defer { stagingRecovery = false }
        return try await operation()
    }

    #if DEBUG
    /// Exercises the same staging lease with an isolated suspended operation;
    /// the test must never open or modify the user's App Support database.
    func testWithExclusiveRestoreStage(
        _ operation: () async throws -> Void
    ) async throws {
        try await withExclusiveRestoreStage(operation)
    }
    #endif

    static func markDataChanged() {
        // An opaque generation avoids timestamp equality during dense commits.
        // Both the write and the post-snapshot acknowledgement share one lock.
        mutationLock.lock()
        UserDefaults.standard.set(UUID().uuidString, forKey: mutationGenerationKey)
        UserDefaults.standard.set(true, forKey: dirtyKey)
        mutationLock.unlock()
        Task(priority: .utility) {
            await shared.scheduleDebouncedBackup()
        }
    }

    private static func snapshotGeneration() -> String {
        mutationLock.lock()
        defer { mutationLock.unlock() }
        return UserDefaults.standard.string(forKey: mutationGenerationKey) ?? ""
    }

    @discardableResult
    private static func reconcileSnapshotDirty(
        startingGeneration: String, defaults: UserDefaults
    ) -> Bool {
        mutationLock.lock()
        defer { mutationLock.unlock() }
        let changed = (defaults.string(forKey: mutationGenerationKey) ?? "") != startingGeneration
        defaults.set(changed, forKey: dirtyKey)
        return changed
    }

    #if DEBUG
    static func testReconcileSnapshotDirty(
        startingGeneration: String, defaults: UserDefaults
    ) -> Bool {
        reconcileSnapshotDirty(startingGeneration: startingGeneration, defaults: defaults)
    }
    #endif

    private func scheduleDebouncedBackup() {
        pendingDebouncedBackup?.cancel()
        let last = UserDefaults.standard.object(forKey: Self.localDateKey) as? Date
        let elapsed = Date().timeIntervalSince(last ?? .distantPast)
        let waitSeconds = max(45, 20 * 60 - elapsed)
        pendingDebouncedBackup = Task(priority: .utility) { [self] in
            do { try await Task.sleep(nanoseconds: UInt64(waitSeconds * 1_000_000_000)) }
            catch { return }
            guard !Task.isCancelled else { return }
            await self.backupIfNeeded()
            // If a mutation landed mid-snapshot, keep it pending until the
            // next eligible interval even without leaving the foreground.
            let stillDirty = UserDefaults.standard.bool(forKey: Self.dirtyKey)
            let sinceLast = Date().timeIntervalSince(
                (UserDefaults.standard.object(forKey: Self.localDateKey) as? Date)
                    ?? .distantPast)
            if stillDirty && sinceLast < 20 * 60 {
                self.scheduleDebouncedBackup()
            }
        }
    }

    static func supportDirectory() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true)
    }

    static func localDirectory() throws -> URL {
        let root = try supportDirectory().appendingPathComponent(
            "ImpressV3Backups", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true)
        return root
    }

    static func mostRecentLocalBackup() -> URL? {
        guard let root = try? localDirectory(),
              let files = try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil)
        else { return nil }
        return files.filter { $0.lastPathComponent.hasPrefix("ImpressV3-") &&
                              $0.pathExtension == "zip" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }.first
    }

    static var cloudFolderSelected: Bool {
        UserDefaults.standard.data(forKey: bookmarkKey) != nil
    }

    static func connectCloudFolder(_ selected: URL) throws {
        guard selected.startAccessingSecurityScopedResource() else {
            throw ImpressV3BackupFailure.notAuthorized
        }
        defer { selected.stopAccessingSecurityScopedResource() }
        let bookmark = try selected.bookmarkData(options: [],
            includingResourceValuesForKeys: nil, relativeTo: nil)
        UserDefaults.standard.set(bookmark, forKey: bookmarkKey)
    }

    static func disconnectCloudFolder() {
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
        UserDefaults.standard.removeObject(forKey: pendingCloudFileKey)
    }

    /// Called at launch and after data changes; no UI or export panel.
    /// One local snapshot is retained even without Files authorization.
    func backupIfNeeded() async {
        do {
            let dirty = UserDefaults.standard.bool(forKey: Self.dirtyKey)
            let previous = Self.mostRecentLocalBackup()
            let last = UserDefaults.standard.object(forKey: Self.localDateKey) as? Date
            let elapsed = Date().timeIntervalSince(last ?? .distantPast)
            if previous == nil || (dirty && elapsed >= 20 * 60) {
                _ = try await createBackup(force: true)
            } else if Self.cloudFolderSelected {
                // Retry the exact last failed local snapshot, rather than
                // assuming an old successful cloud timestamp is up to date.
                let pendingName = UserDefaults.standard.string(
                    forKey: Self.pendingCloudFileKey)
                let pending = pendingName.flatMap { name -> URL? in
                    guard name.hasPrefix("ImpressV3-"), name.hasSuffix(".zip"),
                          !name.contains("/") else { return nil }
                    let item = try? Self.localDirectory().appendingPathComponent(name)
                    guard let item, FileManager.default.fileExists(atPath: item.path) else {
                        return nil
                    }
                    return item
                }
                if let candidate = pending ?? previous,
                   pending != nil ||
                   UserDefaults.standard.object(forKey: Self.cloudDateKey) == nil {
                    try Self.copyToAuthorizedCloud(candidate)
                }
            }
        } catch {
            UserDefaults.standard.set(error.localizedDescription, forKey: Self.failureKey)
        }
    }

    func createBackup(force: Bool = true) async throws -> URL {
        #if DEBUG
        // The visible Settings export/restore path is also exercised by the
        // synthetic UI fixture. Never export live prompts, calibration or the
        // real backup directory into a disposable QA archive.
        if let fixture = ImpressV11UITestFixture.coldRestorePaths {
            return try await buildSyntheticSnapshot(
                paths: fixture, repository: ImpressV3ReviewEnvironment.repository())
        }
        #endif
        if let active { return try await active.value }
        if !force && !UserDefaults.standard.bool(forKey: Self.dirtyKey),
           let recent = Self.mostRecentLocalBackup() {
            return recent
        }
        let job = Task(priority: .utility) { try await self.buildSnapshot() }
        active = job
        do {
            let result = try await job.value
            active = nil
            return result
        } catch {
            active = nil
            UserDefaults.standard.set(error.localizedDescription, forKey: Self.failureKey)
            throw error
        }
    }

    #if DEBUG
    typealias SyntheticRestorePaths = (
        support: URL, documents: URL, calibration: URL,
        database: URL, promptsSuiteName: String
    )

    /// Exact same ZIP/manifest/checksum + WCDB backup implementation, but all
    /// inputs and outputs are synthetic. Real learning history or prompt keys
    /// must NEVER enter this fixture; Chat/Card/FSRS receipts reside in WCDB.
    private func buildSyntheticSnapshot(
        paths: SyntheticRestorePaths,
        repository: ReviewWCDBRepository
    ) async throws -> URL {
        let fm = FileManager.default
        let root = paths.support.appendingPathComponent(
            "ImpressV3Backups", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let staging = root.appendingPathComponent(
            ".fixture-stage-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        let db = staging.appendingPathComponent("ReviewV3.sqlite")
        try await repository.createConsistentBackup(to: db)
        try ImpressV3BackupArchive.verifySQLite(db)
        try JSONEncoder().encode([ImpressV3LearningEntry]()).write(
            to: staging.appendingPathComponent("LearningEntry-v1.json"), options: .atomic)
        guard let defaults = UserDefaults(suiteName: paths.promptsSuiteName) else {
            throw ImpressV3BackupFailure.notAuthorized
        }
        let prompts: Data
        if let saved = defaults.data(forKey: ImpressV3PromptLibrary.storageKey) {
            _ = try JSONDecoder().decode([ImpressV3PromptTemplate].self, from: saved)
            prompts = saved
        } else {
            prompts = try JSONEncoder().encode([ImpressV3PromptTemplate]())
        }
        try prompts.write(to: staging.appendingPathComponent("prompts.json"), options: .atomic)
        let calibration = try await ImpressCalibrationLocalStore(
            storageURL: paths.calibration).archiveData()
        try calibration.write(to: staging.appendingPathComponent("checkins-v1.json"),
                              options: .atomic)
        let mediaNames = try Self.stageCardVideoFiles(
            database: db, staging: staging, support: paths.support)
        let names = ["ReviewV3.sqlite", "LearningEntry-v1.json",
                     "prompts.json", "checkins-v1.json"] + mediaNames
        let records = try names.map { try ImpressV3BackupArchive.inspectFile(
            staging.appendingPathComponent($0), name: $0).0 }
        try JSONEncoder().encode(ImpressV3BackupManifest.make(records)).write(
            to: staging.appendingPathComponent("manifest.json"), options: .atomic)
        let output = root.appendingPathComponent(
            "ImpressV3-" + UUID().uuidString + "-fixture.zip")
        let partial = root.appendingPathComponent(".partial-" + UUID().uuidString)
        defer { try? fm.removeItem(at: partial) }
        try ImpressV3BackupArchive.write(
            files: (names + ["manifest.json"]).map {
                (name: $0, url: staging.appendingPathComponent($0))
            }, destination: partial)
        let verification = staging.appendingPathComponent("verified", isDirectory: true)
        _ = try ImpressV3BackupArchive.extract(source: partial, destination: verification)
        try ImpressV3BackupArchive.verifySQLite(
            verification.appendingPathComponent("ReviewV3.sqlite"))
        _ = try ImpressCalibrationLocalStore.validateArchiveData(Data(contentsOf:
            verification.appendingPathComponent("checkins-v1.json")))
        try fm.moveItem(at: partial, to: output)
        return output
    }

    /// Native test uses a separately constructed disposable WCDB repository.
    func testCreateFixtureBackup(
        paths: SyntheticRestorePaths,
        repository: ReviewWCDBRepository
    ) async throws -> URL {
        try await buildSyntheticSnapshot(paths: paths, repository: repository)
    }
    #endif

    /// Only files referenced by the consistent SQLite backup may enter ZIP.
    /// All copies are re-hashed after staging; an incomplete backup is rejected.
    private static func stageCardVideoFiles(database: URL, staging: URL,
                                            support: URL) throws -> [String] {
        let index = try ImpressV3BackupArchive.mediaIndex(forSQLite: database)
        guard !index.references.isEmpty else { return [] }
        let store = try ImpressCardVideoPrivateStore(rootURL:
            support.appendingPathComponent("ImpressCardMedia", isDirectory: true))
        var seen = Set<UUID>()
        var files = [ImpressV3BackupFileRecord]()
        for ref in index.references where seen.insert(ref.mediaID).inserted {
            let verified = try store.verifiedPlayback(
                cardID: ref.cardID, contentRevision: ref.contentRevision, reference: ref)
            for (name, source, size, digest) in [
                (ref.videoRelativePath, verified.movieURL, ref.videoBytes, ref.videoSHA256),
                (ref.coverRelativePath, verified.coverURL, ref.coverBytes, ref.coverSHA256)
            ] {
                let target = staging.appendingPathComponent(name)
                try FileManager.default.createDirectory(
                    at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: source, to: target)
                let record = try ImpressV3BackupArchive.inspectFile(target, name: name).0
                guard record.size == size && record.sha256 == digest else {
                    throw ImpressV3BackupFailure.invalidChecksum
                }
                files.append(record)
            }
        }
        try index.validateExtractedFiles(files.map {
            ImpressCardVideoArchiveIndex.File(name: $0.name,
                                              bytes: $0.size, sha256: $0.sha256)
        })
        let encoded = try JSONEncoder().encode(index)
        guard encoded.count <= 64 * 1024 else { throw ImpressV3BackupFailure.unsafeSize }
        try encoded.write(to: staging.appendingPathComponent("media-index.json"),
                          options: .atomic)
        return ["media-index.json"] + files.map(\.name)
    }

    private func buildSnapshot() async throws -> URL {
        let mutationAtStart = Self.snapshotGeneration()
        let root = try Self.localDirectory()
        let staging = root.appendingPathComponent(".stage-" + UUID().uuidString,
                                                   isDirectory: true)
        try FileManager.default.createDirectory(
            at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let database = staging.appendingPathComponent("ReviewV3.sqlite")
        let repository = try ImpressV3ReviewEnvironment.repository()
        // The WCDB actor serializes this with any pending FSRS commits.
        try await repository.createConsistentBackup(to: database)
        try ImpressV3BackupArchive.verifySQLite(database)

        let history = try JSONEncoder().encode(ImpressV3LearningJournal.load())
        try history.write(to: staging.appendingPathComponent("LearningEntry-v1.json"),
                          options: .atomic)
        let prompts = try JSONEncoder().encode(ImpressV3PromptLibrary.load())
        try prompts.write(to: staging.appendingPathComponent("prompts.json"),
                          options: .atomic)
        let calibration = try await ImpressCalibrationLocalStore.shared.archiveData()
        try calibration.write(
            to: staging.appendingPathComponent("checkins-v1.json"), options: .atomic)
        let mediaNames = try Self.stageCardVideoFiles(
            database: database, staging: staging, support: Self.supportDirectory())
        let names = ["ReviewV3.sqlite", "LearningEntry-v1.json", "prompts.json",
                     "checkins-v1.json"] + mediaNames
        let archiveName = "ImpressV3-" +
            ISO8601DateFormatter().string(from: Date())
                .replacingOccurrences(of: ":", with: "-") +
            "-" + String(UUID().uuidString.prefix(8)) + ".zip"
        let output = root.appendingPathComponent(archiveName)
        // Only a fully verified snapshot gets a discoverable .zip filename.
        // If iOS suspends the process mid-write, the partial file is never
        // mistaken for the latest valid backup.
        let partial = root.appendingPathComponent(".partial-" + UUID().uuidString)
        let result = try await Task.detached(priority: .utility) { () throws -> URL in
            defer { try? FileManager.default.removeItem(at: partial) }
            let records = try names.map {
                try ImpressV3BackupArchive.inspectFile(
                    staging.appendingPathComponent($0), name: $0).0
            }
            let manifest = ImpressV3BackupManifest.make(records)
            try JSONEncoder().encode(manifest).write(
                to: staging.appendingPathComponent("manifest.json"), options: .atomic)
            try ImpressV3BackupArchive.write(
                files: (names + ["manifest.json"]).map {
                    (name: $0, url: staging.appendingPathComponent($0))
                }, destination: partial)
            let verification = staging.appendingPathComponent(".verified-" + UUID().uuidString)
            _ = try ImpressV3BackupArchive.extract(source: partial, destination: verification)
            try ImpressV3BackupArchive.verifySQLite(
                verification.appendingPathComponent("ReviewV3.sqlite"))
            _ = try ImpressCalibrationLocalStore.validateArchiveData(
                Data(contentsOf: verification.appendingPathComponent("checkins-v1.json")))
            try FileManager.default.removeItem(at: verification)
            try FileManager.default.setAttributes([
                .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication
            ], ofItemAtPath: partial.path)
            try FileManager.default.moveItem(at: partial, to: output)
            return output
        }.value
        // A new card/review commit may have arrived while this snapshot was
        // being assembled. Keep it pending for the next backup cycle.
        // A verified SQLite snapshot is not sufficient if independent JSON
        // stores changed during assembly: never publish a mixed-era ZIP.
        if Self.reconcileSnapshotDirty(startingGeneration: mutationAtStart,
                                        defaults: .standard) {
            try? FileManager.default.removeItem(at: result)
            throw ImpressV3BackupFailure.concurrentChanges
        }
        UserDefaults.standard.set(Date(), forKey: Self.localDateKey)
        UserDefaults.standard.removeObject(forKey: Self.failureKey)
        Self.pruneOlderLocalBackups(keeping: 7)
        // Failure to reach iCloud never invalidates the verified local backup.
        if Self.cloudFolderSelected {
            UserDefaults.standard.set(result.lastPathComponent,
                forKey: Self.pendingCloudFileKey)
            do { try Self.copyToAuthorizedCloud(result) }
            catch {
                UserDefaults.standard.set(
                    "本地备份已成功，iCloud 副本未完成：" + error.localizedDescription,
                    forKey: Self.failureKey)
            }
        }
        return result
    }

    private static func pruneOlderLocalBackups(keeping limit: Int) {
        guard let root = try? localDirectory(),
              let all = try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil) else { return }
        let backups = all.filter {
            $0.lastPathComponent.hasPrefix("ImpressV3-") && $0.pathExtension == "zip"
        }.sorted { $0.lastPathComponent > $1.lastPathComponent }
        let pending = UserDefaults.standard.string(forKey: pendingCloudFileKey)
        for obsolete in backups.dropFirst(limit) {
            // Do not prune the sole pending cloud upload during an offline period.
            guard obsolete.lastPathComponent != pending else { continue }
            try? FileManager.default.removeItem(at: obsolete)
        }
    }

    private static func copyToAuthorizedCloud(_ archive: URL) throws {
        guard let bookmark = UserDefaults.standard.data(forKey: bookmarkKey) else {
            throw ImpressV3BackupFailure.notAuthorized
        }
        var stale = false
        let folder = try URL(resolvingBookmarkData: bookmark,
            options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
        guard !stale, folder.startAccessingSecurityScopedResource() else {
            throw ImpressV3BackupFailure.notAuthorized
        }
        defer { folder.stopAccessingSecurityScopedResource() }
        let target = folder.appendingPathComponent(archive.lastPathComponent)
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinatorError: NSError?
        var copyError: (any Swift.Error)?
        coordinator.coordinate(writingItemAt: target, options: [],
                               error: &coordinatorError) { location in
            do {
                // A previous copy may have completed before the app could
                // record the acknowledgement. An identical file is success;
                // a different existing file must never be overwritten.
                if !FileManager.default.fileExists(atPath: location.path) {
                    try FileManager.default.copyItem(at: archive, to: location)
                }
                let original = try ImpressV3BackupArchive.inspectFile(
                    archive, name: archive.lastPathComponent).0
                let copied = try ImpressV3BackupArchive.inspectFile(
                    location, name: archive.lastPathComponent).0
                guard original.sha256 == copied.sha256,
                      original.size == copied.size else {
                    throw ImpressV3BackupFailure.invalidChecksum
                }
            } catch { copyError = error }
        }
        if let coordinatorError { throw coordinatorError }
        if let copyError { throw copyError }
        // Local file-provider write is verified; remote upload scheduling is
        // controlled by iOS/iCloud and must not be presented as cloud sync done.
        let left = try ImpressV3BackupArchive.inspectFile(archive, name: archive.lastPathComponent).0
        let right = try ImpressV3BackupArchive.inspectFile(target, name: archive.lastPathComponent).0
        guard left.sha256 == right.sha256 else {
            throw ImpressV3BackupFailure.invalidChecksum
        }
        UserDefaults.standard.set(Date(), forKey: cloudDateKey)
        UserDefaults.standard.removeObject(forKey: pendingCloudFileKey)
        UserDefaults.standard.removeObject(forKey: failureKey)
    }

    /// Import is read-only until the user explicitly confirms recovery.
    func inspectRecovery(_ archive: URL) async throws -> ImpressV3BackupInspection {
        #if DEBUG
        let inspectionBase: URL
        if let fixture = ImpressV11UITestFixture.coldRestorePaths {
            inspectionBase = fixture.support
        } else {
            inspectionBase = try Self.supportDirectory()
        }
        #else
        let inspectionBase = try Self.supportDirectory()
        #endif
        return try await inspectRecoveryArchive(archive, base: inspectionBase)
    }

    #if DEBUG
    /// Uses the very same inspection pipeline as the visible Settings action,
    /// but never creates temporary extraction files in real App Support.
    func testInspectFixtureRecovery(
        _ archive: URL, paths: SyntheticRestorePaths
    ) async throws -> ImpressV3BackupInspection {
        try await inspectRecoveryArchive(archive, base: paths.support)
    }
    #endif

    private func inspectRecoveryArchive(
        _ archive: URL, base: URL
    ) async throws -> ImpressV3BackupInspection {
        let container = base.appendingPathComponent(
            "ImpressV3RestoreInspection-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: container) }
        return try await Task.detached(priority: .utility) {
            try ImpressV3BackupArchive.extract(source: archive, destination: container)
            let database = container.appendingPathComponent("ReviewV3.sqlite")
            try ImpressV3BackupArchive.verifySQLite(database)
            let counts = try ImpressV3BackupArchive.recordCounts(database)
            // Malformed JSON must be rejected before destructive confirmation.
            let history = try JSONDecoder().decode(
                [ImpressV3LearningEntry].self,
                from: Data(contentsOf: container.appendingPathComponent("LearningEntry-v1.json")))
            _ = try JSONDecoder().decode(
                [ImpressV3PromptTemplate].self,
                from: Data(contentsOf: container.appendingPathComponent("prompts.json")))
            let manifest = try JSONDecoder().decode(
                ImpressV3BackupManifest.self,
                from: Data(contentsOf: container.appendingPathComponent("manifest.json")))
            let calibrationCount: Int?
            if manifest.formatVersion >= 2 {
                calibrationCount = try ImpressCalibrationLocalStore.validateArchiveData(
                    Data(contentsOf: container.appendingPathComponent("checkins-v1.json")))
            } else {
                calibrationCount = nil
            }
            return ImpressV3BackupInspection(manifest: manifest,
                cardCount: counts.cards, reviewCount: counts.reviews,
                learningCount: history.count, calibrationCount: calibrationCount)
        }.value
    }

    func stageRecovery(_ archive: URL) async throws {
        try await withExclusiveRestoreStage {
            #if DEBUG
            let base: URL
            if let fixture = ImpressV11UITestFixture.coldRestorePaths {
                base = fixture.support
            } else {
                base = try Self.supportDirectory()
            }
            #else
            let base = try Self.supportDirectory()
            #endif
            try await stageValidatedRecovery(archive, base: base) {
                try await self.createBackup(force: true)
            }
        }
    }

    #if DEBUG
    /// Native verification of the exact same pending-restore transaction
    /// without activating a live app singleton or touching private stores.
    func testStageFixtureRecovery(
        _ archive: URL, paths: SyntheticRestorePaths,
        repository: ReviewWCDBRepository
    ) async throws {
        try await withExclusiveRestoreStage {
            try await stageValidatedRecovery(archive, base: paths.support) {
                try await self.buildSyntheticSnapshot(
                    paths: paths, repository: repository)
            }
        }
    }
    #endif

    private func stageValidatedRecovery(
        _ archive: URL, base: URL,
        saveRollback: () async throws -> URL
    ) async throws {
        let pending = base.appendingPathComponent(
            "ImpressV3PendingRestore", isDirectory: true)
        guard !FileManager.default.fileExists(atPath: pending.path) else {
            throw ImpressV3BackupFailure.restoreAlreadyPending
        }
        // Preserve a recoverable copy of the CURRENT state before staging.
        _ = try await saveRollback()
        let verified = base.appendingPathComponent(
            ".ImpressV3RestoreTemp-" + UUID().uuidString, isDirectory: true)
        do {
            _ = try await Task.detached(priority: .utility) {
                try ImpressV3BackupArchive.extract(source: archive, destination: verified)
                try ImpressV3BackupArchive.verifySQLite(
                    verified.appendingPathComponent("ReviewV3.sqlite"))
                let manifest = try JSONDecoder().decode(
                    ImpressV3BackupManifest.self, from: Data(contentsOf:
                        verified.appendingPathComponent("manifest.json")))
                _ = try JSONDecoder().decode([ImpressV3LearningEntry].self,
                    from: Data(contentsOf:
                        verified.appendingPathComponent("LearningEntry-v1.json")))
                _ = try JSONDecoder().decode([ImpressV3PromptTemplate].self,
                    from: Data(contentsOf: verified.appendingPathComponent("prompts.json")))
                if manifest.formatVersion >= 2 {
                    _ = try ImpressCalibrationLocalStore.validateArchiveData(
                        Data(contentsOf: verified.appendingPathComponent("checkins-v1.json")))
                }
            }.value
            try FileManager.default.moveItem(at: verified, to: pending)
        } catch {
            try? FileManager.default.removeItem(at: verified)
            throw error
        }
    }

    /// Execute before V3 Repository initializes on the NEXT cold start.
    /// Restore is never allowed to replace an open WCDB pool.
    static func applyPendingAtColdLaunch() throws {
        try applyPendingAtColdLaunch(
            root: supportDirectory(),
            documents: FileManager.default.urls(
                for: .documentDirectory, in: .userDomainMask)[0],
            calibration: ImpressCalibrationLocalStore.canonicalURL(),
            prompts: .standard, failAfterCalibration: false,
            simulateHardTerminationAfterCalibration: false)
    }

    #if DEBUG
    /// Deterministic, disposable-directory restore fault injection.
    /// Never writes the real application's SQLite or Vault during XCTest.
    static func testApplyPendingAtColdLaunch(
        root: URL, documents: URL, calibration: URL,
        prompts: UserDefaults, failAfterCalibration: Bool = false,
        simulateHardTerminationAfterCalibration: Bool = false) throws {
        try applyPendingAtColdLaunch(root: root, documents: documents,
            calibration: calibration, prompts: prompts,
            failAfterCalibration: failAfterCalibration,
            simulateHardTerminationAfterCalibration: simulateHardTerminationAfterCalibration,
            scheduleBackupOnSuccess: false)
    }
    #endif


    private struct RestoreSavedState: Codable {
        // Names are a fixed, known allowlist. Copies are kept until recovery
        // completes; a crash during rollback can safely retry from the copies.
        let originals: [ImpressV3BackupFileRecord]
        let previousPrompts: Data?
        /// Nil means an older in-flight transaction did not manage video files.
        let previousMedia: [ImpressV3BackupFileRecord]?
    }

    /// Rebuild a private media tree from a fully checked ZIP/rollback snapshot.
    /// Called only after saving the durable PRE-restore image. On interruption,
    /// the next cold start replays the same rollback before WCDB can open.
    private static func installVerifiedCardMedia(
        from source: URL, support: URL, records: [ImpressV3BackupFileRecord]
    ) throws {
        let fm = FileManager.default
        guard records.count <= 256,
              Set(records.map(\.name)).count == records.count,
              records.allSatisfy({ ImpressV3BackupArchive.isSafeMediaName($0.name) }) else {
            throw ImpressV3BackupFailure.invalidManifest
        }
        let staging = support.appendingPathComponent(
            ".ImpressMediaRestore-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        for record in records {
            let original = source.appendingPathComponent(record.name)
            let properties = try original.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard properties.isRegularFile == true,
                  properties.isSymbolicLink != true else {
                throw ImpressV3BackupFailure.invalidArchive
            }
            let verified = try ImpressV3BackupArchive.inspectFile(
                original, name: record.name).0
            guard verified.size == record.size,
                  verified.sha256 == record.sha256 else {
                throw ImpressV3BackupFailure.invalidChecksum
            }
            let copy = staging.appendingPathComponent(record.name)
            try fm.createDirectory(at: copy.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            try fm.copyItem(at: original, to: copy)
            try fm.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: copy.path)
            let checked = try ImpressV3BackupArchive.inspectFile(copy, name: record.name).0
            guard checked.size == record.size && checked.sha256 == record.sha256 else {
                throw ImpressV3BackupFailure.invalidChecksum
            }
        }
        let mediaRoot = support.appendingPathComponent(
            "ImpressCardMedia", isDirectory: true)
        // A private media root substituted with a symlink must never redirect
        // cold-restore deletion or installation outside Application Support.
        // The store validates directory type and symlink status before writes.
        _ = try ImpressCardVideoPrivateStore(rootURL: mediaRoot)
        var mutable = mediaRoot
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try mutable.setResourceValues(values)
        let oldTree = mediaRoot.appendingPathComponent("CardVideo", isDirectory: true)
        if fm.fileExists(atPath: oldTree.path) {
            let properties = try oldTree.resourceValues(
                forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            guard properties.isSymbolicLink != true,
                  properties.isDirectory == true else {
                throw ImpressV3BackupFailure.invalidArchive
            }
            try fm.removeItem(at: oldTree)
        }
        if !records.isEmpty {
            try fm.moveItem(at: staging.appendingPathComponent(
                "CardVideo", isDirectory: true), to: oldTree)
        }
    }

    #if DEBUG
    /// Synthetic XCTest seam: never touches the live Application Support root.
    static func testInstallVerifiedCardMedia(from source: URL, support: URL) throws {
        try installVerifiedCardMedia(from: source, support: support, records: [])
    }
    #endif

    private static func restoreTargets(
        root: URL, documents: URL, calibration: URL
    ) -> [(name: String, location: URL)] {
        let db = documents.appendingPathComponent("ImpressV3/ReviewV3.sqlite")
        return [
            ("ReviewV3.sqlite", db),
            ("ReviewV3.sqlite-wal", URL(fileURLWithPath: db.path + "-wal")),
            ("ReviewV3.sqlite-shm", URL(fileURLWithPath: db.path + "-shm")),
            ("LearningEntry-v1.json", root.appendingPathComponent("ImpressV3/LearningEntry-v1.json")),
            ("checkins-v1.json", calibration)
        ]
    }

    private static func restoreTransactionURL(root: URL) -> URL {
        root.appendingPathComponent("ImpressV3RestoreTransaction", isDirectory: true)
    }

    private static func prepareRestoreTransaction(
        root: URL, documents: URL, calibration: URL, prompts: UserDefaults
    ) throws {
        let fileManager = FileManager.default
        let destination = restoreTransactionURL(root: root)
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw ImpressV3BackupFailure.restoreAlreadyPending
        }
        let preparing = root.appendingPathComponent(
            ".ImpressV3RestorePrepare-" + UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: preparing, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: preparing) }
        var originals: [ImpressV3BackupFileRecord] = []
        for target in restoreTargets(root: root, documents: documents, calibration: calibration) {
            guard fileManager.fileExists(atPath: target.location.path) else { continue }
            let archived = preparing.appendingPathComponent(target.name)
            try fileManager.copyItem(at: target.location, to: archived)
            originals.append(try ImpressV3BackupArchive.inspectFile(archived, name: target.name).0)
        }
        // Old card history must remain restorable even after installing a
        // different backup. Preserve private pixels in the durable rollback
        // directory, not in UserDefaults or a public document store.
        let currentDB = documents.appendingPathComponent("ImpressV3/ReviewV3.sqlite")
        let previousNames = fileManager.fileExists(atPath: currentDB.path)
            ? try stageCardVideoFiles(database: currentDB, staging: preparing, support: root)
            : []
        let savedMedia = try previousNames.filter {
            ImpressV3BackupArchive.isSafeMediaName($0)
        }.map { name in
            try ImpressV3BackupArchive.inspectFile(
                preparing.appendingPathComponent(name), name: name).0
        }
        let metadata = RestoreSavedState(originals: originals,
            previousPrompts: prompts.data(forKey: ImpressV3PromptLibrary.storageKey),
            previousMedia: savedMedia)
        try JSONEncoder().encode(metadata).write(
            to: preparing.appendingPathComponent("restore-transaction.json"), options: .atomic)
        // The rename is the durable prepare/commit boundary. Nothing in the
        // live app is replaced until the full rollback image exists.
        try fileManager.moveItem(at: preparing, to: destination)
        prompts.set(true, forKey: recoveryBlockKey)
    }

    private static func restorePreviousFromTransaction(
        root: URL, documents: URL, calibration: URL, prompts: UserDefaults
    ) throws {
        let fileManager = FileManager.default
        let snapshot = restoreTransactionURL(root: root)
        let metadata = try JSONDecoder().decode(RestoreSavedState.self,
            from: Data(contentsOf: snapshot.appendingPathComponent("restore-transaction.json")))
        let targets = restoreTargets(root: root, documents: documents, calibration: calibration)
        let expected = Set(targets.map(\.name))
        guard Set(metadata.originals.map(\.name)).isSubset(of: expected),
              Set(metadata.originals.map(\.name)).count == metadata.originals.count else {
            throw ImpressV3BackupFailure.invalidManifest
        }
        // Validate every original before destructive rollback starts.
        for item in metadata.originals {
            let restored = try ImpressV3BackupArchive.inspectFile(
                snapshot.appendingPathComponent(item.name), name: item.name).0
            guard restored.sha256 == item.sha256 && restored.size == item.size else {
                throw ImpressV3BackupFailure.invalidChecksum
            }
        }
        let found = Set(metadata.originals.map(\.name))
        for target in targets {
            try fileManager.createDirectory(at: target.location.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: target.location.path) {
                try fileManager.removeItem(at: target.location)
            }
            if found.contains(target.name) {
                try fileManager.copyItem(
                    at: snapshot.appendingPathComponent(target.name), to: target.location)
            }
        }
        if let media = metadata.previousMedia {
            try installVerifiedCardMedia(from: snapshot, support: root,
                                         records: media)
        }
        if let data = metadata.previousPrompts {
            prompts.set(data, forKey: ImpressV3PromptLibrary.storageKey)
        } else {
            prompts.removeObject(forKey: ImpressV3PromptLibrary.storageKey)
        }
    }

    private static func archiveRestoreTransaction(root: URL) throws {
        let snapshot = restoreTransactionURL(root: root)
        guard FileManager.default.fileExists(atPath: snapshot.path) else { return }
        try FileManager.default.moveItem(at: snapshot, to: root.appendingPathComponent(
            "ImpressV3PreRestoreVerified-" + UUID().uuidString, isDirectory: true))
    }

    private static func recoverInterruptedRestore(
        root: URL, documents: URL, calibration: URL, prompts: UserDefaults
    ) throws {
        let snapshot = restoreTransactionURL(root: root)
        guard FileManager.default.fileExists(atPath: snapshot.path) else {
            // A fully completed rename can precede an interrupted defaults update.
            prompts.removeObject(forKey: recoveryBlockKey)
            return
        }
        prompts.set(true, forKey: recoveryBlockKey)
        let pending = root.appendingPathComponent("ImpressV3PendingRestore")
        if FileManager.default.fileExists(atPath: pending.path) {
            // No WCDB pool has opened. Revert all five on-disk files and prompts.
            try restorePreviousFromTransaction(
                root: root, documents: documents, calibration: calibration, prompts: prompts)
            try archiveRestoreTransaction(root: root)
            prompts.removeObject(forKey: recoveryBlockKey)
            // Keep the previously confirmed source staged for another cold
            // launch; never resume halfway through this process.
            throw ImpressV3BackupFailure.restoreInterrupted
        }
        // The pending-to-applied rename is the transaction's commit point.
        // No pending folder means the multi-file installation succeeded.
        try archiveRestoreTransaction(root: root)
        prompts.removeObject(forKey: recoveryBlockKey)
    }

    private static func applyPendingAtColdLaunch(
        root: URL, documents: URL, calibration: URL,
        prompts: UserDefaults, failAfterCalibration: Bool,
        simulateHardTerminationAfterCalibration: Bool,
        scheduleBackupOnSuccess: Bool = true) throws {
        try recoverInterruptedRestore(
            root: root, documents: documents, calibration: calibration, prompts: prompts)
        let pending = root.appendingPathComponent("ImpressV3PendingRestore")
        guard FileManager.default.fileExists(atPath: pending.path) else { return }
        let manifest = try JSONDecoder().decode(ImpressV3BackupManifest.self,
            from: Data(contentsOf: pending.appendingPathComponent("manifest.json")))
        let records = try manifest.files.map {
            try ImpressV3BackupArchive.inspectFile(
                pending.appendingPathComponent($0.name), name: $0.name).0
        }
        try manifest.validate(records)
        try ImpressV3BackupArchive.validateMediaBackup(
            database: pending.appendingPathComponent("ReviewV3.sqlite"),
            folder: pending, manifest: manifest, records: records)
        try ImpressV3BackupArchive.verifySQLite(
            pending.appendingPathComponent("ReviewV3.sqlite"))
        _ = try JSONDecoder().decode([ImpressV3LearningEntry].self,
            from: Data(contentsOf: pending.appendingPathComponent("LearningEntry-v1.json")))
        let restoredPrompts = try JSONDecoder().decode(
            [ImpressV3PromptTemplate].self,
            from: Data(contentsOf: pending.appendingPathComponent("prompts.json")))
        let restoredCalibration: Data?
        if manifest.formatVersion >= 2 {
            let bytes = try Data(contentsOf: pending.appendingPathComponent("checkins-v1.json"))
            _ = try ImpressCalibrationLocalStore.validateArchiveData(bytes)
            restoredCalibration = bytes
        } else {
            // A V1 backup never had calibration; retain local V3.2 history.
            restoredCalibration = nil
        }
        let liveFolder = documents.appendingPathComponent(
            "ImpressV3", isDirectory: true)
        try FileManager.default.createDirectory(
            at: liveFolder, withIntermediateDirectories: true)
        let current = liveFolder.appendingPathComponent("ReviewV3.sqlite")
        let previous = root.appendingPathComponent(
            "ImpressV3PreRestore-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: previous, withIntermediateDirectories: true)
        let fileManager = FileManager.default
        let journalFolder = root.appendingPathComponent("ImpressV3", isDirectory: true)
        let journal = journalFolder.appendingPathComponent("LearningEntry-v1.json")
        let previousCalibration = previous.appendingPathComponent("checkins-v1.json")
        try prepareRestoreTransaction(
            root: root, documents: documents, calibration: calibration, prompts: prompts)
        do {
            for suffix in ["", "-wal", "-shm"] {
                let priorFile = URL(fileURLWithPath: current.path + suffix)
                if fileManager.fileExists(atPath: priorFile.path) {
                    try fileManager.moveItem(at: priorFile, to: previous.appendingPathComponent(
                        priorFile.lastPathComponent))
                }
            }
            try fileManager.copyItem(
                at: pending.appendingPathComponent("ReviewV3.sqlite"), to: current)
            try fileManager.createDirectory(at: journalFolder,
                withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: journal.path) {
                try fileManager.copyItem(at: journal,
                    to: previous.appendingPathComponent("LearningEntry-v1.json"))
                try fileManager.removeItem(at: journal)
            }
            try fileManager.copyItem(at: pending.appendingPathComponent(
                "LearningEntry-v1.json"), to: journal)
            try ImpressV3PromptLibrary.save(restoredPrompts, to: prompts)
            if let restoredCalibration {
                try fileManager.createDirectory(
                    at: calibration.deletingLastPathComponent(),
                    withIntermediateDirectories: true)
                if fileManager.fileExists(atPath: calibration.path) {
                    try fileManager.moveItem(at: calibration, to: previousCalibration)
                }
                try restoredCalibration.write(to: calibration, options: .atomic)
                _ = try ImpressCalibrationLocalStore.validateArchiveData(
                    Data(contentsOf: calibration))
            }
            // The SQLite snapshot's exact media graph has been validated at
            // the start of this cold-restore. This is the final multi-object
            // installation step, still inside the durable rollback interval.
            let media = manifest.files.filter {
                ImpressV3BackupArchive.isSafeMediaName($0.name)
            }
            try installVerifiedCardMedia(from: pending, support: root, records: media)
            #if DEBUG
            if failAfterCalibration || simulateHardTerminationAfterCalibration {
                throw ImpressV3BackupFailure.invalidArchive
            }
            #endif
            // Moving staging away atomically prevents unintended repeat
            // recovery when temporary cleanup fails.
            let applied = root.appendingPathComponent(
                "ImpressV3Applied-" + UUID().uuidString, isDirectory: true)
            try fileManager.moveItem(at: pending, to: applied)
            try? fileManager.removeItem(at: applied)
            // A synthetic cold-start fixture must never enqueue a real
            // application-support backup or cloud operation after restoring
            // its disposable WCDB. Production cold-start retains the signal.
            if scheduleBackupOnSuccess { markDataChanged() }
            // After the pending rename, the restore is committed. If archival
            // fails, the next cold start finishes it without rolling back.
            try? archiveRestoreTransaction(root: root)
            prompts.removeObject(forKey: recoveryBlockKey)
        } catch let applyError {
            // XCTest models process termination: no Swift catch/rollback runs.
            // The next cold start must repair from the durable pre-image.
            if simulateHardTerminationAfterCalibration { throw applyError }
            do {
                try restorePreviousFromTransaction(
                    root: root, documents: documents, calibration: calibration,
                    prompts: prompts)
                try archiveRestoreTransaction(root: root)
                prompts.removeObject(forKey: recoveryBlockKey)
            } catch {
                // Keep a persistent block on opening any half-restored SQLite.
                // The intact transaction directory permits another safe retry.
                prompts.set(true, forKey: recoveryBlockKey)
                throw error
            }
            throw applyError
        }
    }
}
