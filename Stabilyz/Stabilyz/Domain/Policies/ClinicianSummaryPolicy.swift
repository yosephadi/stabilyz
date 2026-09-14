/// The Clinician Summary's window (docs/04 §4.14, Task 9.2.1).
enum ClinicianSummaryPolicy {
    /// How many **scored** walks the "Last N Sessions" list shows, per mode.
    ///
    /// Decided 2026-09-14: five, a one-to-one match for the five walks the
    /// baseline is built from. This resolves docs/21 #9's `[OPEN]` N **for the
    /// clinician screen only**. `SummaryPolicy.recentSessionCount` — the window
    /// each user-facing summary line is compared against at commit — is a
    /// separate, versioned algorithm setting and deliberately stays where it is.
    ///
    /// Calibration walks never count toward it: they carry no relative score.
    static let recentScoredSessionCount = 5
}
