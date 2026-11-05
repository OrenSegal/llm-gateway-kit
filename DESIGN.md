# Design notes

The three mechanisms in this package are not Swift-specific. This note describes each one in plain pseudocode, with the file where the Swift version lives. Everything here is a description of the current code, not a roadmap.

## Request flow

`LLMGateway.complete` (`Sources/LLMGatewayKit/Gateway/LLMGateway.swift`):

```text
complete(request, anonymous):
    if request has image: return completeVision(...)
    hit = semantic_cache.lookup(request.prompt, scope = cache_scope(request))
    if hit: log(source = cache, cost = 0); return hit

    estimate = first_tier.price(len(prompt) / 4 input tokens, max_output or 256)
    if any gate denies (estimate): raise gate_denied
    hold = budget.reserve(estimate, anonymous)     # atomic, see below
    if hold is none: raise gate_denied("dailyBudgetExceeded")
    try:
        response = cascade.send(request, on_spend = record_actual_cost)
    finally:
        budget.release(hold)                       # also when the call failed
    semantic_cache.store(request.prompt, response.text, scope)
    return response
```

## Budget reservation

Goal: concurrent requests must not all pass a daily cap check and then all spend.

A check-then-spend design has a race: ten calls start together, each reads "spent: $0.00, cap: $0.05, my cost: $0.01", all proceed, and the day ends at $0.10. Reservation closes it:

```text
reserve(amount, cap, key):          # one atomic step: an actor method with no await,
    if spent[key] + held[key] + amount > cap: return false    # or one DB transaction
    held[key] += amount
    return true

release(amount, key): held[key] = max(0, held[key] - amount)
record(actual, key):  spent[key] += actual        # real cost, reported by the provider adapter
```

- A hold is not spend. It only blocks other callers while the call is in flight, and is released after the call whether it succeeded or threw. Real cost goes through `record`.
- The key includes the UTC date and the caller class (identified or anonymous), so each has its own cap and the day rolls over at midnight UTC.
- The hold is an estimate priced at the first tier. If the call escalates to a pricier tier or uses more tokens, actual spend can pass the cap by the difference. The README Limitations section says so.
- Atomicity holds only within one store instance. A server-backed `BudgetStore` has to implement `reserve` as a transaction itself.

Code: `Budget/BudgetStore.swift` (the atomic check), `Budget/BudgetEnforcer.swift` (caps, keys).

## Circuit breaker states

One breaker per provider (`Reliability/CircuitBreaker.swift`).

```text
closed    --5 consecutive failures-->  open
open      --recovery_interval passes, next caller-->  half-open  (that caller is the probe)
half-open --probe succeeds-->  closed
half-open --probe fails-->     open   (waits a full recovery_interval again)
half-open --probe never reports-->  after recovery_interval, the next caller becomes the probe
```

- Only one probe runs at a time. Other callers during half-open are refused, so a recovering provider isn't hit by a burst.
- Any success resets the failure count. The threshold counts consecutive failures, not a rate.
- The cascade (`Reliability/TieredCascade.swift`) walks tiers in order and moves on when a tier's breaker refuses, the call throws, or the response's confidence is below that tier's floor. A low-confidence answer is still paid for and recorded as spend; it does not count as a breaker failure.
- If every tier refuses, throws or comes back below its floor, the call fails. The last tier's low-confidence answer is discarded, not returned.

## Cache keys

`SemanticCache` (`Caching/SemanticCache.swift`):

```text
lookup(prompt, scope):
    q = embed(prompt)
    candidates = entries where scope matches, not older than ttl, same embedding model id
    best = candidate with highest cosine(q, entry.embedding), if >= threshold (default 0.92)
    return best.response, or miss
```

- The scope is built by `LLMGateway` from the provider identifiers of every tier, the task type and `maxOutputTokens`. Two requests that differ in any of those never share an answer. The tier list stands in for the model because the answering tier is unknown at lookup time, so an answer from a backup tier is reused for the whole cascade.
- Lookup compares against every entry in scope: O(n) in cache size. Fine for hundreds of entries on a device, wrong for a large shared cache. Swap in a vector index before that.
- The 0.92 default has no tuning data behind it. The trace test uses a toy one-hot embedding so the counts are deterministic; it shows the mechanism, not real paraphrase quality.

`VisionCache` (`Caching/VisionCache.swift`) is the same shape, keyed on a perceptual hash of the image (Hamming distance) plus the exact prompt text, because the same image with a different question needs a different answer.

## Porting

Nothing above depends on Swift beyond the actor used for atomicity. In another language, the equivalents are a mutex or a single-threaded event loop around `reserve`, a Redis Lua script or SQL transaction for a shared budget, and any async circuit-breaker library for the state machine.
