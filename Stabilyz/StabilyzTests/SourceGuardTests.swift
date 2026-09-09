import Foundation
import Testing
@testable import Stabilyz

/// Locates the app's source tree relative to this file, so the scans do not
/// depend on a bundle resource or on where the tests are run from.
private enum SourceTree {
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
