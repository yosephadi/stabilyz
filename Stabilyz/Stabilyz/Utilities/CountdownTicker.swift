import Foundation

/// Waits out one countdown interval (docs/12 §12.2).
///
/// Injected for the same reason `Clock` is: a countdown that slept on the real
/// clock could only be tested by actually waiting five seconds, and a test that
/// waits is a test that is slow *and* flaky. A double drives the cadence
/// directly, so every assertion about tick order and cancellation is
/// deterministic.
///
/// Non-throwing, and **cancellation-aware**: a cancelled wait returns rather
/// than throwing, because a cancelled countdown is an ordinary outcome
/// ([PRD OQ-6] — the user tapped Cancel, the app was backgrounded) and not an
/// error anyone should have to catch. The caller checks `Task.isCancelled`
/// after the wait to find out which happened.
protocol CountdownTicker: Sendable {
    func waitForTick(_ interval: Duration) async
}

/// Sleeps for real. The production ticker.
struct RealTimeCountdownTicker: CountdownTicker {
    init() {}

    func waitForTick(_ interval: Duration) async {
        // `try?` rather than `try`: `Task.sleep` throws on cancellation, and
        // cancelling a countdown is not an error. Returning early is exactly
        // right — the caller's next `Task.isCancelled` check takes it from
        // there, and a user who taps Cancel mid-second is not made to wait out
        // the rest of it.
        try? await Task.sleep(for: interval)
    }
}
