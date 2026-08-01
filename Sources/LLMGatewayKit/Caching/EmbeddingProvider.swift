import Foundation

/// The seam a buyer implements to plug in whatever embedding model they use
/// (OpenAI `text-embedding-3-small`, Gemini `gemini-embedding-001`, a local
/// model, etc). `SemanticCache` never calls a vendor embeddings API directly.
public protocol EmbeddingProvider: Sendable {
    /// Stable identifier for the embedding model in use. `SemanticCache`
    /// stamps every stored entry with this and refuses to compare vectors
    /// across different embedding models — two models' vectors live in
    /// incomparable spaces, so a mismatched comparison can produce a
    /// plausible-looking but meaningless similarity score.
    var modelIdentifier: String { get }

    func embed(_ text: String) async -> [Float]
}
