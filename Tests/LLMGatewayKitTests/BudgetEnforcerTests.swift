import Foundation
import Testing
@testable import LLMGatewayKit

/// Clock the expiry tests can move forward.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_700_000_000)

    func now() -> Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current += seconds } }
}

@Suite("BudgetEnforcer")
struct BudgetEnforcerTests {
    @Test("concurrent reservations never exceed the cap")
    func concurrentReservationsStayWithinCap() async {
        let enforcer = BudgetEnforcer(identifiedDailyCapUSD: 1.0, anonymousDailyCapUSD: 0.5, store: InMemoryBudgetStore())

        let granted = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<100 {
                group.addTask { await enforcer.reserve(estimatedCostUSD: 0.25, isAnonymous: false) != nil }
            }
            return await group.reduce(0) { $1 ? $0 + 1 : $0 }
        }

        #expect(granted == 4)
        #expect(await enforcer.remainingBudgetUSD(isAnonymous: false) == 0)
    }

    @Test("release returns the held budget, and a second settle is a no-op")
    func releaseReturnsBudget() async throws {
        let enforcer = BudgetEnforcer(identifiedDailyCapUSD: 0.5, anonymousDailyCapUSD: 0.1, store: InMemoryBudgetStore())

        let first = try #require(await enforcer.reserve(estimatedCostUSD: 0.5, isAnonymous: false))
        #expect(await enforcer.reserve(estimatedCostUSD: 0.1, isAnonymous: false) == nil)

        await enforcer.release(first)
        await enforcer.release(first)
        await enforcer.commit(first, actualCostUSD: 0.5)
        #expect(await enforcer.dailyUsageUSD(isAnonymous: false) == 0)
        #expect(await enforcer.reserve(estimatedCostUSD: 0.5, isAnonymous: false) != nil)
    }

    @Test("an actual cost above the estimate is recorded in full and blocks further reservations")
    func overageIsRecordedInFull() async throws {
        let enforcer = BudgetEnforcer(identifiedDailyCapUSD: 1.0, anonymousDailyCapUSD: 0.1, store: InMemoryBudgetStore())

        let reservation = try #require(await enforcer.reserve(estimatedCostUSD: 0.25, isAnonymous: false))
        await enforcer.commit(reservation, actualCostUSD: 1.5)

        #expect(await enforcer.dailyUsageUSD(isAnonymous: false) == 1.5)
        #expect(await enforcer.remainingBudgetUSD(isAnonymous: false) == 0)
        #expect(await enforcer.reserve(estimatedCostUSD: 0.01, isAnonymous: false) == nil)
    }

    @Test("an unsettled reservation stops holding budget after its TTL, and a late commit still records spend")
    func expiredReservationFreesBudget() async throws {
        let clock = TestClock()
        let enforcer = BudgetEnforcer(
            identifiedDailyCapUSD: 1.0,
            anonymousDailyCapUSD: 0.1,
            store: InMemoryBudgetStore(),
            reservationTTL: 60,
            now: { clock.now() }
        )

        let stale = try #require(await enforcer.reserve(estimatedCostUSD: 1.0, isAnonymous: false))
        clock.advance(59)
        #expect(await enforcer.reserve(estimatedCostUSD: 0.25, isAnonymous: false) == nil)

        clock.advance(2)
        #expect(await enforcer.reserve(estimatedCostUSD: 0.25, isAnonymous: false) != nil)

        await enforcer.commit(stale, actualCostUSD: 0.5)
        await enforcer.commit(stale, actualCostUSD: 0.5)
        #expect(await enforcer.dailyUsageUSD(isAnonymous: false) == 0.5)
        #expect(await enforcer.remainingBudgetUSD(isAnonymous: false) == 0.25)
    }

    @Test("anonymous callers use the smaller anonymous cap")
    func anonymousUsesSmallerCap() async {
        let enforcer = BudgetEnforcer(identifiedDailyCapUSD: 5.0, anonymousDailyCapUSD: 0.1, store: InMemoryBudgetStore())
        #expect(await enforcer.reserve(estimatedCostUSD: 0.2, isAnonymous: true) == nil)
        #expect(await enforcer.reserve(estimatedCostUSD: 0.2, isAnonymous: false) != nil)
    }

    @Test("scoped envelopes are independent of the identified/anonymous cap")
    func scopedEnvelopeIsIndependent() async throws {
        let enforcer = BudgetEnforcer(identifiedDailyCapUSD: 5.0, anonymousDailyCapUSD: 0.5, store: InMemoryBudgetStore())
        let vision = try #require(await enforcer.reserve(estimatedCostUSD: 0.25, scope: "vision", capUSD: 0.5))
        await enforcer.commit(vision, actualCostUSD: 0.25)

        #expect(await enforcer.reserve(estimatedCostUSD: 0.5, scope: "vision", capUSD: 0.5) == nil)
        #expect(await enforcer.reserve(estimatedCostUSD: 0.25, scope: "vision", capUSD: 0.5) != nil)
        // The identified cap is untouched by scoped spend.
        #expect(await enforcer.dailyUsageUSD(isAnonymous: false) == 0)
    }

    @Test("BudgetGate denies a call that would not fit, counting outstanding holds")
    func budgetGateCountsHolds() async throws {
        let enforcer = BudgetEnforcer(identifiedDailyCapUSD: 1.0, anonymousDailyCapUSD: 0.1, store: InMemoryBudgetStore())
        let gate = BudgetGate(enforcer: enforcer)
        _ = try #require(await enforcer.reserve(estimatedCostUSD: 0.75, isAnonymous: false))

        #expect(await gate.evaluate(context: LLMGateContext(estimatedCostUSD: 0.25)) == .allow)
        #expect(await gate.evaluate(context: LLMGateContext(estimatedCostUSD: 0.5)) == .deny(gate: "budget", reason: "dailyBudgetExceeded"))
    }
}
