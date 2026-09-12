import Foundation

/// Where the session cover is (docs/11 §11.3).
///
/// `countdown → recording → processing → finished` , with `failed` reachable
/// from any of them. A pure enum in its own file so the cover's routing is a
/// total function of it, and testable without rendering (docs/11 §11.5).
///
/// The countdown's own sub-states live on `CountdownCoordinator`; this is the
/// coarser question of which screen the cover is showing.
enum SessionFlowPhase: Equatable {
    /// Counting in. The walk is drawn underneath, so this is really
    /// "recording, with the overlay up".
    case countdown
    /// Walking.
    case recording
    /// Stopped, and the pipeline is running. **Non-dismissible** — the walk is
    /// already recorded and the analysis is all that stands between it and a
    /// result [PRD §5].
    case processing
    /// Committed. Carries what the Score or Noisy screen needs (Task 8.2.5).
    case finished(SessionCommitResult)
    /// The walk could not be analysed or stored. Carries the error the screen
    /// explains through `ErrorPresenter` (docs/15 §15.1).
    case failed(StabilyzError)

    /// Whether the user may leave by their own action.
    ///
    /// False while processing: there is no Cancel, because cancelling would
    /// leave a recorded walk the user can never see [PRD §5 — after
    /// processing, route to Noisy or Score, never neither].
    var isDismissible: Bool {
        switch self {
        case .countdown, .recording, .processing: false
        case .finished, .failed: true
        }
    }

    /// Whether the walk is still being measured. The recorder is live in both.
    var isRecording: Bool {
        switch self {
        case .countdown, .recording: true
        case .processing, .finished, .failed: false
        }
    }

    var result: SessionCommitResult? {
        guard case .finished(let result) = self else { return nil }
        return result
    }

    var error: StabilyzError? {
        guard case .failed(let error) = self else { return nil }
        return error
    }
}
