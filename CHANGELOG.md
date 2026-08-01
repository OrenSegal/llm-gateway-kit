# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2026-08-01

### Added

- Initial release: `SemanticCache` (embedding-similarity text response cache),
  `VisionCache` (perceptual-hash image response cache), `CircuitBreaker` +
  `TieredCascade` (per-provider circuit breakers with confidence-based
  quality escalation), `BudgetEnforcer` (hard daily USD spend caps,
  identified/anonymous tiers, and arbitrary per-scope envelopes),
  `LLMGate`/`CompositeLLMGate` (composable pre-flight gate chain), and
  `LLMGateway` (the orchestrator tying all of the above together).
- `LLMGatewayKitDemo` executable target showing end-to-end setup.
- Unit test suite covering all core components.
