# LLM Gateway Kit

[![CI](https://github.com/OrenSegal/llm-gateway-kit/actions/workflows/ci.yml/badge.svg)](https://github.com/OrenSegal/llm-gateway-kit/actions/workflows/ci.yml) [![License: MIT](https://img.shields.io/badge/license-MIT-black)](LICENSE) [![Swift](https://img.shields.io/badge/swift-5.10%2B-orange)](Package.swift)

**The LLM ops layer for Swift apps. Not another wrapper kit.**

Most "AI starter kits" for iOS give you an API client, an auth screen, a
paywall, and a chat UI. That gets an LLM feature into your app. It does
nothing to keep it affordable or reliable once real users start hitting it.

LLM Gateway Kit is the layer underneath that: **semantic and vision response
caching, tiered circuit breakers across providers, and hard cost-budget
enforcement**: the problems that show up the first time your AI
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
string twice. Many requests are paraphrases, like "what should I use
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

## Where this came from

These three patterns were extracted from the LLM gateway in an iOS app that
is currently in TestFlight beta. Semantic and vision caching serve repeat and
paraphrased requests without a paid call, the tiered cascade tries a cheaper
model first and falls back when a provider fails or returns low confidence,
and the budget enforcer blocks calls once a cost cap is hit. There is no
published cost benchmark for this kit. How much it saves depends on how often
your traffic repeats itself and which provider(s) you're calling.

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

## Limitations

- **The budget cap is soft under concurrency.** `LLMGateway` checks the cap, sends the request, and records the real cost afterwards. Calls that start at the same time can all pass the check before any of them records spend, so a burst can overshoot the cap by the cost of the calls in flight.
- **The pre-flight estimate is rough.** It prices the request at the first tier's rate, counts input tokens as characters divided by 4, and assumes 256 output tokens when `maxOutputTokens` is unset. A call that escalates to a pricier tier costs more than it was checked for.
- **The default budget store is client-side.** `UserDefaultsBudgetStore` is per device and per install, and resets with the app's data. Treat it as a guard against runaway loops, not as billing enforcement; use a server-backed `BudgetStore` for that. Days roll over at midnight UTC.
- **Caches are in memory, unbounded and scanned linearly.** Nothing persists across launches, there is no size cap, and expired entries stay until you call `evictExpired()`. Each lookup compares against every entry, which is fine for hundreds of entries and slow for many thousands.
- **The semantic cache keys on the prompt text only.** It ignores `taskType`, so similar prompts sent for different tasks can share a cached answer (`VisionCache` does separate by `taskType`). The 0.92 similarity default is a starting point with no published tuning data behind it; measure it on your own traffic.

## What this is not

- Not an auth or paywall solution. Bring your own (RevenueCat,
  StoreKit, your backend, whatever you already use).
- Not a chat UI kit. It has no SwiftUI views.
- Not tied to any single LLM vendor. The `LLMProvider` protocol is the
  only thing it depends on, and you implement it.

## License

MIT. See [LICENSE](LICENSE).
