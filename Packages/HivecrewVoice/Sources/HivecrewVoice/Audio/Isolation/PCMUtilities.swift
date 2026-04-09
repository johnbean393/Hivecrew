import Foundation

enum PCMUtilities {
    static func pcm16MonoToFloat32(_ data: Data) -> [Float] {
        let sampleCount = data.count / MemoryLayout<Int16>.size
        guard sampleCount > 0 else { return [] }
        return data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return [] }
            let samples = baseAddress.assumingMemoryBound(to: Int16.self)
            return (0..<sampleCount).map { index in
                Float(samples[index]) / 32768.0
            }
        }
    }

    static func float32ToPCM16Mono(_ samples: [Float]) -> Data {
        guard !samples.isEmpty else { return Data() }
        var pcm = Data(count: samples.count * MemoryLayout<Int16>.size)
        pcm.withUnsafeMutableBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            let out = baseAddress.assumingMemoryBound(to: Int16.self)
            for (index, sample) in samples.enumerated() {
                let clipped = max(-1.0, min(1.0, sample))
                out[index] = Int16((clipped * 32767.0).rounded())
            }
        }
        return pcm
    }

    static func resampleLinear(_ samples: [Float], from sourceRate: Double, to targetRate: Double) -> [Float] {
        guard !samples.isEmpty else { return [] }
        guard abs(sourceRate - targetRate) > 0.5 else { return samples }
        let ratio = targetRate / sourceRate
        let targetCount = max(1, Int((Double(samples.count) * ratio).rounded()))
        return (0..<targetCount).map { index in
            let sourcePosition = Double(index) / ratio
            let lower = Int(sourcePosition.rounded(.down))
            let upper = min(samples.count - 1, lower + 1)
            let fraction = Float(sourcePosition - Double(lower))
            return samples[lower] * (1 - fraction) + samples[upper] * fraction
        }
    }

    static func averagePower(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sum = samples.reduce(Float.zero) { partial, sample in
            partial + (sample * sample)
        }
        return sqrt(sum / Float(samples.count))
    }

    static func normalizedAverage(_ embeddings: [[Float]]) -> [Float] {
        guard let first = embeddings.first else { return [] }
        var combined = Array(repeating: Float.zero, count: first.count)
        for embedding in embeddings where embedding.count == combined.count {
            for index in combined.indices {
                combined[index] += embedding[index]
            }
        }
        let scale = 1.0 / Float(embeddings.count)
        for index in combined.indices {
            combined[index] *= scale
        }
        return normalize(combined)
    }

    static func normalize(_ values: [Float]) -> [Float] {
        guard !values.isEmpty else { return [] }
        let magnitude = sqrt(values.reduce(Float.zero) { partial, value in
            partial + (value * value)
        })
        guard magnitude > 0.000_01 else { return values }
        return values.map { $0 / magnitude }
    }

    static func cosineDistance(_ lhs: [Float], _ rhs: [Float]) -> Float {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return 2.0 }
        let lhsNormalized = normalize(lhs)
        let rhsNormalized = normalize(rhs)
        let similarity = zip(lhsNormalized, rhsNormalized).reduce(Float.zero) { partial, pair in
            partial + (pair.0 * pair.1)
        }
        return 1 - similarity
    }

    static func scaled(_ samples: [Float], gain: Float) -> [Float] {
        guard gain != 1 else { return samples }
        return samples.map { $0 * gain }
    }

    static func silence(sampleCount: Int) -> [Float] {
        Array(repeating: 0, count: max(0, sampleCount))
    }
}
