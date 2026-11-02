import Foundation

/// Classic circuit breaker for a single upstream (an LLM provider, or any
/// failure-prone dependency). Opens after `failureThreshold` consecutive
/// failures, then refuses further attempts until `recoveryInterval` has
/// elapsed, at which point it allows exactly one half-open probe at a time.
/// A probe that never records a result stops blocking after another
/// `recoveryInterval`, when the next caller becomes the probe.
///
/// `LLMGatewayKit` gives every provider in a `TieredCascade` its own
/// breaker, so one struggling provider "opens" independently and traffic
/// routes to the next tier without waiting on retries against a provider
/// that's already down.
public actor CircuitBreaker {
    public enum State: Sendable, Equatable { case closed, open, halfOpen }

    private(set) public var state: State = .closed
    private var failureCount: Int = 0
    private var lastFailureDate: Date?
    private var probeStartedAt: Date?
    private let failureThreshold: Int
    private let recoveryInterval: TimeInterval

    public init(failureThreshold: Int = 5, recoveryInterval: TimeInterval = 60) {
        self.failureThreshold = failureThreshold
        self.recoveryInterval = recoveryInterval
    }

    /// Whether a call may currently be attempted against the guarded upstream.
    /// Transitions `open` → `halfOpen` as a side effect once the recovery
    /// interval has elapsed, so callers should treat this as the single
    /// source of truth immediately before every attempt (don't cache it).
    /// Outside `closed`, a `true` makes the caller the probe: it must make the
    /// call and report back with `recordSuccess` or `recordFailure`.
    public func canAttempt() -> Bool {
        guard wouldAllowAttempt() else { return false }
        if state != .closed {
            state = .halfOpen
            probeStartedAt = Date()
        }
        return true
    }

    /// Whether `canAttempt()` would currently return `true`, without taking the
    /// probe. For callers that only look and won't make the call themselves.
    public func wouldAllowAttempt() -> Bool {
        let waitingSince: Date?
        switch state {
        case .closed: return true
        case .open: waitingSince = lastFailureDate
        case .halfOpen: waitingSince = probeStartedAt
        }
        guard let waitingSince else { return false }
        return Date().timeIntervalSince(waitingSince) >= recoveryInterval
    }

    public func recordSuccess() {
        failureCount = 0
        lastFailureDate = nil
        probeStartedAt = nil
        state = .closed
    }

    public func recordFailure() {
        failureCount += 1
        lastFailureDate = Date()
        probeStartedAt = nil
        if failureCount >= failureThreshold {
            state = .open
        }
    }

    public func reset() {
        failureCount = 0
        lastFailureDate = nil
        probeStartedAt = nil
        state = .closed
    }

    /// Runs `operation` guarded by this breaker: refuses (throws
    /// `LLMGatewayError.circuitOpen`) when the circuit isn't attemptable,
    /// otherwise runs it and records success/failure. Convenience wrapper —
    /// `TieredCascade` uses the lower-level `canAttempt`/`record*` methods
    /// directly so it can fall through to the next tier instead of throwing.
    public func execute<T: Sendable>(
        providerID: String,
        _ operation: @Sendable () async throws -> T
    ) async throws -> T {
        guard canAttempt() else {
            throw LLMGatewayError.circuitOpen(provider: providerID)
        }
        do {
            let result = try await operation()
            recordSuccess()
            return result
        } catch {
            recordFailure()
            throw error
        }
    }
}
