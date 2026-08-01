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
}
