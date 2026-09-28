import Foundation

/// One rung of a `TieredCascade`: a provider paired with its own circuit
/// breaker and an optional confidence floor. Each tier fails over to the
/// next independently — a low-confidence response from tier 1 escalates to
/// tier 2 even if tier 1 didn't throw, and an open breaker on tier 1 routes
/// straight to tier 2 without attempting a call that would just fail.
public struct CascadeTier: Sendable {
    public let provider: any LLMProvider
    public let breaker: CircuitBreaker
    /// If the response's `confidence` is present and below this floor, the
    /// cascade treats it as a quality escalation and tries the next tier
    /// even though the call itself succeeded. `nil` disables quality
    /// escalation for this tier (only failures/open-breaker escalate).
    public let confidenceFloor: Double?

    public init(provider: any LLMProvider, breaker: CircuitBreaker? = nil, confidenceFloor: Double? = nil) {
        self.provider = provider
        self.breaker = breaker ?? CircuitBreaker()
        self.confidenceFloor = confidenceFloor
    }
}

/// Runs a request down an ordered list of provider tiers — e.g. a cheap/fast
/// primary model with a stronger/pricier backup — escalating to the next
/// tier on failure, an open circuit breaker, or (optionally) low confidence.
///
/// This is the pattern used in the app this was extracted from to run a lower-cost vision model
/// as primary with a higher-quality model as fallback: most calls resolve on
/// the cheap tier, and only the ones that actually need it escalate, so
/// average cost per call stays close to the cheap tier's price while
/// reliability and quality track the expensive tier's ceiling.
public struct TieredCascade: Sendable {
    public let tiers: [CascadeTier]

    /// - Parameter tiers: Ordered cheapest/fastest first. Must be non-empty.
    public init(tiers: [CascadeTier]) {
        precondition(!tiers.isEmpty, "TieredCascade requires at least one tier")
        self.tiers = tiers
    }

    /// Attempts each tier in order. Returns the first response that either
    /// has no confidence signal or clears its tier's confidence floor.
    /// Throws `LLMGatewayError.allProvidersFailed` only if every tier either
    /// had an open breaker or threw.
    public func send(_ request: LLMRequest) async throws -> LLMResponse {
        var lastError: Error?
        for tier in tiers {
            guard await tier.breaker.canAttempt() else {
                lastError = LLMGatewayError.circuitOpen(provider: tier.provider.identifier)
                continue
            }
            do {
                let response = try await tier.provider.send(request)
                await tier.breaker.recordSuccess()
                if let floor = tier.confidenceFloor, let confidence = response.confidence, confidence < floor {
                    // Quality escalation: this tier "succeeded" but isn't
                    // confident enough — try the next tier without treating
                    // this as a breaker failure (the provider didn't error).
                    continue
                }
                return response
            } catch {
                await tier.breaker.recordFailure()
                lastError = error
            }
        }
        if let lastError {
            throw lastError
        }
        throw LLMGatewayError.allProvidersFailed
    }
}
