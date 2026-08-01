import Foundation
import Testing
@testable import LLMGatewayKit

private struct CountingProvider: LLMProvider {
    let identifier: String
    let counter: Counter

    func estimatedCostUSD(inputTokens: Int, outputTokens: Int) -> Double { 0.01 }

    func send(_ request: LLMRequest) async throws -> LLMResponse {
        await counter.increment()
        return LLMResponse(text: "answer #\(await counter.value)", usage: LLMUsage(inputTokens: 10, outputTokens: 10), confidence: 0.9, modelID: identifier)
    }
}

private actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}

private struct FixedEmbeddingProvider: EmbeddingProvider {
    let modelIdentifier = "fixed-v1"
    func embed(_ text: String) async -> [Float] { [1, 0, 0] }
}

@Suite("LLMGateway")
struct LLMGatewayTests {
    @Test("a semantic cache hit never invokes the provider")
    func cacheHitSkipsProvider() async throws {
        let counter = Counter()
        let provider = CountingProvider(identifier: "primary", counter: counter)
        let cascade = TieredCascade(tiers: [CascadeTier(provider: provider)])
        let budget = BudgetEnforcer(identifiedDailyCapUSD: 5.0, anonymousDailyCapUSD: 1.0, store: InMemoryBudgetStore())
        let cache = SemanticCache(embeddingProvider: FixedEmbeddingProvider(), similarityThreshold: 0.5)
        let gateway = LLMGateway(cascade: cascade, budget: budget, semanticCache: cache)

        _ = try await gateway.complete(LLMRequest(prompt: "hello"))
        #expect(await counter.value == 1)

        // Same embedding vector (fixed provider) => cache hit on the second call.
        _ = try await gateway.complete(LLMRequest(prompt: "a different but semantically-equal prompt"))
        #expect(await counter.value == 1, "provider should not be called again on a cache hit")
    }

    @Test("budget gate denies the call once the cap is exhausted")
    func budgetGateDenies() async {
        let counter = Counter()
        let provider = CountingProvider(identifier: "primary", counter: counter)
        let cascade = TieredCascade(tiers: [CascadeTier(provider: provider)])
        let budget = BudgetEnforcer(identifiedDailyCapUSD: 0.005, anonymousDailyCapUSD: 0.001, store: InMemoryBudgetStore())
        let gateway = LLMGateway(cascade: cascade, budget: budget)

        do {
            _ = try await gateway.complete(LLMRequest(prompt: "hello, this call should exceed the tiny cap"))
            Issue.record("expected a budget denial")
        } catch LLMGatewayError.gateDenied(let reason) {
            #expect(reason == "dailyBudgetExceeded")
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        #expect(await counter.value == 0, "provider must not be called once the gate denies")
    }

    @Test("a successful provider call records spend against the budget")
    func recordsSpendOnSuccess() async throws {
        let counter = Counter()
        let provider = CountingProvider(identifier: "primary", counter: counter)
        let cascade = TieredCascade(tiers: [CascadeTier(provider: provider)])
        let budget = BudgetEnforcer(identifiedDailyCapUSD: 5.0, anonymousDailyCapUSD: 1.0, store: InMemoryBudgetStore())
        let gateway = LLMGateway(cascade: cascade, budget: budget)

        _ = try await gateway.complete(LLMRequest(prompt: "hello"))
        let used = await budget.dailyUsageUSD(isAnonymous: false)
        #expect(used > 0)
    }
}
