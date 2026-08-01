import Foundation

/// Token usage for a single LLM call. Providers report whatever they have;
/// unknown fields default to zero rather than throwing, so a partial usage
/// payload from a provider still lets the gateway keep a conservative cost
/// estimate instead of losing accounting entirely.
public struct LLMUsage: Sendable, Equatable {
    public let inputTokens: Int
    public let outputTokens: Int
    /// "Thinking"/reasoning tokens some providers bill at the output rate.
    /// Callers that don't have this concept can leave it at zero.
    public let reasoningTokens: Int

    public init(inputTokens: Int, outputTokens: Int, reasoningTokens: Int = 0) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.reasoningTokens = reasoningTokens
    }

    public var billedOutputTokens: Int { outputTokens + reasoningTokens }
}

/// A single LLM request. `image` is optional so the same request type covers
/// both text and vision calls — a provider that only does text can ignore it.
public struct LLMRequest: Sendable, Equatable {
    public let prompt: String
    public let image: Data?
    public let taskType: String
    public let maxOutputTokens: Int?

    public init(prompt: String, image: Data? = nil, taskType: String = "default", maxOutputTokens: Int? = nil) {
        self.prompt = prompt
        self.image = image
        self.taskType = taskType
        self.maxOutputTokens = maxOutputTokens
    }
}

/// What a provider call returns. `confidence` is optional — providers that
/// don't emit a calibrated confidence signal (most text completion APIs)
/// leave it `nil`; providers that do (e.g. structured vision extraction with
/// per-item confidence) populate it so the tiered cascade can use it as a
/// quality-escalation signal.
public struct LLMResponse: Sendable, Equatable {
    public let text: String
    public let usage: LLMUsage
    public let confidence: Double?
    public let modelID: String

    public init(text: String, usage: LLMUsage, confidence: Double? = nil, modelID: String) {
        self.text = text
        self.usage = usage
        self.confidence = confidence
        self.modelID = modelID
    }
}

/// The seam a buyer implements once per LLM vendor (OpenAI, Anthropic,
/// Gemini, a self-hosted model, whatever). LLMGatewayKit never talks to a
/// vendor API directly — it only ever calls through this protocol, so the
/// caching/circuit-breaker/budget layers are provider-agnostic.
public protocol LLMProvider: Sendable {
    /// Stable identifier used in telemetry and circuit-breaker bookkeeping.
    var identifier: String { get }

    /// Approximate USD cost per the given token counts, at this provider's
    /// current pricing. Used for budget pre-flight checks (an *estimate*
    /// before the call) and for recording actual spend afterward.
    func estimatedCostUSD(inputTokens: Int, outputTokens: Int) -> Double

    func send(_ request: LLMRequest) async throws -> LLMResponse
}

public enum LLMGatewayError: Error, Sendable, Equatable {
    case circuitOpen(provider: String)
    case budgetExceeded(scope: String)
    case allProvidersFailed
    case gateDenied(reason: String)
}
