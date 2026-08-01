import Foundation

/// Hard daily USD spend cap on LLM calls, enforced *before* the call is
/// made (not just tracked after the fact). This is the piece that turns "we
/// have a cost dashboard" into "a runaway loop or an abusive user literally
/// cannot spend past the cap" — the check runs pre-flight and calls are
/// refused, not merely logged, once the budget is exhausted.
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

    /// - Parameters:
    ///   - identifiedDailyCapUSD: Daily cap for authenticated/identified callers.
    ///   - anonymousDailyCapUSD: Daily cap for anonymous callers. Typically much
    ///     smaller — this is what stops a single anonymous session from running
    ///     up unbounded spend before any auth/paywall gate would catch it.
    ///   - store: Where spend totals are persisted. Defaults to `UserDefaults`.
    ///   - keyPrefix: Namespace for stored keys, in case the host app uses
    ///     `UserDefaults` for other things too.
    public init(
        identifiedDailyCapUSD: Double,
        anonymousDailyCapUSD: Double,
        store: BudgetStore = UserDefaultsBudgetStore(),
        keyPrefix: String = "llmgatewaykit.budget."
    ) {
        self.identifiedDailyCapUSD = identifiedDailyCapUSD
        self.anonymousDailyCapUSD = anonymousDailyCapUSD
        self.store = store
        self.keyPrefix = keyPrefix
    }

    /// Pre-flight check: would spending `estimatedCostUSD` more today stay
    /// within the caller's cap? Call this BEFORE making the LLM request.
    public func canSpend(estimatedCostUSD: Double, isAnonymous: Bool) async -> Bool {
        let cap = isAnonymous ? anonymousDailyCapUSD : identifiedDailyCapUSD
        let used = await store.spend(forKey: todayKey(isAnonymous: isAnonymous))
        return (used + estimatedCostUSD) <= cap
    }

    /// Record actual spend after a call completes. Call this with the real
    /// cost, not the estimate — estimates and actuals can diverge (token
    /// counts aren't always known until the response comes back).
    public func record(actualCostUSD: Double, isAnonymous: Bool) async {
        await store.addSpend(actualCostUSD, forKey: todayKey(isAnonymous: isAnonymous))
    }

    public func dailyUsageUSD(isAnonymous: Bool) async -> Double {
        await store.spend(forKey: todayKey(isAnonymous: isAnonymous))
    }

    public func remainingBudgetUSD(isAnonymous: Bool) async -> Double {
        let cap = isAnonymous ? anonymousDailyCapUSD : identifiedDailyCapUSD
        return max(0, cap - (await store.spend(forKey: todayKey(isAnonymous: isAnonymous))))
    }

    // MARK: - Arbitrary per-scope envelopes

    /// General-purpose sibling to the identified/anonymous cap above, for
    /// carving out a smaller sub-budget for a specific feature or task type
    /// (e.g. "image analysis gets $0.50/day even within a user's larger cap").
    public func canSpend(estimatedCostUSD: Double, scope: String, capUSD: Double) async -> Bool {
        let used = await store.spend(forKey: scopedKey(scope))
        return (used + estimatedCostUSD) <= capUSD
    }

    public func record(actualCostUSD: Double, scope: String) async {
        await store.addSpend(actualCostUSD, forKey: scopedKey(scope))
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
