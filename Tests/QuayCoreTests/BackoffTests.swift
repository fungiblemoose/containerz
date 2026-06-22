import XCTest
@testable import QuayCore

final class BackoffTests: XCTestCase {
    func testExponentialGrowthAndCap() {
        let b = Backoff(base: 2, cap: 300, maxAttempts: 10)
        XCTAssertEqual(b.delay(forAttempt: 0), 2)
        XCTAssertEqual(b.delay(forAttempt: 1), 4)
        XCTAssertEqual(b.delay(forAttempt: 2), 8)
        XCTAssertEqual(b.delay(forAttempt: 3), 16)
        XCTAssertEqual(b.delay(forAttempt: 7), 256)
        XCTAssertEqual(b.delay(forAttempt: 8), 300, "capped at 5m")
        XCTAssertEqual(b.delay(forAttempt: 20), 300, "stays capped")
    }

    func testCooldownWindow() {
        var b = Backoff(base: 2, cap: 300, maxAttempts: 10)
        let t0 = Date(timeIntervalSince1970: 1000)
        XCTAssertTrue(b.mayAct(now: t0))
        b.recordAttempt(now: t0)
        XCTAssertEqual(b.attempts, 1)
        XCTAssertFalse(b.mayAct(now: t0.addingTimeInterval(1)), "within 2s window")
        XCTAssertTrue(b.mayAct(now: t0.addingTimeInterval(2)), "after 2s window")
    }

    func testExhaustion() {
        var b = Backoff(base: 2, cap: 300, maxAttempts: 3)
        var t = Date(timeIntervalSince1970: 0)
        for _ in 0..<3 {
            XCTAssertFalse(b.isExhausted)
            b.recordAttempt(now: t)
            t = t.addingTimeInterval(1000) // skip past cooldown
        }
        XCTAssertTrue(b.isExhausted)
    }

    func testResetClearsState() {
        var b = Backoff(base: 2, cap: 300, maxAttempts: 10)
        let t0 = Date(timeIntervalSince1970: 0)
        b.recordAttempt(now: t0)
        b.recordAttempt(now: t0.addingTimeInterval(1000))
        XCTAssertEqual(b.attempts, 2)
        b.reset()
        XCTAssertEqual(b.attempts, 0)
        XCTAssertTrue(b.mayAct(now: t0))
    }
}
