import Foundation
import Testing
@testable import LLMGatewayKit

private struct FakeHasher: PerceptualHasher {
    let hashes: [Data: String]

    func hash(_ image: Data) async -> String {
        hashes[image] ?? "0000000000000000"
    }
}

@Suite("VisionCache")
struct VisionCacheTests {
    @Test("an empty hash is a miss and is not stored")
    func emptyHashNeverMatches() async {
        let failed = Data([1])
        let alsoFailed = Data([2])
        let cache = VisionCache(hasher: FakeHasher(hashes: [failed: "", alsoFailed: ""]))
        await cache.store(image: failed, prompt: "q", response: "a carton of eggs", taskType: "scan")
        #expect(await cache.count == 0)
        #expect(await cache.lookup(image: alsoFailed, prompt: "q", taskType: "scan") == nil)
    }

    @Test("the closest stored image answers, not the first one within tolerance")
    func closestMatchWins() async {
        let near = Data([1])
        let exact = Data([2])
        // "ffffffffffffff00" is 8 bits from "ffffffffffffffff": inside the default tolerance of 10.
        let hasher = FakeHasher(hashes: [near: "ffffffffffffff00", exact: "ffffffffffffffff"])
        let cache = VisionCache(hasher: hasher)
        await cache.store(image: near, prompt: "q", response: "a similar-looking jar", taskType: "scan")
        await cache.store(image: exact, prompt: "q", response: "this exact jar", taskType: "scan")
        #expect(await cache.lookup(image: exact, prompt: "q", taskType: "scan") == "this exact jar")
    }

    @Test("of two answers stored for the same image, the newer one is served")
    func newerAnswerWins() async {
        let image = Data([1])
        let cache = VisionCache(hasher: FakeHasher(hashes: [image: "ffffffffffffffff"]))
        await cache.store(image: image, prompt: "q", response: "old answer", taskType: "scan")
        await cache.store(image: image, prompt: "q", response: "new answer", taskType: "scan")
        #expect(await cache.lookup(image: image, prompt: "q", taskType: "scan") == "new answer")
    }

    @Test("hits on an identical hash")
    func exactHit() async {
        let imageA = Data([1, 2, 3])
        let hasher = FakeHasher(hashes: [imageA: "ffffffffffffffff"])
        let cache = VisionCache(hasher: hasher, maxHammingDistance: 0)
        await cache.store(image: imageA, prompt: "q", response: "a can of beans", taskType: "scan")
        let result = await cache.lookup(image: imageA, prompt: "q", taskType: "scan")
        #expect(result == "a can of beans")
    }

    @Test("hits within the Hamming distance tolerance")
    func closeHashHit() async {
        let imageA = Data([1])
        let imageB = Data([2])
        // "fffffffffffffff0" differs from "ffffffffffffffff" by 4 bits (one hex digit: f vs 0).
        let hasher = FakeHasher(hashes: [
            imageA: "ffffffffffffffff",
            imageB: "fffffffffffffff0",
        ])
        let cache = VisionCache(hasher: hasher, maxHammingDistance: 10)
        await cache.store(image: imageA, prompt: "q", response: "same scene, recompressed", taskType: "scan")
        let result = await cache.lookup(image: imageB, prompt: "q", taskType: "scan")
        #expect(result == "same scene, recompressed")
    }

    @Test("misses when Hamming distance exceeds tolerance")
    func tooFarMisses() async {
        let imageA = Data([1])
        let imageB = Data([2])
        let hasher = FakeHasher(hashes: [
            imageA: "ffffffffffffffff",
            imageB: "0000000000000000",
        ])
        let cache = VisionCache(hasher: hasher, maxHammingDistance: 10)
        await cache.store(image: imageA, prompt: "q", response: "unrelated", taskType: "scan")
        let result = await cache.lookup(image: imageB, prompt: "q", taskType: "scan")
        #expect(result == nil)
    }

    @Test("the prompt partitions the cache")
    func promptPartitions() async {
        let imageA = Data([1])
        let hasher = FakeHasher(hashes: [imageA: "ffffffffffffffff"])
        let cache = VisionCache(hasher: hasher, maxHammingDistance: 10)
        await cache.store(image: imageA, prompt: "count the eggs", response: "12", taskType: "scan")
        #expect(await cache.lookup(image: imageA, prompt: "list allergens", taskType: "scan") == nil)
        #expect(await cache.lookup(image: imageA, prompt: "count the eggs", taskType: "scan") == "12")
    }

    @Test("task type partitions the cache")
    func taskTypePartitions() async {
        let imageA = Data([1])
        let hasher = FakeHasher(hashes: [imageA: "ffffffffffffffff"])
        let cache = VisionCache(hasher: hasher, maxHammingDistance: 10)
        await cache.store(image: imageA, prompt: "q", response: "scan result", taskType: "scan")
        let result = await cache.lookup(image: imageA, prompt: "q", taskType: "ocr")
        #expect(result == nil)
    }

    @Test("lookup treats an entry older than the TTL as a miss")
    func expiredEntryIsMiss() async {
        let imageA = Data([1])
        let hasher = FakeHasher(hashes: [imageA: "ffffffffffffffff"])
        let cache = VisionCache(hasher: hasher, ttl: -1, maxHammingDistance: 0)
        await cache.store(image: imageA, prompt: "q", response: "stale", taskType: "scan")
        #expect(await cache.lookup(image: imageA, prompt: "q", taskType: "scan") == nil)
    }

    @Test("hammingDistance treats unequal-length hashes as maximally distant")
    func unequalLengthIsMaxDistance() {
        #expect(VisionCache.hammingDistance("ff", "ffff") == Int.max)
    }
}
