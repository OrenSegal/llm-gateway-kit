import Foundation

/// Token counts of one model request.
public struct TokenCounts: Codable, Sendable, Equatable {
    public var input: Int
    public var output: Int
    public var cacheRead: Int
    public var cacheWrite5m: Int
    public var cacheWrite1h: Int
    /// The part of `output` that is thinking. Not added to `total` a second time.
    public var thinking: Int

    public init(input: Int = 0, output: Int = 0, cacheRead: Int = 0, cacheWrite5m: Int = 0, cacheWrite1h: Int = 0, thinking: Int = 0) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite5m = cacheWrite5m
        self.cacheWrite1h = cacheWrite1h
        self.thinking = thinking
    }

    /// The tokens that the model received: new input, cache reads and cache writes.
    public var context: Int { input + cacheRead + cacheWrite5m + cacheWrite1h }

    public static let zero = TokenCounts()

    public var total: Int { input + output + cacheRead + cacheWrite5m + cacheWrite1h }

    public static func + (a: TokenCounts, b: TokenCounts) -> TokenCounts {
        TokenCounts(
            input: a.input + b.input,
            output: a.output + b.output,
            cacheRead: a.cacheRead + b.cacheRead,
            cacheWrite5m: a.cacheWrite5m + b.cacheWrite5m,
            cacheWrite1h: a.cacheWrite1h + b.cacheWrite1h,
            thinking: a.thinking + b.thinking
        )
    }

    public static func += (a: inout TokenCounts, b: TokenCounts) { a = a + b }
}

/// US dollars for each million tokens.
public struct ModelPrice: Codable, Sendable, Equatable {
    public var input: Double
    public var output: Double
    /// When `nil`, the table multiplier applies to `input`.
    public var cacheRead: Double?

    public init(input: Double, output: Double, cacheRead: Double? = nil) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
    }
}

/// API list prices for each model, with cache multipliers. `LLMGateway(pricing:)` uses it
/// to price each response by its model id.
public struct PricingTable: Codable, Sendable, Equatable {
    public var models: [String: ModelPrice]
    public var fallback: ModelPrice
    public var cacheReadMultiplier: Double
    public var cacheWrite5mMultiplier: Double
    public var cacheWrite1hMultiplier: Double

    public init(
        models: [String: ModelPrice], fallback: ModelPrice, cacheReadMultiplier: Double = 0.1,
        cacheWrite5mMultiplier: Double = 1.25, cacheWrite1hMultiplier: Double = 2.0
    ) {
        self.models = models
        self.fallback = fallback
        self.cacheReadMultiplier = cacheReadMultiplier
        self.cacheWrite5mMultiplier = cacheWrite5mMultiplier
        self.cacheWrite1hMultiplier = cacheWrite1hMultiplier
    }

    /// Anthropic first-party list prices, cached 2026-11-03. Override with `load(from:)`.
    public static let builtin = PricingTable(
        models: [
            "claude-fable-5-2": ModelPrice(input: 8, output: 40, cacheRead: 0.20),
            "claude-mythos-5-2": ModelPrice(input: 8, output: 40, cacheRead: 0.20),
            "claude-fable-5-1": ModelPrice(input: 10, output: 50),
            "claude-fable-5": ModelPrice(input: 10, output: 50),
            "claude-opus-5-5": ModelPrice(input: 4, output: 20, cacheRead: 0.20),
            "claude-opus-5": ModelPrice(input: 5, output: 25),
            "claude-opus-4": ModelPrice(input: 5, output: 25),
            "claude-sonnet-5-5": ModelPrice(input: 2, output: 10, cacheRead: 0.10),
            "claude-sonnet-5": ModelPrice(input: 2, output: 10),
            "claude-sonnet-4": ModelPrice(input: 3, output: 15),
            "claude-haiku-5-5": ModelPrice(input: 0.10, output: 0.50),
            "claude-haiku-4-5": ModelPrice(input: 1, output: 5),
            // OpenAI models, as listed in the open-source Orca price table (github.com/stablyai/orca), read 2026-11-16.
            // Not checked against OpenAI's own price page. Correct them with `load(from:)` when they change.
            "gpt-5": ModelPrice(input: 1.25, output: 10, cacheRead: 0.125),
            "gpt-5.2": ModelPrice(input: 1.75, output: 14, cacheRead: 0.175),
            "gpt-5.3": ModelPrice(input: 1.75, output: 14, cacheRead: 0.175),
            "gpt-5.4": ModelPrice(input: 2.5, output: 15, cacheRead: 0.25),
            "gpt-5.4-mini": ModelPrice(input: 0.75, output: 4.5, cacheRead: 0.075),
            "gpt-5.4-nano": ModelPrice(input: 0.2, output: 1.25, cacheRead: 0.02),
            "gpt-5.5": ModelPrice(input: 5, output: 30, cacheRead: 0.5),
            "gpt-5.6-sol": ModelPrice(input: 4, output: 20, cacheRead: 0.4),
            "gpt-5.6-terra": ModelPrice(input: 2, output: 12, cacheRead: 0.2),
            "gpt-5.6-luna": ModelPrice(input: 0.2, output: 1.2, cacheRead: 0.02),
            "gpt-6-astra": ModelPrice(input: 10, output: 50, cacheRead: 1),
            "gpt-6-sol": ModelPrice(input: 2, output: 10, cacheRead: 0.2),
            "gpt-6.1-sol": ModelPrice(input: 2, output: 10, cacheRead: 0.1),
            "gpt-6-luna": ModelPrice(input: 0.1, output: 0.5, cacheRead: 0.01),
        ],
        fallback: ModelPrice(input: 4, output: 20)
    )

    /// Exact id first, then the longest table key that is a prefix of the id.
    public func price(for model: String) -> ModelPrice {
        if let exact = models[model] { return exact }
        let match = models.keys.filter { model.hasPrefix($0) }.max { $0.count < $1.count }
        return match.flatMap { models[$0] } ?? fallback
    }

    /// Dollars for one cache-read token of `model`.
    public func readPrice(for model: String) -> Double {
        let p = price(for: model)
        return (p.cacheRead ?? p.input * cacheReadMultiplier) / 1_000_000
    }

    /// Dollars for one input token of `model`.
    public func inputPrice(for model: String) -> Double {
        price(for: model).input / 1_000_000
    }

    /// Cost in US dollars.
    public func cost(model: String, tokens: TokenCounts) -> Double {
        let p = price(for: model)
        let read = p.cacheRead ?? p.input * cacheReadMultiplier
        let dollars =
            Double(tokens.input) * p.input
            + Double(tokens.output) * p.output
            + Double(tokens.cacheRead) * read
            + Double(tokens.cacheWrite5m) * p.input * cacheWrite5mMultiplier
            + Double(tokens.cacheWrite1h) * p.input * cacheWrite1hMultiplier
        return dollars / 1_000_000
    }

    public static func load(from url: URL) -> PricingTable {
        guard let data = try? Data(contentsOf: url),
              let table = try? JSONDecoder().decode(PricingTable.self, from: data)
        else { return .builtin }
        return table
    }
}
