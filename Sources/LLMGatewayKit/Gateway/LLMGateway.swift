import Foundation

/// The orchestrator that ties the three pillars together: cache lookup →
/// gate chain → budget-checked, circuit-broken tiered provider cascade →
/// cost recording → cache store. The gate chain runs only on a cache miss,
/// so a denying gate does not stop a cached answer. This is the type most apps only ever need
/// to touch directly.
///
/// Request flow for `complete(_:isAnonymous:)`:
///   1. Check the semantic cache. A hit returns immediately with no provider
///      call and no spend.
///   2. On a miss, run the gate chain. Any denial short-circuits with `.gateDenied`.
///   3. Reserve the estimated cost against the budget. If that would cross the
///      cap, the call is refused with `.gateDenied`.
///   4. Run the tiered provider cascade (which owns its own circuit breakers),
///      recording the real cost of every provider call that returns a response.
///   5. Release the reservation, store the response in the cache.
///
/// `completeVision(_:isAnonymous:)` follows the same shape but checks the
/// vision (perceptual-hash) cache instead of the semantic cache.
public final class LLMGateway: @unchecked Sendable {
    private let gate: any LLMGate
    private let semanticCache: SemanticCache?
    private let visionCache: VisionCache?
    private let cascade: TieredCascade
    private let budget: BudgetEnforcer
    private let auditLogger: CostAuditLogger

    public init(
        cascade: TieredCascade,
        budget: BudgetEnforcer,
        gate: (any LLMGate)? = nil,
        semanticCache: SemanticCache? = nil,
        visionCache: VisionCache? = nil,
        auditLogger: CostAuditLogger = CostAuditLogger()
    ) {
        self.cascade = cascade
        self.budget = budget
        self.gate = gate ?? CompositeLLMGate(gates: [])
        self.semanticCache = semanticCache
        self.visionCache = visionCache
        self.auditLogger = auditLogger
    }

    /// Text completion. Cheapest-first: cache, then budget-gated provider cascade.
    /// A request with an image goes through `completeVision`, because the text
    /// cache can't see the image.
    public func complete(_ request: LLMRequest, isAnonymous: Bool = false) async throws -> LLMResponse {
        if request.image != nil {
            return try await completeVision(request, isAnonymous: isAnonymous)
        }

        let scope = cacheScope(for: request)
        let lookup = await semanticCache?.lookupKeepingEmbedding(prompt: request.prompt, scope: scope)
        if let cached = lookup?.response {
            await auditLogger.log(source: .semanticCache, costUSD: 0)
            return LLMResponse(text: cached, usage: LLMUsage(inputTokens: 0, outputTokens: 0), modelID: "cache")
        }

        let estimatedCost = estimate(inputTokens: request.prompt.count / 4, outputTokens: request.maxOutputTokens ?? 256)
        let response = try await sendWithinBudget(request, estimatedCost: estimatedCost, isAnonymous: isAnonymous)
        if let semanticCache, let lookup {
            await semanticCache.store(prompt: request.prompt, response: response.text, scope: scope, embedding: lookup.embedding)
        }
        return response
    }

    /// Vision completion. Same shape as `complete`, keyed on image perceptual
    /// hash and the prompt instead of prompt embedding.
    public func completeVision(_ request: LLMRequest, isAnonymous: Bool = false) async throws -> LLMResponse {
        guard let image = request.image else {
            return try await complete(request, isAnonymous: isAnonymous)
        }

        let scope = cacheScope(for: request)
        if let visionCache, let cached = await visionCache.lookup(image: image, prompt: request.prompt, taskType: scope) {
            await auditLogger.log(source: .visionCache, costUSD: 0)
            return LLMResponse(text: cached, usage: LLMUsage(inputTokens: 0, outputTokens: 0), modelID: "cache")
        }

        let estimatedCost = estimate(inputTokens: 1_300, outputTokens: request.maxOutputTokens ?? 400)
        let response = try await sendWithinBudget(request, estimatedCost: estimatedCost, isAnonymous: isAnonymous)
        if let visionCache {
            await visionCache.store(image: image, prompt: request.prompt, response: response.text, taskType: scope)
        }
        return response
    }

    private func sendWithinBudget(_ request: LLMRequest, estimatedCost: Double, isAnonymous: Bool) async throws -> LLMResponse {
        let decision = await gate.evaluate(context: LLMGateContext(isAnonymous: isAnonymous, estimatedCostUSD: estimatedCost))
        guard decision.isAllowed else {
            if case .deny(_, let reason) = decision {
                throw LLMGatewayError.gateDenied(reason: reason)
            }
            throw LLMGatewayError.gateDenied(reason: "unknown")
        }
        guard let reservation = await budget.reserve(estimatedCostUSD: estimatedCost, isAnonymous: isAnonymous) else {
            throw LLMGatewayError.gateDenied(reason: "dailyBudgetExceeded")
        }

        do {
            let response = try await cascade.send(request) { [budget, auditLogger] cost in
                await budget.record(actualCostUSD: cost, isAnonymous: isAnonymous)
                await auditLogger.log(source: .provider, costUSD: cost)
            }
            await budget.release(reservation)
            return response
        } catch {
            await budget.release(reservation)
            throw error
        }
    }

    /// Priced at the most expensive tier, because a failure or an open breaker
    /// on a cheaper tier sends the call there. Pricing the hold at the first
    /// tier let a burst during failover spend several times the cap.
    private func estimate(inputTokens: Int, outputTokens: Int) -> Double {
        cascade.tiers.map { $0.provider.estimatedCostUSD(inputTokens: inputTokens, outputTokens: outputTokens) }.max() ?? 0
    }

    /// Everything besides the prompt and image that changes the answer. The
    /// cascade's tiers stand in for the model, since which tier answers isn't
    /// known until after the lookup. `description` quotes the strings, so
    /// different values can't join into the same scope.
    private func cacheScope(for request: LLMRequest) -> String {
        [cascade.tiers.map(\.provider.identifier), [request.taskType], [request.maxOutputTokens.map(String.init) ?? "default"]].description
    }

    public var auditLog: CostAuditLogger { auditLogger }
}
