import Foundation

/// Thrown by a dependency slot that has no implementation yet.
///
/// The composition root is built in Phase 1 (docs/22) but most concrete
/// services arrive in later phases. Rather than leave those slots optional —
/// which would push `if let` noise into every call site permanently — they are
/// filled with conformances that fail loudly and name the task that replaces
/// them. Nothing calls these yet; the app launches to a placeholder screen.
struct DependencyNotWired: Error, Equatable, CustomStringConvertible {
    /// The protocol that has no live implementation.
    let dependency: String
    /// The task in docs/23-engineering-task-breakdown.md that supplies it.
    let owningTask: String

    var description: String {
        "\(dependency) is not wired yet — supplied by Task \(owningTask)."
    }
}

// MARK: - Motion (Tasks 4.1.1 / 4.1.2)

/// Reports the hardware as unavailable, which is the honest state before
/// Task 4.1.1 lands: Session Setup already treats "no sensor" as a degraded
/// Start (docs/07 §7.6).
struct UnwiredMotionSensorService: MotionSensorService {
    var isAvailable: Bool { get async { false } }
    var authorizationStatus: MotionAuthorizationStatus { get async { .notDetermined } }

    func requestAuthorization() async -> MotionAuthorizationStatus { .notDetermined }

    func start(policy: MotionAcquisitionPolicy) async throws -> AsyncStream<SensorSample> {
        throw DependencyNotWired(dependency: "MotionSensorService", owningTask: "4.1.1")
    }

    func stop() async {}
}

struct UnwiredPedometerService: PedometerService {
    var isAvailable: Bool { get async { false } }
    var authorizationStatus: MotionAuthorizationStatus { get async { .notDetermined } }

    func start() async throws -> AsyncStream<PedometerEvent> {
        throw DependencyNotWired(dependency: "PedometerService", owningTask: "4.1.2")
    }

    func stop() async {}

    func events(from start: Date, to end: Date) async throws -> PedometerEvent? {
        throw DependencyNotWired(dependency: "PedometerService", owningTask: "4.1.2")
    }
}

// MARK: - Audio (Task 7.1.1)

/// Silence, which is exactly the specified degraded behaviour: audio failure is
/// surfaced only as silent degradation and can never fail a session
/// (docs/10 §10.4).
///
/// **No longer in either production graph** — both now hold
/// `EngineAudioFeedbackService`. This stays as the preview and test double
/// docs/12 §12.2 calls for: a conformance that does nothing, for the places that
/// need an `AudioFeedbackService` and no sound.
struct SilentAudioFeedbackService: AudioFeedbackService {
    var events: AsyncStream<AudioFeedbackEvent> {
        AsyncStream { $0.finish() }
    }

    init() {}

    func playStartTone() async {}
    func playStopTone() async {}
    func playStepTick() async {}
    func startMetronome(bpm: Double) async {}
    func stopMetronome() async {}
    func suspend() async {}
    func resume() async {}
}

// MARK: - Crypto (Tasks 10.1.1 / 10.1.3)

/// Deliberately not backed by a stand-in RNG or KDF. Substituting a non-vetted
/// primitive here — even temporarily — is the exact failure the PRD's
/// "no custom cryptography" rule exists to prevent.
///
/// **The RNG and KDF are no longer in either production graph** — both hold
/// `SystemRandomSource` and `CommonCryptoKeyDerivation` (Task 10.1.1). These
/// two stay as doubles that fail loudly, for tests that must prove nothing
/// quietly substitutes for them.
struct UnwiredRandomSource: RandomSource {
    func bytes(count: Int) throws -> [UInt8] {
        throw DependencyNotWired(dependency: "RandomSource", owningTask: "10.1.1")
    }
}

struct UnwiredKeyDerivation: KeyDerivation {
    func deriveKey(passphrase: [UInt8], salt: [UInt8], iterations: Int, keyByteCount: Int) throws -> [UInt8] {
        throw DependencyNotWired(dependency: "KeyDerivation", owningTask: "10.1.1")
    }

    func calibratedIterationCount(targetDuration: TimeInterval) -> Int {
        // Calibration needs the real KDF; docs/13 §13.2 starting point until then.
        300_000
    }
}

/// The archive envelope — header, KDF parameters, key-check value, payload —
/// arrives with Task 10.1.3, composed from `CommonCryptoKeyDerivation` and
/// `AESGCMEncryptionService` (Task 10.1.2).
struct UnwiredSecureArchiveCoding: SecureArchiveCoding {
    func seal(payload: Data, passphrase: [UInt8]) async throws -> Data {
        throw DependencyNotWired(dependency: "SecureArchiveCoding", owningTask: "10.1.3")
    }

    func open(archive: Data, passphrase: [UInt8]) async throws -> Data {
        throw DependencyNotWired(dependency: "SecureArchiveCoding", owningTask: "10.1.3")
    }
}

// MARK: - Repositories (Tasks 3.2.1 / 3.2.2 / 3.2.3)

/// Reads throw rather than returning empty results: an empty read would look
/// like "no data yet" and could route the app through onboarding or report a
/// baseline as missing, which is worse than a loud failure.
struct UnwiredUserProfileRepository: UserProfileRepository {
    func fetchProfile() async throws -> UserProfile? {
        throw DependencyNotWired(dependency: "UserProfileRepository", owningTask: "3.2.3")
    }

    func save(_ profile: UserProfile) async throws {
        throw DependencyNotWired(dependency: "UserProfileRepository", owningTask: "3.2.3")
    }
}

struct UnwiredGaitSessionRepository: GaitSessionRepository {
    private var notWired: DependencyNotWired {
        DependencyNotWired(dependency: "GaitSessionRepository", owningTask: "3.2.1")
    }

    func save(_ session: GaitSession) async throws { throw notWired }
    func session(id: UUID) async throws -> GaitSession? { throw notWired }

    func sessions(mode: TestMode, includeInvalid: Bool, limit: Int?) async throws -> [GaitSession] {
        throw notWired
    }

    func validSessionCount(mode: TestMode) async throws -> Int { throw notWired }
}

struct UnwiredBaselineRepository: BaselineRepository {
    private var notWired: DependencyNotWired {
        DependencyNotWired(dependency: "BaselineRepository", owningTask: "3.2.2")
    }

    func baseline(mode: TestMode) async throws -> Baseline? { throw notWired }
    func save(_ baseline: Baseline) async throws { throw notWired }
    func allBaselines() async throws -> [Baseline] { throw notWired }
}
