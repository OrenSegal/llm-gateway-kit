import Foundation

/// Persistence seam for spend tracking. `UserDefaults` (the default) is
/// fine for a single-device client-side budget; swap in a server-backed
/// implementation if spend needs to be shared/authoritative across devices.
///
/// Amounts are whole micro-dollars (1 USD = 1,000,000), so sums and cap
/// comparisons are exact: three $0.10 calls are exactly a $0.30 cap.
public protocol BudgetStore: Sendable {
    func spend(forKey key: String) async -> Int64
    func addSpend(_ amount: Int64, forKey key: String) async

    /// Holds `amount` if spend plus existing holds plus `amount` stays within
    /// `cap`, and returns whether it did. The check and the hold must be one
    /// atomic step (an actor method with no `await` inside, or a single database
    /// transaction): this is what stops concurrent calls overshooting a cap.
    /// Holds are not spend, so they don't appear in `spend(forKey:)`.
    func reserve(_ amount: Int64, cap: Int64, forKey key: String) async -> Bool

    /// Gives back a hold taken with `reserve`.
    func release(_ amount: Int64, forKey key: String) async
}

/// Default `UserDefaults`-backed store. `UserDefaults` itself is thread-safe
/// for individual get/set calls; the read-modify-write in `addSpend` is
/// serialized by routing through this actor rather than an `NSLock` (which
/// Swift 6 strict concurrency disallows locking/unlocking across an
/// `await` boundary). Holds stay in memory, so a process killed mid-call
/// doesn't leave its estimate counted against the cap.
public actor UserDefaultsBudgetStore: BudgetStore {
    /// The store `BudgetEnforcer` uses by default. Holds live in the actor and
    /// `addSpend` is a read-modify-write, so two stores on the same
    /// `UserDefaults` domain admit twice the cap and lose updates; share this one.
    public static let shared = UserDefaultsBudgetStore()

    private let defaults: UserDefaults
    private var holds: [String: Int64] = [:]

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func spend(forKey key: String) async -> Int64 {
        Int64(defaults.integer(forKey: key))
    }

    public func addSpend(_ amount: Int64, forKey key: String) async {
        defaults.set(defaults.integer(forKey: key) + Int(amount), forKey: key)
    }

    public func reserve(_ amount: Int64, cap: Int64, forKey key: String) async -> Bool {
        guard Int64(defaults.integer(forKey: key)) + holds[key, default: 0] + amount <= cap else { return false }
        holds[key, default: 0] += amount
        return true
    }

    public func release(_ amount: Int64, forKey key: String) async {
        holds[key] = max(0, holds[key, default: 0] - amount)
    }
}

/// In-memory store, useful for tests and previews.
public actor InMemoryBudgetStore: BudgetStore {
    private var totals: [String: Int64] = [:]
    private var holds: [String: Int64] = [:]

    public init() {}

    public func spend(forKey key: String) async -> Int64 {
        totals[key] ?? 0
    }

    public func addSpend(_ amount: Int64, forKey key: String) async {
        totals[key, default: 0] += amount
    }

    public func reserve(_ amount: Int64, cap: Int64, forKey key: String) async -> Bool {
        guard totals[key, default: 0] + holds[key, default: 0] + amount <= cap else { return false }
        holds[key, default: 0] += amount
        return true
    }

    public func release(_ amount: Int64, forKey key: String) async {
        holds[key] = max(0, holds[key, default: 0] - amount)
    }
}
