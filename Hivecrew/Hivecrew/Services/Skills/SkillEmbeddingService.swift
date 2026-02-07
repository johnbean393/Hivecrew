//
//  SkillEmbeddingService.swift
//  Hivecrew
//
//  On-device sentence embedding service for skill matching pre-filtering.
//  Uses macOS NaturalLanguage framework (NLEmbedding) to compute 512-dim
//  sentence vectors entirely on-device with zero API calls.
//

import Accelerate
import Foundation
import NaturalLanguage
import HivecrewShared

/// Service for computing and comparing sentence embeddings for skill pre-filtering.
/// Uses `NLEmbedding.sentenceEmbedding(for: .english)` to produce 512-dimensional
/// vectors that capture semantic meaning, enabling fast cosine-similarity ranking
/// before the more expensive LLM-based skill selection.
public class SkillEmbeddingService {
    
    // MARK: - Properties
    
    /// Lazily loaded sentence embedding model
    private lazy var sentenceEmbedding: NLEmbedding? = {
        NLEmbedding.sentenceEmbedding(for: .english)
    }()
    
    /// Whether the embedding model is available on this system
    public var isAvailable: Bool {
        sentenceEmbedding != nil
    }
    
    /// Hard cap on candidates from pre-filtering (only applied for very large collections).
    /// Acts as a backstop; the relative score threshold is the primary cutoff mechanism.
    public static let hardTopK = 20
    
    /// Minimum number of skills before pre-filtering activates.
    /// Below this threshold, all skills are passed directly to the LLM.
    public static let prefilterThreshold = 25
    
    /// Relative score cutoff ratio. Skills scoring above `topScore * cutoffRatio`
    /// are kept. When scores are clustered (embedding model can't differentiate),
    /// this naturally passes most skills through. When there's genuine separation,
    /// low-scorers get cut.
    public static let relativeCutoffRatio = 0.6
    
    // MARK: - Initialization
    
    public init() {}
    
    // MARK: - Embedding Computation
    
    /// Compute a sentence embedding vector for the given text.
    /// - Parameter text: The text to embed (typically a skill description or task description)
    /// - Returns: A 512-dimensional vector, or nil if the embedding model is unavailable
    public func computeEmbedding(for text: String) -> [Double]? {
        guard let model = sentenceEmbedding else {
            print("SkillEmbeddingService: NLEmbedding sentence model unavailable")
            return nil
        }
        return model.vector(for: text)
    }
    
    // MARK: - Similarity (Accelerate / AMX)
    
    /// Compute cosine similarity between two vectors using Accelerate vDSP.
    /// On Apple Silicon, vDSP operations dispatch to the AMX coprocessor for
    /// hardware-accelerated vector math.
    /// - Returns: A value between -1 and 1, where 1 means identical direction
    public func cosineSimilarity(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        
        // vDSP.dot computes the dot product using AMX-accelerated SIMD
        let dotProduct = vDSP.dot(a, b)
        
        // vDSP.sumOfSquares computes sum of element squares via AMX
        let magnitudeA = sqrt(vDSP.sumOfSquares(a))
        let magnitudeB = sqrt(vDSP.sumOfSquares(b))
        
        let magnitude = magnitudeA * magnitudeB
        guard magnitude > 0 else { return 0 }
        
        return dotProduct / magnitude
    }
    
    // MARK: - Ranking
    
