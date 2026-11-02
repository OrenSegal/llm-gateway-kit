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

private struct FixedHasher: PerceptualHasher {
    func hash(_ image: Data) async -> String { "ffff" }
}

/// Flat price per call. `modelID` can differ from `identifier`, as it does for
/// vendors that report a dated model name in the response.
private struct PricedProvider: LLMProvider {
    let identifier: String
    var modelID: String?
    let priceUSD: Double
    var confidence: Double?
    var fails = false
    var counter = Counter()

    func estimatedCostUSD(inputTokens: Int, outputTokens: Int) -> Double { priceUSD }

    func send(_ request: LLMRequest) async throws -> LLMResponse {
        await counter.increment()
        // Long enough that concurrent callers overlap inside the call.
        try await Task.sleep(nanoseconds: 20_000_000)
        if fails { throw URLError(.badServerResponse) }
        return LLMResponse(
            text: "\(identifier) #\(await counter.value)",
            usage: LLMUsage(inputTokens: 1, outputTokens: 1),
            confidence: confidence,
            modelID: modelID ?? identifier
        )
    }
}

/// Priced by token count, so the pre-flight estimate (256 output tokens) is far
/// above what the call really costs (1 output token).
private struct PerTokenProvider: LLMProvider {
    let identifier = "per-token"

    func estimatedCostUSD(inputTokens: Int, outputTokens: Int) -> Double { Double(outputTokens) * 0.001 }

    func send(_ request: LLMRequest) async throws -> LLMResponse {
        LLMResponse(text: "ok", usage: LLMUsage(inputTokens: 0, outputTokens: 1), modelID: identifier)
    }
}

