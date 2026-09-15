import Foundation
import Testing
@testable import Stabilyz

/// Locates the app's source tree relative to this file, so the scans do not
/// depend on a bundle resource or on where the tests are run from.
enum SourceTree {
    static func appSourceRoot(file: StaticString = #filePath) -> URL {
        URL(fileURLWithPath: String(describing: file))
            .deletingLastPathComponent()   // StabilyzTests
            .deletingLastPathComponent()   // Stabilyz (project dir)
            .appendingPathComponent("Stabilyz")
    }

    /// Every `.swift` file under a layer folder, with its path relative to the
    /// source root for readable failures.
    static func swiftFiles(in layer: String) -> [(path: String, url: URL)] {
        let root = appSourceRoot()
        let folder = root.appendingPathComponent(layer)
        guard let walker = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: nil
        ) else { return [] }

        return walker.compactMap { entry in
            guard let url = entry as? URL, url.pathExtension == "swift" else { return nil }
            let path = url.path.replacingOccurrences(of: root.path + "/", with: "")
            return (path, url)
        }
    }
}

// MARK: - Import hygiene

/// Enforces the layering rule in CLAUDE.md and docs/03 rule 1: `Domain/` and
/// `Algorithms/` import no Apple frameworks except Foundation, with Accelerate
/// additionally allowed under `Algorithms/`.
///
/// A scan rather than a convention, because the rule is invisible at the point
/// it would be broken — adding `import SwiftData` to a domain file compiles
/// perfectly and only shows up as a problem much later.
@Suite struct ImportHygieneTests {
    /// `import X`, capturing X. Ignores anything indented, which is inside a
    /// type, and anything after a comment marker.
    static func imports(in source: String) -> [String] {
        source.split(separator: "\n").compactMap { line -> String? in
            let text = line.trimmingCharacters(in: .whitespaces)
            guard text.hasPrefix("import ") else { return nil }
            // `@testable import X`, `import struct Foundation.Data`, etc.
            let parts = text.split(separator: " ").map(String.init)
            guard let module = parts.last?.split(separator: ".").first else { return nil }
            return String(module)
        }
    }

    @Test func domainImportsOnlyFoundation() {
        let files = SourceTree.swiftFiles(in: "Domain")
        #expect(files.isEmpty == false, "the Domain scan found no files — the scan itself is broken")

        for file in files {
            guard let source = try? String(contentsOf: file.url, encoding: .utf8) else {
                Issue.record("could not read \(file.path)")
                continue
            }
            for module in Self.imports(in: source) {
                #expect(
                    module == "Foundation",
                    "\(file.path) imports \(module) — Domain may import only Foundation"
                )
            }
        }
    }

    @Test func algorithmsImportOnlyFoundationAndAccelerate() {
        let files = SourceTree.swiftFiles(in: "Algorithms")
        #expect(files.isEmpty == false, "the Algorithms scan found no files — the scan itself is broken")

        for file in files {
            guard let source = try? String(contentsOf: file.url, encoding: .utf8) else {
                Issue.record("could not read \(file.path)")
                continue
            }
            for module in Self.imports(in: source) {
                #expect(
                    module == "Foundation" || module == "Accelerate",
                    "\(file.path) imports \(module) — Algorithms may import only Foundation and Accelerate"
                )
            }
        }
    }

    @Test func theScanWouldCatchAForbiddenImport() {
        // A guard that never fails is indistinguishable from one that cannot.
        let offending = """
        import Foundation
        import SwiftData

        struct Example {}
        """
        let modules = Self.imports(in: offending)

        #expect(modules == ["Foundation", "SwiftData"])
        #expect(modules.contains { $0 != "Foundation" })
    }

    @Test func theScanIgnoresTheWordImportInsideProse() {
        let source = """
        /// This type is important, and does not import anything unusual.
        // import SwiftUI would be wrong here
        import Foundation
        """
        // The commented line is indented-free but starts with "//", so it is not
        // an import; the doc comment is prose.
        #expect(Self.imports(in: source) == ["Foundation"])
    }
}

