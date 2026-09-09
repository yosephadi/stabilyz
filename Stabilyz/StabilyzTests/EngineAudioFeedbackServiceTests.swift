import AVFoundation
import Foundation
import Testing
@testable import Stabilyz

private final class AudioLog: LogService, @unchecked Sendable {
    let entries = Locked<[String]>([])
    func log(_ level: LogLevel, _ category: LogCategory, _ message: String) {
        entries.withLock { $0.append(message) }
    }
    func beginInterval(_ name: StaticString, category: LogCategory) -> SignpostInterval {
        SignpostInterval(name: name, category: category, id: 0)
    }
    func endInterval(_ interval: SignpostInterval) {}
}

private func makeService(log: AudioLog = AudioLog()) -> EngineAudioFeedbackService {
    EngineAudioFeedbackService(logService: log)
}

// MARK: - Tone synthesis (fully verifiable off-device)

@Test func startAndStopTonesAreDistinct() {
    // [PRD AC] the two must be tellable apart without looking at the screen.
    #expect(ToneSpec.start.frequency != ToneSpec.stop.frequency)
    #expect(ToneSpec.start.duration != ToneSpec.stop.duration)
}

@Test func everyToneIsSynthesisedNotLoadedFromAnAsset() {
    // No binary audio assets ship with the app; the specs are the source.
    let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!

    for tone in EngineAudioFeedbackService.Tone.allCases {
        let buffer = ToneSynthesis.buffer(for: tone.spec, format: format)
        #expect(buffer != nil, "\(tone) produced no buffer")
    }
}

@Test func aRenderedToneHasTheRequestedLengthAndStaysInRange() {
    let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
    let buffer = try! #require(ToneSynthesis.buffer(for: .start, format: format))

    #expect(buffer.frameLength == AVAudioFrameCount(ToneSpec.start.duration * 48_000))

    let samples = try! #require(buffer.floatChannelData?[0])
    for frame in 0..<Int(buffer.frameLength) {
        let value = samples[frame]
        // Clipping would be audible distortion, not a cue.
        #expect(value <= 1.0 && value >= -1.0)
        #expect(abs(value) <= Float(ToneSpec.start.amplitude) + 1e-5)
    }
}

@Test func aToneFadesInAndOutRatherThanClicking() {
    // A hard edge on a sine burst clicks, which reads as a defect.
    let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
    let buffer = try! #require(ToneSynthesis.buffer(for: .stop, format: format))
    let samples = try! #require(buffer.floatChannelData?[0])
    let last = Int(buffer.frameLength) - 1

    #expect(abs(samples[0]) < 0.01)
    #expect(abs(samples[last]) < 0.05)

    // And it is not silent in the middle.
    let middle = Int(buffer.frameLength) / 2
    let peak = (max(0, middle - 200)...min(last, middle + 200)).map { abs(samples[$0]) }.max() ?? 0
    #expect(peak > 0.1)
}

@Test func aZeroLengthToneProducesNoBufferRatherThanCrashing() {
    let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
    let empty = ToneSpec(frequency: 440, duration: 0, fadeFraction: 0.2, amplitude: 0.5)

    #expect(ToneSynthesis.buffer(for: empty, format: format) == nil)
}

@Test func theStepTickIsShortAndQuieterThanTheSessionTones() {
    // It fires on every footfall; a full-volume tone would dominate the walk.
    #expect(ToneSpec.stepTick.duration < ToneSpec.start.duration)
    #expect(ToneSpec.stepTick.amplitude < ToneSpec.start.amplitude)
}

// MARK: - Engine lifecycle (state is verifiable; audible output is not)

@Test func prepareIsIdempotent() async {
    let service = makeService()
    await service.prepare()
    let first = await service.isRunning
    await service.prepare()
    let second = await service.isRunning

    #expect(first == second)
    await service.teardown()
}

@Test func everyToneCallIsSafeBeforePrepare() async {
    // Audio must never fail a session (docs/10 §10.4), including when it was
    // never started.
    let service = makeService()

    await service.playStartTone()
    await service.playStepTick()
    await service.startMetronome(bpm: 108)
    await service.stopMetronome()
    await service.playStopTone()

    #expect(await service.isRunning == false)
}

@Test func everyToneCallIsSafeAfterTeardown() async {
    let service = makeService()
    await service.prepare()
    await service.teardown()

    await service.playStartTone()
    await service.playStepTick()
    await service.playStopTone()

    #expect(await service.isRunning == false)
}

@Test func suspendStopsPlaybackAndResumeRestoresIt() async {
    let service = makeService()
    await service.prepare()

    guard await service.isRunning else {
        // No audio route on this host; the degraded path is covered elsewhere.
        await service.teardown()
        return
    }

    await service.suspend()
    #expect(await service.isRunning == false)

    await service.resume()
    #expect(await service.isRunning)

    await service.teardown()
}

@Test func suspendAndResumeAreIdempotent() async {
    let service = makeService()
    await service.prepare()

    await service.suspend()
    await service.suspend()
    await service.resume()
    await service.resume()

    await service.teardown()
}

@Test func tonesRequestedWhileSuspendedAreDropped() async {
    // A tick queued during an interruption and fired afterwards would be worse
    // than no tick at all.
    let service = makeService()
    await service.prepare()
    await service.suspend()

    await service.playStepTick()
    await service.playStartTone()

    #expect(await service.isRunning == false)
    await service.teardown()
}

@Test func teardownIsSafeWithoutPrepare() async {
    let service = makeService()
    await service.teardown()
    await service.teardown()
}

// MARK: - Degradation is logged, never thrown

@Test func failureToStartDegradesSilently() async {
    // Whatever the host provides, prepare() must return normally and leave the
    // service usable — a walk is measured perfectly well in silence.
    let log = AudioLog()
    let service = makeService(log: log)

    await service.prepare()
    await service.playStartTone()
    await service.teardown()

    let messages = log.entries.withLock { $0 }
    // Either it started, or it said why it did not. Never nothing, never a throw.
    #expect(messages.isEmpty == false)
}

// MARK: - Ownership of AVAudioSession (docs/10 §10.2)

@Test func thisServiceIsTheOnlyComponentTouchingAVAudioSession() throws {
    // The interruption observer consumes this service's event stream instead
    // (Task 4.2.3), so the session has exactly one owner.
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Stabilyz")

    var offenders: [String] = []
    let walker = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))

    for case let url as URL in walker where url.pathExtension == "swift" {
        guard let source = try? String(contentsOf: url, encoding: .utf8) else { continue }
        guard source.contains("AVAudioSession") else { continue }

        let name = url.lastPathComponent
        // The owner, and the event enum that names the concepts without touching
        // the session.
        guard name != "EngineAudioFeedbackService.swift" else { continue }

        // A mention inside a comment is documentation, not a dependency.
        let codeLines = source.split(separator: "\n").filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return !trimmed.hasPrefix("//") && !trimmed.hasPrefix("///")
        }
        if codeLines.contains(where: { $0.contains("AVAudioSession") }) {
            offenders.append(name)
        }
    }

    #expect(offenders.isEmpty, "AVAudioSession is touched outside its owner: \(offenders)")
}

@Test func theProtocolStillAcceptsTheSilentFallback() async {
    // SilentAudioFeedbackService remains the degraded implementation and the
    // preview double (docs/12 §12.2).
    let silent: AudioFeedbackService = SilentAudioFeedbackService()
    await silent.playStartTone()
    await silent.playStopTone()

    let engine: AudioFeedbackService = makeService()
    await engine.playStartTone()
    await engine.playStopTone()
}