private func roomyBudget() -> BudgetEnforcer {
    BudgetEnforcer(identifiedDailyCapUSD: 100, anonymousDailyCapUSD: 100, store: InMemoryBudgetStore())
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

    // MARK: - Spend accounting

    @Test("an escalated call records every leg at the price of the tier that served it")
    func recordsEveryEscalatedLeg() async throws {
        let cascade = TieredCascade(tiers: [
            CascadeTier(provider: PricedProvider(identifier: "cheap", modelID: "m-cheap", priceUSD: 0.01, confidence: 0.1), confidenceFloor: 0.5),
            CascadeTier(provider: PricedProvider(identifier: "pricey", modelID: "m-pricey", priceUSD: 1.0)),
        ])
        let budget = roomyBudget()
        let gateway = LLMGateway(cascade: cascade, budget: budget)

        _ = try await gateway.complete(LLMRequest(prompt: "x"))

        #expect(abs(await budget.dailyUsageUSD(isAnonymous: false) - 1.01) < 1e-9)
        let logged = await gateway.auditLog.drainPending().reduce(0) { $0 + $1.costUSD }
        #expect(abs(logged - 1.01) < 1e-9)
    }

    @Test("a call where every tier returns low confidence throws and still records what it paid")
    func recordsSpendWhenAllLowConfidence() async {
        let cascade = TieredCascade(tiers: [
            CascadeTier(provider: PricedProvider(identifier: "only", priceUSD: 0.5, confidence: 0.1), confidenceFloor: 0.5),
        ])
        let budget = roomyBudget()
        let gateway = LLMGateway(cascade: cascade, budget: budget)

        await #expect(throws: LLMGatewayError.allProvidersFailed) {
            _ = try await gateway.complete(LLMRequest(prompt: "x"))
        }

        #expect(abs(await budget.dailyUsageUSD(isAnonymous: false) - 0.5) < 1e-9)
        let logged = await gateway.auditLog.drainPending().reduce(0) { $0 + $1.costUSD }
        #expect(abs(logged - 0.5) < 1e-9)
    }

    @Test("a paid low-confidence leg stays recorded when the next tier throws")
    func recordsPaidLegBeforeLaterFailure() async {
        let cascade = TieredCascade(tiers: [
            CascadeTier(provider: PricedProvider(identifier: "cheap", priceUSD: 0.5, confidence: 0.1), confidenceFloor: 0.5),
            CascadeTier(provider: PricedProvider(identifier: "down", priceUSD: 1.0, fails: true)),
        ])
        let budget = roomyBudget()

        await #expect(throws: URLError.self) {
            _ = try await LLMGateway(cascade: cascade, budget: budget).complete(LLMRequest(prompt: "x"))
        }

        #expect(abs(await budget.dailyUsageUSD(isAnonymous: false) - 0.5) < 1e-9)
    }

    // MARK: - Budget reservation

    @Test("concurrent calls cannot pass a cap that only fits one of them")
    func concurrentCallsRespectCap() async {
        let counter = Counter()
        let cascade = TieredCascade(tiers: [CascadeTier(provider: PricedProvider(identifier: "a", priceUSD: 0.01, counter: counter))])
        let budget = BudgetEnforcer(identifiedDailyCapUSD: 0.01, anonymousDailyCapUSD: 0.01, store: InMemoryBudgetStore())
        let gateway = LLMGateway(cascade: cascade, budget: budget)

        let served = await withTaskGroup(of: Bool.self) { group in
            for i in 0..<20 {
                group.addTask { (try? await gateway.complete(LLMRequest(prompt: "p\(i)"))) != nil }
            }
            var served = 0
            for await ok in group where ok { served += 1 }
            return served
        }

        #expect(served == 1)
        #expect(await counter.value == 1)
        #expect(abs(await budget.dailyUsageUSD(isAnonymous: false) - 0.01) < 1e-9)
    }

    @Test("a failed call gives its reservation back")
    func failedCallReleasesReservation() async throws {
        let budget = BudgetEnforcer(identifiedDailyCapUSD: 0.01, anonymousDailyCapUSD: 0.01, store: InMemoryBudgetStore())
        let down = TieredCascade(tiers: [CascadeTier(provider: PricedProvider(identifier: "down", priceUSD: 0.01, fails: true))])
        let up = TieredCascade(tiers: [CascadeTier(provider: PricedProvider(identifier: "up", priceUSD: 0.01))])

        await #expect(throws: URLError.self) {
            _ = try await LLMGateway(cascade: down, budget: budget).complete(LLMRequest(prompt: "x"))
        }
        #expect(await budget.dailyUsageUSD(isAnonymous: false) == 0)

        // The only way this fits under the cap is if the failed call released its hold.
        _ = try await LLMGateway(cascade: up, budget: budget).complete(LLMRequest(prompt: "x"))
    }

    @Test("a finished call holds its real cost, not its estimate")
    func settlesToActualCost() async throws {
        let cascade = TieredCascade(tiers: [CascadeTier(provider: PerTokenProvider())])
        // Fits one $0.256 estimate at a time, and many $0.001 actuals.
        let budget = BudgetEnforcer(identifiedDailyCapUSD: 0.3, anonymousDailyCapUSD: 0.3, store: InMemoryBudgetStore())
        let gateway = LLMGateway(cascade: cascade, budget: budget)

        for i in 0..<3 {
            _ = try await gateway.complete(LLMRequest(prompt: "p\(i)"))
        }

        #expect(abs(await budget.dailyUsageUSD(isAnonymous: false) - 0.003) < 1e-9)
    }

    // MARK: - Cache keys

    @Test("the vision cache does not answer a different question about the same image")
    func visionCacheSeparatesPrompts() async throws {
        let counter = Counter()
        let cascade = TieredCascade(tiers: [CascadeTier(provider: CountingProvider(identifier: "a", counter: counter))])
        let gateway = LLMGateway(cascade: cascade, budget: roomyBudget(), visionCache: VisionCache(hasher: FixedHasher()))
        let image = Data([1])

        let eggs = try await gateway.completeVision(LLMRequest(prompt: "count the eggs", image: image))
        let allergens = try await gateway.completeVision(LLMRequest(prompt: "list allergens", image: image))
        #expect(allergens.text != eggs.text)
        #expect(await counter.value == 2)

        let eggsAgain = try await gateway.completeVision(LLMRequest(prompt: "count the eggs", image: image))
        #expect(eggsAgain.text == eggs.text)
        #expect(await counter.value == 2, "the same question about the same image is still a hit")
    }

    @Test("the vision cache separates requests with different output limits")
    func visionCacheSeparatesParams() async throws {
        let counter = Counter()
        let cascade = TieredCascade(tiers: [CascadeTier(provider: CountingProvider(identifier: "a", counter: counter))])
        let gateway = LLMGateway(cascade: cascade, budget: roomyBudget(), visionCache: VisionCache(hasher: FixedHasher()))

        _ = try await gateway.completeVision(LLMRequest(prompt: "q", image: Data([1]), maxOutputTokens: 10))
        _ = try await gateway.completeVision(LLMRequest(prompt: "q", image: Data([1]), maxOutputTokens: 500))
        #expect(await counter.value == 2)
    }

    @Test("the semantic cache separates task types and output limits")
    func semanticCacheSeparatesRequests() async throws {
        let counter = Counter()
        let cascade = TieredCascade(tiers: [CascadeTier(provider: CountingProvider(identifier: "a", counter: counter))])
        let cache = SemanticCache(embeddingProvider: FixedEmbeddingProvider(), similarityThreshold: 0.5)
        let gateway = LLMGateway(cascade: cascade, budget: roomyBudget(), semanticCache: cache)

        _ = try await gateway.complete(LLMRequest(prompt: "q", taskType: "summary"))
        _ = try await gateway.complete(LLMRequest(prompt: "q", taskType: "translate"))
        #expect(await counter.value == 2)

        _ = try await gateway.complete(LLMRequest(prompt: "q", taskType: "summary", maxOutputTokens: 10))
        #expect(await counter.value == 3)

        _ = try await gateway.complete(LLMRequest(prompt: "q", taskType: "summary"))
        _ = try await gateway.complete(LLMRequest(prompt: "q", taskType: "translate"))
        #expect(await counter.value == 3, "each variant keeps its own entry and still hits")
    }

    @Test("gateways with different models sharing a semantic cache do not share answers")
    func semanticCacheSeparatesModels() async throws {
        let counter = Counter()
        let cache = SemanticCache(embeddingProvider: FixedEmbeddingProvider(), similarityThreshold: 0.5)
        let first = TieredCascade(tiers: [CascadeTier(provider: CountingProvider(identifier: "model-a", counter: counter))])
        let second = TieredCascade(tiers: [CascadeTier(provider: CountingProvider(identifier: "model-b", counter: counter))])

        _ = try await LLMGateway(cascade: first, budget: roomyBudget(), semanticCache: cache).complete(LLMRequest(prompt: "q"))
        _ = try await LLMGateway(cascade: second, budget: roomyBudget(), semanticCache: cache).complete(LLMRequest(prompt: "q"))
        #expect(await counter.value == 2)
    }

    @Test("complete with an image does not answer from the text cache")
    func completeWithImageSkipsTextCache() async throws {
        let counter = Counter()
        let cascade = TieredCascade(tiers: [CascadeTier(provider: CountingProvider(identifier: "a", counter: counter))])
        let cache = SemanticCache(embeddingProvider: FixedEmbeddingProvider(), similarityThreshold: 0.5)
        let gateway = LLMGateway(cascade: cascade, budget: roomyBudget(), semanticCache: cache)

        _ = try await gateway.complete(LLMRequest(prompt: "what is this", image: Data([1])))
        _ = try await gateway.complete(LLMRequest(prompt: "what is this", image: Data([2])))
        #expect(await counter.value == 2)
    }
}
