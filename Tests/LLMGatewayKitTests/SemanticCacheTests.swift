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

/// An embedding backend whose model can be swapped, as happens when an app
/// ships a new embedding model while old entries are still cached.
private final class SwappableEmbeddingProvider: EmbeddingProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var model = "model-a"

    var modelIdentifier: String {
        lock.lock(); defer { lock.unlock() }
        return model
    }

    func switchModel(to newModel: String) {
        lock.lock(); defer { lock.unlock() }
        model = newModel
    }

    func embed(_ text: String) async -> [Float] { [1, 0, 0] }
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

    @Test("a similarity equal to the threshold is a hit")
    func similarityAtTheThresholdHits() async {
        let provider = FakeEmbeddingProvider(vectors: ["hello": [1, 0, 0], "hello again": [1, 0, 0]])
        let cache = SemanticCache(embeddingProvider: provider, similarityThreshold: 1.0)
        await cache.store(prompt: "hello", response: "world")
        #expect(await cache.lookup(prompt: "hello again") == "world")
    }

    @Test("an entry stored under another embedding model is never compared")
    func otherEmbeddingModelIsAMiss() async {
        let provider = SwappableEmbeddingProvider()
        let cache = SemanticCache(embeddingProvider: provider, similarityThreshold: 0.9)
        await cache.store(prompt: "hello", response: "world")
        #expect(await cache.lookup(prompt: "hello") == "world")

        provider.switchModel(to: "model-b")
        #expect(await cache.lookup(prompt: "hello") == nil)
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

    @Test("the same prompt in two scopes keeps two entries that never cross")
    func scopesAreSeparate() async {
        let provider = FakeEmbeddingProvider(vectors: ["hello": [1, 0, 0]])
        let cache = SemanticCache(embeddingProvider: provider, similarityThreshold: 0.9)
        await cache.store(prompt: "hello", response: "from a", scope: "a")
        await cache.store(prompt: "hello", response: "from b", scope: "b")
        #expect(await cache.count == 2)
        #expect(await cache.lookup(prompt: "hello", scope: "a") == "from a")
        #expect(await cache.lookup(prompt: "hello", scope: "b") == "from b")
        #expect(await cache.lookup(prompt: "hello") == nil)
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

    @Test("lookup treats an entry older than the TTL as a miss")
    func expiredEntryIsMiss() async {
        let provider = FakeEmbeddingProvider(vectors: ["hello": [1, 0, 0]])
        let cache = SemanticCache(embeddingProvider: provider, ttl: -1, similarityThreshold: 0.9)
        await cache.store(prompt: "hello", response: "world")
        #expect(await cache.lookup(prompt: "hello") == nil)
    }

    @Test("an empty embedding never produces a stored entry")
    func emptyEmbeddingSkipsStore() async {
        let provider = FakeEmbeddingProvider(vectors: [:])
        let cache = SemanticCache(embeddingProvider: provider)
        await cache.store(prompt: "unembeddable", response: "should not store")
        #expect(await cache.count == 0)
    }
}
