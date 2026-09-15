import Foundation

/// An error whose description names a case and carries nothing a person could
/// be identified by, and no health data: counts, versions, modes and random
/// session ids at most (docs/20).
protocol LogSafeError: Error {}

/// What an error may say in a log (Task 11.1.2, docs/20, docs/15 §15.2).
///
/// Every log message is recorded with `.public` privacy (`OSLogService`), so
/// the call site is the only place redaction can happen. A bare `\(error)`
/// hands the log whatever the error's description happens to contain — and
/// some do carry user data: `EntityMapping.MappingError` quotes the stored
/// profile field it could not read. So errors are described through here:
///
/// - `StabilyzError`: its `technicalDescription`, whose payloads are integers;
/// - a `LogSafeError`: its case, as written;
/// - anything else: its type and bridged domain and code — never its
///   description or user info.
enum LogRedaction {
    static func describe(_ error: Error) -> String {
        if let error = error as? StabilyzError {
            return error.technicalDescription
        }
        if error is LogSafeError {
            return String(describing: error)
        }
        let bridged = error as NSError
        return "\(type(of: error)) (\(bridged.domain) code \(bridged.code))"
    }
}

// Audited: every associated value is an Int, a TestMode or a session UUID.
extension BaselineCalculationService.CalculationError: LogSafeError {}
extension ArchiveEncodingError: LogSafeError {}
extension ArchiveInspectionError: LogSafeError {}
extension StoreSnapshotCoding.DecodingError: LogSafeError {}
