import Foundation

/// Persistence seam for spend tracking. `UserDefaults` (the default) is
/// fine for a single-device client-side budget; swap in a server-backed
/// implementation if spend needs to be shared/authoritative across devices.
///
/// A store keeps two things per key: settled spend, and holds (reservations)
/// that have not been committed or released yet.
public protocol BudgetStore: Sendable {
    /// Settled spend for `key`. Does not include live holds.
    func spend(forKey key: String) async -> Double
    /// Adds settled spend with no reservation. Used by the deprecated
    /// `BudgetEnforcer.record` path.
    func addSpend(_ amount: Double, forKey key: String) async

    /// Places a hold of `amount` on `key` if settled spend plus live holds
    /// plus `amount` stays within `capUSD`, and returns the hold's id; returns
    /// nil otherwise. The check and the hold must happen as one step, with no
    /// suspension point between them, or concurrent callers can both pass the
    /// check and the cap stops being hard. A hold stops counting against the
    /// cap at `expiresAt`.
    func reserve(_ amount: Double, forKey key: String, capUSD: Double, now: Date, expiresAt: Date) async -> UUID?
    /// Removes the hold and adds `actualCost` to settled spend for the hold's
    /// key, even if the hold has expired. A no-op if the hold was already
    /// committed or released.
    func commit(_ id: UUID, actualCost: Double) async
    /// Removes the hold without recording spend. A no-op if the hold was
    /// already committed or released.
    func release(_ id: UUID) async
    /// Sum of unexpired holds on `key`.
    func heldSpend(forKey key: String, now: Date) async -> Double
}

/// Hold bookkeeping shared by the built-in stores. Not thread-safe on its
/// own; each store keeps one inside its actor.
struct HoldLedger: Sendable {
    private struct Hold: Sendable {
        let key: String
        let amount: Double
        let expiresAt: Date
    }

    /// shortcut: an expired hold is kept for a day so a late commit still
    /// records its spend; a commit later than that is dropped. Persist holds
    /// in your own store if calls can settle more than a day late.
    static let lateCommitWindow: TimeInterval = 86_400

    private var holds: [UUID: Hold] = [:]

    func held(forKey key: String, now: Date) -> Double {
        holds.values.reduce(0) { $1.key == key && $1.expiresAt > now ? $0 + $1.amount : $0 }
    }

    mutating func reserve(_ amount: Double, forKey key: String, settled: Double, capUSD: Double, now: Date, expiresAt: Date) -> UUID? {
        holds = holds.filter { $0.value.expiresAt.addingTimeInterval(Self.lateCommitWindow) > now }
        guard amount >= 0, settled + held(forKey: key, now: now) + amount <= capUSD else { return nil }
        let id = UUID()
        holds[id] = Hold(key: key, amount: amount, expiresAt: expiresAt)
        return id
    }

    /// Removes the hold and returns its key, or nil if it was already settled.
    mutating func settle(_ id: UUID) -> String? {
        holds.removeValue(forKey: id)?.key
    }
}

/// Default `UserDefaults`-backed store. `UserDefaults` itself is thread-safe
/// for individual get/set calls; the read-modify-write in `addSpend` is
/// serialized by routing through this actor rather than an `NSLock` (which
/// Swift 6 strict concurrency disallows locking/unlocking across an
/// `await` boundary).
///
/// Settled spend is persisted; holds live in memory only. If the app quits
/// mid-call, the hold disappears and the spend is never recorded. Two store
/// instances (or processes) sharing one `UserDefaults` suite do not see each
/// other's holds, so the cap is only hard within one instance.
public actor UserDefaultsBudgetStore: BudgetStore {
    private let defaults: UserDefaults
    private var ledger = HoldLedger()

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

    public func reserve(_ amount: Double, forKey key: String, capUSD: Double, now: Date, expiresAt: Date) async -> UUID? {
        ledger.reserve(amount, forKey: key, settled: defaults.double(forKey: key), capUSD: capUSD, now: now, expiresAt: expiresAt)
    }

    public func commit(_ id: UUID, actualCost: Double) async {
        guard let key = ledger.settle(id) else { return }
        defaults.set(defaults.double(forKey: key) + actualCost, forKey: key)
    }

    public func release(_ id: UUID) async {
        _ = ledger.settle(id)
    }

    public func heldSpend(forKey key: String, now: Date) async -> Double {
        ledger.held(forKey: key, now: now)
    }
}

/// In-memory store, useful for tests and previews.
public actor InMemoryBudgetStore: BudgetStore {
    private var totals: [String: Double] = [:]
    private var ledger = HoldLedger()

    public init() {}

    public func spend(forKey key: String) async -> Double {
        totals[key] ?? 0
    }

    public func addSpend(_ amount: Double, forKey key: String) async {
        totals[key, default: 0] += amount
    }

    public func reserve(_ amount: Double, forKey key: String, capUSD: Double, now: Date, expiresAt: Date) async -> UUID? {
        ledger.reserve(amount, forKey: key, settled: totals[key] ?? 0, capUSD: capUSD, now: now, expiresAt: expiresAt)
    }

    public func commit(_ id: UUID, actualCost: Double) async {
        guard let key = ledger.settle(id) else { return }
        totals[key, default: 0] += actualCost
    }

    public func release(_ id: UUID) async {
        _ = ledger.settle(id)
    }

    public func heldSpend(forKey key: String, now: Date) async -> Double {
        ledger.held(forKey: key, now: now)
    }
}
