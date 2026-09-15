import Foundation
import Testing
@testable import Stabilyz

/// Export My Data from hand-off to cleanup (Task 10.2.2, docs/04 §4.16).

// MARK: - Doubles

private final class FakeExporter: ArchiveExporting, @unchecked Sendable {
    let requests = Locked<[ExportRequest]>([])
    let discarded = Locked<[PreparedExport]>([])
    let sweeps = Locked(0)
    let result: Result<PreparedExport, StabilyzError>

    init(_ result: Result<PreparedExport, StabilyzError>) { self.result = result }

    func prepare(_ request: ExportRequest) async throws -> PreparedExport {
        requests.withLock { $0.append(request) }
        return try result.get()
    }

    func discard(_ export: PreparedExport) async { discarded.withLock { $0.append(export) } }
    func discardStaleExports() async { sweeps.withLock { $0 += 1 } }
}

/// Holds `prepare` open until released.
private actor GatedExporter: ArchiveExporting {
    let export: PreparedExport
    private var waiting: CheckedContinuation<Void, Never>?
    private var released = false
    private(set) var discarded: [PreparedExport] = []

    init(export: PreparedExport) { self.export = export }

    var isWaiting: Bool { waiting != nil }

    func release() {
        released = true
        waiting?.resume()
        waiting = nil
    }

    func prepare(_ request: ExportRequest) async throws -> PreparedExport {
        if !released { await withCheckedContinuation { waiting = $0 } }
        return export
    }

    func discard(_ export: PreparedExport) async { discarded.append(export) }
    func discardStaleExports() async {}
}

private struct CalibratingKeyDerivation: KeyDerivation {
    let calibration: Int
    func deriveKey(passphrase: [UInt8], salt: [UInt8], iterations: Int, keyByteCount: Int) throws -> [UInt8] { [] }
    func calibratedIterationCount(targetDuration: TimeInterval) -> Int { calibration }
}

private final class SilentLog: LogService, @unchecked Sendable {
    func log(_ level: LogLevel, _ category: LogCategory, _ message: String) {}
    func beginInterval(_ name: StaticString, category: LogCategory) -> SignpostInterval {
        SignpostInterval(name: name, category: category, id: 0)
    }
    func endInterval(_ interval: SignpostInterval) {}
}

private final class Closes {
    var count = 0
}

private let prepared = PreparedExport(
    id: UUID(),
    fileURL: URL(fileURLWithPath: "/tmp/StabilyzExports/x/Stabilyz-Backup-2027-01-15-080000.stabilyz"),
    directoryURL: URL(fileURLWithPath: "/tmp/StabilyzExports/x")
)
private let request = ExportRequest(passphrase: Array("correct horse".utf8), iterations: 1_000)

@MainActor
private func makeFlow(
    _ exporter: ArchiveExporting = FakeExporter(.success(prepared)),
    calibration: Int = 1_200_000,
    closes: Closes = Closes()
) -> ExportFlowModel {
    ExportFlowModel(
        exporter: exporter,
        keyDerivation: CalibratingKeyDerivation(calibration: calibration),
        logService: SilentLog(),
        onClose: { closes.count += 1 }
    )
}

/// A flow already showing the share sheet.
@MainActor
private func sharing(_ exporter: FakeExporter, closes: Closes = Closes()) async -> ExportFlowModel {
    let flow = makeFlow(exporter, closes: closes)
    await flow.generate(request)
    return flow
}

// MARK: - Start

@MainActor @Test func theFlowOpensOnTheWizardAndSweepsLeftovers() async {
    let exporter = FakeExporter(.success(prepared))
    let flow = makeFlow(exporter)

    #expect(flow.phase == .entering)
    await flow.start()
    #expect(exporter.sweeps.withLock { $0 } == 1)
}

// MARK: - Hand-off from the wizard

