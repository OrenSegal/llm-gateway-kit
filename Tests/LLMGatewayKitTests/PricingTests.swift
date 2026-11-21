import Foundation
import Testing
@testable import LLMGatewayKit

/// Answers as a model whose id differs from the provider's `identifier`.
private struct AliasedProvider: LLMProvider {
    let identifier = "anthropic"
    func estimatedCostUSD(inputTokens: Int, outputTokens: Int) -> Double { 0.01 }
    func send(_ request: LLMRequest) async throws -> LLMResponse {
        LLMResponse(text: "ok", usage: LLMUsage(inputTokens: 1_000, outputTokens: 400, reasoningTokens: 100), modelID: "claude-sonnet-5-5-20261101")
    }
}

@Suite("Pricing")
struct PricingTests {
    @Test("LLMUsage reasoning moves inside TokenCounts output and is noted as thinking")
    func usageConversion() {
        let tokens = TokenCounts(LLMUsage(inputTokens: 10, outputTokens: 20, reasoningTokens: 5))
        #expect(tokens == TokenCounts(input: 10, output: 25, thinking: 5))
        #expect(tokens.total == 35, "thinking must not be counted twice")
    }

    @Test("the gateway prices a response by its model id when given a table")
    func gatewayPricesByModelID() async throws {
        let table = PricingTable(models: ["claude-sonnet-5-5": ModelPrice(input: 2, output: 10)], fallback: ModelPrice(input: 100, output: 100))
        let budget = BudgetEnforcer(identifiedDailyCapUSD: 5.0, anonymousDailyCapUSD: 0.1, store: InMemoryBudgetStore())
        let gateway = LLMGateway(
            cascade: TieredCascade(tiers: [CascadeTier(provider: AliasedProvider())]),
            budget: budget,
            pricing: table
        )

        _ = try await gateway.complete(LLMRequest(prompt: "hello"))

        // Prefix match on the dated id: 1,000 input at $2/M plus 500 output (400 + 100 reasoning) at $10/M.
        let expected = (1_000 * 2.0 + 500 * 10.0) / 1_000_000
        #expect(abs(await budget.dailyUsageUSD(isAnonymous: false) - expected) < 1e-12)
        #expect(await gateway.auditLog.drainPending().map(\.costUSD) == [await budget.dailyUsageUSD(isAnonymous: false)])
    }
}
