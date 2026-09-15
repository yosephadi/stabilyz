import Foundation
import Testing
@testable import Stabilyz

// MARK: - Nothing sensitive reaches a log (Task 11.1.2, docs/20, docs/15 §15.2)

/// Every message is logged with `.public` privacy, so what a call site
/// interpolates is what the device log keeps. docs/20 names what must never
/// be there: passphrases, keys, salts, nonces, raw sensor samples, metric
/// values and profile fields.
///
/// A scan, like the other source guards: `\(cadence)` compiles, logs, and looks
/// harmless in the one place it was typed. The rule has to hold at every call
/// site at once, including the ones written after this test.
@Suite struct LogPrivacyGuardTests {

    /// Every app layer that can hold a log call.
    static let layers = ["App", "Features", "Services", "Persistence", "Domain", "Algorithms", "Utilities"]

    /// An interpolated expression naming any of these is refused. Word
    /// boundaries keep configuration out of it: `sampleRateHz` is not a sample.
    static let forbidden = try! NSRegularExpression(
        pattern: #"(?i)(passphrase|password|\bkeys?\b|derivedKey|keyBytes|\bsalt\b|\bnonce\b|\bsamples?\b|accel|gyro|\brotation\b|attitude|\bmetrics?\b|cadence|\bbpm\b|stepTimes?\b|timestamps?\b|\bprofile\b|amputation|\bside\b|kLevel|prosthesis|relativeIndex|\bscores?\b|\bstats?\b|\bmean\b|\bsd\b|displayName|\burl\b|\bpath\b|fileName)"#
    )

    /// The full text of every `.log(` call, from the call to its closing
    /// parenthesis, across lines. Parentheses inside string literals do not
    /// count; parentheses inside an interpolation do.
    static func logCalls(in source: String) -> [String] {
        let code = StepFeedbackSchedulingGuardTests.codeLines(in: source).joined(separator: "\n")
        let characters = Array(code)
        let marker = Array(".log(")
        var calls: [String] = []

        var index = 0
        while index + marker.count <= characters.count {
            guard Array(characters[index..<index + marker.count]) == marker else {
                index += 1
                continue
            }
            let start = index
            var cursor = index + marker.count
            var depth = 1
            var inString = false
            var interpolationDepths: [Int] = []

            while cursor < characters.count, depth > 0 {
                let character = characters[cursor]
                if inString {
                    if character == "\\", cursor + 1 < characters.count {
                        if characters[cursor + 1] == "(" {
                            interpolationDepths.append(depth)
                            depth += 1
                            inString = false
                        }
                        cursor += 2
                        continue
                    }
                    if character == "\"" { inString = false }
                } else {
                    switch character {
                    case "\"":
                        inString = true
                    case "(":
                        depth += 1
                    case ")":
                        depth -= 1
                        if let last = interpolationDepths.last, depth == last {
                            interpolationDepths.removeLast()
                            inString = true
                        }
                    default:
                        break
                    }
                }
                cursor += 1
            }

            calls.append(String(characters[start..<cursor]))
            index = cursor
        }
        return calls
    }

    /// The expressions inside every `\(…)` in a piece of source.
    static func interpolations(in text: String) -> [String] {
        let characters = Array(text)
        var found: [String] = []
        var index = 0
        while index + 1 < characters.count {
            guard characters[index] == "\\", characters[index + 1] == "(" else {
                index += 1
                continue
            }
            var cursor = index + 2
            var depth = 1
            while cursor < characters.count {
                if characters[cursor] == "(" { depth += 1 }
                if characters[cursor] == ")" {
                    depth -= 1
                    if depth == 0 { break }
                }
                cursor += 1
            }
            found.append(String(characters[(index + 2)..<min(cursor, characters.count)]))
            index = cursor + 1
        }
        return found
    }