@MainActor @Test func theWizardsRequestIsWhatTheExporterReceives() async throws {
    let exporter = FakeExporter(.success(prepared))
    let flow = makeFlow(exporter, calibration: 9_000_000)

    flow.wizard.passphrase = "correct horse"
    flow.wizard.confirmation = "correct horse"
    flow.wizard.continueToWarning()
    flow.wizard.hasAcknowledgedWarning = true
    await flow.wizard.createBackup()
    await flow.generationTask?.value

    let received = try #require(exporter.requests.withLock { $0.first })
    #expect(received.passphrase == Array("correct horse".utf8))
    #expect(received.iterations == 5_000_000)
    #expect(flow.phase == .sharing(prepared))
}

@MainActor @Test func cancellingTheWizardClosesTheFlow() {
    let closes = Closes()
    let flow = makeFlow(closes: closes)
    flow.wizard.passphrase = "correct horse"

    flow.wizard.cancel()

    #expect(closes.count == 1)
    #expect(flow.wizard.passphrase.isEmpty)
}

// MARK: - Generation

@MainActor @Test func aPreparedFileMovesTheFlowToSharing() async {
    let flow = await sharing(FakeExporter(.success(prepared)))
    #expect(flow.phase == .sharing(prepared))
}

@MainActor @Test func aGenerationFailureShowsTheExportMessage() async {
    for failure in [StabilyzError.Export.archiveGenerationFailed, .fileWriteFailed, .keyDerivationFailed] {
        let flow = makeFlow(FakeExporter(.failure(.export(failure))))
        await flow.generate(request)

        guard case .failed(let presentation) = flow.phase else {
            Issue.record("expected failure for \(failure), got \(flow.phase)")
            continue
        }
        #expect(presentation.message == "Export didn't complete — nothing was changed.")
        #expect(presentation.isRecoverable)
    }
}

@MainActor @Test func aSecondRequestWhileGeneratingIsIgnored() async {
    let exporter = FakeExporter(.success(prepared))
    let flow = await sharing(exporter)

    await flow.generate(request)
    #expect(exporter.requests.withLock { $0.count } == 1)
}

// MARK: - The share sheet, and cleanup

@MainActor @Test func aCompletedShareDeletesTheFileAndSaysSo() async {
    let exporter = FakeExporter(.success(prepared))
    let flow = await sharing(exporter)

    await flow.shareFinished(completed: true, failed: false)

    #expect(flow.phase == .finished(.shared))
    #expect(exporter.discarded.withLock { $0 } == [prepared])
}

@MainActor @Test func aDismissedShareSheetDeletesTheFileToo() async {
    let exporter = FakeExporter(.success(prepared))
    let flow = await sharing(exporter)

    await flow.shareFinished(completed: false, failed: false)

    #expect(flow.phase == .finished(.notShared))
    #expect(exporter.discarded.withLock { $0 } == [prepared])
}

@MainActor @Test func aFailedShareDeletesTheFileAndShowsAnError() async {
    let exporter = FakeExporter(.success(prepared))
    let flow = await sharing(exporter)

    await flow.shareFinished(completed: false, failed: true)

    guard case .failed(let presentation) = flow.phase else {
        Issue.record("expected a failure, got \(flow.phase)")
        return
    }
    #expect(presentation.message == "Export didn't complete — nothing was changed.")
    #expect(exporter.discarded.withLock { $0 } == [prepared])
}

@MainActor @Test func aSecondReportOfTheSameEndingDeletesNothingTwice() async {
    let exporter = FakeExporter(.success(prepared))
    let flow = await sharing(exporter)

    await flow.shareFinished(completed: true, failed: false)
    await flow.shareFinished(completed: false, failed: false)

    #expect(flow.phase == .finished(.shared))
    #expect(exporter.discarded.withLock { $0.count } == 1)
}

