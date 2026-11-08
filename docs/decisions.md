# Decisions

Five choices that shape how the kit behaves. Each links the commit and the
tests that hold it in place. The commits record what was decided, not what
else was weighed: the alternatives below were written on 2026-11-07, and
"not recorded" marks options nobody wrote about at the time.

## 1. Reserve the estimate before the call instead of checking, then spending

- **Context.** v0.1.0 checked spent-so-far against the cap, made the call,
  then recorded the cost. Ten calls that start together all read
  "spent $0.00, cap $0.05, my cost $0.01", all pass, and the day ends at
  $0.10. The v0.1.0 tests ran calls one at a time, so they passed while the
  cap could be overrun under concurrency. An audit found it, not a user; 0.1.1
  shipped with the race disclosed in Limitations ("the budget cap is soft
  under concurrency"), and 0.2.0 fixed it.
- **Decision.** `reserve(amount, cap, key)` checks `spent + held + amount`
  against the cap and adds the hold in one step with no `await` inside the
  actor method. The hold is released after the call, on failure too, and
  real cost is recorded separately (`DESIGN.md`, "Budget reservation").
- **Alternatives.** A lock around the whole provider call: serializes every
  request, so one slow call blocks all others. Post-hoc reconciliation
  (record, then refuse the next call): still lets a burst through. Neither is
  recorded as weighed at the time.
- **Consequences.** A burst cannot pass the cap together. The hold is an
  estimate priced at the first tier, so an escalated or longer call can
  still overshoot by the estimate's error (README, Limitations). Atomicity
  holds only inside one store; a server-backed `BudgetStore` must make
  `reserve` a transaction.
- **Evidence.** 971be2f (PR #5, released in 0.2.0). Tests:
  "concurrent calls cannot pass a cap that only fits one of them",
  "each store admits exactly the reservations that fit under concurrency",
  "a failed call gives its reservation back".

## 2. Exactly one half-open probe, with a timeout

- **Context.** In v0.1.0 every caller arriving while the breaker was
  half-open went through, so a recovering provider took the whole burst.
- **Decision.** The first caller after `recoveryInterval` becomes the only
  probe; others are refused. If the probe never reports, the next caller
  after another `recoveryInterval` replaces it. `wouldAllowAttempt()` lets a
  gate check state without taking the probe.
- **Alternatives.** Allow N probes, or a success rate over a window: not
  recorded.
- **Consequences.** A `recoveryInterval` of 0 removes the probe limit
  (README, Limitations). The threshold counts consecutive failures, not a
  rate, so an alternating fail/succeed provider never opens.
- **Evidence.** 971be2f (PR #5). Tests: "half-open allows exactly one of
  several concurrent probes", "a probe that never reports stops blocking
  after the recovery interval",
  "a CircuitBreakerGate on a cascade's breaker leaves the probe for the cascade".

## 3. Cache scope is the tier list, task type and output limit, not the model that answered

- **Context.** v0.1.0 keyed the semantic cache on the prompt alone, so a
  different task type or output limit could receive another request's
  answer, and the vision cache answered a different question about the
  same image.
- **Decision.** `LLMGateway` builds the scope from every tier's provider id,
  the task type and `maxOutputTokens`; the vision key adds the exact prompt.
  The answering tier is unknown at lookup time, so the tier list stands in
  for the model.
- **Alternatives.** Key on the answering model: impossible before the call.
  Key on the first tier only: would mix answers from cascades with different
  backups. Not recorded beyond that.
- **Consequences.** An answer from a backup tier is reused for the whole
  cascade. A reworded question about the same image is a paid call.
- **Evidence.** 971be2f (PR #5). Tests: "the semantic cache separates task
  types and output limits", "the vision cache does not answer a different
  question about the same image", "the same prompt in two scopes keeps two
  entries that never cross".

## 4. The kit never talks to a vendor API

- **Context.** The kit's job is cost and reliability around any provider.
- **Decision.** Everything goes through the `LLMProvider` protocol
  (`send`, `estimatedCostUSD`, `identifier`); the package ships no OpenAI,
  Anthropic or Gemini adapter and has no networking code.
- **Alternatives.** Bundle adapters for two or three vendors: not recorded.
- **Consequences.** No vendor SDK dependency and nothing to keep in sync
  with vendor APIs, but also no adapter that has been run against a real
  provider. Cost accuracy is whatever your adapter's `estimatedCostUSD`
  computes.
- **Evidence.** `Sources/LLMGatewayKit/Core/LLMProvider.swift`; the demo and
  every test use mock providers.

## 5. Report behavior as counts a test asserts, not as savings

- **Context.** There is no real traffic to measure savings on: Shelfie, the
  app these patterns come from, runs its own server-side gateway and does not
  use this package.
- **Decision.** `TraceReplayTests` replays 22 scripted requests through one
  gateway and asserts each count in the README table, using a toy one-hot
  embedding so the counts are deterministic.
- **Alternatives.** Publish a cost-savings percentage: no data to back it.
- **Consequences.** CI fails if the README's counts stop matching the code.
  The trace shows that each mechanism fires, not how often it would on real
  traffic or how well a real embedding model catches paraphrases.
- **Evidence.** 1ef3096 (PR #3). Test: "a scripted 22-request trace: cache
  hits, budget denials, breaker failover".
