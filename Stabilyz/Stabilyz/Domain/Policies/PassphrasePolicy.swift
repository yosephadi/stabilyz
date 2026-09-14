import Foundation

/// The export passphrase's rules (docs/13 §13.2–13.3, Task 10.2.1).
///
/// One place for both the rule the export wizard enforces and the form a
/// passphrase takes before it becomes a key, so they cannot drift: what is
/// measured is exactly what is encrypted, and restore canonicalizes the same
/// way export did.
enum PassphrasePolicy {
    /// Decided 2026-09-15 (docs/13 §13.3 had left the minimum as a product
    /// decision): eight characters, counted after edge whitespace is removed.
    static let minimumLength = 8

    enum Issue: Equatable {
        /// Nothing but whitespace, or nothing at all.
        case empty
        case tooShort(minimum: Int)
        /// The confirmation cannot be, or become, the passphrase.
        case mismatch
    }

    /// The passphrase as it becomes key material: leading and trailing
    /// whitespace removed, then Unicode NFC.
    ///
    /// **Trimmed both ways — decided 2026-09-15.** A space the keyboard adds at
    /// the end of a word must never lock someone out of their own backup, so
    /// export and restore both drop it. Spaces *inside* the passphrase are
    /// part of it.
    ///
    /// NFC, because an accented letter can arrive as one code point or as a
    /// letter plus a combining mark depending on the keyboard; the two must
    /// derive the same key (docs/13 §13.2 [REC]).
    ///
    /// **This is a file-format contract.** Changing it would stop existing
    /// backups opening.
    static func canonical(_ passphrase: String) -> String {
        passphrase
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
    }

    /// Whether the passphrase itself is acceptable, ignoring the confirmation.
    static func strengthIssue(for passphrase: String) -> Issue? {
        let form = canonical(passphrase)
        if form.isEmpty { return .empty }
        // `count` is characters as a person sees them: an emoji or an accented
        // letter is one, however many code points it takes.
        if form.count < minimumLength { return .tooShort(minimum: minimumLength) }
        return nil
    }

    /// Whether the confirmation can still become the passphrase.
    ///
    /// Nil while the confirmation is empty or is a correct beginning of the
    /// passphrase, so nobody is told "doesn't match" halfway through typing it.
    /// Compared in canonical form, so a stray edge space is not a mismatch —
    /// consistent with it not being part of the key.
    static func confirmationIssue(passphrase: String, confirmation: String) -> Issue? {
        let typed = canonical(confirmation)
        guard !typed.isEmpty else { return nil }
        return canonical(passphrase).hasPrefix(typed) ? nil : .mismatch
    }

    /// Both rules pass and the two entries are the same passphrase.
    static func accepts(passphrase: String, confirmation: String) -> Bool {
        strengthIssue(for: passphrase) == nil && canonical(passphrase) == canonical(confirmation)
    }
}
