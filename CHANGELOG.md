# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `DESIGN.md`: budget reservation, breaker states and cache keys in language-neutral pseudocode.
- `docs/decisions.md`: five design decisions with the commit and tests behind each.
- README: a request-flow diagram, and Limitations entries for the missing real provider adapter, the synthetic trace and the absence of production use.

## [0.2.0] - 2026-11-02

### Changed

- **Breaking:** `BudgetStore` requires `reserve(_:capUSD:forKey:)` and `release(_:forKey:)`. Custom stores must make `reserve` atomic.
- **Breaking:** `VisionCache.lookup` and `store` require a `prompt`.
- `LLMGateway` now enforces the budget it is given even when a custom gate chain leaves out `BudgetGate`.
- `CostAuditLogger` gets one `.provider` entry per paid provider call, so an escalated call logs more than one and a call that paid and then threw is logged too.
- `complete` sends a request with an image through `completeVision` instead of the text cache.

### Added

- `BudgetEnforcer.reserve(estimatedCostUSD:isAnonymous:)` and `release(_:)`.
- `TieredCascade.send(_:onSpend:)`, which reports the cost of each provider call.
- `SemanticCache` `scope` parameter on `lookup` and `store`, default empty.
- `CircuitBreaker.wouldAllowAttempt()`, a check that doesn't take the probe.

### Fixed

- Concurrent calls can no longer pass the daily cap together: `LLMGateway` reserves the estimate atomically before the request and releases it afterwards, on failure too.
- Recorded spend covers every provider call that returned a response, priced by the tier that made it. Before, an escalated call recorded only the last tier, a `modelID` different from the provider's `identifier` fell back to the first tier's price, and a call where every tier returned low confidence recorded nothing.
- The vision cache no longer answers a different question about the same image.
- `LLMGateway` no longer shares cached answers across task types, `maxOutputTokens` values or cascades with different tiers.
- `CircuitBreaker` allows exactly one half-open probe at a time. A probe that never reports stops blocking after `recoveryInterval`.

## [0.1.1] - 2026-10-26

### Added

- `TraceReplayTests`: a scripted 22-request trace through `LLMGateway` that pins cache hits, budget refusals and circuit-breaker failover. The README reports its counts.

### Fixed

- `SemanticCache.lookup` and `VisionCache.lookup` now treat entries older than `ttl` as misses. Before, expired entries were served until `evictExpired()` ran, which contradicted the `ttl` doc comments.

## [0.1.0] - 2026-08-01

### Added

- Initial release: `SemanticCache` (embedding-similarity text response cache),
  `VisionCache` (perceptual-hash image response cache), `CircuitBreaker` +
  `TieredCascade` (per-provider circuit breakers with confidence-based
  quality escalation), `BudgetEnforcer` (daily USD spend caps,
  identified/anonymous tiers, and arbitrary per-scope envelopes),
  `LLMGate`/`CompositeLLMGate` (composable pre-flight gate chain), and
  `LLMGateway` (the orchestrator tying all of the above together).
- `LLMGatewayKitDemo` executable target showing end-to-end setup.
- Unit test suite covering all core components.
