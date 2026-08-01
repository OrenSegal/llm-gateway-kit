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
    @Test("hits on an identical hash")
    func exactHit() async {
        let imageA = Data([1, 2, 3])
        let hasher = FakeHasher(hashes: [imageA: "ffffffffffffffff"])
        let cache = VisionCache(hasher: hasher, maxHammingDistance: 0)
        await cache.store(image: imageA, response: "a can of beans", taskType: "scan")
        let result = await cache.lookup(image: imageA, taskType: "scan")
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
        await cache.store(image: imageA, response: "same scene, recompressed", taskType: "scan")
        let result = await cache.lookup(image: imageB, taskType: "scan")
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
        await cache.store(image: imageA, response: "unrelated", taskType: "scan")
        let result = await cache.lookup(image: imageB, taskType: "scan")
        #expect(result == nil)
    }

    @Test("task type partitions the cache")
    func taskTypePartitions() async {
        let imageA = Data([1])
        let hasher = FakeHasher(hashes: [imageA: "ffffffffffffffff"])
        let cache = VisionCache(hasher: hasher, maxHammingDistance: 10)
        await cache.store(image: imageA, response: "scan result", taskType: "scan")
        let result = await cache.lookup(image: imageA, taskType: "ocr")
        #expect(result == nil)
    }

    @Test("hammingDistance treats unequal-length hashes as maximally distant")
    func unequalLengthIsMaxDistance() {
        #expect(VisionCache.hammingDistance("ff", "ffff") == Int.max)
    }
}
