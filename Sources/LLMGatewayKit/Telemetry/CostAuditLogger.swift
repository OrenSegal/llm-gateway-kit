import Foundation

/// Where a served response came from — useful for measuring how much of
/// your traffic is actually being deflected by caching vs. hitting a paid
/// provider, which is the number that proves out the cost-reduction claim.
public enum LLMResponseSource: String, Sendable, Codable, Equatable {
    case semanticCache
    case visionCache
    case provider
}

/// Lightweight in-memory spend ledger. Fire-and-forget: logging a call never
/// blocks or fails the request path. Drain periodically (e.g. on a timer, or
/// on app background) and ship entries wherever you want durable analytics —
/// this type deliberately doesn't own any network/storage backend so it has
/// zero dependencies.
public actor CostAuditLogger {
    public struct Entry: Sendable, Codable, Equatable {
        public let id: String
        public let source: LLMResponseSource
        public let costUSD: Double
        public let timestamp: Date

        public init(id: String = UUID().uuidString, source: LLMResponseSource, costUSD: Double, timestamp: Date = Date()) {
            self.id = id
            self.source = source
            self.costUSD = costUSD
            self.timestamp = timestamp
        }
    }

    private var pending: [Entry] = []
    private let maxEntries: Int

    public init(maxEntries: Int = 500) {
        self.maxEntries = maxEntries
    }

    public func log(source: LLMResponseSource, costUSD: Double) {
        pending.append(Entry(source: source, costUSD: costUSD))
        if pending.count > maxEntries {
            pending.removeFirst()
        }
    }

    /// Drains and returns all pending entries, clearing the buffer.
    public func drainPending() -> [Entry] {
        let entries = pending
        pending = []
        return entries
    }

    /// Convenience rollup: fraction of served entries that came from a cache
    /// rather than a paid provider call, since the buffer was last drained.
    public func cacheHitRate() -> Double {
        guard !pending.isEmpty else { return 0 }
        let hits = pending.filter { $0.source != .provider }.count
        return Double(hits) / Double(pending.count)
    }
}