@MainActor @Test func closingWithTheShareSheetUpDeletesTheFile() async {
    let exporter = FakeExporter(.success(prepared))
    let closes = Closes()
    let flow = await sharing(exporter, closes: closes)

    flow.close()
    await flow.cleanupTask?.value

    #expect(closes.count == 1)
    #expect(exporter.discarded.withLock { $0 } == [prepared])
}

@MainActor @Test func aFileFinishedAfterTheFlowClosedIsDeletedAtOnce() async {
    let gated = GatedExporter(export: prepared)
    let flow = makeFlow(gated)

    let generation = Task { await flow.generate(request) }
    var spins = 0
    while await gated.isWaiting == false, spins < 1_000 {
        await Task.yield()
        spins += 1
    }

    flow.close()
    await gated.release()
    await generation.value

    #expect(await gated.discarded == [prepared])
    #expect(flow.phase != .sharing(prepared))
}

@MainActor @Test func showingShareOptionsAgainOnlyWorksWhileSharing() async {
    let flow = makeFlow()
    flow.showShareOptions()
    #expect(flow.shareAttempt == 0)

    await flow.generate(request)
    flow.showShareOptions()
    #expect(flow.shareAttempt == 1)
}

// MARK: - Starting over

@MainActor @Test func tryingAgainAfterAnUnsharedBackupStartsAFreshWizard() async {
    let flow = await sharing(FakeExporter(.success(prepared)))
    await flow.shareFinished(completed: false, failed: false)
    let first = ObjectIdentifier(flow.wizard)

    flow.startOver()

    #expect(flow.phase == .entering)
    #expect(ObjectIdentifier(flow.wizard) != first)
    #expect(flow.wizard.passphrase.isEmpty)
    #expect(flow.wizard.step == .passphrase)
}

@MainActor @Test func startingOverIsRefusedMidExport() async {
    let flow = await sharing(FakeExporter(.success(prepared)))
    let wizard = ObjectIdentifier(flow.wizard)

    flow.startOver()

    #expect(flow.phase == .sharing(prepared))
    #expect(ObjectIdentifier(flow.wizard) == wizard)
}

@MainActor @Test func theFreshWizardIsWiredToTheFlow() async throws {
    let exporter = FakeExporter(.failure(.export(.fileWriteFailed)))
    let flow = makeFlow(exporter)
    await flow.generate(request)
    flow.startOver()

    flow.wizard.passphrase = "another horse"
    flow.wizard.confirmation = "another horse"
    flow.wizard.continueToWarning()
    flow.wizard.hasAcknowledgedWarning = true
    await flow.wizard.createBackup()
    await flow.generationTask?.value

    #expect(exporter.requests.withLock { $0.count } == 2)
}

// MARK: - Recording a completed export (Task 10.2.3)

@MainActor
@Test func aCompletedShareIsRecordedAsAnExport() async {
    let recorded = Closes()
    let flow = ExportFlowModel(
        exporter: FakeExporter(.success(prepared)),
        keyDerivation: CalibratingKeyDerivation(calibration: 600_000),
        logService: SilentLog(),
        onExported: { recorded.count += 1 }
    )

    await flow.generate(ExportRequest(passphrase: Array("correct horse".utf8), iterations: 600_000))
    await flow.shareFinished(completed: true, failed: false)

    #expect(recorded.count == 1)
}

@MainActor
@Test func aShareThatDidNotCompleteIsNotAnExport() async {
    for (completed, failed) in [(false, false), (false, true), (true, true)] {
        let recorded = Closes()
        let flow = ExportFlowModel(
            exporter: FakeExporter(.success(prepared)),
            keyDerivation: CalibratingKeyDerivation(calibration: 600_000),
            logService: SilentLog(),
            onExported: { recorded.count += 1 }
        )

        await flow.generate(ExportRequest(passphrase: Array("correct horse".utf8), iterations: 600_000))
        await flow.shareFinished(completed: completed, failed: failed)

        #expect(recorded.count == 0, "completed: \(completed), failed: \(failed)")
    }
}
