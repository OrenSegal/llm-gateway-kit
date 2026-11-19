import Foundation
import Testing
@testable import LLMGatewayKit

@Suite("CostAuditLogger")
struct CostAuditLoggerTests {
    @Test("cacheHitRate is the share of entries served from a cache, and 0 when empty")
    func cacheHitRate() async {
        let logger = CostAuditLogger()
        #expect(await logger.cacheHitRate() == 0)

        await logger.log(source: .semanticCache, costUSD: 0)
        await logger.log(source: .provider, costUSD: 0.01)
        await logger.log(source: .provider, costUSD: 0.01)
        await logger.log(source: .provider, costUSD: 0.05)
        #expect(await logger.cacheHitRate() == 0.25)
    }

    @Test("the buffer keeps the newest maxEntries entries, and draining empties it")
    func bufferIsBoundedAndDrains() async {
        let logger = CostAuditLogger(maxEntries: 2)
        await logger.log(source: .provider, costUSD: 0.01)
        await logger.log(source: .provider, costUSD: 0.02)
        await logger.log(source: .visionCache, costUSD: 0)

        let entries = await logger.drainPending()
        #expect(entries.map(\.costUSD) == [0.02, 0])
        #expect(entries.map(\.source) == [.provider, .visionCache])
        #expect(await logger.drainPending().isEmpty)
    }
}
