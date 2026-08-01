import Foundation

/// Context a gate needs to make a decision. Built once per request by the
/// caller (or by `LLMGateway` if it's driving the gate chain itself).
public struct LLMGateContext: Sendable {
    public let isAnonymous: Bool
    public let estimatedCostUSD: Double
    public let metadata: [String: String]

    public init(isAnonymous: Bool = false, estimatedCostUSD: Double = 0, metadata: [String: String] = [:]) {
        self.isAnonymous = isAnonymous
        self.estimatedCostUSD = estimatedCostUSD
        self.metadata = metadata
    }
}

public enum LLMGateDecision: Sendable, Equatable {
    case allow
    case deny(gate: String, reason: String)

    public var isAllowed: Bool {
        if case .allow = self { return true }
        return false
    }
}

/// One link in a pre-flight check chain that runs before an LLM call is
/// attempted — a kill switch, a reachability check, a budget cap, a circuit
/// breaker, an entitlement check, whatever the host app needs. Keeping every
/// gate behind this one protocol means call sites never hand-roll an ad-hoc
/// "if not allowed, bail" check next to the LLM call itself; they all funnel
/// through one composable, testable chain.
public protocol LLMGate: Sendable {
    /// Stable identifier carried on denials for telemetry.
    var identifier: String { get }

    func evaluate(context: LLMGateContext) async -> LLMGateDecision
}

/// Runs gates in order and short-circuits on the first denial. Order
/// matters for cost: put cheap, purely in-memory checks first (kill
/// switches, entitlement flags) and anything that does I/O or could block
/// on a network/keychain round trip last, so a request that a free local
/// gate would refuse never pays for the expensive check.
public struct CompositeLLMGate: LLMGate, Sendable {
    public let identifier = "composite"
    public let gates: [any LLMGate]

    public init(gates: [any LLMGate]) {
        self.gates = gates
    }

    public func evaluate(context: LLMGateContext) async -> LLMGateDecision {
        for gate in gates {
            let decision = await gate.evaluate(context: context)
            if case .deny = decision {
                return decision
            }
        }
        return .allow
    }
}

// MARK: - Built-in gates

/// Wraps a `BudgetEnforcer` as a gate so it can compose with other checks in
/// a `CompositeLLMGate` chain.
public struct BudgetGate: LLMGate {
    public let identifier = "budget"
    private let enforcer: BudgetEnforcer

    public init(enforcer: BudgetEnforcer) {
        self.enforcer = enforcer
    }

    public func evaluate(context: LLMGateContext) async -> LLMGateDecision {
        let allowed = await enforcer.canSpend(
            estimatedCostUSD: context.estimatedCostUSD,
            isAnonymous: context.isAnonymous
        )
        return allowed ? .allow : .deny(gate: identifier, reason: "dailyBudgetExceeded")
    }
}

/// Wraps a `CircuitBreaker` as a gate.
public struct CircuitBreakerGate: LLMGate {
    public let identifier = "circuitBreaker"
    private let breaker: CircuitBreaker
    private let providerID: String

    public init(breaker: CircuitBreaker, providerID: String) {
        self.breaker = breaker
        self.providerID = providerID
    }

    public func evaluate(context: LLMGateContext) async -> LLMGateDecision {
        await breaker.canAttempt() ? .allow : .deny(gate: identifier, reason: "circuitOpen:\(providerID)")
    }
}

/// A simple boolean toggle — a kill switch, a feature flag, an
/// entitlement check — supplied as a closure so it composes without a
/// host app needing to depend on any particular flag system.
public struct ClosureGate: LLMGate {
    public let identifier: String
    private let check: @Sendable (LLMGateContext) async -> Bool
    private let denialReason: String

    public init(identifier: String, denialReason: String, check: @escaping @Sendable (LLMGateContext) async -> Bool) {
        self.identifier = identifier
        self.denialReason = denialReason
        self.check = check
    }

    public func evaluate(context: LLMGateContext) async -> LLMGateDecision {
        await check(context) ? .allow : .deny(gate: identifier, reason: denialReason)
    }
}