    /// `x != nil` / `x == nil`: logs whether something exists, never what it
    /// is. `scored=\(score != nil)` says a walk was scored, not its score.
    static let presenceCheck = try! NSRegularExpression(pattern: #"^[A-Za-z_][\w.]*\s*[!=]=\s*nil$"#)

    /// `something.count`: how many, never what. docs/20 lists sample counts
    /// among what a session log carries. Not for key material, whose length
    /// is part of what must not be recorded.
    static let countOnly = try! NSRegularExpression(pattern: #"^[A-Za-z_][\w.]*\.count$"#)
    static let keyMaterial = try! NSRegularExpression(pattern: #"(?i)(passphrase|password|key|salt|nonce)"#)

    /// Interpolations a log call must not make.
    static func violations(in source: String) -> [String] {
        logCalls(in: source).flatMap { call in
            interpolations(in: call).filter { expression in
                let trimmed = expression.trimmingCharacters(in: .whitespaces)
                if trimmed == "error" { return true }
                let whole = NSRange(trimmed.startIndex..., in: trimmed)
                if presenceCheck.firstMatch(in: trimmed, range: whole) != nil { return false }
                if countOnly.firstMatch(in: trimmed, range: whole) != nil,
                   keyMaterial.firstMatch(in: trimmed, range: whole) == nil {
                    return false
                }
                let range = NSRange(trimmed.startIndex..., in: trimmed)
                return forbidden.firstMatch(in: trimmed, range: range) != nil
            }
        }
    }

    // MARK: The scan

    @Test func noLogCallInterpolatesSensitiveValuesOrRawErrors() {
        var callCount = 0
        for layer in Self.layers {
            for file in SourceTree.swiftFiles(in: layer) {
                guard let source = try? String(contentsOf: file.url, encoding: .utf8) else {
                    Issue.record("could not read \(file.path)")
                    continue
                }
                callCount += Self.logCalls(in: source).count
                for violation in Self.violations(in: source) {
                    Issue.record(
                        "\(file.path) logs \\(\(violation)) — describe errors through LogRedaction and never log passphrases, keys, samples, metric values or profile fields (docs/20)"
                    )
                }
            }
        }
        // A scan that finds nothing is a broken scan, not a clean codebase.
        #expect(callCount > 50, "found only \(callCount) log calls — the scanner is not reading the source")
    }

    // MARK: Mutation checks

    @Test func theScanCatchesSensitiveInterpolations() {
        #expect(Self.violations(in: #"logService.log(.info, .audio, "metronome started at \(Int(bpm)) bpm")"#).isEmpty == false)
        #expect(Self.violations(in: #"logService.log(.error, .persistence, "history load failed: \(error)")"#).isEmpty == false)
        #expect(Self.violations(in: #"logService.log(.info, .app, "saved \(profile.amputationLevel)")"#).isEmpty == false)
        #expect(Self.violations(in: #"logService.log(.debug, .motion, "first sample \(samples.first!)")"#).isEmpty == false)
        #expect(Self.violations(in: #"logService.log(.info, .backup, "derived \(derivedKey.count) bytes")"#).isEmpty == false)
        // Spread over lines.
        let multiline = #"""
        logService.log(
            .info, .processing,
            "cadence \(metrics.cadenceMean)"
        )
        """#
        #expect(Self.violations(in: multiline).isEmpty == false)
    }

    @Test func theScanAllowsWhatTheAppLegitimatelyLogs() {
        let allowed = #"""
        logService.log(.info, .session, "session started: mode=\(mode.rawValue)")
        logService.log(.error, .backup, "restore write failed: \(type(of: error))")
        logService.log(.error, .backup, "restore recovery: snapshot damaged (\(LogRedaction.describe(error))); store left as it is")
        logService.log(.info, .motion, "motion updates started at \(policy.sampleRateHz) Hz")
        logService.log(.info, .backup, "removed \(leftovers.count) stale export(s)")
        logService.log(.error, .backup, "export flow failed: \(failure.technicalDescription)")
        logService.log(.info, .processing, "session valid: scored=\(score != nil) provisional=\(provisional != nil)")
        """#
        #expect(Self.violations(in: allowed).isEmpty, "\(Self.violations(in: allowed))")
        #expect(Self.logCalls(in: allowed).count == 7)
    }

    @Test func aCountIsAllowedButTheSamplesAndKeyLengthsAreNot() {
        #expect(Self.violations(in: #"logService.log(.info, .session, "samples=\(series.samples.count)")"#).isEmpty)
        #expect(Self.violations(in: #"logService.log(.debug, .motion, "first sample \(series.samples.first!)")"#).isEmpty == false)
        #expect(Self.violations(in: #"logService.log(.info, .backup, "derived \(derivedKey.count) bytes")"#).isEmpty == false)
    }

    @Test func aPresenceCheckIsAllowedButTheValueBehindItIsNot() {
        #expect(Self.violations(in: #"logService.log(.info, .processing, "scored=\(score != nil)")"#).isEmpty)
        #expect(Self.violations(in: #"logService.log(.info, .processing, "index=\(score?.relativeIndex)")"#).isEmpty == false)
        #expect(Self.violations(in: #"logService.log(.info, .processing, "index=\(score?.relativeIndex != nil ? score!.relativeIndex : 0)")"#).isEmpty == false)
    }

    @Test func parenthesesInsideTheMessageDoNotEndTheCall() {
        let source = #"logService.log(.info, .backup, "removed (\(count)) item(s)") ; let after = profile"#
        let calls = Self.logCalls(in: source)
        #expect(calls.count == 1)
        #expect(calls.first?.hasSuffix(#"item(s)")"#) == true)
        #expect(Self.violations(in: source).isEmpty, "code after the call is not part of it")
    }
}

// MARK: - LogRedaction

@Test func aStoreRowErrorNeverCarriesTheProfileFieldItQuotes() {
    let error = EntityMapping.MappingError.unknownAmputationLevel("transfemoral-left-2019")
    let described = LogRedaction.describe(error)

    #expect(described.contains("transfemoral") == false)
    #expect(described.contains("MappingError"))
}

@Test func stabilyzErrorsAreDescribedByTheirTechnicalDescription() {
    let error = StabilyzError.archiveImport(.wrongPassphrase)
    #expect(LogRedaction.describe(error) == error.technicalDescription)
}

@Test func auditedErrorsKeepTheirCaseName() {
    #expect(LogRedaction.describe(BaselineCalculationService.CalculationError.sessionsOutOfOrder) == "sessionsOutOfOrder")
    #expect(LogRedaction.describe(StoreSnapshotCoding.DecodingError.digestMismatch) == "digestMismatch")
}

@Test func anUnknownErrorIsReducedToItsTypeAndCode() {
    struct Leaky: Error, CustomStringConvertible {
        var description: String { "passphrase=correct horse" }
    }
    let described = LogRedaction.describe(Leaky())

    #expect(described.contains("correct horse") == false)
    #expect(described.contains("Leaky"))
}
