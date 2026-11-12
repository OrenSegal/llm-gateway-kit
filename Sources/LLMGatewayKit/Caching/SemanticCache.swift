import Foundation

/// Embedding-similarity response cache for text prompts.
///
/// A plain exact-match cache only helps when the same string is sent twice.
/// Many prompts are paraphrases of each other, like "what's expiring soon" vs
/// "what should I use up" — that an exact-match cache always misses.
/// `SemanticCache` embeds each prompt and looks up the nearest neighbor by
/// cosine similarity, so paraphrased-but-equivalent prompts hit the cache
/// too. How much this saves depends on how often your app's prompts repeat
/// in meaning even when the exact wording varies.
///
/// A `scope` separates requests whose answers differ even for the same prompt,
/// such as a different model or task. Entries only match within their scope.
/// `LLMGateway` sets it from the request and its cascade.
///
/// Thread-safe via `actor` isolation — safe to share one instance across
/// concurrent requests.
public actor SemanticCache {
    private struct CacheKey: Hashable {
        let scope: String
        let prompt: String
    }

    private struct CacheEntry {
        let embedding: [Float]
        let embeddingModel: String
        let response: String
        let storedAt: Date
    }

    private let embeddingProvider: EmbeddingProvider
    private let ttl: TimeInterval
    private let similarityThreshold: Double
    private var cache: [CacheKey: CacheEntry] = [:]

    /// - Parameters:
    ///   - embeddingProvider: The embedding backend you supply.
    ///   - ttl: How long a stored response stays eligible for a hit. Defaults to 24h.
    ///   - similarityThreshold: Cosine similarity required for a hit. Default 0.92
    ///     is a starting point with no tuning data behind it; measure it on
    ///     your own traffic, and raise it toward 0.97+ for tasks where a near-miss is unacceptable
    ///     (e.g. anything touching a monetary amount or a safety claim).
    public init(
        embeddingProvider: EmbeddingProvider,
        ttl: TimeInterval = 86_400,
        similarityThreshold: Double = 0.92
    ) {
        self.embeddingProvider = embeddingProvider
        self.ttl = ttl
        self.similarityThreshold = similarityThreshold
    }

    /// Returns a cached response for a semantically similar prior prompt, or
    /// `nil` on a miss. Never throws — an embedding failure degrades to a
    /// cache miss rather than failing the caller's request.
    public func lookup(prompt: String, scope: String = "") async -> String? {
        await lookupKeepingEmbedding(prompt: prompt, scope: scope).response
    }

    /// `lookup` that also hands back the prompt's embedding, so a caller that
    /// stores the answer after a miss doesn't pay to embed the prompt twice.
    func lookupKeepingEmbedding(prompt: String, scope: String) async -> (response: String?, embedding: [Float]) {
        let queryEmbedding = await embeddingProvider.embed(prompt)
        return (queryEmbedding.isEmpty ? nil : nearest(to: queryEmbedding, scope: scope), queryEmbedding)
    }

    private func nearest(to queryEmbedding: [Float], scope: String) -> String? {

        let cutoff = Date().addingTimeInterval(-ttl)
        var best: (key: CacheKey, similarity: Double)?
        for (key, entry) in cache {
            // Expired entries are misses even before evictExpired() sweeps them.
            guard key.scope == scope, entry.storedAt > cutoff, entry.embeddingModel == embeddingProvider.modelIdentifier else { continue }
            let sim = Self.cosineSimilarity(queryEmbedding, entry.embedding)
            if sim >= similarityThreshold, best == nil || sim > best!.similarity {
                best = (key, sim)
            }
        }
        guard let best else { return nil }
        return cache[best.key]?.response
    }

    public func store(prompt: String, response: String, scope: String = "") async {
        store(prompt: prompt, response: response, scope: scope, embedding: await embeddingProvider.embed(prompt))
    }

    func store(prompt: String, response: String, scope: String, embedding: [Float]) {
        guard !embedding.isEmpty else { return }
        cache[CacheKey(scope: scope, prompt: prompt)] = CacheEntry(
            embedding: embedding,
            embeddingModel: embeddingProvider.modelIdentifier,
            response: response,
            storedAt: Date()
        )
    }

    /// Sweeps entries older than `ttl`. Call periodically (e.g. on app
    /// foreground) — this is not done automatically so the cache stays a
    /// pure, testable actor with no background timers of its own.
    public func evictExpired() async {
        let cutoff = Date().addingTimeInterval(-ttl)
        cache = cache.filter { $0.value.storedAt > cutoff }
    }

    public func removeAll() {
        cache.removeAll()
    }

    public var count: Int { cache.count }

    static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0.0 }
        let dot = zip(a, b).reduce(0.0) { $0 + Double($1.0 * $1.1) }
        let magA = sqrt(a.reduce(0.0) { $0 + Double($1 * $1) })
        let magB = sqrt(b.reduce(0.0) { $0 + Double($1 * $1) })
        guard magA > 0, magB > 0 else { return 0.0 }
        return dot / (magA * magB)
    }
}
