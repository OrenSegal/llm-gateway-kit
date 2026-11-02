import Foundation
import Testing
@testable import LLMGatewayKit

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
