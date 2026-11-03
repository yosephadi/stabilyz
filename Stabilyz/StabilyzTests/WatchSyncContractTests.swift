import Foundation
import Testing
@testable import Stabilyz

/// The phone ↔ watch message contract (Task 12.1.2, docs/04 §4.18,
/// docs/21 §21.2).
@Suite struct WatchSyncContractTests {
    static let sessionID = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!
    /// Deliberately not a whole number: the fraction is what a lossy date
    /// encoding would drop.
    static let goAt = Date(timeIntervalSince1970: 1_793_000_000.123_456)

    static let phoneMessages: [PhoneToWatchMessage] = [
        .countdownStarted(
            sessionID: sessionID,
            mode: .quick,
            durationSeconds: 120,
            plannedGoAt: goAt,
            hapticOwner: .watch,
            hapticsEnabled: true
        ),
        .countdownStarted(
            sessionID: sessionID,
            mode: .full,
            durationSeconds: 360,
            plannedGoAt: goAt,
            hapticOwner: .phone,
            hapticsEnabled: false
        ),
        .started(sessionID: sessionID, t0: goAt.addingTimeInterval(0.004_2)),
        .stopped(sessionID: sessionID),
        .cancelled(sessionID: sessionID),
        .hapticsChanged(enabled: false),
        .hapticsChanged(enabled: true),
    ]

    static func json(_ text: String) -> Data { Data(text.utf8) }

    // MARK: Round trips

    @Test(arguments: phoneMessages)
    func everyPhoneMessageRoundTrips(_ message: PhoneToWatchMessage) throws {
        let data = try WatchSyncCoder.encode(message)
        #expect(WatchSyncCoder.decodePhoneToWatch(data) == message)
    }

    @Test func theStopRequestRoundTrips() throws {
        let message = WatchToPhoneMessage.stopRequest(sessionID: Self.sessionID)
        let data = try WatchSyncCoder.encode(message)
        #expect(WatchSyncCoder.decodeWatchToPhone(data) == message)
    }

    @Test func datesSurviveTheWireExactly() throws {
        let t0 = Date(timeIntervalSince1970: 1_793_000_005.000_123_4)
        let data = try WatchSyncCoder.encode(PhoneToWatchMessage.started(sessionID: Self.sessionID, t0: t0))
        guard case .started(_, let decoded) = WatchSyncCoder.decodePhoneToWatch(data) else {
            Issue.record("did not decode a started message")
            return
        }
        #expect(decoded.timeIntervalSince1970 == t0.timeIntervalSince1970)
    }

    // MARK: Versioning