// MARK: - Terminology guard

/// [PRD OQ-1] reserves "asymmetry" for the unilateral step-time comparison.
/// Calling the autocorrelation output "symmetry" would overclaim what it
/// measures, so user-facing copy says **gait consistency**.
///
/// This scans **string literals only** — not comments, not identifiers — because
/// the rule is about what the user reads. `stepTimeAsymmetry` as a type name is
/// correct and must not trip the guard.
///
/// It exists now, before EPIC 8 writes the Score screen's copy, so the first
/// violation fails a test rather than reaching a user.
@Suite struct TerminologyGuardTests {
    static let forbidden = ["symmetry", "symmetric", "asymmetry", "asymmetric"]

    /// The asymmetry feature's own sanctioned labels. Everything else is a
    /// violation.
    static let allowed: Set<String> = [
        "Step-time asymmetry",
        "step-time asymmetry"
    ]

    /// String literals in a Swift source, with comment lines removed first.
    ///
    /// Deliberately simple: a line-oriented scan over quoted spans. It cannot be
    /// fooled by an identifier, which is the case that matters, and being
    /// approximate at the edges is fine for a guard that only ever needs to be
    /// loud.
    static func stringLiterals(in source: String) -> [String] {
        var literals: [String] = []

        for rawLine in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Comments and doc comments are not copy.
            if trimmed.hasPrefix("//") { continue }

            var inside = false
            var current = ""
            var previous: Character?
            for character in line {
                if character == "\"" && previous != "\\" {
                    if inside {
                        literals.append(current)
                        current = ""
                    }
                    inside.toggle()
                } else if inside {
                    current.append(character)
                }
                previous = character
            }
        }
        return literals
    }

    static func violations(in source: String) -> [String] {
        stringLiterals(in: source).filter { literal in
            guard forbidden.contains(where: { literal.localizedCaseInsensitiveContains($0) }) else {
                return false
            }
            // Sanctioned labels for the asymmetry feature itself are fine.
            return !allowed.contains(literal)
        }
    }

    @Test func userFacingCopyNeverUsesTheReservedTerm() {
        var scanned = 0

        for layer in ["Features", "DesignSystem", "Domain"] {
            for file in SourceTree.swiftFiles(in: layer) {
                guard let source = try? String(contentsOf: file.url, encoding: .utf8) else { continue }
                scanned += 1
                for violation in Self.violations(in: source) {
                    Issue.record(
                        "\(file.path) has user-facing copy \"\(violation)\" — [PRD OQ-1] reserves that term for the unilateral step-time comparison; the autocorrelation output is \"gait consistency\""
                    )
                }
            }
        }

        #expect(scanned > 0, "the terminology scan found no files — the scan itself is broken")
    }

    @Test func theGuardCatchesCopyButNotIdentifiers() {
        // The case that matters: a type name is correct, a label is not.
        let identifierOnly = """
        let value = metrics.stepTimeAsymmetry
        case stepTimeAsymmetry
        """
        #expect(Self.violations(in: identifierOnly).isEmpty)

        let badCopy = """
        let label = "Your symmetry improved"
        """
        #expect(Self.violations(in: badCopy) == ["Your symmetry improved"])
    }

    @Test func theGuardIgnoresComments() {
        let source = """
        // Never call this symmetry in copy.
        /// Asymmetry is reserved for the limb comparison.
        let label = "Gait consistency"
        """
        #expect(Self.violations(in: source).isEmpty)
    }

    @Test func theSanctionedAsymmetryLabelIsAllowed() {
        let source = """
        let label = "Step-time asymmetry"
        """
        #expect(Self.violations(in: source).isEmpty)

        // But a looser variant is not silently accepted.
        let loose = """
        let label = "Your asymmetry score"
        """
        #expect(Self.violations(in: loose).isEmpty == false)
    }
}

// MARK: - Step Feedback schedules nothing (Task 7.2.1)

