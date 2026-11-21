import Foundation

/// Budget held for one LLM call between `reserve` and `commit`/`release`.
public struct Reservation: Sendable, Hashable {
    public let id: UUID
    /// The store key the hold sits on. It includes the UTC day, so a call
    /// that spans midnight settles against the day it reserved on.
    public let key: String
    public let estimatedCostUSD: Double
    /// After this, the hold stops counting against the cap.
    public let expiresAt: Date
}

/// Daily USD spend cap on LLM calls, enforced *before* the call is made (not
/// just tracked after the fact). A runaway loop or an abusive user is refused
/// once the cap is reached, not merely logged.
///
/// Use it in three steps:
///   1. `reserve` the estimated cost. The store checks and holds in one
///      atomic step, so no reservation is granted that would take settled
///      spend plus outstanding holds over the cap, however many calls start
///      at once.
///   2. Make the call.
///   3. `commit` the actual cost, or `release` if the call failed.
///
/// Admission is a hard cap; settled spend is not. The estimate is a guess,
/// and `commit` records the full actual cost even when it is higher, because
/// that money is already spent and capping the record would hide it. So
/// settled spend can exceed the cap by the estimate error of calls already
/// admitted. Once it does, every further `reserve` fails.
///
/// A reservation that is never settled (a crash, a hung task) stops holding
/// budget after `reservationTTL`. A commit that arrives after expiry still
/// records its spend, and since that budget may already have gone to other
/// calls, a late commit can also take settled spend over the cap. Set the
/// TTL above your slowest call.
///
/// Supports a simple two-tier policy out of the box (identified vs
/// anonymous users get different caps, mirroring the common shape of "signed
/// in users get a bigger budget than anonymous/trial traffic") and a general
/// per-scope cap for anything else (per feature, per task type, per org).
public actor BudgetEnforcer {
    private let store: BudgetStore
    private let identifiedDailyCapUSD: Double
    private let anonymousDailyCapUSD: Double
    private let keyPrefix: String
    private let reservationTTL: TimeInterval
    private let now: @Sendable () -> Date

    /// - Parameters:
    ///   - identifiedDailyCapUSD: Daily cap for authenticated/identified callers.
    ///   - anonymousDailyCapUSD: Daily cap for anonymous callers. Typically much
    ///     smaller — this is what stops a single anonymous session from running
    ///     up unbounded spend before any auth/paywall gate would catch it.
    ///   - store: Where spend totals are persisted. Defaults to `UserDefaults`.
    ///   - keyPrefix: Namespace for stored keys, in case the host app uses
    ///     `UserDefaults` for other things too.
    ///   - reservationTTL: How long an unsettled reservation holds budget.
    ///     Set it above your slowest expected call, cascade fallbacks included.
    ///   - now: Clock, injectable for tests.
    public init(
        identifiedDailyCapUSD: Double,
        anonymousDailyCapUSD: Double,
        store: BudgetStore = UserDefaultsBudgetStore(),
        keyPrefix: String = "llmgatewaykit.budget.",
        reservationTTL: TimeInterval = 300,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.identifiedDailyCapUSD = identifiedDailyCapUSD
        self.anonymousDailyCapUSD = anonymousDailyCapUSD
        self.store = store
        self.keyPrefix = keyPrefix
        self.reservationTTL = reservationTTL
        self.now = now
    }

    // MARK: - Reserve, then commit or release

    /// Holds `estimatedCostUSD` against the caller's daily cap. Returns nil if
    /// the hold would take settled spend plus outstanding holds over the cap.
    public func reserve(estimatedCostUSD: Double, isAnonymous: Bool) async -> Reservation? {
        await reserve(estimatedCostUSD, key: todayKey(isAnonymous: isAnonymous), capUSD: cap(isAnonymous: isAnonymous))
    }

    /// Scoped sibling of `reserve(estimatedCostUSD:isAnonymous:)`, for a
    /// smaller sub-budget on one feature or task type.
    public func reserve(estimatedCostUSD: Double, scope: String, capUSD: Double) async -> Reservation? {
        await reserve(estimatedCostUSD, key: scopedKey(scope), capUSD: capUSD)
    }

    /// Settles the reservation at the real cost, which may be above or below
    /// the estimate. Commit or release each reservation once; a second
    /// settle is a no-op.
    public func commit(_ reservation: Reservation, actualCostUSD: Double) async {
        await store.commit(reservation.id, actualCost: actualCostUSD)
    }

    /// Returns the held budget, for a call that failed or was never sent.
    public func release(_ reservation: Reservation) async {
        await store.release(reservation.id)
    }

    // MARK: - Deprecated check-then-record

    /// Would spending `estimatedCostUSD` more today stay within the caller's
    /// cap, counting outstanding holds? Holds nothing, so concurrent callers
    /// can all pass.
    @available(*, deprecated, message: "canSpend then record can overshoot the cap under concurrency. Call reserve(estimatedCostUSD:isAnonymous:) before the request, then commit(_:actualCostUSD:) or release(_:) after it.")
    public func canSpend(estimatedCostUSD: Double, isAnonymous: Bool) async -> Bool {
        await fits(estimatedCostUSD, key: todayKey(isAnonymous: isAnonymous), capUSD: cap(isAnonymous: isAnonymous))
    }

    /// Records spend with no reservation.
    @available(*, deprecated, message: "Use commit(_:actualCostUSD:) on a reservation from reserve(estimatedCostUSD:isAnonymous:).")
    public func record(actualCostUSD: Double, isAnonymous: Bool) async {
        await store.addSpend(actualCostUSD, forKey: todayKey(isAnonymous: isAnonymous))
    }

    @available(*, deprecated, message: "canSpend then record can overshoot the cap under concurrency. Call reserve(estimatedCostUSD:scope:capUSD:) before the request, then commit(_:actualCostUSD:) or release(_:) after it.")
    public func canSpend(estimatedCostUSD: Double, scope: String, capUSD: Double) async -> Bool {
        await fits(estimatedCostUSD, key: scopedKey(scope), capUSD: capUSD)
    }

    @available(*, deprecated, message: "Use commit(_:actualCostUSD:) on a reservation from reserve(estimatedCostUSD:scope:capUSD:).")
    public func record(actualCostUSD: Double, scope: String) async {
        await store.addSpend(actualCostUSD, forKey: scopedKey(scope))
    }

    // MARK: - Reporting

    /// Settled spend today. Outstanding holds are not included.
    public func dailyUsageUSD(isAnonymous: Bool) async -> Double {
        await store.spend(forKey: todayKey(isAnonymous: isAnonymous))
    }

    /// Cap minus settled spend minus outstanding holds, floored at zero.
    public func remainingBudgetUSD(isAnonymous: Bool) async -> Double {
        let key = todayKey(isAnonymous: isAnonymous)
        let used = await store.spend(forKey: key) + (await store.heldSpend(forKey: key, now: now()))
        return max(0, cap(isAnonymous: isAnonymous) - used)
    }

    /// Non-reserving check used by `BudgetGate`.
    func fits(estimatedCostUSD: Double, isAnonymous: Bool) async -> Bool {
        await fits(estimatedCostUSD, key: todayKey(isAnonymous: isAnonymous), capUSD: cap(isAnonymous: isAnonymous))
    }

    private func fits(_ amount: Double, key: String, capUSD: Double) async -> Bool {
        let used = await store.spend(forKey: key) + (await store.heldSpend(forKey: key, now: now()))
        return used + amount <= capUSD
    }

    private func reserve(_ amount: Double, key: String, capUSD: Double) async -> Reservation? {
        let start = now()
        let expiresAt = start.addingTimeInterval(reservationTTL)
        guard let id = await store.reserve(amount, forKey: key, capUSD: capUSD, now: start, expiresAt: expiresAt) else {
            return nil
        }
        return Reservation(id: id, key: key, estimatedCostUSD: amount, expiresAt: expiresAt)
    }

    private func cap(isAnonymous: Bool) -> Double {
        isAnonymous ? anonymousDailyCapUSD : identifiedDailyCapUSD
    }

    private func todayKey(isAnonymous: Bool) -> String {
        "\(keyPrefix)\(isAnonymous ? "anon" : "user").\(dateString())"
    }

    private func scopedKey(_ scope: String) -> String {
        "\(keyPrefix)scope.\(scope).\(dateString())"
    }

    private func dateString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: now())
    }
}
