# LLM Gateway Kit

[![CI](https://github.com/OrenSegal/llm-gateway-kit/actions/workflows/ci.yml/badge.svg)](https://github.com/OrenSegal/llm-gateway-kit/actions/workflows/ci.yml) [![License: MIT](https://img.shields.io/badge/license-MIT-black)](LICENSE) [![Swift](https://img.shields.io/badge/swift-5.10%2B-orange)](Package.swift)

**The LLM ops layer for Swift apps. Not another wrapper kit.**

Most "AI starter kits" for iOS give you an API client, an auth screen, a
paywall, and a chat UI. That gets an LLM feature into your app. It does
nothing to keep it affordable or reliable once real users start hitting it.

LLM Gateway Kit is the layer underneath that: **semantic and vision response
caching, tiered circuit breakers across providers, and hard cost-budget
enforcement**: the production concerns that show up the first time your AI
feature has real traffic, a flaky provider, or a user who finds the free
tier's edges.

It is deliberately *not* a wrapper kit. It has no opinion about your auth,
your paywall, or your UI. It has one job: sit between your app and whatever
LLM provider(s) you call, and make that path cheaper and more resilient.
Bring your own provider adapter, your own auth, your own paywall. LLM
Gateway Kit handles cost and reliability.

## The three pillars

### 1. Semantic + vision response caching

A plain exact-match cache only helps when a user sends the literal same
string twice. Real traffic is dominated by paraphrases, like "what should I use
up soon" vs. "what's expiring in my pantry", that an exact-match cache
always misses.

`SemanticCache` embeds each prompt and serves a cached response for any
prompt whose embedding clears a cosine-similarity threshold, so paraphrased
requests hit the cache too. `VisionCache` does the same thing for image
calls using perceptual image hashing (Hamming distance) instead of text
embeddings. Most starter kits only cache text chat and have nothing for
vision/photo-analysis calls, which are frequently the larger cost center.

Both are pluggable: you supply your own `EmbeddingProvider` and
`PerceptualHasher` implementations, so the cache works with whatever
embedding model or hashing algorithm you already use.

### 2. Tiered circuit breakers

`CircuitBreaker` is a standard closed → open → half-open breaker per
provider. `TieredCascade` chains providers into an ordered fallback list,
typically a cheap/fast primary and a stronger/pricier backup, and escalates
to the next tier when:

- the current tier's breaker is open (provider is down/degraded), or
- the call itself throws, or
- the response comes back with a confidence score below that tier's floor
  (a *quality* escalation, not just a *failure* escalation)

Most calls resolve on the cheap tier. Only the ones that actually need it
escalate, so average cost per call stays close to the cheap tier's price
while reliability tracks the expensive tier's ceiling.

### 3. Hard budget enforcement

`BudgetEnforcer` is a **pre-flight** check, not a post-hoc dashboard. It
denies a call before it happens once a daily USD cap is hit. A runaway
loop or an abusive/anonymous session cannot spend past the cap, because the
check runs before the request goes out, not after. Ships with:

- separate daily caps for identified vs. anonymous callers (anonymous
  traffic typically needs a much smaller ceiling than authenticated users)
- arbitrary per-scope envelopes (e.g. a smaller sub-budget just for vision
  calls, or per feature/task type)
- a pluggable `BudgetStore` (`UserDefaults` by default; swap in a
  server-backed store if spend needs to be authoritative across devices)

All three pillars compose through `LLMGate`/`CompositeLLMGate`, a
short-circuiting chain of pre-flight checks (budget, circuit state, your own
kill switches/entitlement checks) that keeps the "should this call even
happen" logic in one place instead of scattered across call sites.

## The result

These three patterns, running in production inside a real shipping iOS app
under real user traffic, measurably cut LLM inference cost by **40-50%**.
That's not a synthetic benchmark. It's what semantic/vision cache hits plus
a cheap-first tiered cascade actually save once traffic has the paraphrase
and repeat-query patterns real usage always has. Your mileage will vary with
your traffic shape, but the mechanism is the same regardless of which
provider(s) you're calling.

## Install

Swift Package Manager, via Xcode (File → Add Package Dependencies) or in
`Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/OrenSegal/llm-gateway-kit.git", from: "0.1.0")
]
```

## Quickstart

```swift
import LLMGatewayKit

// 1. Implement LLMProvider once per vendor you call (OpenAI, Anthropic,
//    Gemini, a self-hosted model...). LLMGatewayKit never talks to a vendor
//    API directly, only ever through this protocol.
struct MyProvider: LLMProvider {
    let identifier = "my-provider"

    func estimatedCostUSD(inputTokens: Int, outputTokens: Int) -> Double {
        Double(inputTokens) * 0.0000003 + Double(outputTokens) * 0.0000006
    }

    func send(_ request: LLMRequest) async throws -> LLMResponse {
        // Call your vendor's SDK/REST API here and map the result.
        LLMResponse(text: "...", usage: LLMUsage(inputTokens: 120, outputTokens: 40), modelID: identifier)
    }
}

// 2. Wire a tiered cascade: a cheap primary and (optionally) a stronger backup.
let cascade = TieredCascade(tiers: [
    CascadeTier(provider: MyProvider(), confidenceFloor: 0.8),
    // CascadeTier(provider: MyStrongerBackupProvider()),
])

// 3. Set a hard daily budget cap.
let budget = BudgetEnforcer(identifiedDailyCapUSD: 5.0, anonymousDailyCapUSD: 0.50)

// 4. (Optional) Add semantic caching: implement EmbeddingProvider once.
let cache = SemanticCache(embeddingProvider: MyEmbeddingProvider())

// 5. Put it together.
let gateway = LLMGateway(cascade: cascade, budget: budget, semanticCache: cache)

let response = try await gateway.complete(
    LLMRequest(prompt: "what should I use up soon"),
    isAnonymous: false
)
print(response.text)
```

See `Sources/LLMGatewayKitDemo/main.swift` for a complete, runnable example
(`swift run LLMGatewayKitDemo`) using mock providers so you can see the
cache-hit/circuit-breaker/budget behavior without any real API keys.

If your machine has `swiftly` installed and `swift build` fails at the link
step with `ld: unknown option: -no_warn_duplicate_libraries`, a standalone
swiftly toolchain is shadowing Xcode's own toolchain in `$PATH`. Use
`make build` / `make test` / `make run` (or `xcrun swift build` directly) to
force Xcode's toolchain instead.

## What this is not

- Not an auth or paywall solution. Bring your own (RevenueCat,
  StoreKit, your backend, whatever you already use).
- Not a chat UI kit. It has no SwiftUI views.
- Not tied to any single LLM vendor. The `LLMProvider` protocol is the
  only thing it depends on, and you implement it.

## License

MIT. See [LICENSE](LICENSE).
