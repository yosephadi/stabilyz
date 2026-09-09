import Foundation

/// Holds a session's samples while it records (docs/07 §7.2, docs/14 §14.3).
///
/// Bounded in memory with an optional temp scratch file behind it. Once the
/// in-memory chunk reaches capacity it is spilled to disk and released, so a
/// long session cannot grow without limit and a lagging consumer cannot force
/// samples to be dropped — **recording is the irreplaceable data** [REC].
///
/// Raw samples never reach the store. They live here and in the scratch file
/// for the duration of the session only, and the scratch file is deleted at
/// freeze or discard (docs/06 §6.4).
///
/// A plain class rather than an actor: it is owned by, and isolated to, the
/// `SessionRecorder` actor. Giving it its own isolation would make every append
/// an `await`, and appends that suspend can interleave — which would reorder
/// the very samples the acquisition order depends on.
final class SessionSampleBuffer {
    /// Samples held in memory before spilling.
    ///
    /// [REC — tunable.] 6000 is a minute at 100 Hz. A full six-minute session is
    /// ~36k samples (~0.5 MB), so this is not a memory necessity; it bounds the
    /// working set and gives the scratch file a crash-recovery role
    /// (docs/06 §6.4).
    static let defaultCapacity = 6_000

    private let fileIO: FileIO
    private let logService: LogService
    private let capacity: Int
    private let scratchURL: URL

    private var inMemory: [SensorSample] = []
    private var spilledCount = 0
    private var hasScratchFile = false
    /// Set when a spill fails. The samples stay in memory instead, so a disk
    /// problem degrades the buffer rather than losing the recording.
    private var scratchDisabled = false

    init(
        fileIO: FileIO,
        logService: LogService,
        capacity: Int = SessionSampleBuffer.defaultCapacity,
        scratchName: String = "session-\(UUID().uuidString).ndjson"
    ) {
        self.fileIO = fileIO
        self.logService = logService
        self.capacity = capacity
        self.scratchURL = fileIO.temporaryDirectory().appendingPathComponent(scratchName)
    }

    /// Total samples held, in memory and on disk.
    var count: Int { spilledCount + inMemory.count }

    var isSpilling: Bool { hasScratchFile }

    func append(_ sample: SensorSample) {
        inMemory.append(sample)
        if inMemory.count >= capacity && !scratchDisabled {
            spill()
        }
    }

    /// Returns every sample in acquisition order and clears the buffer.
    ///
    /// The scratch file is deleted once its contents have been read back; a
    /// session's raw samples never outlive the session (docs/06 §6.4).
    func freeze(anchor: TimeAnchor) -> [SensorSample] {
        if !inMemory.isEmpty && hasScratchFile && !scratchDisabled {
            spill()
        }

        var samples: [SensorSample] = []
        if hasScratchFile {
            samples = readScratch(anchor: anchor)
        }
        samples.append(contentsOf: inMemory)

        reset()
        return samples
    }

    /// Drops everything without producing a buffer, used when a session ends
    /// without a result.
    func discard() {
        reset()
    }

    // MARK: - Scratch file

    private func spill() {
        let records = inMemory.map(ScratchRecord.init)
        do {
            var payload = Data()
            let encoder = JSONEncoder()
            for record in records {
                payload.append(try encoder.encode(record))
                payload.append(0x0A) // newline-delimited, so the file is appendable
            }

            if hasScratchFile, let existing = try? fileIO.read(from: scratchURL) {
                try fileIO.write(existing + payload, to: scratchURL)
            } else {
                try fileIO.write(payload, to: scratchURL)
            }

            hasScratchFile = true
            spilledCount += inMemory.count
            inMemory.removeAll(keepingCapacity: true)
        } catch {
            // Keep the samples in memory. Losing them to a disk error would
            // discard the one thing that cannot be recreated (docs/14 §14.3).
            scratchDisabled = true
            logService.log(.warning, .session, "scratch spill failed; holding samples in memory")
        }
    }

    private func readScratch(anchor: TimeAnchor) -> [SensorSample] {
        guard let data = try? fileIO.read(from: scratchURL) else {
            logService.log(.error, .session, "scratch file unreadable; using in-memory samples only")
            return []
        }

        let decoder = JSONDecoder()
        return data
            .split(separator: 0x0A)
            .compactMap { try? decoder.decode(ScratchRecord.self, from: Data($0)) }
            .map { $0.sensorSample(anchor: anchor) }
    }

    private func reset() {
        inMemory.removeAll()
        spilledCount = 0
        scratchDisabled = false
        if hasScratchFile {
            try? fileIO.remove(at: scratchURL)
            hasScratchFile = false
        }
    }
}

/// The on-disk sample record.
///
/// The anchor is constant for a session, so it is not repeated per sample. The
/// shape deliberately matches `GaitFixture.Sample`: a scratch file is a capture,
/// which is what lets the debug capture tool in docs/07 §7.9 lift a real session
/// into a fixture. The format is ephemeral — the file never outlives the
/// session — so it carries no version.
private struct ScratchRecord: Codable {
    let t: TimeInterval
    let ax: Double
    let ay: Double
    let az: Double
    let gx: Double?
    let gy: Double?
    let gz: Double?

    init(_ sample: SensorSample) {
        t = sample.deviceTimestamp
        ax = sample.acceleration.x
        ay = sample.acceleration.y
        az = sample.acceleration.z
        gx = sample.gravity?.x
        gy = sample.gravity?.y
        gz = sample.gravity?.z
    }

    func sensorSample(anchor: TimeAnchor) -> SensorSample {
        SensorSample(
            deviceTimestamp: t,
            anchor: anchor,
            acceleration: Vector3(x: ax, y: ay, z: az),
            gravity: gx.flatMap { gx in
                guard let gy, let gz else { return nil }
                return Vector3(x: gx, y: gy, z: gz)
            }
        )
    }
}
