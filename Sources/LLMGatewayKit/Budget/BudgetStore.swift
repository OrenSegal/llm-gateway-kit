import Foundation

/// Persistence seam for spend tracking. `UserDefaults` (the default) is
/// fine for a single-device client-side budget; swap in a server-backed
/// implementation if spend needs to be shared/authoritative across devices.
public protocol BudgetStore: Sendable {
    func spend(forKey key: String) async -> Double
    func addSpend(_ amount: Double, forKey key: String) async
}

/// Default `UserDefaults`-backed store. `UserDefaults` itself is thread-safe
/// for individual get/set calls; the read-modify-write in `addSpend` is
/// serialized by routing through this actor rather than an `NSLock` (which
/// Swift 6 strict concurrency disallows locking/unlocking across an
/// `await` boundary).
public actor UserDefaultsBudgetStore: BudgetStore {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func spend(forKey key: String) async -> Double {
        defaults.double(forKey: key)
    }

    public func addSpend(_ amount: Double, forKey key: String) async {
        let current = defaults.double(forKey: key)
        defaults.set(current + amount, forKey: key)
    }
}

/// In-memory store, useful for tests and previews.
public actor InMemoryBudgetStore: BudgetStore {
    private var totals: [String: Double] = [:]

    public init() {}

    public func spend(forKey key: String) async -> Double {
        totals[key] ?? 0
    }

    public func addSpend(_ amount: Double, forKey key: String) async {
        totals[key, default: 0] += amount
    }
}
