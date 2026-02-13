import Accelerate
import Foundation

public struct CandidateScorer {
    public static func cosineSimilarity(_ lhs: [Float], _ rhs: [Float]) -> Double {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return 0 }
        var dot: Float = 0
        vDSP_dotpr(lhs, 1, rhs, 1, &dot, vDSP_Length(lhs.count))
        return Double(dot)
    }

    public static func recencyWeight(date: Date) -> Double {
        let age = Date().timeIntervalSince(date)
        return max(0, 1 - min(1, age / 864_000))
    }
}
