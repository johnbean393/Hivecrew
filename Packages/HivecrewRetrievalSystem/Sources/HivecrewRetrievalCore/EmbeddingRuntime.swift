import Accelerate
import Foundation
import NaturalLanguage

public actor EmbeddingRuntime {
    public enum Backend: String, Sendable {
        case amxCPU
        case gpu
        case fallbackHashing
    }

    private let sentenceEmbedding = NLEmbedding.sentenceEmbedding(for: .english)
    private let vectorLength = 256

    public init() {}

    public func embed(texts: [String]) throws -> ([[Float]], Backend) {
        if texts.isEmpty { return ([], .fallbackHashing) }
        let backend: Backend
        if texts.count >= 16 {
            backend = .gpu
        } else if sentenceEmbedding != nil {
            backend = .amxCPU
        } else {
            backend = .fallbackHashing
        }
        let vectors = texts.map { text in
            switch backend {
            case .amxCPU, .gpu:
                if let sentenceEmbedding, let value = sentenceEmbedding.vector(for: text) {
                    return normalize(vector: value.map(Float.init), targetLength: vectorLength)
                }
                return fallbackVector(for: text)
            case .fallbackHashing:
                return fallbackVector(for: text)
            }
        }
        return (vectors, backend)
    }

    private func fallbackVector(for text: String) -> [Float] {
        var vector = Array(repeating: Float(0), count: vectorLength)
        for (offset, scalar) in text.unicodeScalars.enumerated() {
            vector[offset % vectorLength] += Float((Int(scalar.value) % 97) + 1)
        }
        return normalize(vector: vector, targetLength: vectorLength)
    }

    private func normalize(vector: [Float], targetLength: Int) -> [Float] {
        var resized = vector
        if resized.count < targetLength {
            resized.append(contentsOf: Array(repeating: 0, count: targetLength - resized.count))
        } else if resized.count > targetLength {
            resized = Array(resized.prefix(targetLength))
        }
        var output = resized
        var sumSq: Float = 0
        vDSP_svesq(output, 1, &sumSq, vDSP_Length(output.count))
        let denominator = max(sqrt(sumSq), 0.0001)
        var divisor = denominator
        vDSP_vsdiv(output, 1, &divisor, &output, 1, vDSP_Length(output.count))
        return output
    }
}