/// [PRD AC, OQ-4] Step Feedback is reactive and **must never imply a tempo**.
/// The metronome of Task 7.2.2 is the component allowed to schedule; these two
/// files are not.
///
/// A scan rather than a test, because the failure is an addition, not a wrong
/// answer: a `Timer` added here to "smooth out" the ticks would pass every
/// behavioural test on a steady walk and only misbehave on the irregular gait
/// this app exists to measure.
@Suite struct StepFeedbackSchedulingGuardTests {
    /// Every way of asking for something to happen later.
    static let schedulingSymbols = [
        "Timer", "DispatchSourceTimer", "asyncAfter", "Task.sleep",
        "DispatchQueue.schedule", "AVAudioTime", "scheduleBuffer(", "RunLoop"
    ]

    static let stepFeedbackFiles = [
        "Services/Audio/StepFeedbackBridge.swift",
        "Services/Audio/StepTickGate.swift"
    ]

    /// Code lines only; a comment saying the word "Timer" is not a timer.
    static func codeLines(in source: String) -> [String] {
        source.split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("//") && !$0.isEmpty }
    }

    @Test func theStepFeedbackPathSchedulesNothing() throws {
        let root = SourceTree.appSourceRoot()

        for path in Self.stepFeedbackFiles {
            let url = root.appendingPathComponent(path)
            let source = try #require(
                try? String(contentsOf: url, encoding: .utf8),
                "\(path) is missing — the scan itself is broken"
            )

            for line in Self.codeLines(in: source) {
                for symbol in Self.schedulingSymbols {
                    #expect(
                        line.contains(symbol) == false,
                        "\(path) uses \(symbol) — Step Feedback is reactive and must never imply a tempo [PRD OQ-4]"
                    )
                }
            }
        }
    }

    @Test func theScanWouldCatchAScheduler() {
        // A guard that never fails is indistinguishable from one that cannot.
        let offending = """
        // A Timer here would be wrong.
        let timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in }
        """
        let lines = Self.codeLines(in: offending)

        #expect(lines.count == 1, "the comment line was not excluded")
        #expect(lines.contains { line in Self.schedulingSymbols.contains { line.contains($0) } })
    }
}

// MARK: - The metronome never reads step timing (Task 7.2.2)

/// The mirror of `StepFeedbackSchedulingGuardTests`. Step Feedback mirrors
/// steps and never schedules; the metronome schedules and never mirrors steps
/// [PRD OQ-4]. Together the two scans pin the property that keeps the two
/// engines distinguishable — a metronome that quietly nudged toward the user's
/// own cadence would still sound plausible and would no longer be the
/// pre-scheduled tempo the PRD describes.
@Suite struct MetronomeIndependenceGuardTests {
    static let stepSymbols = ["LiveStepEvent", "LiveStepDetector", "StepTickGate", "stepEvents", "StepFeedbackBridge"]

    static let metronomeFiles = [
        "Services/Audio/MetronomeSchedule.swift",
        "Domain/Models/MetronomeCue.swift"
    ]

    @Test func theMetronomePathReadsNoStepTiming() throws {
        let root = SourceTree.appSourceRoot()

        for path in Self.metronomeFiles {
            let url = root.appendingPathComponent(path)
            let source = try #require(
                try? String(contentsOf: url, encoding: .utf8),
                "\(path) is missing — the scan itself is broken"
            )

            for line in StepFeedbackSchedulingGuardTests.codeLines(in: source) {
                for symbol in Self.stepSymbols {
                    #expect(
                        line.contains(symbol) == false,
                        "\(path) refers to \(symbol) — the metronome is a scheduled tempo and must never follow the walk's own steps [PRD OQ-4]"
                    )
                }
            }
        }
    }

    @Test func theScanWouldCatchStepTimingLeakingIn() {
        let offending = """
        // Mentioning LiveStepEvent in prose is fine.
        func nudge(towards event: LiveStepEvent) {}
        """
        let lines = StepFeedbackSchedulingGuardTests.codeLines(in: offending)

        #expect(lines.count == 1)
        #expect(lines.contains { line in Self.stepSymbols.contains { line.contains($0) } })
    }
}

