import Foundation

/// Classic circuit breaker for a single upstream (an LLM provider, or any
/// failure-prone dependency). Opens after `failureThreshold` consecutive
/// failures, then refuses further attempts until `recoveryInterval` has
/// elapsed, at which point it allows exactly one half-open probe.
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
    public func canAttempt() -> Bool {
        switch state {
        case .closed:
            return true
        case .open:
            guard let lastFailure = lastFailureDate,
                  Date().timeIntervalSince(lastFailure) >= recoveryInterval else {
                return false
            }
            state = .halfOpen
            return true
        case .halfOpen:
            return true
        }
    }

    public func recordSuccess() {
        failureCount = 0
        lastFailureDate = nil
        state = .closed
    }

    public func recordFailure() {
        failureCount += 1
        lastFailureDate = Date()
        if failureCount >= failureThreshold {
            state = .open
        }
    }

    public func reset() {
        failureCount = 0
        lastFailureDate = nil
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