    /// Rank skills by semantic similarity to a task description using cached embeddings.
    /// Returns candidates that pass the relative score threshold, erring on the side of inclusion.
    ///
    /// The pre-filter is intentionally permissive -- its job is to cut *obvious* noise
    /// (skills with very low similarity), not to make final selection decisions (the LLM
    /// does that). It uses a **relative score threshold** as the primary cutoff:
    ///
    /// - Compute cosine similarity for all skills
    /// - Keep every skill scoring above `topScore * relativeCutoffRatio` (default 0.6)
    /// - When scores are clustered (embedding model can't differentiate), nearly all pass
    /// - When there's genuine separation, low-scorers get cut
    /// - A hard cap (`hardTopK`) prevents sending too many in extreme cases
    /// - Skills without cached embeddings are always included unconditionally
    ///
    /// Uses Accelerate vDSP for all vector math, which dispatches to the AMX coprocessor
    /// on Apple Silicon.
    ///
    /// - Parameters:
    ///   - skills: The skills to rank (should have cached embeddings in metadata)
    ///   - task: The task description to match against
    /// - Returns: Skills passing the relative threshold, or all skills if embedding is
    ///            unavailable or skill count is below threshold
    public func rankSkills(
        _ skills: [Skill],
        forTask task: String
    ) -> [Skill] {
        // Don't pre-filter small collections
        guard skills.count > Self.prefilterThreshold else {
            return skills
        }
        
        // Compute task embedding
        guard let taskEmbedding = computeEmbedding(for: task) else {
            print("SkillEmbeddingService: Failed to compute task embedding, returning all skills")
            return skills
        }
        
        // Precompute the task embedding magnitude once (via AMX-accelerated vDSP)
        let taskMagnitude = sqrt(vDSP.sumOfSquares(taskEmbedding))
        guard taskMagnitude > 0 else {
            print("SkillEmbeddingService: Task embedding has zero magnitude, returning all skills")
            return skills
        }
        
        // Separate skills into those with embeddings (scoreable) and those without (always included)
        var scoredSkills: [(skill: Skill, score: Double)] = []
        var uncachedSkills: [Skill] = []
        scoredSkills.reserveCapacity(skills.count)
        
        for skill in skills {
            let metadata = SkillParser.loadLocalMetadata(for: skill.name)
            
            if let embedding = metadata?.embedding {
                // AMX-accelerated dot product and magnitude
                let dot = vDSP.dot(taskEmbedding, embedding)
                let skillMagnitude = sqrt(vDSP.sumOfSquares(embedding))
                let denominator = taskMagnitude * skillMagnitude
                let score = denominator > 0 ? dot / denominator : 0
                scoredSkills.append((skill: skill, score: score))
            } else {
                // No cached embedding — always include to avoid silent exclusion
                uncachedSkills.append(skill)
                print("SkillEmbeddingService: No cached embedding for '\(skill.name)', included unconditionally")
            }
        }
        
        // Sort scored skills by similarity descending
        scoredSkills.sort { $0.score > $1.score }
        
        // Relative threshold: keep everything scoring above topScore * cutoffRatio.
        // When scores are clustered (e.g. 0.22-0.34), this passes nearly all through.
        // When there's genuine separation, low-scorers get cut.
        let topScore = scoredSkills.first?.score ?? 0
        let cutoff = topScore * Self.relativeCutoffRatio
        
        let aboveCutoff = scoredSkills.filter { $0.score >= cutoff }
        
        // Apply hard cap only as a backstop for very large collections
        let capped = Array(aboveCutoff.prefix(Self.hardTopK))
        
        // Combine: scored skills above threshold + all uncached skills
        var result = capped.map { $0.skill }
        result.append(contentsOf: uncachedSkills)
        
        // Log the ranking
        let keptSummary = capped.map { "\($0.skill.name) (\(String(format: "%.3f", $0.score)))" }.joined(separator: ", ")
        let cutCount = scoredSkills.count - capped.count
        let uncachedSummary = uncachedSkills.isEmpty ? "" : ", \(uncachedSkills.count) uncached"
        print("SkillEmbeddingService: Pre-filtered \(skills.count) → \(result.count) candidates (cutoff=\(String(format: "%.3f", cutoff)), cut \(cutCount) below threshold\(uncachedSummary)): \(keptSummary)")
        
        return result
    }
    
    // MARK: - Embedding Cache Management
    
    // MARK: - Embedding Text
    
    /// Build the text to embed for a skill. Combines name and description so that
    /// technical skill names (e.g. "build123d", "render-glb") contribute to the
    /// embedding vector alongside the natural-language description.
    public static func embeddingText(for skill: Skill) -> String {
        "\(skill.name): \(skill.description)"
    }
    
    /// Compute and cache the embedding for a skill if missing or stale.
    /// Embeds `"{name}: {description}"` so that technical skill names contribute
    /// to the semantic vector.
    /// - Parameters:
    ///   - skill: The skill to compute an embedding for
    ///   - existingMetadata: The skill's current local metadata (to check/update)
    /// - Returns: Updated metadata with the embedding, or the original if computation failed
    public func ensureEmbedding(
        for skill: Skill,
        existingMetadata: SkillParser.LocalMetadata
    ) -> SkillParser.LocalMetadata {
        let textToEmbed = Self.embeddingText(for: skill)
        
        // Check if embedding is already computed and up-to-date
        if existingMetadata.embedding != nil,
           existingMetadata.embeddingText == textToEmbed {
            return existingMetadata
        }
        
        // Compute new embedding (name + description combined)
        guard let embedding = computeEmbedding(for: textToEmbed) else {
            return existingMetadata
        }
        
        // Return updated metadata
        var updated = existingMetadata
        updated.embedding = embedding
        updated.embeddingText = textToEmbed
        
        print("SkillEmbeddingService: Computed embedding for '\(skill.name)'")
        return updated
    }
}
