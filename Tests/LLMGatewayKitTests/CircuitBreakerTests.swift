import Foundation
import Testing
@testable import LLMGatewayKit

private actor InvocationFlag {
    private(set) var value = false
    func markInvoked() { value = true }
}

@Suite("CircuitBreaker")
struct CircuitBreakerTests {
    @Test("starts closed and allows attempts")
    func startsClosed() async {
        let breaker = CircuitBreaker(failureThreshold: 3, recoveryInterval: 60)
        #expect(await breaker.state == .closed)
        #expect(await breaker.canAttempt())
    }

    @Test("opens after reaching the failure threshold")
    func opensAfterThreshold() async {
        let breaker = CircuitBreaker(failureThreshold: 3, recoveryInterval: 60)
        await breaker.recordFailure()
        await breaker.recordFailure()
        #expect(await breaker.state == .closed)
        await breaker.recordFailure()
        #expect(await breaker.state == .open)
        #expect(await breaker.canAttempt() == false)
    }

    @Test("success resets failure count and closes the circuit")
    func successResets() async {
        let breaker = CircuitBreaker(failureThreshold: 2, recoveryInterval: 60)
        await breaker.recordFailure()
        await breaker.recordSuccess()
        await breaker.recordFailure()
        #expect(await breaker.state == .closed)
    }

    @Test("transitions to half-open after the recovery interval elapses")
    func halfOpenAfterRecovery() async {
        let breaker = CircuitBreaker(failureThreshold: 1, recoveryInterval: 0)
        await breaker.recordFailure()
        #expect(await breaker.state == .open)
        // recoveryInterval is 0, so the next canAttempt() call should flip to half-open.
        #expect(await breaker.canAttempt())
        #expect(await breaker.state == .halfOpen)
    }

    @Test("reset returns the breaker to closed with a clean slate")
    func resetClearsState() async {
        let breaker = CircuitBreaker(failureThreshold: 1, recoveryInterval: 60)
        await breaker.recordFailure()
        #expect(await breaker.state == .open)
        await breaker.reset()
        #expect(await breaker.state == .closed)
        #expect(await breaker.canAttempt())
    }

    @Test("execute throws circuitOpen without invoking the operation when open")
    func executeSkipsWhenOpen() async {
        let breaker = CircuitBreaker(failureThreshold: 1, recoveryInterval: 60)
        await breaker.recordFailure()

        let invoked = InvocationFlag()
        do {
            _ = try await breaker.execute(providerID: "test-provider") {
                await invoked.markInvoked()
                return 1
            }
            Issue.record("expected circuitOpen to be thrown")
        } catch LLMGatewayError.circuitOpen(let provider) {
            #expect(provider == "test-provider")
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        #expect(await invoked.value == false)
    }

    @Test("half-open allows exactly one of several concurrent probes")
    func halfOpenAllowsOneProbe() async throws {
        let breaker = CircuitBreaker(failureThreshold: 1, recoveryInterval: Self.recovery)
        await breaker.recordFailure()
        try await Task.sleep(nanoseconds: Self.pastRecovery)

        #expect(await Self.grantedAttempts(breaker, callers: 5) == 1)
        #expect(await breaker.state == .halfOpen)
    }

    @Test("a probe that never reports stops blocking after the recovery interval")
    func abandonedProbeTimesOut() async throws {
        let breaker = CircuitBreaker(failureThreshold: 1, recoveryInterval: Self.recovery)
        await breaker.recordFailure()
        try await Task.sleep(nanoseconds: Self.pastRecovery)
        #expect(await breaker.canAttempt())
        #expect(await breaker.canAttempt() == false)

        try await Task.sleep(nanoseconds: Self.pastRecovery)
        #expect(await Self.grantedAttempts(breaker, callers: 5) == 1)
    }

    @Test("a failed probe reopens and waits out the full recovery interval")
    func failedProbeReopens() async throws {
        let breaker = CircuitBreaker(failureThreshold: 1, recoveryInterval: Self.recovery)
        await breaker.recordFailure()
        try await Task.sleep(nanoseconds: Self.pastRecovery)
        #expect(await breaker.canAttempt())

        await breaker.recordFailure()
        #expect(await breaker.state == .open)
        #expect(await breaker.canAttempt() == false)
    }

    @Test("a successful probe closes the circuit for everyone")
    func successfulProbeCloses() async throws {
        let breaker = CircuitBreaker(failureThreshold: 1, recoveryInterval: Self.recovery)
        await breaker.recordFailure()
        try await Task.sleep(nanoseconds: Self.pastRecovery)
        #expect(await breaker.canAttempt())

        await breaker.recordSuccess()
        #expect(await Self.grantedAttempts(breaker, callers: 5) == 5)
    }

    @Test("a CircuitBreakerGate on a cascade's breaker leaves the probe for the cascade")
    func gateDoesNotConsumeProbe() async throws {
        let breaker = CircuitBreaker(failureThreshold: 1, recoveryInterval: Self.recovery)
        await breaker.recordFailure()
        try await Task.sleep(nanoseconds: Self.pastRecovery)
        let gate = CircuitBreakerGate(breaker: breaker, providerID: "p")

        #expect(await gate.evaluate(context: LLMGateContext()).isAllowed)
        #expect(await breaker.canAttempt(), "the gate only looked, so the probe is still free")
        #expect(await gate.evaluate(context: LLMGateContext()).isAllowed == false)
    }

    // Long enough that a slow CI machine won't let the interval lapse between
    // two calls in a test that expects it not to have.
    private static let recovery: TimeInterval = 0.3
    private static let pastRecovery: UInt64 = 350_000_000

    private static func grantedAttempts(_ breaker: CircuitBreaker, callers: Int) async -> Int {
        await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<callers {
                group.addTask { await breaker.canAttempt() }
            }
            var granted = 0
            for await ok in group where ok { granted += 1 }
            return granted
        }
    }
}