// MARK: - Scoring cannot see the audio config (Task 7.2.3)

/// [PRD §7 AC, docs/10 §10.4] The audio layer must be incapable of altering the
/// batch outcome.
///
/// `RawSessionBuffer` **carries** `audioConfig` — it is persisted with the
/// session for transparency — and the pipeline is handed that whole buffer. So
/// "the scoring math ignores it" is not structural on its own: nothing but this
/// scan stops a future stage from reading `buffer.audioConfig` and, say,
/// widening a tolerance for metronome-paced walks. The byte-identity tests would
/// catch that on the cases they cover; this catches it everywhere.
@Suite struct ScoringIndependenceGuardTests {
    static let audioSymbols = [
        "audioConfig", "SessionAudioConfig", "AudioFeedback", "Metronome",
        "MetronomeCue", "StepTick", "stepFeedback", "playStepTick", "LiveStepEvent"
    ]

    @Test func noAlgorithmReadsAnythingAboutAudio() {
        let files = SourceTree.swiftFiles(in: "Algorithms")
        #expect(files.isEmpty == false, "the Algorithms scan found no files — the scan itself is broken")

        for file in files {
            guard let source = try? String(contentsOf: file.url, encoding: .utf8) else {
                Issue.record("could not read \(file.path)")
                continue
            }

            for line in StepFeedbackSchedulingGuardTests.codeLines(in: source) {
                for symbol in Self.audioSymbols {
                    #expect(
                        line.contains(symbol) == false,
                        "\(file.path) refers to \(symbol) — scoring must be incapable of seeing how the walk was paced [PRD §7 AC]"
                    )
                }
            }
        }
    }

    @Test func theScanWouldCatchAnAlgorithmReadingTheAudioConfig() {
        let offending = """
        // Reading audioConfig in a comment is fine.
        let paced = buffer.audioConfig != .none
        """
        let lines = StepFeedbackSchedulingGuardTests.codeLines(in: offending)

        #expect(lines.count == 1)
        #expect(lines.contains { line in Self.audioSymbols.contains { line.contains($0) } })
    }
}

// MARK: - Design tokens are the only source of colour, size and spacing (Task 8.1.3)

/// `DesignSystem/` is the only place a raw colour, a font size or a spacing
/// number may appear. `Features/` names tokens or it names nothing.
///
/// A scan rather than a convention, for the same reason as the import guard:
/// the rule is invisible at the point it would be broken. `.padding(20)` and
/// `.foregroundStyle(.blue)` compile perfectly, look right on the one screen
/// they were typed on, and only show up as a problem when the palette moves and
/// one view stays behind — exactly what happened to `bg-base`, which lived in
/// two places and drifted.
@Suite struct DesignTokenGuardTests {

    /// `Color(red:…)`, `UIColor(…)`, and the SwiftUI system colours.
    ///
    /// The system-colour half is word-bounded so it matches `.blue` but not
    /// `.blueprint` — and, the case that actually occurs, not the `.white` at
    /// the head of `.whitespacesAndNewlines`.
    static let rawColour = #"(Color|UIColor)\s*\(\s*(red:|white:|hex:|rgb:|\.sRGB|displayP3)|0x[0-9A-Fa-f]{6}\b|\.(white|black|blue|red|green|gray|grey|orange|yellow|pink|purple|teal|indigo|mint|brown|cyan)\b"#

    /// A point size pinned into a view, instead of a style from §3 that
    /// Dynamic Type can scale.
    static let fixedFontSize = #"\.system\(\s*size:|Font\.custom\("#