    @Test func everyEncodedMessageCarriesTheCurrentVersion() throws {
        let data = try WatchSyncCoder.encode(PhoneToWatchMessage.stopped(sessionID: Self.sessionID))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["version"] as? Int == WatchSyncVersion.current)
        #expect(WatchSyncVersion.current == 1)
    }

    @Test(arguments: [0, 2, 99, -1])
    func anUnknownVersionIsDropped(_ version: Int) throws {
        let phone = try WatchSyncCoder.encode(PhoneToWatchMessage.stopped(sessionID: Self.sessionID), version: version)
        let watch = try WatchSyncCoder.encode(WatchToPhoneMessage.stopRequest(sessionID: Self.sessionID), version: version)
        #expect(WatchSyncCoder.decodePhoneToWatch(phone) == nil)
        #expect(WatchSyncCoder.decodeWatchToPhone(watch) == nil)
    }

    @Test func aMissingVersionIsDropped() {
        let data = Self.json(#"{"message":{"stopped":{"sessionID":"6F9619FF-8B86-D011-B42D-00C04FC964FF"}}}"#)
        #expect(WatchSyncCoder.decodePhoneToWatch(data) == nil)
    }

    @Test func aNonIntegerVersionIsDropped() {
        let data = Self.json(#"{"version":"1","message":{"stopped":{"sessionID":"6F9619FF-8B86-D011-B42D-00C04FC964FF"}}}"#)
        #expect(WatchSyncCoder.decodePhoneToWatch(data) == nil)
    }

    // MARK: Malformed input

    @Test func junkIsDropped() {
        #expect(WatchSyncCoder.decodePhoneToWatch(Data()) == nil)
        #expect(WatchSyncCoder.decodePhoneToWatch(Self.json("not json")) == nil)
        #expect(WatchSyncCoder.decodePhoneToWatch(Self.json(#"{"version":1}"#)) == nil)
        #expect(WatchSyncCoder.decodeWatchToPhone(Self.json("[]")) == nil)
    }

    @Test func anUnknownMessageTypeIsDropped() {
        let data = Self.json(#"{"version":1,"message":{"paused":{"sessionID":"6F9619FF-8B86-D011-B42D-00C04FC964FF"}}}"#)
        #expect(WatchSyncCoder.decodePhoneToWatch(data) == nil)
    }

    @Test func anUnknownModeIsDropped() {
        let data = Self.json(#"{"version":1,"message":{"countdownStarted":{"sessionID":"6F9619FF-8B86-D011-B42D-00C04FC964FF","mode":"quickTest","durationSeconds":120,"plannedGoAt":1793000000,"hapticOwner":"watch","hapticsEnabled":true}}}"#)
        #expect(WatchSyncCoder.decodePhoneToWatch(data) == nil)
    }

    @Test func aMessageIsNotReadInTheWrongDirection() throws {
        let fromPhone = try WatchSyncCoder.encode(PhoneToWatchMessage.stopped(sessionID: Self.sessionID))
        let fromWatch = try WatchSyncCoder.encode(WatchToPhoneMessage.stopRequest(sessionID: Self.sessionID))
        #expect(WatchSyncCoder.decodeWatchToPhone(fromPhone) == nil)
        #expect(WatchSyncCoder.decodePhoneToWatch(fromWatch) == nil)
    }

    // MARK: Pinned wire format

    /// A version-1 payload written by hand. If this stops decoding, the wire
    /// format changed and `WatchSyncVersion` must be bumped.
    @Test func aHandWrittenVersionOnePayloadStillDecodes() {
        let countdown = Self.json(#"{"version":1,"message":{"countdownStarted":{"sessionID":"6F9619FF-8B86-D011-B42D-00C04FC964FF","mode":"full","durationSeconds":360,"plannedGoAt":1793000000.5,"hapticOwner":"phone","hapticsEnabled":false}}}"#)
        let stop = Self.json(#"{"version":1,"message":{"stopRequest":{"sessionID":"6F9619FF-8B86-D011-B42D-00C04FC964FF"}}}"#)
        let haptics = Self.json(#"{"version":1,"message":{"hapticsChanged":{"enabled":true}}}"#)

        #expect(WatchSyncCoder.decodePhoneToWatch(countdown) == .countdownStarted(
            sessionID: Self.sessionID,
            mode: .full,
            durationSeconds: 360,
            plannedGoAt: Date(timeIntervalSince1970: 1_793_000_000.5),
            hapticOwner: .phone,
            hapticsEnabled: false
        ))
        #expect(WatchSyncCoder.decodeWatchToPhone(stop) == .stopRequest(sessionID: Self.sessionID))
        #expect(WatchSyncCoder.decodePhoneToWatch(haptics) == .hapticsChanged(enabled: true))
    }

    @Test func wireRawValuesArePinned() {
        #expect(WireTestMode.allCases.map(\.rawValue) == ["quick", "full"])
        #expect(WireHapticOwner.allCases.map(\.rawValue) == ["phone", "watch"])
    }

    // MARK: Session scoping

    @Test func sessionScopedMessagesExposeTheirSession() {
        for message in Self.phoneMessages {
            if case .hapticsChanged = message {
                #expect(message.sessionID == nil)
            } else {
                #expect(message.sessionID == Self.sessionID)
            }
        }
    }
}
