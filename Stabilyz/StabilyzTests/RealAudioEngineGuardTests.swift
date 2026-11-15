import Foundation
import Testing

/// Keeps `.requiresRealAudioEngine` attached to exactly the tests that build a
/// real audio engine: no such test without the trait (it would crash or stall
/// hosted CI), and no test with the trait that does not build one (it would be
/// skipped on CI for no reason).
///
/// The scan reads the test sources as text. It understands the shape those
/// tests have today — top-level `@Test func` declarations, with the service
/// built either in the test or in a file-private helper function — and fails
/// loudly on any other shape rather than guessing.
struct RealAudioEngineGuardTests {
    /// Spelled in two halves so this file does not match its own scan.
    private static let constructor = "EngineAudioFeedback" + "Service("
    private static let trait = ".requiresRealAudio" + "Engine"

    private static var testSources: [(name: String, text: String)] {
        let folder = URL(fileURLWithPath: String(describing: #filePath)).deletingLastPathComponent()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        // The trait's own definition and this guard name the trait in prose
        // and code; neither holds a test that could build an engine.
        let definitions: Set<String> = ["RealAudioEngineTrait.swift", "RealAudioEngineGuardTests.swift"]
        return names.filter { $0.hasSuffix(".swift") && !definitions.contains($0) }.sorted().compactMap { name in
            guard let text = try? String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8) else {
                return nil
            }
            return (name, text)
        }
    }

    /// Splits a file into its top-level declarations: a new chunk starts at
    /// every line that begins in column 0 with something other than a closing
    /// brace, a comment or whitespace.
    private static func topLevelChunks(of text: String) -> [String] {
        var chunks: [String] = []
        var current: [Substring] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let startsDeclaration = line.first.map { !$0.isWhitespace && $0 != "}" && $0 != ")" } ?? false
                && !line.hasPrefix("//")
            if startsDeclaration, !current.isEmpty {
                chunks.append(current.joined(separator: "\n"))
                current = []
            }
            current.append(line)
        }
        if !current.isEmpty { chunks.append(current.joined(separator: "\n")) }
        return chunks
    }

    private static func helperName(of chunk: String) -> String? {
        for prefix in ["private func ", "fileprivate func ", "func "] where chunk.hasPrefix(prefix) {
            return chunk.dropFirst(prefix.count).prefix { $0.isLetter || $0.isNumber || $0 == "_" }.description
        }
        return nil
    }

    private struct Finding: CustomStringConvertible {
        let file: String
        let declaration: String
        let problem: String
        var description: String { "\(file): \(declaration) — \(problem)" }
    }

    private static func findings() -> (problems: [Finding], markedTests: Int, filesWithEngine: Int) {
        var problems: [Finding] = []
        var marked = 0
        var filesWithEngine = 0

        for (name, text) in testSources where text.contains(constructor) || text.contains(trait) {
            if text.contains(constructor) { filesWithEngine += 1 }
            let chunks = topLevelChunks(of: text)
            let helpers = Set(chunks.compactMap { chunk -> String? in
                guard chunk.contains(constructor) else { return nil }
                return helperName(of: chunk)
            })

            for chunk in chunks {
                let head = String(chunk.prefix { $0 != "\n" }.prefix(90))
                let isTest = chunk.hasPrefix("@Test")
                let isHelper = helperName(of: chunk).map(helpers.contains) ?? false
                let buildsEngine = chunk.contains(constructor)
                    || helpers.contains { chunk.contains($0 + "(") && !isHelper }
                let hasTrait = chunk.contains(trait)

                if hasTrait { marked += isTest ? 1 : 0 }
                switch (isTest, buildsEngine, hasTrait) {
                case (true, true, false):
                    problems.append(Finding(file: name, declaration: head,
                        problem: "builds a real audio engine but is not marked \(trait)"))
                case (true, false, true):
                    problems.append(Finding(file: name, declaration: head,
                        problem: "is marked \(trait) but builds no real audio engine"))
                case (false, true, _) where !isHelper:
                    problems.append(Finding(file: name, declaration: head,
                        problem: "builds a real audio engine in a shape this guard cannot check; "
                            + "use a top-level @Test func or a file-private helper func"))
                case (false, _, true):
                    problems.append(Finding(file: name, declaration: head,
                        problem: "carries \(trait) outside a top-level @Test func"))
                default:
                    break
                }
            }
        }
        return (problems, marked, filesWithEngine)
    }

    @Test func theTraitSitsOnExactlyTheTestsThatBuildARealAudioEngine() {
        let result = Self.findings()
        #expect(result.problems.isEmpty, "\(result.problems.map(\.description).joined(separator: "\n"))")
        // The scan found something to check — an empty result must not pass by
        // looking at nothing.
        #expect(result.filesWithEngine > 0)
        #expect(result.markedTests > 0)
    }

    @Test func onlyTheNamedVariableSetToOneSwitchesTheTestsOff() {
        #expect(RealAudioEngine.isSkipped(in: [RealAudioEngine.skipVariable: "1"]))
        #expect(!RealAudioEngine.isSkipped(in: [:]))
        #expect(!RealAudioEngine.isSkipped(in: ["CI": "true"]))
        #expect(!RealAudioEngine.isSkipped(in: [RealAudioEngine.skipVariable: "0"]))
        #expect(!RealAudioEngine.isSkipped(in: [RealAudioEngine.skipVariable: "true"]))
    }
}
