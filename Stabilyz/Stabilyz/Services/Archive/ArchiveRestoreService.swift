import Foundation

/// Replaces the local store with a staged export (docs/13 §13.5, Task 10.3.4).
protocol ArchiveRestoring: Sendable {
    /// - Throws: `StabilyzError.archiveImport(.corruptedArchive)` when the
    ///   staged payload breaks a clinical rule (nothing touched);
    ///   `.archiveImport(.restoreFailed)` when the replace failed and the store
    ///   is exactly as it was; `.archiveImport(.restoreIncomplete)` in the one
    ///   case the pre-restore state could not be put back.
    func restore(_ staged: DecodedArchivePayload) async throws -> RestoreReceipt
}

/// Production `ArchiveRestoring` (docs/13 §13.5).
///
/// An import is a restore, not a merge [PRD OQ-2], and it is atomic: a failure
/// at any point leaves the store exactly as it was [PRD §7 hard requirement].
/// Three layers make that true:
///
/// 1. **The transaction.** Everything is deleted and the archive inserted in
///    one save (`StoreWriter.replaceAll`); a failed save rolls back.
/// 2. **The snapshot.** Before the replace, the whole store — invalid sessions
///    included — is read into memory. After any failure, and after any write
///    that does not read back as exactly the archive, the store is compared
///    with the snapshot and, if it differs, the snapshot is written back and
///    checked again. This is what catches a failure the transaction did not.
/// 3. **The staging (Task 10.3.5).** The same snapshot, plus an in-progress
///    marker, is on disk before the first write, and removed only once the
///    outcome is settled. A process that dies in between leaves the marker,
///    and `RestoreRecoveryService` puts the snapshot back at the next launch.
///    A store that could not be put back keeps its staging for the same
///    reason.
///
/// **Order.** Clinical rules are checked before anything is read or written;
/// then snapshot, staging, replace, verify. Only after verification is the
/// staging cleared, caches rebuilt and the replacement broadcast.
struct ArchiveRestoreService: ArchiveRestoring {
    private let replacer: StoreReplacing
    private let events: StoreReplacementEvents
    private let logService: LogService
    private let staging: RestoreStaging?
    private let rebuildBaselineStates: (@Sendable () async throws -> Void)?

    /// - Parameters:
    ///   - staging: the on-disk safety net; nil only where there is no disk to
    ///     keep one on (tests of the in-memory layers).
    ///   - rebuildBaselineStates: throws away every cached `BaselineState`
    ///     (`BaselineStateStore.rebuild`). Run before the broadcast, so a
    ///     subscriber reloading on the event reads fresh states.
    init(
        replacer: StoreReplacing,
        events: StoreReplacementEvents,
        logService: LogService,
        staging: RestoreStaging? = nil,
        rebuildBaselineStates: (@Sendable () async throws -> Void)? = nil
    ) {
        self.replacer = replacer
        self.events = events
        self.logService = logService
        self.staging = staging
        self.rebuildBaselineStates = rebuildBaselineStates
    }

