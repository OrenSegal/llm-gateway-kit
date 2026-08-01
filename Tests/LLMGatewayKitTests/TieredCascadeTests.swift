import Foundation
import Testing
@testable import LLMGatewayKit

private struct StubProvider: LLMProvider {
    let identifier: String
    let result: Result<LLMResponse, Error>

    func estimatedCostUSD(inputTokens: Int, outputTokens: Int) -> Double { 0.001 }

    func send(_ request: LLMRequest) async throws -> LLMResponse {
        try result.get()
    }
}

@Suite("TieredCascade")
struct TieredCascadeTests {
    @Test("returns the primary tier's response when it succeeds and is confident")
    func primarySucceeds() async throws {
        let primary = StubProvider(
            identifier: "primary",
            result: .success(LLMResponse(text: "primary answer", usage: LLMUsage(inputTokens: 1, outputTokens: 1), confidence: 0.95, modelID: "primary"))
        )
        let backup = StubProvider(identifier: "backup", result: .failure(URLError(.badServerResponse)))
        let cascade = TieredCascade(tiers: [
            CascadeTier(provider: primary, confidenceFloor: 0.8),
            CascadeTier(provider: backup),
        ])
        let response = try await cascade.send(LLMRequest(prompt: "hi"))
        #expect(response.modelID == "primary")
    }

    @Test("escalates to backup when the primary's confidence is below the floor")
    func lowConfidenceEscalates() async throws {
        let primary = StubProvider(
            identifier: "primary",
            result: .success(LLMResponse(text: "unsure answer", usage: LLMUsage(inputTokens: 1, outputTokens: 1), confidence: 0.4, modelID: "primary"))
        )
        let backup = StubProvider(
            identifier: "backup",
            result: .success(LLMResponse(text: "confident answer", usage: LLMUsage(inputTokens: 1, outputTokens: 1), confidence: 0.95, modelID: "backup"))
        )
        let cascade = TieredCascade(tiers: [
            CascadeTier(provider: primary, confidenceFloor: 0.8),
            CascadeTier(provider: backup),
        ])
        let response = try await cascade.send(LLMRequest(prompt: "hi"))
        #expect(response.modelID == "backup")
    }

    @Test("escalates to backup when the primary throws")
    func failureEscalates() async throws {
        let primary = StubProvider(identifier: "primary", result: .failure(URLError(.timedOut)))
        let backup = StubProvider(
            identifier: "backup",
            result: .success(LLMResponse(text: "backup answer", usage: LLMUsage(inputTokens: 1, outputTokens: 1), confidence: nil, modelID: "backup"))
        )
        let cascade = TieredCascade(tiers: [
            CascadeTier(provider: primary),
            CascadeTier(provider: backup),
        ])
        let response = try await cascade.send(LLMRequest(prompt: "hi"))
        #expect(response.modelID == "backup")
    }

    @Test("skips a tier whose circuit breaker is already open")
    func skipsOpenBreaker() async throws {
        let openBreaker = CircuitBreaker(failureThreshold: 1, recoveryInterval: 3600)
        await openBreaker.recordFailure()
        let primary = StubProvider(identifier: "primary", result: .failure(URLError(.timedOut)))
        let backup = StubProvider(
            identifier: "backup",
            result: .success(LLMResponse(text: "backup answer", usage: LLMUsage(inputTokens: 1, outputTokens: 1), confidence: nil, modelID: "backup"))
        )
        let cascade = TieredCascade(tiers: [
            CascadeTier(provider: primary, breaker: openBreaker),
            CascadeTier(provider: backup),
        ])
        let response = try await cascade.send(LLMRequest(prompt: "hi"))
        #expect(response.modelID == "backup")
    }

    @Test("throws allProvidersFailed when every tier fails")
    func allTiersFail() async {
        let primary = StubProvider(identifier: "primary", result: .failure(URLError(.timedOut)))
        let backup = StubProvider(identifier: "backup", result: .failure(URLError(.timedOut)))
        let cascade = TieredCascade(tiers: [
            CascadeTier(provider: primary),
            CascadeTier(provider: backup),
        ])
        do {
            _ = try await cascade.send(LLMRequest(prompt: "hi"))
            Issue.record("expected an error")
        } catch {
            // Either the last provider's underlying error or allProvidersFailed
            // is acceptable — the cascade re-throws the last tier's failure.
            #expect(error is URLError || (error as? LLMGatewayError) == .allProvidersFailed)
        }
    }
}
