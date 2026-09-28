import Foundation

/// The seam a buyer implements to produce a perceptual hash for an image.
/// Any perceptual-hash algorithm works (aHash/dHash/pHash) as long as it
/// returns a fixed-length hex string where Hamming distance between two
/// hashes approximates visual similarity. A cryptographic hash (SHA256, MD5)
/// does NOT work here — it only matches byte-identical images, which defeats
/// the point (re-compressed or resized copies of the same photo would miss).
public protocol PerceptualHasher: Sendable {
    func hash(_ image: Data) async -> String
}

/// Perceptual-hash response cache for vision/image LLM calls.
///
/// Most "AI starter kit" caching only covers text chat. Vision calls
/// (photo analysis, OCR, object detection) are a distinct and often
/// larger cost center, and a text-embedding cache cannot help there —
/// there is no text prompt to embed. `VisionCache` keys instead on a
/// perceptual hash of the image, so two photos of the same physical scene
/// (retaken, re-cropped, recompressed) can still hit the cache even though
/// their bytes differ, using Hamming distance between hashes as the
/// similarity metric instead of cosine similarity.
public actor VisionCache {
    private struct CacheEntry {
        let hash: String
        let response: String
        let taskType: String
        let storedAt: Date
        var hitCount: Int
    }

    private let hasher: PerceptualHasher
    private let ttl: TimeInterval
    private let maxHammingDistance: Int
    private var cache: [CacheEntry] = []

    /// - Parameters:
    ///   - hasher: Buyer-supplied perceptual hash implementation.
    ///   - ttl: How long a stored response stays eligible for a hit. Defaults to 24h.
    ///   - maxHammingDistance: Maximum bit difference between hashes to count as
    ///     a match. Default 10 mirrors the threshold used in the app this was extracted from for
    ///     64-bit perceptual hashes — tune tighter for hash algorithms with
    ///     more bits, or for tasks where a near-miss is unacceptable.
    public init(
        hasher: PerceptualHasher,
        ttl: TimeInterval = 86_400,
        maxHammingDistance: Int = 10
    ) {
        self.hasher = hasher
        self.ttl = ttl
        self.maxHammingDistance = maxHammingDistance
    }

    public func lookup(image: Data, taskType: String) async -> String? {
        let queryHash = await hasher.hash(image)
        guard let index = cache.firstIndex(where: {
            $0.taskType == taskType && Self.hammingDistance($0.hash, queryHash) <= maxHammingDistance
        }) else {
            return nil
        }
        cache[index].hitCount += 1
        return cache[index].response
    }

    public func store(image: Data, response: String, taskType: String) async {
        let hash = await hasher.hash(image)
        cache.append(CacheEntry(hash: hash, response: response, taskType: taskType, storedAt: Date(), hitCount: 0))
    }

    public func evictExpired() async {
        let cutoff = Date().addingTimeInterval(-ttl)
        cache = cache.filter { $0.storedAt > cutoff }
    }

    public func removeAll() {
        cache.removeAll()
    }

    public var count: Int { cache.count }

    /// Hex-string Hamming distance. Hashes of unequal length (e.g. two
    /// different hasher configurations) are treated as maximally distant
    /// rather than crashing.
    static func hammingDistance(_ a: String, _ b: String) -> Int {
        guard a.count == b.count else { return .max }
        var distance = 0
        for (charA, charB) in zip(a, b) where charA != charB {
            guard let valueA = charA.hexDigitValue, let valueB = charB.hexDigitValue else {
                distance += 4
                continue
            }
            distance += (valueA ^ valueB).nonzeroBitCount
        }
        return distance
    }
}