    /// A bare number inside a layout modifier. The lookbehind keeps
    /// `Space.x4` and `Space.x12` out of it — the digit there is part of an
    /// identifier, not a measurement.
    ///
    /// A literal `0` is allowed. The 4pt scale in §4 starts at 4, so zero is
    /// not a value taken from it — it is the absence of a gap, and
    /// `VStack(spacing: 0)` says that more plainly than a token could.
    static let magicNumber = #"\.(padding|frame|cornerRadius|offset|lineSpacing)\([^)]*?(?<![\w.])(?!0(?![\d.]))\d+(\.\d+)?\b|(spacing|width|height|radius):\s*(?<![\w.])(?!0(?![\d.]))\d+"#

    /// Compiled once. Building an `NSRegularExpression` is expensive enough
    /// that doing it per line turned this scan into seconds of CPU and starved
    /// the timing-sensitive audio tests running alongside it.
    static let patterns: [(name: String, regex: NSRegularExpression)] = [
        ("a raw colour", rawColour),
        ("a fixed font size", fixedFontSize),
        ("a magic layout number", magicNumber)
    ].compactMap { name, pattern in
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        return (name, regex)
    }

    /// Offending code lines, each tagged with what it tripped. Comments are
    /// excluded: prose describing `.padding(20)` is not `.padding(20)`.
    static func violations(in source: String) -> [(kind: String, line: String)] {
        var found: [(kind: String, line: String)] = []

        for line in StepFeedbackSchedulingGuardTests.codeLines(in: source) {
            let range = NSRange(line.startIndex..., in: line)
            for pattern in patterns where pattern.regex.firstMatch(in: line, range: range) != nil {
                found.append((pattern.name, line))
            }
        }

        // A pattern that failed to compile would make this scan silently
        // toothless, so the count is asserted rather than assumed.
        precondition(patterns.count == 3, "a design-token pattern did not compile")
        return found
    }

    @Test func featuresNameTokensRatherThanValues() {
        let files = SourceTree.swiftFiles(in: "Features")
        #expect(files.isEmpty == false, "the Features scan found no files — the scan itself is broken")

        for file in files {
            guard let source = try? String(contentsOf: file.url, encoding: .utf8) else {
                Issue.record("could not read \(file.path)")
                continue
            }
            for violation in Self.violations(in: source) {
                Issue.record(
                    "\(file.path) contains \(violation.kind): \"\(violation.line)\" — Features/ may only name tokens from DesignSystem/"
                )
            }
        }
    }

    /// The other half of "only home": the raw values have to actually be
    /// somewhere, or the scan above is passing because the palette is empty.
    @Test func theDesignSystemIsWhereTheRawValuesLive() {
        let files = SourceTree.swiftFiles(in: "DesignSystem")
        #expect(files.isEmpty == false, "the DesignSystem scan found no files — the scan itself is broken")

        let sources = files.compactMap { try? String(contentsOf: $0.url, encoding: .utf8) }
        let combined = sources.joined(separator: "\n")

        #expect(combined.contains("0x"), "no hex colour lives in DesignSystem/ — the palette has gone missing")
        #expect(
            Self.violations(in: combined).isEmpty == false,
            "DesignSystem/ holds no raw values at all, so 'the only home for them' is describing nothing"
        )
    }

    // MARK: Mutation checks — a guard that never fails is one that cannot

    @Test func theScanWouldCatchARawColour() {
        #expect(Self.violations(in: "let brand = Color(red: 1, green: 0, blue: 0)").isEmpty == false)
        #expect(Self.violations(in: ".foregroundStyle(.blue)").isEmpty == false)
        #expect(Self.violations(in: "let c = UIColor(rgb: 0x1B4F8C)").isEmpty == false)
    }

    @Test func theScanWouldCatchAFixedFontSize() {
        #expect(Self.violations(in: ".font(.system(size: 34, weight: .bold))").isEmpty == false)
        #expect(Self.violations(in: #".font(Font.custom("SFPro", size: 17))"#).isEmpty == false)
    }

    @Test func theScanWouldCatchAMagicLayoutNumber() {
        #expect(Self.violations(in: ".padding(.horizontal, 20)").isEmpty == false)
        #expect(Self.violations(in: "VStack(spacing: 16) {").isEmpty == false)
        #expect(Self.violations(in: ".frame(minHeight: 44)").isEmpty == false)

        // Zero is the documented exception, and only exactly zero.
        #expect(Self.violations(in: "VStack(spacing: 0) {").isEmpty)
        #expect(Self.violations(in: ".padding(.top, 0)").isEmpty)
        #expect(Self.violations(in: "VStack(spacing: 0.5) {").isEmpty == false)
    }

    @Test func theScanIgnoresComments() {
        let source = """
        // Was .padding(.horizontal, 20) before the tokens landed.
        /// The brand colour is Color(red: 0.1, green: 0.3, blue: 0.5).
        .padding(.horizontal, Space.screenMargin)
        """
        #expect(Self.violations(in: source).isEmpty)
    }

    @Test func theScanAcceptsTokenReferences() {
        // Every shape the restyled onboarding actually uses, including the
        // digit-bearing token names and the `.white` that is really a
        // character set.
        let good = """
        .padding(.horizontal, Space.screenMargin)
        .padding(.vertical, Space.x6)
        VStack(spacing: Space.x4) {
        HStack(spacing: Space.x1) {
        .frame(height: Space.x2)
        .frame(maxWidth: .infinity, minHeight: Metrics.minimumTapTarget)
        .foregroundStyle(StabilyzColor.ink900)
        .font(StabilyzFont.bodyRegular)
        RoundedRectangle(cornerRadius: Radius.card)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        Color.clear
        """
        #expect(Self.violations(in: good).isEmpty, "\(Self.violations(in: good))")
    }
}

