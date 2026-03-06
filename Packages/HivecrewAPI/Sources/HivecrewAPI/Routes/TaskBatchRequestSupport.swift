//
//  TaskBatchRequestSupport.swift
//  HivecrewAPI
//
//  Validation and expansion helpers for prompt-bar batch task creation.
//

import Foundation

enum TaskBatchRequestSupport {

    static let allowedCopyCountRange = 1...8

    static func validatedTargets(_ targets: [CreateTaskBatchTarget]) throws -> [CreateTaskBatchTarget] {
        guard !targets.isEmpty else {
            throw APIError.badRequest("Missing required field: targets")
        }

        return try targets.enumerated().map { index, target in
            let providerId = target.providerId.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !providerId.isEmpty else {
                throw APIError.badRequest("Missing providerId for targets[\(index)]")
            }

            let modelId = target.modelId.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !modelId.isEmpty else {
                throw APIError.badRequest("Missing modelId for targets[\(index)]")
            }

            guard allowedCopyCountRange.contains(target.copyCount) else {
                throw APIError.badRequest("Invalid copyCount for targets[\(index)]")
            }

            let reasoningEffort = target.reasoningEffort?
                .trimmingCharacters(in: .whitespacesAndNewlines)

            return CreateTaskBatchTarget(
                providerId: providerId,
                modelId: modelId,
                copyCount: target.copyCount,
                reasoningEnabled: target.reasoningEnabled,
                reasoningEffort: reasoningEffort?.isEmpty == true ? nil : reasoningEffort
            )
        }
    }

    static func expandedTargets(_ validatedTargets: [CreateTaskBatchTarget]) -> [CreateTaskBatchTarget] {
        validatedTargets.flatMap { target in
            Array(
                repeating: CreateTaskBatchTarget(
                    providerId: target.providerId,
                    modelId: target.modelId,
                    copyCount: 1,
                    reasoningEnabled: target.reasoningEnabled,
                    reasoningEffort: target.reasoningEffort
                ),
                count: target.copyCount
            )
        }
    }
}
