import Foundation
import Testing
@testable import LLMGatewayKit

/// Records the keys it is asked about, to pin the key format.
private actor KeyRecordingStore: BudgetStore {
    private(set) var keys: [String] = []
    func spend(forKey key: String) async -> Double { keys.append(key); return 0 }
    func addSpend(_ amount: Double, forKey key: String) async { keys.append(key) }
    func reserve(_ amount: Double, capUSD: Double, forKey key: String) async -> Bool { keys.append(key); return true }
    func release(_ amount: Double, forKey key: String) async { keys.append(key) }
}

@Suite("BudgetEnforcer")
struct BudgetEnforcerTests {
    @Test("allows spend within the identified cap")
    func allowsWithinCap() async {
        let enforcer = BudgetEnforcer(identifiedDailyCapUSD: 5.0, anonymousDailyCapUSD: 0.5, store: InMemoryBudgetStore())
        #expect(await enforcer.canSpend(estimatedCostUSD: 1.0, isAnonymous: false))
    }

    @Test("denies spend once the identified cap is exhausted")
    func deniesOverCap() async {
        let enforcer = BudgetEnforcer(identifiedDailyCapUSD: 1.0, anonymousDailyCapUSD: 0.5, store: InMemoryBudgetStore())
        await enforcer.record(actualCostUSD: 0.9, isAnonymous: false)
        #expect(await enforcer.canSpend(estimatedCostUSD: 0.2, isAnonymous: false) == false)
    }

    @Test("anonymous callers use the smaller anonymous cap")
    func anonymousUsesSmallerCap() async {
        let enforcer = BudgetEnforcer(identifiedDailyCapUSD: 5.0, anonymousDailyCapUSD: 0.1, store: InMemoryBudgetStore())
        #expect(await enforcer.canSpend(estimatedCostUSD: 0.2, isAnonymous: true) == false)
        #expect(await enforcer.canSpend(estimatedCostUSD: 0.2, isAnonymous: false))
    }

    @Test("remainingBudgetUSD reflects recorded spend")
    func remainingBudgetReflectsSpend() async {
        let enforcer = BudgetEnforcer(identifiedDailyCapUSD: 5.0, anonymousDailyCapUSD: 0.5, store: InMemoryBudgetStore())
        await enforcer.record(actualCostUSD: 2.0, isAnonymous: false)
        let remaining = await enforcer.remainingBudgetUSD(isAnonymous: false)
        #expect(abs(remaining - 3.0) < 0.0001)
    }

    @Test("scoped envelopes are independent of the identified/anonymous cap")
    func scopedEnvelopeIsIndependent() async {
        let enforcer = BudgetEnforcer(identifiedDailyCapUSD: 5.0, anonymousDailyCapUSD: 0.5, store: InMemoryBudgetStore())
        await enforcer.record(actualCostUSD: 0.4, scope: "vision")
        #expect(await enforcer.canSpend(estimatedCostUSD: 0.05, scope: "vision", capUSD: 0.5))
        #expect(await enforcer.canSpend(estimatedCostUSD: 0.5, scope: "vision", capUSD: 0.5) == false)
        // The identified cap is untouched by scoped spend.
        #expect(await enforcer.canSpend(estimatedCostUSD: 4.0, isAnonymous: false))
    }

    @Test("each store admits exactly the reservations that fit under concurrency")
    func storesReserveAtomically() async {
        // UserDefaults(suiteName:) with a unique name keeps this out of .standard.
        let suite = "llmgatewaykit.tests.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let stores: [any BudgetStore] = [InMemoryBudgetStore(), UserDefaultsBudgetStore(defaults: UserDefaults(suiteName: suite)!)]

        for store in stores {
            let enforcer = BudgetEnforcer(identifiedDailyCapUSD: 3.0, anonymousDailyCapUSD: 0.5, store: store)
            let admitted = await withTaskGroup(of: Bool.self) { group in
                for _ in 0..<20 {
                    group.addTask { await enforcer.reserve(estimatedCostUSD: 1.0, isAnonymous: false) != nil }
                }
                var admitted = 0
                for await ok in group where ok { admitted += 1 }
                return admitted
            }
            #expect(admitted == 3)
        }
    }

    @Test("a cap that is an exact multiple of the call cost admits every call that fits")
    func exactMultipleOfCostFitsTheCap() async {
        // 0.1 + 0.1 + 0.1 is 0.30000000000000004 as a Double, which is over 0.3.
        let suite = "llmgatewaykit.tests.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let stores: [any BudgetStore] = [InMemoryBudgetStore(), UserDefaultsBudgetStore(defaults: UserDefaults(suiteName: suite)!)]

        for store in stores {
            let enforcer = BudgetEnforcer(identifiedDailyCapUSD: 0.30, anonymousDailyCapUSD: 0.30, store: store)
            var admitted = 0
            for _ in 0..<4 {
                guard let hold = await enforcer.reserve(estimatedCostUSD: 0.10, isAnonymous: false) else { continue }
                await enforcer.record(actualCostUSD: 0.10, isAnonymous: false)
                await enforcer.release(hold)
                admitted += 1
            }
            #expect(admitted == 3)

            await enforcer.record(actualCostUSD: 0.10, isAnonymous: true)
            await enforcer.record(actualCostUSD: 0.10, isAnonymous: true)
            #expect(await enforcer.canSpend(estimatedCostUSD: 0.10, isAnonymous: true))
            #expect(await enforcer.canSpend(estimatedCostUSD: 0.11, isAnonymous: true) == false)

            await enforcer.record(actualCostUSD: 0.10, scope: "vision")
            await enforcer.record(actualCostUSD: 0.10, scope: "vision")
            #expect(await enforcer.canSpend(estimatedCostUSD: 0.10, scope: "vision", capUSD: 0.30))
            #expect(await enforcer.canSpend(estimatedCostUSD: 0.11, scope: "vision", capUSD: 0.30) == false)
        }
    }