// MARK: - Debug-only code cannot reach a release build (Task 8.1.4)

/// The reset in `Debug/` and `Persistence/DebugDataReset.swift` erases the
/// user's data with no confirmation and no recovery. That is correct for a dev
/// build and catastrophic in a shipped one, so "it is debug-only" has to be a
/// property of the source rather than a promise in a comment.
///
/// Two halves. Every debug file is wrapped in `#if DEBUG` from its first line of
/// code, so its symbols do not exist in a release build; and no file outside
/// them names those symbols except inside a `#if DEBUG` block of its own. The
/// second half is what makes the first useful — a call site that escaped the
/// guard would fail to compile in release, but only after someone tried to
/// ship it.
@Suite struct DebugIsolationGuardTests {

    /// Files that may contain debug-only code.
    static let debugPaths = ["Debug", "Persistence/DebugDataReset.swift"]

    /// Symbols that must never be reachable from release code.
    static let debugSymbols = ["DebugDataReset", "debugResetGesture", "DebugResetGesture", "debugStoreWriter", "eraseAllData"]

    /// Whether a source is wrapped in `#if DEBUG` from its first code line.
    ///
    /// Leading comments and blank lines are allowed above it — a file header is
    /// not code — but the first thing the compiler sees must be the guard, so
    /// that `import` included, nothing in the file exists in release.
    static func isWrappedInDebug(_ source: String) -> Bool {
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map {
            String($0).trimmingCharacters(in: .whitespaces)
        }
        guard let first = lines.first(where: { !$0.isEmpty && !$0.hasPrefix("//") }) else { return false }
        return first == "#if DEBUG" && source.contains("#endif")
    }

