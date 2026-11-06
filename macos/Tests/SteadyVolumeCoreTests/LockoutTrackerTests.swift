import XCTest
@testable import SteadyVolumeCore

final class LockoutTrackerTests: XCTestCase {
    private let clock = TestClock()

    func testFourFailuresDoNotLockOut() {
        let tracker = LockoutTracker(now: clock.provider)
        for _ in 0..<4 { XCTAssertFalse(tracker.recordFailure()) }
        XCTAssertNil(tracker.remainingLockout())
        XCTAssertEqual(tracker.attemptsRemaining, 1)
    }

    func testFifthFailureLocksOutFor30Seconds() {
        let tracker = LockoutTracker(now: clock.provider)
        for _ in 0..<4 { tracker.recordFailure() }
        XCTAssertTrue(tracker.recordFailure())
        XCTAssertEqual(tracker.remainingLockout(), 30)
        clock.advance(29)
        XCTAssertEqual(tracker.remainingLockout(), 1)
        clock.advance(1)
        XCTAssertNil(tracker.remainingLockout())
    }

    func testCounterRestartsAfterALockoutEnds() {
        let tracker = LockoutTracker(now: clock.provider)
        for _ in 0..<5 { tracker.recordFailure() }
        clock.advance(30)
        XCTAssertNil(tracker.remainingLockout())
        XCTAssertEqual(tracker.attemptsRemaining, 5)
        for _ in 0..<4 { XCTAssertFalse(tracker.recordFailure()) }
    }

    func testSuccessResetsTheCounter() {
        let tracker = LockoutTracker(now: clock.provider)
        for _ in 0..<4 { tracker.recordFailure() }
        tracker.recordSuccess()
        XCTAssertEqual(tracker.failedAttempts, 0)
        for _ in 0..<4 { XCTAssertFalse(tracker.recordFailure()) }
    }

    func testPersistedStateSurvivesARestart() {
        let tracker = LockoutTracker(now: clock.provider)
        for _ in 0..<5 { tracker.recordFailure() }
        clock.advance(10)
        let restarted = LockoutTracker(now: clock.provider, failedAttempts: tracker.failedAttempts, lockoutUntil: tracker.lockoutUntil)
        XCTAssertEqual(restarted.remainingLockout(), 20)
    }

    func testPersistedFailureCountCarriesOver() {
        let restarted = LockoutTracker(now: clock.provider, failedAttempts: 4)
        XCTAssertTrue(restarted.recordFailure())
        XCTAssertEqual(LockoutTracker(now: clock.provider, failedAttempts: 99).failedAttempts, 4)
        XCTAssertEqual(LockoutTracker(now: clock.provider, failedAttempts: -3).failedAttempts, 0)
    }

    func testADeadlineFarInTheFutureIsCappedAt30Seconds() {
        let tracker = LockoutTracker(now: clock.provider, lockoutUntil: clock.now.addingTimeInterval(86_400))
        XCTAssertEqual(tracker.remainingLockout(), 30)
    }
}
