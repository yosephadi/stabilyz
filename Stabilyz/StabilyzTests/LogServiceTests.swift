import Foundation
import Synchronization
import Testing
@testable import Stabilyz

/// The capturing log sink from docs/12 §12.2.
private final class CapturingLogService: LogService {
    struct Entry: Equatable {
        let level: LogLevel
        let category: LogCategory
        let message: String
    }

    private let state = Mutex<(entries: [Entry], open: Set<UInt64>, closed: [UInt64], next: UInt64)>(([], [], [], 1))

    var entries: [Entry] { state.withLock { $0.entries } }
    var openIntervalIDs: Set<UInt64> { state.withLock { $0.open } }
    var closedIntervalIDs: [UInt64] { state.withLock { $0.closed } }

    func log(_ level: LogLevel, _ category: LogCategory, _ message: String) {
        state.withLock { $0.entries.append(Entry(level: level, category: category, message: message)) }
    }

    func beginInterval(_ name: StaticString, category: LogCategory) -> SignpostInterval {
        let id = state.withLock { value -> UInt64 in
            let id = value.next
            value.next += 1
            value.open.insert(id)
            return id
        }
        return SignpostInterval(name: name, category: category, id: id)
    }

    func endInterval(_ interval: SignpostInterval) {
        state.withLock {
            guard $0.open.remove(interval.id) != nil else { return }
            $0.closed.append(interval.id)
        }
    }
}

private struct StageFailure: Error {}

// MARK: - Categories

@Test func logCategoriesCoverTheDocumentedSubsystems() {
    // docs/20 fixes this list; a missing category means an unlabelled subsystem.
    #expect(Set(LogCategory.allCases.map(\.rawValue)) == [
        "app", "session", "motion", "processing", "baseline", "audio", "backup", "persistence"
    ])
}

// MARK: - Logging

@Test func logServiceRecordsLevelCategoryAndMessage() {
    let log = CapturingLogService()
    log.log(.info, .session, "session stopped: mode=quickTest gaps=0")
    log.log(.error, .backup, "export failed: file")

    #expect(log.entries == [
        .init(level: .info, category: .session, message: "session stopped: mode=quickTest gaps=0"),
        .init(level: .error, category: .backup, message: "export failed: file")
    ])
}

// MARK: - Signpost intervals

@Test func intervalsAreUniqueAndCloseIndependently() {
    let log = CapturingLogService()

    let first = log.beginInterval("preprocessing", category: .processing)
    let second = log.beginInterval("segmentation", category: .processing)
    #expect(first.id != second.id)
    #expect(log.openIntervalIDs == [first.id, second.id])

    log.endInterval(first)
    #expect(log.openIntervalIDs == [second.id])
    #expect(log.closedIntervalIDs == [first.id])
}

@Test func closingAnIntervalTwiceIsIgnored() {
    let log = CapturingLogService()
    let interval = log.beginInterval("quality", category: .processing)

    log.endInterval(interval)
    log.endInterval(interval)

    #expect(log.closedIntervalIDs == [interval.id])
}

@Test func measureClosesTheIntervalOnSuccess() async {
    let log = CapturingLogService()
    let result = await log.measure("features", category: .processing) { 42 }

    #expect(result == 42)
    #expect(log.openIntervalIDs.isEmpty)
    #expect(log.closedIntervalIDs.count == 1)
}

@Test func measureClosesTheIntervalWhenTheStageThrows() async {
    let log = CapturingLogService()

    await #expect(throws: StageFailure.self) {
        try await log.measure("scoring", category: .processing) { throw StageFailure() }
    }

    // A failed stage must not leak an open signpost interval.
    #expect(log.openIntervalIDs.isEmpty)
    #expect(log.closedIntervalIDs.count == 1)
}

// MARK: - Production implementation

@Test func osLogServiceHandlesFullIntervalLifecycle() {
    let service = OSLogService(subsystem: "com.stabilyz.tests")

    service.log(.info, .app, "launched")
    let interval = service.beginInterval("processing", category: .processing)
    #expect(interval.category == .processing)

    service.endInterval(interval)
    // Ending twice must not trap on the missing parked state.
    service.endInterval(interval)
}

@Test func osLogServiceIsWiredIntoTheLiveGraph() {
    let dependencies = AppDependencies.live()
    #expect(dependencies.logService is OSLogService)
}