    /// The lines of a source that are **not** inside any `#if DEBUG` region.
    ///
    /// Tracks nesting, and treats `#else` of a DEBUG block as release code —
    /// which is exactly right: the `#else` branch is what ships.
    static func releaseLines(in source: String) -> [String] {
        var lines: [String] = []
        var debugDepth = 0
        var stack: [Bool] = []

        for raw in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("#if") {
                let isDebug = trimmed == "#if DEBUG"
                stack.append(isDebug)
                if isDebug { debugDepth += 1 }
                continue
            }
            if trimmed.hasPrefix("#else") {
                if stack.last == true { debugDepth -= 1; stack[stack.count - 1] = false }
                continue
            }
            if trimmed.hasPrefix("#endif") {
                if stack.popLast() == true { debugDepth -= 1 }
                continue
            }
            if debugDepth == 0, !trimmed.isEmpty, !trimmed.hasPrefix("//") {
                lines.append(line)
            }
        }
        return lines
    }

    static func isDebugFile(_ path: String) -> Bool {
        debugPaths.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    @Test func everyDebugFileIsWrappedInIfDebug() {
        let root = SourceTree.appSourceRoot()
        var checked = 0

        for layer in ["Debug", "Persistence"] {
            for file in SourceTree.swiftFiles(in: layer) where Self.isDebugFile(file.path) {
                guard let source = try? String(contentsOf: file.url, encoding: .utf8) else {
                    Issue.record("could not read \(file.path)")
                    continue
                }
                checked += 1
                #expect(
                    Self.isWrappedInDebug(source),
                    "\(file.path) is debug-only code that is not wrapped in #if DEBUG from its first code line"
                )
            }
        }

        #expect(checked > 0, "the debug scan found no debug files — the scan itself is broken")
        #expect(
            FileManager.default.fileExists(atPath: root.appendingPathComponent("Debug").path),
            "Debug/ has gone missing — the scan is guarding nothing"
        )
    }

    @Test func noReleaseCodeNamesADebugSymbol() {
        var scanned = 0

        for layer in ["App", "Features", "Domain", "Algorithms", "Services", "Persistence", "DesignSystem", "Utilities", "Debug"] {
            for file in SourceTree.swiftFiles(in: layer) {
                guard let source = try? String(contentsOf: file.url, encoding: .utf8) else { continue }
                scanned += 1
                for line in Self.releaseLines(in: source) {
                    for symbol in Self.debugSymbols where line.contains(symbol) {
                        Issue.record(
                            "\(file.path) names \(symbol) outside #if DEBUG: \"\(line.trimmingCharacters(in: .whitespaces))\" — the reset must not be reachable from a release build"
                        )
                    }
                }
            }
        }

        #expect(scanned > 0, "the release scan found no files — the scan itself is broken")
    }

    // MARK: Mutation checks — a guard that never fails is one that cannot

    @Test func theScanWouldCatchAnUnwrappedDebugFile() {
        #expect(Self.isWrappedInDebug("import SwiftUI\n#if DEBUG\nenum X {}\n#endif\n") == false,
                "an import above the guard still ships")
        #expect(Self.isWrappedInDebug("enum DebugDataReset {}\n") == false)

        // And accepts the real shape: header comment, then the guard.
        #expect(Self.isWrappedInDebug("// A header.\n\n#if DEBUG\nimport SwiftUI\n#endif\n"))
    }

    @Test func theScanWouldCatchAReleaseCallSite() {
        let offending = """
        struct Home: View {
            var body: some View {
                Text("Home").debugResetGesture(writer: nil, router: router)
            }
        }
        """
        let lines = Self.releaseLines(in: offending)
        #expect(lines.contains { line in Self.debugSymbols.contains { line.contains($0) } })
    }

    @Test func theScanAcceptsAGuardedCallSite() {
        let fine = """
        struct Home: View {
            var body: some View {
                #if DEBUG
                home.debugResetGesture(writer: dependencies.debugStoreWriter, router: router)
                #else
                home
                #endif
            }
        }
        """
        let lines = Self.releaseLines(in: fine)
        #expect(lines.contains { line in Self.debugSymbols.contains { line.contains($0) } } == false)
        #expect(lines.contains { $0.contains("home") }, "the #else branch should still be read as release code")
    }

    @Test func theElseBranchOfADebugBlockCountsAsRelease() {
        // The branch that ships is the one that must be clean.
        let offending = """
        #if DEBUG
        let x = 1
        #else
        DebugDataReset.eraseDefaults()
        #endif
        """
        let lines = Self.releaseLines(in: offending)
        #expect(lines.contains { $0.contains("DebugDataReset") })
        #expect(lines.contains { $0.contains("let x = 1") } == false)
    }
}
