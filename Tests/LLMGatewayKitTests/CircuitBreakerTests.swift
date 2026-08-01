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
}
