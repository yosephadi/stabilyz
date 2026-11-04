import Foundation
import Testing
@testable import Stabilyz

/// Which watch Stops end the walk (Task 12.3.2, PRD §8 decision 2).
@Suite struct WatchStopFilterTests {
    let current = UUID()
    var request: WatchStopRequest { WatchStopRequest(sessionID: current) }

    @Test func aStopForTheRunningSessionIsAccepted() {
        #expect(WatchStopFilter.accepts(request, currentSession: current, isRunning: true, alreadyStopped: false))
    }

    @Test func aStopForAnotherSessionIsDropped() {
        let other = WatchStopRequest(sessionID: UUID())
        #expect(WatchStopFilter.accepts(other, currentSession: current, isRunning: true, alreadyStopped: false) == false)
        #expect(WatchStopFilter.accepts(request, currentSession: nil, isRunning: true, alreadyStopped: false) == false)
    }

    @Test func aStopBeforeGoIsDropped() {
        #expect(WatchStopFilter.accepts(request, currentSession: current, isRunning: false, alreadyStopped: false) == false)
    }

    @Test func aDuplicateOrLateStopIsDropped() {
        #expect(WatchStopFilter.accepts(request, currentSession: current, isRunning: true, alreadyStopped: true) == false)
    }
}
