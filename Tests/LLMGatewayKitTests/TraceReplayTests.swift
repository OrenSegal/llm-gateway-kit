import Foundation
import Testing
@testable import LLMGatewayKit

// Replays a fixed, scripted request trace through one LLMGateway with mock
// providers, and pins the counts the README "Results" section reports.
// Synthetic traffic and made-up prices: this shows what each mechanism does,
// not how much it saves on real traffic.

private actor CallLog {
    private(set) var calls = 0
    private(set) var down = false
    func record() { calls += 1 }
    func setDown(_ value: Bool) { down = value }
}

private struct ScriptedProvider: LLMProvider {
    let identifier: String
    let pricePerCallUSD: Double
    let log: CallLog

    func estimatedCostUSD(inputTokens: Int, outputTokens: Int) -> Double { pricePerCallUSD }

    func send(_ request: LLMRequest) async throws -> LLMResponse {
        await log.record()
        if await log.down { throw URLError(.badServerResponse) }
        return LLMResponse(text: "\(identifier): \(request.prompt)", usage: LLMUsage(inputTokens: 10, outputTokens: 10), modelID: identifier)
    }
}

/// One-hot vector over a fixed vocabulary: prompts that share their vocabulary
/// word count as paraphrases (similarity 1), all others as unrelated (0).
private struct TopicEmbedding: EmbeddingProvider {
    let modelIdentifier = "topic-v1"
    static let vocabulary = [
        "expiring", "dinner", "groceries", "milk",
        "soup", "salad", "pasta", "tacos", "curry", "stew", "pizza",
        "eggs", "rice", "beans", "bread", "cheese",
    ]

    func embed(_ text: String) async -> [Float] {
        let words = Set(text.lowercased().split(separator: " ").map(String.init))
        return Self.vocabulary.map { words.contains($0) ? 1 : 0 }
    }
}

@Suite("Trace replay")
struct TraceReplayTests {
    @Test("a scripted 22-request trace: cache hits, budget denials, breaker failover")
    func replay() async throws {
        let primaryLog = CallLog()
        let backupLog = CallLog()
        let primary = ScriptedProvider(identifier: "cheap", pricePerCallUSD: 0.01, log: primaryLog)
        let backup = ScriptedProvider(identifier: "strong", pricePerCallUSD: 0.05, log: backupLog)
        let primaryBreaker = CircuitBreaker(failureThreshold: 5, recoveryInterval: 3_600)
        let cascade = TieredCascade(tiers: [
            CascadeTier(provider: primary, breaker: primaryBreaker),
            CascadeTier(provider: backup),
        ])
        let budget = BudgetEnforcer(identifiedDailyCapUSD: 5.0, anonymousDailyCapUSD: 0.035, store: InMemoryBudgetStore())
        let gateway = LLMGateway(
            cascade: cascade,
            budget: budget,
            semanticCache: SemanticCache(embeddingProvider: TopicEmbedding(), similarityThreshold: 0.92)
        )

        // Phase 1, cache: 4 new questions, then 6 rewordings of them.
        let phase1 = [
            "what is expiring this week", "what can I cook for dinner", "make a groceries list", "do I have milk",
            "show me what is expiring", "anything expiring soon", "dinner ideas tonight",
            "update my groceries please", "is there milk left", "quick dinner please",
        ]
        for prompt in phase1 {
            _ = try await gateway.complete(LLMRequest(prompt: prompt))
        }
        let phase1Log = await gateway.auditLog.drainPending()
        #expect(phase1Log.filter { $0.source == .provider }.count == 4)
        #expect(phase1Log.filter { $0.source == .semanticCache }.count == 6)
        #expect(await primaryLog.calls == 4)

        // Phase 2, budget: 5 new anonymous questions against a $0.035/day anonymous cap.
        var anonymousServed = 0
        var anonymousDenied = 0
        for prompt in ["eggs recipe", "rice recipe", "beans recipe", "bread recipe", "cheese recipe"] {
            do {
                _ = try await gateway.complete(LLMRequest(prompt: prompt), isAnonymous: true)
                anonymousServed += 1
            } catch LLMGatewayError.gateDenied(let reason) {
                #expect(reason == "dailyBudgetExceeded")
                anonymousDenied += 1
            }
        }
        #expect(anonymousServed == 3)
        #expect(anonymousDenied == 2)
        #expect(await primaryLog.calls == 7) // denied calls never reached a provider

        // Phase 3, outage: the cheap provider goes down; 7 new identified questions.
        await primaryLog.setDown(true)
        var servedBy: [String] = []
        for prompt in ["soup tonight", "salad tonight", "pasta tonight", "tacos tonight", "curry tonight", "stew tonight", "pizza tonight"] {
            servedBy.append(try await gateway.complete(LLMRequest(prompt: prompt)).modelID)
        }
        #expect(servedBy == Array(repeating: "strong", count: 7))
        #expect(await primaryLog.calls == 7 + 5) // 5 failed attempts, then the breaker stops trying
        #expect(await primaryBreaker.state == .open)
        #expect(await backupLog.calls == 7)

        // Spend: 4 + 3 cheap calls at $0.01, 7 backup calls at $0.05.
        #expect(abs(await budget.dailyUsageUSD(isAnonymous: false) - 0.39) < 1e-9)
        #expect(abs(await budget.dailyUsageUSD(isAnonymous: true) - 0.03) < 1e-9)
    }
}
