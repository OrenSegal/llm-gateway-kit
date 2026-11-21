import Foundation

/// The orchestrator that ties the three pillars together: gate chain →
/// cache lookup → budget-checked, circuit-broken tiered provider cascade →
/// cache store → cost recording. This is the type most apps only ever need
/// to touch directly.
///
/// Request flow for `complete(_:isAnonymous:)`:
///   1. Check the semantic cache. A hit returns immediately — no provider
///      call, no spend.
///   2. Run the gate chain. Any denial short-circuits with `.gateDenied`.
///   3. On a miss, estimate cost and reserve it with the budget enforcer.
///      No reservation means `.gateDenied(reason: "dailyBudgetExceeded")`.
///   4. Run the tiered provider cascade (which owns its own circuit breakers).
///      If it throws, release the reservation.
///   5. Commit the actual cost, store the response in the cache, log the
///      settled cost to the audit logger.
///
/// `completeVision(_:image:isAnonymous:)` follows the same shape but checks
/// the vision (perceptual-hash) cache instead of the semantic cache.
public final class LLMGateway: @unchecked Sendable {
    private let gate: any LLMGate
    private let semanticCache: SemanticCache?
    private let visionCache: VisionCache?
    private let cascade: TieredCascade
    private let budget: BudgetEnforcer
    private let auditLogger: CostAuditLogger
    private let pricing: PricingTable?

    /// - Parameter pricing: When set, each response's actual cost comes from
    ///   this table, looked up by the response's `modelID`; an unknown id gets
    ///   the table's fallback price. When nil, the provider prices it with
    ///   `estimatedCostUSD`. The pre-flight estimate always comes from the provider.
    public init(
        cascade: TieredCascade,
        budget: BudgetEnforcer,
        gate: (any LLMGate)? = nil,
        semanticCache: SemanticCache? = nil,
        visionCache: VisionCache? = nil,
        auditLogger: CostAuditLogger = CostAuditLogger(),
        pricing: PricingTable? = nil
    ) {
        self.cascade = cascade
        self.budget = budget
        self.gate = gate ?? CompositeLLMGate(gates: [])
        self.semanticCache = semanticCache
        self.visionCache = visionCache
        self.auditLogger = auditLogger
        self.pricing = pricing
    }

    /// Text completion. Cheapest-first: cache, then the budget-reserved provider cascade.
    public func complete(_ request: LLMRequest, isAnonymous: Bool = false) async throws -> LLMResponse {
        if let semanticCache, let cached = await semanticCache.lookup(prompt: request.prompt) {
            await auditLogger.log(source: .semanticCache, costUSD: 0)
            return LLMResponse(text: cached, usage: LLMUsage(inputTokens: 0, outputTokens: 0), modelID: "cache")
        }

        let estimatedCost = cascade.tiers.first?.provider.estimatedCostUSD(
            inputTokens: request.prompt.count / 4,
            outputTokens: request.maxOutputTokens ?? 256
        ) ?? 0
        let response = try await sendWithinBudget(request, estimatedCost: estimatedCost, isAnonymous: isAnonymous)
        if let semanticCache {
            await semanticCache.store(prompt: request.prompt, response: response.text)
        }
        return response
    }

    /// Vision completion. Same shape as `complete`, keyed on image perceptual
    /// hash instead of prompt embedding.
    public func completeVision(_ request: LLMRequest, isAnonymous: Bool = false) async throws -> LLMResponse {
        guard let image = request.image else {
            return try await complete(request, isAnonymous: isAnonymous)
        }

        if let visionCache, let cached = await visionCache.lookup(image: image, taskType: request.taskType) {
            await auditLogger.log(source: .visionCache, costUSD: 0)
            return LLMResponse(text: cached, usage: LLMUsage(inputTokens: 0, outputTokens: 0), modelID: "cache")
        }

        let estimatedCost = cascade.tiers.first?.provider.estimatedCostUSD(
            inputTokens: 1_300,
            outputTokens: request.maxOutputTokens ?? 400
        ) ?? 0
        let response = try await sendWithinBudget(request, estimatedCost: estimatedCost, isAnonymous: isAnonymous)
        if let visionCache {
            await visionCache.store(image: image, response: response.text, taskType: request.taskType)
        }
        return response
    }

    /// Gate chain, then reserve, send, and commit or release.
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

        let response: LLMResponse
        do {
            response = try await cascade.send(request)
        } catch {
            // Covers cancellation too: nothing settled, so return the hold.
            await budget.release(reservation)
            throw error
        }
        let actualCost = costForProvider(modelID: response.modelID, usage: response.usage)
        await budget.commit(reservation, actualCostUSD: actualCost)
        await auditLogger.log(source: .provider, costUSD: actualCost)
        return response
    }

    private func costForProvider(modelID: String, usage: LLMUsage) -> Double {
        if let pricing {
            return pricing.cost(model: modelID, tokens: TokenCounts(usage))
        }
        guard let provider = cascade.tiers.first(where: { $0.provider.identifier == modelID })?.provider
            ?? cascade.tiers.first?.provider else {
            return 0
        }
        return provider.estimatedCostUSD(inputTokens: usage.inputTokens, outputTokens: usage.billedOutputTokens)
    }

    public var auditLog: CostAuditLogger { auditLogger }
}
