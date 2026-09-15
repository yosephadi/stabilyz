// On-device calibration screen for Task 11.2.2.

#if DEBUG
import SwiftUI

/// Settings → Diagnostics, in debug builds only: run the PBKDF2 benchmark and
/// read the audio route's latency on a real iPhone.
///
/// Everything is also logged under the `backup` and `audio` categories, so a
/// device session can be read back from Console without screenshots.
struct DiagnosticsView: View {
    let benchmark: HardwareBenchmark

    @State private var derivation: HardwareBenchmark.DerivationReport?
    @State private var audio: AudioRouteReport?
    @State private var hasReadAudio = false
    @State private var isMeasuring = false
    @State private var failure: String?

    var body: some View {
        List {
            Section {
                Button(isMeasuring ? "Measuring…" : "Measure PBKDF2") { measure() }
                    .disabled(isMeasuring)
                    .accessibilityIdentifier("diagnostics.measureKDF")

                if let derivation {
                    ForEach(derivation.timings) { timing in
                        LabeledContent(
                            "\(timing.iterations.formatted()) iterations",
                            value: "\(Int(timing.milliseconds.rounded())) ms"
                        )
                    }
                    LabeledContent("Calibrated for target", value: derivation.calibratedIterations.formatted())
                    LabeledContent("An export would use", value: derivation.exportIterations.formatted())
                }
                if let failure {
                    Text(failure)
                }
            } header: {
                Text("Key derivation")
            } footer: {
                Text("Task 11.2.2. Run on the oldest iPhone the app supports; the export targets about 300 ms.")
            }

            Section {
                Button("Read audio route") {
                    Task {
                        audio = await benchmark.readAudio()
                        hasReadAudio = true
                    }
                }
                    .accessibilityIdentifier("diagnostics.readAudio")

                if let audio {
                    LabeledContent("Output latency", value: milliseconds(audio.outputLatency))
                    LabeledContent("IO buffer", value: milliseconds(audio.ioBufferDuration))
                    LabeledContent("Sample rate", value: "\(Int(audio.sampleRate)) Hz")
                    LabeledContent("Route", value: audio.outputPorts.joined(separator: ", "))
                    LabeledContent("Category", value: audio.category)
                } else if hasReadAudio {
                    Text("No audio engine in this build's graph.")
                }
            } header: {
                Text("Audio")
            } footer: {
                Text("Read-only. Most meaningful with headphones or the speaker route you walk with.")
            }
        }
        .navigationTitle("Diagnostics")
        .accessibilityIdentifier("diagnostics.screen")
    }

    private func milliseconds(_ seconds: TimeInterval) -> String {
        "\((seconds * 1_000).formatted(.number.precision(.fractionLength(1)))) ms"
    }

    private func measure() {
        isMeasuring = true
        failure = nil
        let benchmark = self.benchmark
        Task {
            do {
                derivation = try await Task.detached(priority: .userInitiated) {
                    try benchmark.measureKeyDerivation()
                }.value
            } catch {
                failure = "Measurement failed: \(LogRedaction.describe(error))"
            }
            isMeasuring = false
        }
    }
}
#endif
