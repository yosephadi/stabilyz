import Foundation

/// Access to a file picked outside the app's sandbox (Task 10.3.2).
///
/// A document picker hands back a security-scoped URL: readable only between
/// a start and a matching stop. Injected so the restore screen's hold on the
/// picked file — taken at selection, released on swap, close or success — is
/// testable without a real picker.
protocol SecurityScopedAccess: Sendable {
    /// Starts access. `false` when the URL needs none (a file already inside
    /// the sandbox) or it was refused; either way there is nothing to end.
    func begin(_ url: URL) -> Bool
    func end(_ url: URL)
}

/// The system's security-scoped resource calls.
struct SystemSecurityScopedAccess: SecurityScopedAccess {
    func begin(_ url: URL) -> Bool {
        url.startAccessingSecurityScopedResource()
    }

    func end(_ url: URL) {
        url.stopAccessingSecurityScopedResource()
    }
}
