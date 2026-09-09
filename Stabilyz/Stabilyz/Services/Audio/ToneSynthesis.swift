import AVFoundation
import Foundation

/// The tones the app plays, synthesised rather than shipped.
///
/// No binary assets: a sine burst with a short envelope is a handful of lines,
/// diffable, and avoids carrying audio files whose provenance and licensing
/// would need tracking for a two-tone app.
///
/// **PROVISIONAL — the sounds themselves are unvalidated.** Pitch, length and
/// envelope are placeholders pending device listening (Phase 12). What matters
/// for [PRD AC] is that start and stop are *distinct*, which is asserted by
/// construction below and by test.
struct ToneSpec: Sendable, Equatable {
    let frequency: Double
    let duration: Double
    /// Fraction of the tone spent fading in and out. A hard edge on a sine
    /// burst clicks, which reads as a defect rather than a cue.
    let fadeFraction: Double
    let amplitude: Double

    /// PROVISIONAL. Rising pitch for start.
    static let start = ToneSpec(frequency: 880, duration: 0.18, fadeFraction: 0.2, amplitude: 0.5)
    /// PROVISIONAL. Lower and slightly longer for stop, so the two are
    /// distinguishable without looking at the screen [PRD AC].
    static let stop = ToneSpec(frequency: 440, duration: 0.28, fadeFraction: 0.2, amplitude: 0.5)
    /// PROVISIONAL. Short and quiet: a step tick fires often and must not
    /// dominate the walk.
    static let stepTick = ToneSpec(frequency: 1_320, duration: 0.05, fadeFraction: 0.35, amplitude: 0.3)
    /// PROVISIONAL. The metronome click, Task 7.2.2.
    static let metronome = ToneSpec(frequency: 1_000, duration: 0.06, fadeFraction: 0.3, amplitude: 0.35)
}

/// Renders a `ToneSpec` into a PCM buffer.
enum ToneSynthesis {
    /// Builds the buffer once, at start-up, so the play path never allocates or
    /// synthesises — [PRD §7] requires the sound to feel connected to the step.
    static func buffer(for spec: ToneSpec, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let sampleRate = format.sampleRate
        let frameCount = AVAudioFrameCount(spec.duration * sampleRate)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
        else { return nil }

        buffer.frameLength = frameCount
        let fadeFrames = max(1, Int(Double(frameCount) * spec.fadeFraction))

        for channel in 0..<Int(format.channelCount) {
            guard let samples = buffer.floatChannelData?[channel] else { continue }
            for frame in 0..<Int(frameCount) {
                let time = Double(frame) / sampleRate
                let value = sin(2 * .pi * spec.frequency * time)

                // Linear fade at each end.
                let fadeIn = min(1.0, Double(frame) / Double(fadeFrames))
                let fadeOut = min(1.0, Double(Int(frameCount) - frame) / Double(fadeFrames))
                samples[frame] = Float(value * spec.amplitude * min(fadeIn, fadeOut))
            }
        }
        return buffer
    }
}
