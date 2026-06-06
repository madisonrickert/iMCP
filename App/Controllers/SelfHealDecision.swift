import Foundation

// Pure, dependency-free decision logic for the Bonjour advertisement self-heal.
// Extracted from `ServerNetworkManager` (ServerController.swift) so the
// rate-limit / backoff / reentrancy math can be unit-tested in isolation — see
// Tests/SelfHealTests, which symlinks THIS file as its single source of truth.
// It has no Network/AppKit dependencies, so it compiles standalone under SwiftPM.
//
// Context: an unbounded self-heal that re-registered on every `path-satisfied`
// callback drove the Network framework into a stack-overflow (SIGBUS). These
// rules make re-registration bounded and non-reentrant.
enum SelfHeal {
    // Cooldown floors (seconds): transient-unhealthy (.ready-but-invisible,
    // .waiting, .setup) vs definitively dead (.failed/.cancelled). Both are
    // floors, never bypasses.
    static let cooldown: TimeInterval = 45
    static let deadCooldown: TimeInterval = 10
    // After this many consecutive failed attempts the cooldown grows…
    static let backoffThreshold = 5
    // …capped here, so a never-becomes-visible listener settles instead of
    // hammering Bonjour forever.
    static let maxBackoff: TimeInterval = 300

    enum Decision: Equatable {
        case skipHealthy  // healthy → caller resets counters, no action
        case skipBelowThreshold  // unhealthy but the soft strike threshold isn't met
        case skipInFlight  // a re-register is already running (reentrancy guard)
        case skipCooldown(remaining: TimeInterval)
        case reregister(attemptNumber: Int, escalated: Bool)
    }

    // Minimum seconds before another re-register is allowed, given how many
    // consecutive attempts have already failed to restore health. Past the
    // backoff threshold the floor doubles each attempt, capped at `maxBackoff`.
    static func interval(definitelyDead: Bool, attempts: Int) -> TimeInterval {
        let base = definitelyDead ? deadCooldown : cooldown
        guard attempts >= backoffThreshold else { return base }
        let over = attempts - backoffThreshold  // 0, 1, 2, …
        let factor = Double(1 << min(over + 1, 8))  // 2, 4, 8, … (shift-capped)
        return min(base * factor, maxBackoff)
    }

    // Pure gate. `strikes` is the post-increment unhealthy-check counter;
    // `bypassThreshold` lets a path transition (sleep/wake) act on the first
    // strike while STILL being rate-limited by the cooldown + reentrancy guard.
    // Caller supplies `now` for determinism.
    static func decide(
        healthy: Bool,
        definitelyDead: Bool,
        strikes: Int,
        softThreshold: Int,
        bypassThreshold: Bool,
        isReregistering: Bool,
        now: Date,
        lastReregisterAt: Date?,
        priorAttempts: Int
    ) -> Decision {
        if healthy { return .skipHealthy }
        guard definitelyDead || bypassThreshold || strikes >= softThreshold else {
            return .skipBelowThreshold
        }
        // Reentrancy guard first — the cheapest gate and the actual overflow fix.
        guard !isReregistering else { return .skipInFlight }
        let cd = interval(definitelyDead: definitelyDead, attempts: priorAttempts)
        if let last = lastReregisterAt {
            let elapsed = now.timeIntervalSince(last)
            if elapsed < cd { return .skipCooldown(remaining: cd - elapsed) }
        }
        return .reregister(
            attemptNumber: priorAttempts + 1,
            escalated: priorAttempts >= backoffThreshold
        )
    }
}