    @Test("the day in a budget key is the Gregorian UTC date in ASCII digits, whatever the device locale")
    func dayKeyIgnoresLocale() async {
        // Pins the stored key format. A DateFormatter left on the device locale
        // writes the Buddhist year in th_TH and Arabic-Indic digits in ar_SA;
        // this only goes red for that on a machine set to such a region.
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = TimeZone(secondsFromGMT: 0)!
        let before = gregorian.dateComponents([.year, .month, .day], from: Date())
        let store = KeyRecordingStore()
        let enforcer = BudgetEnforcer(identifiedDailyCapUSD: 1, anonymousDailyCapUSD: 1, store: store, keyPrefix: "p.")
        await enforcer.record(actualCostUSD: 0.01, isAnonymous: false)
        await enforcer.record(actualCostUSD: 0.01, scope: "vision")
        let after = gregorian.dateComponents([.year, .month, .day], from: Date())

        // Either side of midnight UTC is acceptable if the test straddles it.
        func pad(_ value: Int?) -> String {
            let digits = String(value ?? 0)
            return digits.count < 2 ? "0" + digits : digits
        }
        let days: [String] = [before, after].map { "\(pad($0.year))-\(pad($0.month))-\(pad($0.day))" }
        let keys = await store.keys
        #expect(keys.count == 2)
        #expect(days.map { "p.user." + $0 }.contains(keys.first ?? ""))
        #expect(days.map { "p.scope.vision." + $0 }.contains(keys.last ?? ""))
    }

    @Test("enforcers created with the default store share one set of holds")
    func defaultStoreIsShared() async {
        // Unique prefix: holds are in memory, so nothing is written to UserDefaults.standard.
        let prefix = "llmgatewaykit.tests.\(UUID().uuidString)."
        let first = BudgetEnforcer(identifiedDailyCapUSD: 3.0, anonymousDailyCapUSD: 0.5, keyPrefix: prefix)
        let second = BudgetEnforcer(identifiedDailyCapUSD: 3.0, anonymousDailyCapUSD: 0.5, keyPrefix: prefix)
        let admitted = await withTaskGroup(of: Bool.self) { group in
            for i in 0..<20 {
                group.addTask { await (i % 2 == 0 ? first : second).reserve(estimatedCostUSD: 1.0, isAnonymous: false) != nil }
            }
            var admitted = 0
            for await ok in group where ok { admitted += 1 }
            return admitted
        }
        #expect(admitted == 3)
    }

    @Test("negative, NaN and infinite amounts are refused or dropped")
    func invalidAmounts() async {
        let enforcer = BudgetEnforcer(identifiedDailyCapUSD: 0.05, anonymousDailyCapUSD: 0.05, store: InMemoryBudgetStore())
        await enforcer.record(actualCostUSD: .nan, isAnonymous: false)
        await enforcer.record(actualCostUSD: -1000, isAnonymous: false)
        await enforcer.record(actualCostUSD: .infinity, scope: "vision")
        #expect(await enforcer.dailyUsageUSD(isAnonymous: false) == 0)
        #expect(await enforcer.canSpend(estimatedCostUSD: 0.01, scope: "vision", capUSD: 0.05))

        #expect(await enforcer.reserve(estimatedCostUSD: -1000, isAnonymous: false) == nil)
        #expect(await enforcer.reserve(estimatedCostUSD: .nan, isAnonymous: false) == nil)
        #expect(await enforcer.reserve(estimatedCostUSD: 500, isAnonymous: false) == nil)
        #expect(await enforcer.reserve(estimatedCostUSD: 0.01, isAnonymous: false) != nil)
    }

    @Test("a reservation counts against the cap until released, and is not spend")
    func reservationHoldsUntilReleased() async throws {
        let enforcer = BudgetEnforcer(identifiedDailyCapUSD: 1.0, anonymousDailyCapUSD: 0.5, store: InMemoryBudgetStore())
        let hold = try #require(await enforcer.reserve(estimatedCostUSD: 1.0, isAnonymous: false))
        #expect(await enforcer.reserve(estimatedCostUSD: 0.1, isAnonymous: false) == nil)
        #expect(await enforcer.dailyUsageUSD(isAnonymous: false) == 0)

        await enforcer.release(hold)
        #expect(await enforcer.reserve(estimatedCostUSD: 0.1, isAnonymous: false) != nil)
    }

    @Test("reservations count recorded spend and use the caller's own cap")
    func reservationSeesSpendAndCap() async {
        let enforcer = BudgetEnforcer(identifiedDailyCapUSD: 1.0, anonymousDailyCapUSD: 0.1, store: InMemoryBudgetStore())
        #expect(await enforcer.reserve(estimatedCostUSD: 0.2, isAnonymous: true) == nil)
        await enforcer.record(actualCostUSD: 0.9, isAnonymous: false)
        #expect(await enforcer.reserve(estimatedCostUSD: 0.2, isAnonymous: false) == nil)
        #expect(await enforcer.reserve(estimatedCostUSD: 0.1, isAnonymous: false) != nil)
    }
}
