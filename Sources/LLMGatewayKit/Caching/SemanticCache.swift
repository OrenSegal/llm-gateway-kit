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
/// Thread-safe via `actor` isolation — safe to share one instance across
/// concurrent requests.
public actor SemanticCache {
    private struct CacheEntry {
        let embedding: [Float]
        let embeddingModel: String
        let response: String
        let storedAt: Date
    }

    private let embeddingProvider: EmbeddingProvider
    private let ttl: TimeInterval
    private let similarityThreshold: Double
    private var cache: [String: CacheEntry] = [:]

    /// - Parameters:
    ///   - embeddingProvider: Buyer-supplied embedding backend.
    ///   - ttl: How long a stored response stays eligible for a hit. Defaults to 24h.
    ///   - similarityThreshold: Cosine similarity required for a hit. Default 0.92
    ///     is tuned to allow paraphrase hits while blocking unrelated prompts;
    ///     raise it toward 0.97+ for tasks where a near-miss is unacceptable
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
    public func lookup(prompt: String) async -> String? {
        let queryEmbedding = await embeddingProvider.embed(prompt)
        guard !queryEmbedding.isEmpty else { return nil }

        var best: (key: String, similarity: Double)?
        for (key, entry) in cache {
            guard entry.embeddingModel == embeddingProvider.modelIdentifier else { continue }
            let sim = Self.cosineSimilarity(queryEmbedding, entry.embedding)
            if sim >= similarityThreshold, best == nil || sim > best!.similarity {
                best = (key, sim)
            }
        }
        guard let best else { return nil }
        return cache[best.key]?.response
    }

    public func store(prompt: String, response: String) async {
        let embedding = await embeddingProvider.embed(prompt)
        guard !embedding.isEmpty else { return }
        cache[prompt] = CacheEntry(
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
