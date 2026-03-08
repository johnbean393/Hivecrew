//
//  TaskRoutes+Multipart.swift
//  HivecrewAPI
//

import Foundation
import Hummingbird

struct TaskMultipartFormResult {
    let description: String
    let providerName: String
    let modelId: String
    let priority: APITaskPriority
    let filePaths: [String]
    let outputDirectory: String?
    let planFirst: Bool
    let reasoningEnabled: Bool?
    let reasoningEffort: String?
    let mentionedSkillNames: [String]
    let referencedTaskIds: [String]
    let continuationSourceTaskId: String?
}

struct TaskBatchMultipartFormResult {
    let description: String
    let targets: [CreateTaskBatchTarget]
    let filePaths: [String]
    let planFirst: Bool
    let mentionedSkillNames: [String]
}

extension TaskRoutes {
    func parseTaskMultipartForm(request: Request) async throws -> TaskMultipartFormResult {
        var description = ""
        var providerName = ""
        var modelId = ""
        var priority = APITaskPriority.normal
        var filePaths: [String] = []
        var outputDirectory: String?
        var planFirst = false
        var reasoningEnabled: Bool?
        var reasoningEffort: String?
        var mentionedSkillNames: [String] = []
        var referencedTaskIds: [String] = []
        var continuationSourceTaskId: String?

        let taskId = UUID().uuidString
        let bodyData = try await request.body.collect(upTo: maxTotalUploadSize)
        let boundary = try extractMultipartBoundary(from: request)
        let parts = parseMultipartData(data: Data(buffer: bodyData), boundary: boundary)

        for part in parts {
            if let name = part.name {
                if name == "description" {
                    description = String(data: part.data, encoding: .utf8) ?? ""
                } else if name == "providerName" {
                    providerName = String(data: part.data, encoding: .utf8) ?? ""
                } else if name == "modelId" {
                    modelId = String(data: part.data, encoding: .utf8) ?? ""
                } else if name == "priority" {
                    if let priorityString = String(data: part.data, encoding: .utf8),
                       let parsedPriority = APITaskPriority(rawValue: priorityString) {
                        priority = parsedPriority
                    }
                } else if name == "outputDirectory" {
                    outputDirectory = String(data: part.data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                } else if name == "planFirst" {
                    if let value = String(data: part.data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) {
                        planFirst = value == "true" || value == "1"
                    }
                } else if name == "reasoningEnabled" {
                    if let value = String(data: part.data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) {
                        reasoningEnabled = value == "true" || value == "1"
                    }
                } else if name == "reasoningEffort" {
                    reasoningEffort = String(data: part.data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                } else if name == "mentionedSkillNames" || name == "mentionedSkillNames[]" {
                    if let value = String(data: part.data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                        mentionedSkillNames.append(value)
                    }
                } else if name == "referencedTaskIds" || name == "referencedTaskIds[]" {
                    if let value = String(data: part.data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                        referencedTaskIds.append(value)
                    }
                } else if name == "continuationSourceTaskId" {
                    continuationSourceTaskId = String(data: part.data, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                } else if name == "files" {
                    let filename = part.filename ?? "file_\(filePaths.count)"
                    if part.data.count > maxFileSize {
                        throw APIError.payloadTooLarge("File '\(filename)' exceeds maximum size of \(maxFileSize / 1024 / 1024)MB")
                    }
                    let savedURL = try await fileStorage.saveUploadedFile(
                        data: part.data,
                        filename: filename,
                        taskId: taskId
                    )
                    filePaths.append(savedURL.path)
                }
            }
        }

        return TaskMultipartFormResult(
            description: description,
            providerName: providerName,
            modelId: modelId,
            priority: priority,
            filePaths: filePaths,
            outputDirectory: outputDirectory,
            planFirst: planFirst,
            reasoningEnabled: reasoningEnabled,
            reasoningEffort: reasoningEffort,
            mentionedSkillNames: mentionedSkillNames,
            referencedTaskIds: referencedTaskIds,
            continuationSourceTaskId: continuationSourceTaskId
        )
    }

    func parseTaskBatchMultipartForm(request: Request) async throws -> TaskBatchMultipartFormResult {
        var description = ""
        var targets: [CreateTaskBatchTarget] = []
        var filePaths: [String] = []
        var planFirst = false
        var mentionedSkillNames: [String] = []

        let uploadId = UUID().uuidString
        let bodyData = try await request.body.collect(upTo: maxTotalUploadSize)
        let boundary = try extractMultipartBoundary(from: request)
        let parts = parseMultipartData(data: Data(buffer: bodyData), boundary: boundary)

        for part in parts {
            guard let name = part.name else { continue }

            if name == "description" {
                description = String(data: part.data, encoding: .utf8) ?? ""
            } else if name == "targets" {
                targets = try parseTaskBatchTargets(part.data)
            } else if name == "planFirst" {
                if let value = String(data: part.data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) {
                    planFirst = value == "true" || value == "1"
                }
            } else if name == "mentionedSkillNames" || name == "mentionedSkillNames[]" {
                if let value = String(data: part.data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                    !value.isEmpty {
                    mentionedSkillNames.append(value)
                }
            } else if name == "files" {
                let filename = part.filename ?? "file_\(filePaths.count)"
                if part.data.count > maxFileSize {
                    throw APIError.payloadTooLarge(
                        "File '\(filename)' exceeds maximum size of \(maxFileSize / 1024 / 1024)MB"
                    )
                }
                let savedURL = try await fileStorage.saveUploadedFile(
                    data: part.data,
                    filename: filename,
                    taskId: uploadId
                )
                filePaths.append(savedURL.path)
            }
        }

        return TaskBatchMultipartFormResult(
            description: description,
            targets: targets,
            filePaths: filePaths,
            planFirst: planFirst,
            mentionedSkillNames: mentionedSkillNames
        )
    }

    func parseTaskBatchTargets(_ data: Data) throws -> [CreateTaskBatchTarget] {
        do {
            return try JSONDecoder().decode([CreateTaskBatchTarget].self, from: data)
        } catch {
            throw APIError.badRequest("Invalid targets payload")
        }
    }
}
