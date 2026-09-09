import Foundation

/// A recorded or synthesised sensor capture (docs/07 §7.9).
///
/// The on-disk format is JSON: debuggable, diffable, and cheap to migrate. Keys
/// are short because a six-minute capture at 100 Hz is ~36k samples.
///
/// Captures carry the **known gait parameters** they were built or recorded to
/// represent, so a test can assert against what the fixture is supposed to be
/// rather than against magic numbers.
struct GaitFixture: Codable, Equatable, Sendable {
    /// Bumped when the file layout changes, so old captures stay readable.
    static let currentFormatVersion = 1

    struct Metadata: Codable, Equatable, Sendable {
        let name: String
        let formatVersion: Int
        let sampleRateHz: Double
        /// Whether samples carry a gravity vector (device-motion capture).
        let deviceMotionIncluded: Bool
        /// Cadence the capture represents, when known.
        let cadenceBPM: Double?
        /// Signal-to-noise ratio the capture represents, when known.
        let signalToNoiseRatio: Double?
        /// What this fixture is for, in words.
        let notes: String?

        init(
            name: String,
            formatVersion: Int = GaitFixture.currentFormatVersion,
            sampleRateHz: Double,
            deviceMotionIncluded: Bool,
            cadenceBPM: Double? = nil,
            signalToNoiseRatio: Double? = nil,
            notes: String? = nil
        ) {
            self.name = name
            self.formatVersion = formatVersion
            self.sampleRateHz = sampleRateHz
            self.deviceMotionIncluded = deviceMotionIncluded
            self.cadenceBPM = cadenceBPM
            self.signalToNoiseRatio = signalToNoiseRatio
            self.notes = notes
        }
    }

    /// One sample. `t` is a device timestamp in seconds, on the same monotonic
    /// timebase as `SensorSample.deviceTimestamp` (docs/07 §7.4).
    ///
    /// **Gaps are represented by absence**: a suspension is simply a jump in
    /// `t`, exactly as CoreMotion delivers it, so a fixture can script the gap
    /// cases docs/07 §7.7 describes without any extra encoding.
    struct Sample: Codable, Equatable, Sendable {
        let t: TimeInterval
        let ax: Double
        let ay: Double
        let az: Double
        let gx: Double?
        let gy: Double?
        let gz: Double?

        init(t: TimeInterval, ax: Double, ay: Double, az: Double, gx: Double? = nil, gy: Double? = nil, gz: Double? = nil) {
            self.t = t
            self.ax = ax
            self.ay = ay
            self.az = az
            self.gx = gx
            self.gy = gy
            self.gz = gz
        }
    }

    /// A scripted pedometer update (docs/12 §12.2).
    struct PedometerScriptEntry: Codable, Equatable, Sendable {
        /// Offset from the capture start, in seconds.
        let t: TimeInterval
        let steps: Int
        let cadence: Double?
        let pace: Double?
        let distance: Double?

        init(t: TimeInterval, steps: Int, cadence: Double? = nil, pace: Double? = nil, distance: Double? = nil) {
            self.t = t
            self.steps = steps
            self.cadence = cadence
            self.pace = pace
            self.distance = distance
        }
    }

    let metadata: Metadata
    let samples: [Sample]
    let pedometerScript: [PedometerScriptEntry]

    init(metadata: Metadata, samples: [Sample], pedometerScript: [PedometerScriptEntry] = []) {
        self.metadata = metadata
        self.samples = samples
        self.pedometerScript = pedometerScript
    }

    enum LoadError: Error, Equatable {
        case unsupportedFormatVersion(Int)
        case empty
    }

    /// Decodes a capture, refusing formats this build does not understand
    /// rather than silently misreading them.
    static func decode(from data: Data) throws -> GaitFixture {
        let fixture = try JSONDecoder().decode(GaitFixture.self, from: data)

        guard fixture.metadata.formatVersion <= currentFormatVersion else {
            throw LoadError.unsupportedFormatVersion(fixture.metadata.formatVersion)
        }
        guard !fixture.samples.isEmpty else {
            throw LoadError.empty
        }
        return fixture
    }

    func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }

    /// Capture length measured from device timestamps, not sample count, so a
    /// scripted gap is reflected honestly.
    var duration: TimeInterval {
        guard let first = samples.first, let last = samples.last else { return 0 }
        return last.t - first.t
    }

    /// Capture timestamps are relative to the start of the capture. Replaying
    /// places them on the live uptime timebase by offsetting from the anchor,
    /// so a fixture is indistinguishable from hardware delivering now
    /// (docs/07 §7.4).
    func sensorSamples(anchoredAt anchor: TimeAnchor) -> [SensorSample] {
        samples.map { sample in
            SensorSample(
                deviceTimestamp: anchor.uptime + sample.t,
                anchor: anchor,
                acceleration: Vector3(x: sample.ax, y: sample.ay, z: sample.az),
                gravity: sample.gx.flatMap { gx in
                    guard let gy = sample.gy, let gz = sample.gz else { return nil }
                    return Vector3(x: gx, y: gy, z: gz)
                }
            )
        }
    }
}
