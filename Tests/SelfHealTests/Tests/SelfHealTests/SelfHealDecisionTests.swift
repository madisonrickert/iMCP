import XCTest

@testable import SelfHealLogic

// Regression tests for the bounded, non-reentrant Bonjour self-heal gate. These
// exercise the pure decision math (no NWListener / Network.framework) — the same
// `SelfHeal` source the app compiles, symlinked into this package.
final class SelfHealDecisionTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    // A healthy listener never re-registers, whatever the prior counters say.
    func testHealthyIsSilent() {
        let d = SelfHeal.decide(
            healthy: true,
            definitelyDead: false,
            strikes: 99,
            softThreshold: 3,
            bypassThreshold: true,
            isReregistering: false,
            now: t0,
            lastReregisterAt: t0.addingTimeInterval(-1000),
            priorAttempts: 9
        )
        XCTAssertEqual(d, .skipHealthy)
    }

    // Unhealthy but below the soft threshold (not dead, not a path bypass) → no action.
    func testBelowThresholdSkips() {
        let d = SelfHeal.decide(
            healthy: false,
            definitelyDead: false,
            strikes: 1,
            softThreshold: 3,
            bypassThreshold: false,
            isReregistering: false,
            now: t0,
            lastReregisterAt: nil,
            priorAttempts: 0
        )
        XCTAssertEqual(d, .skipBelowThreshold)
    }

    // A path-satisfied burst collapses: the first fires, the second within the
    // cooldown window is dropped. This is the storm fix.
    func testCooldownCoalescesBurst() {
        let first = SelfHeal.decide(
            healthy: false,
            definitelyDead: false,
            strikes: 1,
            softThreshold: 3,
            bypassThreshold: true,
            isReregistering: false,
            now: t0,
            lastReregisterAt: nil,
            priorAttempts: 0
        )
        XCTAssertEqual(first, .reregister(attemptNumber: 1, escalated: false))

        let second = SelfHeal.decide(
            healthy: false,
            definitelyDead: false,
            strikes: 2,
            softThreshold: 3,
            bypassThreshold: true,
            isReregistering: false,
            now: t0.addingTimeInterval(2),  // 2s after the first
            lastReregisterAt: t0,
            priorAttempts: 1
        )
        XCTAssertEqual(second, .skipCooldown(remaining: SelfHeal.cooldown - 2))
    }

    // Reentrancy wins even when the cooldown has fully elapsed — a slow in-flight
    // heal can never be doubled (the actual stack-overflow guard).
    func testReentrancyBeatsCooldown() {
        let d = SelfHeal.decide(
            healthy: false,
            definitelyDead: true,
            strikes: 1,
            softThreshold: 3,
            bypassThreshold: false,
            isReregistering: true,
            now: t0.addingTimeInterval(10_000),
            lastReregisterAt: t0,
            priorAttempts: 0
        )
        XCTAssertEqual(d, .skipInFlight)
    }

    // A definitively dead listener uses the short 10s floor but is still
    // rate-limited — fast recovery, not a bypass.
    func testDeadListenerFloorIsRateLimited() {
        let tooSoon = SelfHeal.decide(
            healthy: false,
            definitelyDead: true,
            strikes: 1,
            softThreshold: 3,
            bypassThreshold: false,
            isReregistering: false,
            now: t0.addingTimeInterval(3),
            lastReregisterAt: t0,
            priorAttempts: 0
        )
        XCTAssertEqual(tooSoon, .skipCooldown(remaining: SelfHeal.deadCooldown - 3))

        let elapsed = SelfHeal.decide(
            healthy: false,
            definitelyDead: true,
            strikes: 1,
            softThreshold: 3,
            bypassThreshold: false,
            isReregistering: false,
            now: t0.addingTimeInterval(12),
            lastReregisterAt: t0,
            priorAttempts: 0
        )
        XCTAssertEqual(elapsed, .reregister(attemptNumber: 1, escalated: false))
    }

    // Backoff escalates past the threshold and caps at maxBackoff.
    func testBackoffEscalatesAndCaps() {
        XCTAssertEqual(SelfHeal.interval(definitelyDead: false, attempts: 0), 45)  // base
        XCTAssertEqual(SelfHeal.interval(definitelyDead: false, attempts: 4), 45)  // still base
        XCTAssertEqual(SelfHeal.interval(definitelyDead: false, attempts: 5), 90)  // 45*2
        XCTAssertEqual(SelfHeal.interval(definitelyDead: false, attempts: 6), 180)  // 45*4
        XCTAssertEqual(SelfHeal.interval(definitelyDead: false, attempts: 7), 300)  // 45*8 → cap 300
        XCTAssertEqual(SelfHeal.interval(definitelyDead: false, attempts: 50), 300)  // capped
        XCTAssertEqual(SelfHeal.interval(definitelyDead: true, attempts: 0), 10)  // dead base

        // The `escalated` flag flips once prior attempts have reached the threshold.
        let esc = SelfHeal.decide(
            healthy: false,
            definitelyDead: false,
            strikes: 9,
            softThreshold: 3,
            bypassThreshold: false,
            isReregistering: false,
            now: t0.addingTimeInterval(10_000),
            lastReregisterAt: t0,
            priorAttempts: 5
        )
        XCTAssertEqual(esc, .reregister(attemptNumber: 6, escalated: true))
    }
}
