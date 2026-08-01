import Foundation
import LLMGatewayKit

// ─── LLMGatewayKit quickstart demo ───────────────────────────────────────
// A minimal, runnable example showing the three pillars wired together:
// semantic caching, a tiered circuit-broken provider cascade, and hard
// budget enforcement. Everything here is a mock/in-memory stand-in for a
// real vendor SDK — swap `MockLLMProvider` for a thin adapter around
// OpenAI/Anthropic/Gemini/your-own-model and the rest of the gateway is
// unchanged.
// ──────────────────────────────────────────────────────────────────────────

/// Toy provider: buyers replace this with a real adapter (a struct/actor
/// that calls their vendor's SDK/REST API and maps the response onto
/// `LLMResponse`). Everything else in the package only ever talks to the
/// `LLMProvider` protocol, never to this type.
struct MockLLMProvider: LLMProvider {
    let identifier: String
    let costPerInputTokenUSD: Double
    let costPerOutputTokenUSD: Double
    let shouldFail: Bool

    func estimatedCostUSD(inputTokens: Int, outputTokens: Int) -> Double {
        Double(inputTokens) * costPerInputTokenUSD + Double(outputTokens) * costPerOutputTokenUSD
    }

    func send(_ request: LLMRequest) async throws -> LLMResponse {
        if shouldFail {
            throw URLError(.badServerResponse)
        }
        return LLMResponse(
            text: "[\(identifier)] response to: \(request.prompt.prefix(40))",
            usage: LLMUsage(inputTokens: request.prompt.count / 4, outputTokens: 64),
            confidence: 0.97,
            modelID: identifier
        )
    }
}

/// Toy embedding provider: a real one calls your embeddings API. This one
/// fakes a vector from word overlap so the demo can show a cache hit
/// without a network call.
struct MockEmbeddingProvider: EmbeddingProvider {
    let modelIdentifier = "mock-embedding-v1"

    func embed(_ text: String) async -> [Float] {
        let words = Set(text.lowercased().split(separator: " "))
        let vocabulary = ["reset", "password", "my", "account", "cannot", "login", "forgot", "help", "billing", "weather"]
        return vocabulary.map { words.contains(Substring($0)) ? 1.0 : 0.0 }
    }
}

@main
struct Demo {
    static func main() async {
        // 1. Wire a two-tier cascade: a cheap primary, a stronger fallback.
        let primary = MockLLMProvider(identifier: "cheap-fast-model", costPerInputTokenUSD: 0.0000003, costPerOutputTokenUSD: 0.0000006, shouldFail: false)
        let backup = MockLLMProvider(identifier: "strong-slow-model", costPerInputTokenUSD: 0.000003, costPerOutputTokenUSD: 0.000006, shouldFail: false)
        let cascade = TieredCascade(tiers: [
            CascadeTier(provider: primary, confidenceFloor: 0.8),
            CascadeTier(provider: backup),
        ])

        // 2. Hard budget cap — identified users get $5/day, anonymous get $0.50/day.
        let budget = BudgetEnforcer(
            identifiedDailyCapUSD: 5.0,
            anonymousDailyCapUSD: 0.50,
            store: InMemoryBudgetStore()
        )

        // 3. Semantic cache so paraphrases of the same question reuse a response.
        //    0.85 is close to the 0.92 default used against a real embedding
        //    model; this toy word-overlap embedder needs a slightly lower bar.
        let cache = SemanticCache(embeddingProvider: MockEmbeddingProvider(), similarityThreshold: 0.85)

        let gateway = LLMGateway(cascade: cascade, budget: budget, semanticCache: cache)

        print("First call (cache miss, hits the cheap-fast-model tier):")
        let first = try? await gateway.complete(LLMRequest(prompt: "reset my password"))
        print("  -> \(first?.text ?? "nil") (source model: \(first?.modelID ?? "?"))")

        print("\nSecond call, a paraphrase (cache hit, zero spend):")
        let second = try? await gateway.complete(LLMRequest(prompt: "please reset my password"))
        print("  -> \(second?.text ?? "nil") (source model: \(second?.modelID ?? "?"))")

        print("\nThird call, unrelated prompt (cache miss again):")
        let third = try? await gateway.complete(LLMRequest(prompt: "what's the weather today"))
        print("  -> \(third?.text ?? "nil") (source model: \(third?.modelID ?? "?"))")

        let entries = await gateway.auditLog.drainPending()
        let cacheHits = entries.filter { $0.source != .provider }.count
        print("\nAudit log: \(entries.count) calls, \(cacheHits) served from cache, \(entries.count - cacheHits) hit a paid provider.")
    }
}
