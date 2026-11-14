import Foundation
import Testing
@testable import Stabilyz

@Suite struct BaselineProgressCopyTests {
    @Test func progressUsesTheOneWordingAndTheDomainsRequiredCount() {
        #expect(Baseline.requiredValidSessionCount == 5)
        for walk in 1...5 {
            #expect(BaselineProgressCopy.progress(walk: walk) == "Walk \(walk) of 5 toward your baseline")
        }
    }

    @Test func progressIsClampedToTheRange() {
        #expect(BaselineProgressCopy.progress(walk: 9) == "Walk 5 of 5 toward your baseline")
        #expect(BaselineProgressCopy.progress(walk: -1) == "Walk 0 of 5 toward your baseline")
    }

    @Test func remainingUsesNumeralsAndAgreesInNumber() {
        #expect(BaselineProgressCopy.remaining(4) == "4 more walks to go")
        #expect(BaselineProgressCopy.remaining(1) == "1 more walk to go")
    }

    @Test func noOldPhrasingSurvives() {
        let all = (1...5).flatMap { [BaselineProgressCopy.progress(walk: $0), BaselineProgressCopy.remainingSentence($0)] }
        for text in all {
            #expect(!text.contains("sessions complete"))
            #expect(!text.contains("calibration walks"))
            #expect(!text.localizedCaseInsensitiveContains("four more"))
        }
    }
}
