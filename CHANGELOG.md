# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `LLMPricing` library product: `PricingTable`, `ModelPrice` and `TokenCounts`, Foundation only. `LLMGatewayKit` depends on it and re-exports it.
- `LLMGateway(pricing:)`: when set, each response's actual cost comes from the table, looked up by the response's `modelID`.
- `TokenCounts(_ usage: LLMUsage)`: moves reasoning tokens inside `output` and notes them in `thinking`.
- `BudgetEnforcer.reserve`, `commit(_:actualCostUSD:)`, `release(_:)` and the `Reservation` type.

### Changed

- **Breaking:** `BudgetStore` has four new requirements: `reserve`, `commit`, `release` and `heldSpend`. Custom stores must implement them, and `reserve` must check and hold with no suspension point in between. `InMemoryBudgetStore` and `UserDefaultsBudgetStore` implement them.

- The budget cap is now hard on admission. `BudgetEnforcer.reserve` checks the cap and places a hold in one atomic store step, so concurrent calls can no longer all pass the check and overshoot it. Settle each reservation with `commit(_:actualCostUSD:)` or `release(_:)`. Unsettled reservations stop holding budget after `reservationTTL` (default 300 seconds). An actual cost above the estimate is recorded in full.
- `LLMGateway` reserves after the gate chain allows, commits the actual cost on success, and releases on any error, cancellation included. Its default gate chain is now empty; `BudgetGate` remains as an optional non-reserving pre-check that counts outstanding holds.
- `remainingBudgetUSD` subtracts outstanding holds. `dailyUsageUSD` still reports settled spend only.

### Deprecated

- `BudgetEnforcer.canSpend` and `record`. Migration: replace `canSpend(estimatedCostUSD:...)` with `reserve(estimatedCostUSD:...)`, which returns a `Reservation` or nil, and replace `record(actualCostUSD:...)` with `commit(reservation, actualCostUSD:)`, or `release(reservation)` if the call failed.

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
