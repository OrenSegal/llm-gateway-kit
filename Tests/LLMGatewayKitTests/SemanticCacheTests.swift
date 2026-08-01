import Foundation
import Testing
@testable import LLMGatewayKit

private struct FakeEmbeddingProvider: EmbeddingProvider {
    let modelIdentifier = "fake-v1"
    let vectors: [String: [Float]]

    func embed(_ text: String) async -> [Float] {
        vectors[text] ?? []
    }
}

@Suite("SemanticCache")
struct SemanticCacheTests {
    @Test("stores and returns an exact-vector hit")
    func exactHit() async {
        let provider = FakeEmbeddingProvider(vectors: ["hello": [1, 0, 0]])
        let cache = SemanticCache(embeddingProvider: provider, similarityThreshold: 0.9)
        await cache.store(prompt: "hello", response: "world")
        let result = await cache.lookup(prompt: "hello")
        #expect(result == "world")
    }

    @Test("returns nil on a genuine miss below the similarity threshold")
    func miss() async {
        let provider = FakeEmbeddingProvider(vectors: [
            "hello": [1, 0, 0],
            "goodbye": [0, 1, 0],
        ])
        let cache = SemanticCache(embeddingProvider: provider, similarityThreshold: 0.9)
        await cache.store(prompt: "hello", response: "world")
        let result = await cache.lookup(prompt: "goodbye")
        #expect(result == nil)
    }

    @Test("hits on a near-duplicate vector above the similarity threshold")
    func paraphraseHit() async {
        let provider = FakeEmbeddingProvider(vectors: [
            "please reset my password": [1, 0.1, 0],
            "reset my password": [1, 0, 0],
        ])
        let cache = SemanticCache(embeddingProvider: provider, similarityThreshold: 0.9)
        await cache.store(prompt: "reset my password", response: "a password reset link was sent")
        let result = await cache.lookup(prompt: "please reset my password")
        #expect(result == "a password reset link was sent")
    }

    @Test("evictExpired removes entries older than the TTL")
    func evictsExpired() async {
        let provider = FakeEmbeddingProvider(vectors: ["hello": [1, 0, 0]])
        let cache = SemanticCache(embeddingProvider: provider, ttl: -1, similarityThreshold: 0.9)
        await cache.store(prompt: "hello", response: "world")
        #expect(await cache.count == 1)
        await cache.evictExpired()
        #expect(await cache.count == 0)
    }

    @Test("an empty embedding never produces a stored entry")
    func emptyEmbeddingSkipsStore() async {
        let provider = FakeEmbeddingProvider(vectors: [:])
        let cache = SemanticCache(embeddingProvider: provider)
        await cache.store(prompt: "unembeddable", response: "should not store")
        #expect(await cache.count == 0)
    }
}