    func restore(_ staged: DecodedArchivePayload) async throws -> RestoreReceipt {
        // 1. Clinical rules, before the store is read or written.
        guard let target = Self.target(for: staged.payload) else {
            logService.log(.error, .backup, "restore refused: staged payload breaks a clinical rule")
            throw StabilyzError.archiveImport(.corruptedArchive)
        }

        // 2. The snapshot. Unreadable means nothing has been written yet.
        let snapshot: StoreContents
        do {
            snapshot = try await replacer.contents()
        } catch {
            logService.log(.error, .backup, "restore snapshot failed: \(type(of: error))")
            throw StabilyzError.archiveImport(.restoreFailed)
        }

        // 3. The staging, on disk before the first write. Without it a killed
        //    process could not be recovered, so no staging means no restore.
        var stagedHere = false
        if let staging {
            do {
                stagedHere = try staging.stage(snapshot)
            } catch {
                logService.log(.error, .backup, "restore staging failed; store not touched: \(type(of: error))")
                throw StabilyzError.archiveImport(.restoreFailed)
            }
            if !stagedHere {
                logService.log(.warning, .backup, "restore staging kept from an earlier restore that could not be put back")
            }
        }

        // 4. The replace.
        do {
            try await replacer.replaceAll(with: target)
        } catch {
            logService.log(.error, .backup, "restore write failed: \(type(of: error))")
            try await putBack(snapshot)
            if stagedHere { clearStaging() }
            throw StabilyzError.archiveImport(.restoreFailed)
        }

        // 5. Verification: the store must read back as exactly the archive.
        let written = try? await replacer.contents()
        guard written == target else {
            logService.log(.error, .backup, "restore verification failed: store does not match the archive")
            try await putBack(snapshot)
            if stagedHere { clearStaging() }
            throw StabilyzError.archiveImport(.restoreFailed)
        }

        // 6. Settled: the archive is the store. Any staging — this restore's,
        //    or one kept from before — describes a store that no longer exists.
        clearStaging()

        // 7. Everything cached about the old store goes.
        do {
            try await rebuildBaselineStates?()
        } catch {
            // The store is right; the cache rebuilds from it on next refresh.
            logService.log(.error, .backup, "baseline state rebuild after restore failed: \(type(of: error))")
        }

        let receipt = RestoreReceipt(
            schemaVersion: staged.schemaVersion,
            sessionCount: target.sessions.count,
            baselineModes: target.baselines.map(\.mode)
        )
        logService.log(
            .info, .backup,
            "restore completed: schema v\(receipt.schemaVersion) sessions=\(receipt.sessionCount) baselines=\(receipt.baselineModes.count)"
        )
        events.publish(StoreReplacement(receipt: receipt))
        return receipt
    }

    // MARK: - Rollback

    /// Leaves the store exactly as `snapshot`, or reports that it could not —
    /// in which case the staging stays, for launch recovery.
    ///
    /// The usual case is that the transaction already rolled back and there is
    /// nothing to do; the comparison is what proves it. Otherwise the snapshot
    /// is written back and read again.
    private func putBack(_ snapshot: StoreContents) async throws {
        if let current = try? await replacer.contents(), current == snapshot {
            return
        }
        do {
            try await replacer.replaceAll(with: snapshot)
            guard try await replacer.contents() == snapshot else {
                throw StabilyzError.archiveImport(.restoreIncomplete)
            }
            logService.log(.info, .backup, "restore rolled back to the pre-restore snapshot")
        } catch {
            logService.log(.error, .backup, "restore rollback failed; staging kept for launch recovery: \(type(of: error))")
            throw StabilyzError.archiveImport(.restoreIncomplete)
        }
    }

    /// A staging that cannot be removed would put the snapshot back at the
    /// next launch. Logged loudly; the outcome in hand is still the right one.
    private func clearStaging() {
        do {
            try staging?.clear()
        } catch {
            logService.log(.error, .backup, "could not remove restore staging: \(type(of: error))")
        }
    }

    // MARK: - Clinical rules

    /// The store contents a staged payload becomes, or nil when it breaks a
    /// rule the app could never have produced (docs/13 §13.4 completeness).
    ///
    /// Inspection has already validated the archive; these are checked again
    /// at the last moment before the store is replaced, because nothing after
    /// this point can refuse:
    ///
    /// - a profile past the disclaimer gate, at most one baseline per mode, no
    ///   duplicate session ids (`ArchivePayload.inconsistency`);
    /// - **valid sessions only**, each carrying metrics [PRD §5, §6];
    /// - every baseline built from five of the archive's own sessions **of its
    ///   mode** — a baseline whose sources are missing or belong to the other
    ///   mode would be scored against forever, since v1 never recalibrates
    ///   [PRD OQ-5, §6].
    static func target(for payload: ArchivePayload) -> StoreContents? {
        guard payload.inconsistency == nil,
              payload.sessions.allSatisfy({ $0.isUserVisible && $0.metrics != nil })
        else { return nil }

        let sessionModes = Dictionary(uniqueKeysWithValues: payload.sessions.map { ($0.id, $0.mode) })
        for baseline in payload.baselines {
            guard baseline.sourceSessionIDs.allSatisfy({ sessionModes[$0] == baseline.mode }) else {
                return nil
            }
        }

        return StoreContents(profile: payload.profile, baselines: payload.baselines, sessions: payload.sessions)
    }
}
