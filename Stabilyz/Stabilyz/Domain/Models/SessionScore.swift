import Foundation

// MARK: - Remaining forward declaration
//
// EPIC 2 has replaced every other placeholder. What is left is a type owned by
// a later epic that EPIC 2 models must already name.


/// Placeholder — full definition in Tasks 6.2.2/6.2.3 (docs/05 §5.1).
struct SessionScore: Sendable, Equatable, Codable {
    let relativeIndex: Int

    init(relativeIndex: Int) {
        self.relativeIndex = relativeIndex
    }
}
