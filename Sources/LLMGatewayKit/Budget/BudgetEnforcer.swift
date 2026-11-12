import Foundation

/// Daily USD spend cap on LLM calls, enforced *before* the call is made (not
/// just tracked after the fact). Each call reserves its estimated cost first,
/// so calls that start together can't all pass, and once spend plus live
/// reservations would cross the cap, further calls are refused, not merely
/// logged, which stops a runaway loop or an abusive user from running up costs
/// indefinitely. The reservation is an estimate, so a single call can cost more
/// than it reserved and take spend past the cap by that difference.
///
/// Supports a simple two-tier policy out of the box (identified vs
/// anonymous users get different caps, mirroring the common shape of "signed
/// in users get a bigger budget than anonymous/trial traffic") and a general
/// per-scope cap for anything else (per feature, per task type, per org).
///
/// Scoped caps are check-then-record with no reservation, so calls that start
/// together can all pass a scoped `canSpend`.
public actor BudgetEnforcer {
    /// A hold on part of a daily cap, returned by `reserve`. It remembers its
    /// day, so a call that crosses midnight UTC releases the right one.
    public struct Reservation: Sendable {
        fileprivate let key: String
        fileprivate let amount: Int64
    }

    private let store: BudgetStore
    private let identifiedDailyCapUSD: Double
    private let anonymousDailyCapUSD: Double
    private let keyPrefix: String

    /// - Parameters:
    ///   - identifiedDailyCapUSD: Daily cap for authenticated/identified callers.
    ///   - anonymousDailyCapUSD: Daily cap for anonymous callers. Typically much
    ///     smaller — this is what stops a single anonymous session from running
    ///     up unbounded spend before any auth/paywall gate would catch it.
    ///   - store: Where spend totals are persisted. Defaults to one shared
    ///     `UserDefaults`-backed store, so enforcers created with the default
    ///     see each other's holds and spend.
    ///   - keyPrefix: Namespace for stored keys, in case the host app uses
    ///     `UserDefaults` for other things too.
    public init(
        identifiedDailyCapUSD: Double,
        anonymousDailyCapUSD: Double,
        store: BudgetStore = UserDefaultsBudgetStore.shared,
        keyPrefix: String = "llmgatewaykit.budget."
    ) {
        self.identifiedDailyCapUSD = identifiedDailyCapUSD
        self.anonymousDailyCapUSD = anonymousDailyCapUSD
        self.store = store
        self.keyPrefix = keyPrefix
    }

    /// Read-only check: would spending `estimatedCostUSD` more today stay within
    /// the caller's cap? It holds nothing and doesn't see other calls' holds, so
    /// use `reserve` when the answer decides whether to make a paid request.
    public func canSpend(estimatedCostUSD: Double, isAnonymous: Bool) async -> Bool {
        let cap = isAnonymous ? anonymousDailyCapUSD : identifiedDailyCapUSD
        guard let amount = Self.micros(estimatedCostUSD), let cap = Self.micros(cap) else { return false }
        return await store.spend(forKey: todayKey(isAnonymous: isAnonymous)) + amount <= cap
    }

    /// Atomically holds `estimatedCostUSD` against the caller's cap, or returns
    /// `nil` if that would cross it or the estimate is negative, NaN or infinite. Call this BEFORE making the LLM request,
    /// `record` what the request really cost, then `release` the hold, on
    /// failure too.
    public func reserve(estimatedCostUSD: Double, isAnonymous: Bool) async -> Reservation? {
        guard Self.isValid(estimatedCostUSD) else { return nil }
        let cap = isAnonymous ? anonymousDailyCapUSD : identifiedDailyCapUSD
        let key = todayKey(isAnonymous: isAnonymous)
        guard let amount = Self.micros(estimatedCostUSD), let cap = Self.micros(cap),
              await store.reserve(amount, cap: cap, forKey: key) else { return nil }
        return Reservation(key: key, amount: amount)
    }

    public func release(_ reservation: Reservation) async {
        await store.release(reservation.amount, forKey: reservation.key)
    }

    /// Record actual spend after a call completes. Call this with the real
    /// cost, not the estimate — estimates and actuals can diverge (token
    /// counts aren't always known until the response comes back). A cost that
    /// is negative, NaN or infinite is dropped: added to the total it would
    /// either lower recorded spend or make every later check fail.
    public func record(actualCostUSD: Double, isAnonymous: Bool) async {
        guard Self.isValid(actualCostUSD) else { return }
        await store.addSpend(actualCostUSD, forKey: todayKey(isAnonymous: isAnonymous))
    }

    public func dailyUsageUSD(isAnonymous: Bool) async -> Double {
        Double(await store.spend(forKey: todayKey(isAnonymous: isAnonymous))) / Self.microsPerUSD
    }

    public func remainingBudgetUSD(isAnonymous: Bool) async -> Double {
        let cap = isAnonymous ? anonymousDailyCapUSD : identifiedDailyCapUSD
        return max(0, cap - (await dailyUsageUSD(isAnonymous: isAnonymous)))
    }

    // MARK: - Arbitrary per-scope envelopes

    /// General-purpose sibling to the identified/anonymous cap above, for
    /// carving out a smaller sub-budget for a specific feature or task type
    /// (e.g. "image analysis gets $0.50/day even within a user's larger cap").
    public func canSpend(estimatedCostUSD: Double, scope: String, capUSD: Double) async -> Bool {
        guard let amount = Self.micros(estimatedCostUSD), let cap = Self.micros(capUSD) else { return false }
        return await store.spend(forKey: scopedKey(scope)) + amount <= cap
    }

    public func record(actualCostUSD: Double, scope: String) async {
        guard Self.isValid(actualCostUSD) else { return }
        await store.addSpend(actualCostUSD, forKey: scopedKey(scope))
    }

    private static func isValid(_ amountUSD: Double) -> Bool {
        amountUSD.isFinite && amountUSD >= 0
    }

    private func todayKey(isAnonymous: Bool) -> String {
        "\(keyPrefix)\(isAnonymous ? "anon" : "user").\(Self.dateString())"
    }

    private func scopedKey(_ scope: String) -> String {
        "\(keyPrefix)scope.\(scope).\(Self.dateString())"
    }

    private static func dateString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: Date())
    }
}
