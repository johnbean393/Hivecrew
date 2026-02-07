//
//  SkillEmbeddingService.swift
//  Hivecrew
//
//  On-device sentence embedding service for skill matching pre-filtering.
//  Uses macOS NaturalLanguage framework (NLEmbedding) to compute 512-dim
//  sentence vectors entirely on-device with zero API calls.
//

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
    
    /// Default number of top candidates to return from pre-filtering
    public static let defaultTopK = 8
    
    /// Minimum number of skills before pre-filtering activates
    /// Below this threshold, all skills are passed directly to the LLM
    public static let prefilterThreshold = 10
    
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
    
    // MARK: - Similarity
    
    /// Compute cosine similarity between two vectors.
    /// - Returns: A value between -1 and 1, where 1 means identical direction
    public func cosineSimilarity(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        
        var dotProduct: Double = 0
        var magnitudeA: Double = 0
        var magnitudeB: Double = 0
        
        for i in 0..<a.count {
            dotProduct += a[i] * b[i]
            magnitudeA += a[i] * a[i]
            magnitudeB += b[i] * b[i]
        }
        
        let magnitude = sqrt(magnitudeA) * sqrt(magnitudeB)
        guard magnitude > 0 else { return 0 }
        
        return dotProduct / magnitude
    }
    
    // MARK: - Ranking
    
    /// Rank skills by semantic similarity to a task description using cached embeddings.
    /// Returns the top-K most similar skills.
    ///
    /// - Parameters:
    ///   - skills: The skills to rank (must have cached embeddings in metadata)
    ///   - task: The task description to match against
    ///   - topK: Number of top candidates to return (default: 8)
    /// - Returns: The top-K skills sorted by descending similarity, or all skills if
    ///            embedding is unavailable or skill count is below threshold
    public func rankSkills(
        _ skills: [Skill],
        forTask task: String,
        topK: Int = SkillEmbeddingService.defaultTopK
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
        
        // Load cached embeddings for each skill and compute similarity
        var scoredSkills: [(skill: Skill, score: Double)] = []
        
        for skill in skills {
            let metadata = SkillParser.loadLocalMetadata(for: skill.name)
            
            if let embedding = metadata?.embedding {
                let score = cosineSimilarity(taskEmbedding, embedding)
                scoredSkills.append((skill: skill, score: score))
            } else {
                // No cached embedding — include with a neutral score so it's not excluded
                // This handles skills that haven't had their embedding computed yet
                scoredSkills.append((skill: skill, score: 0))
                print("SkillEmbeddingService: No cached embedding for '\(skill.name)', included with neutral score")
            }
        }
        
        // Sort by similarity descending
        scoredSkills.sort { $0.score > $1.score }
        
        // Log the ranking
        let topResults = scoredSkills.prefix(topK)
        let shortlist = topResults.map { "\($0.skill.name) (\(String(format: "%.3f", $0.score)))" }.joined(separator: ", ")
        print("SkillEmbeddingService: Pre-filtered \(skills.count) skills to top \(topK): \(shortlist)")
        
        // Return top-K
        return Array(scoredSkills.prefix(topK).map { $0.skill })
    }
    
    // MARK: - Embedding Cache Management
    
    /// Compute and cache the embedding for a skill if missing or stale.
    /// - Parameters:
    ///   - skill: The skill to compute an embedding for
    ///   - existingMetadata: The skill's current local metadata (to check/update)
    /// - Returns: Updated metadata with the embedding, or the original if computation failed
    public func ensureEmbedding(
        for skill: Skill,
        existingMetadata: SkillParser.LocalMetadata
    ) -> SkillParser.LocalMetadata {
        // Check if embedding is already computed and up-to-date
        if existingMetadata.embedding != nil,
           existingMetadata.embeddingText == skill.description {
            return existingMetadata
        }
        
        // Compute new embedding
        guard let embedding = computeEmbedding(for: skill.description) else {
            return existingMetadata
        }
        
        // Return updated metadata
        var updated = existingMetadata
        updated.embedding = embedding
        updated.embeddingText = skill.description
        
        print("SkillEmbeddingService: Computed embedding for '\(skill.name)'")
        return updated
    }
}
