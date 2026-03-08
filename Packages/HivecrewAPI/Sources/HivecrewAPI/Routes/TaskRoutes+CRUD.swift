//
//  TaskRoutes+CRUD.swift
//  HivecrewAPI
//

import Foundation
import Hummingbird
import HTTPTypes
import NIOCore

extension TaskRoutes {
    @Sendable
    func createTask(request: Request, context: APIRequestContext) async throws -> Response {
        let contentType = request.headers[.contentType] ?? ""

        var description: String = ""
        var providerName: String = ""
        var modelId: String = ""
        var uploadedFilePaths: [String] = []
        var outputDirectory: String?
        var planFirst: Bool = false
        var reasoningEnabled: Bool?
        var reasoningEffort: String?
        var mentionedSkillNames: [String] = []
        var referencedTaskIds: [String] = []
        var continuationSourceTaskId: String?
        var contextPackId: String?
        var contextSuggestionIds: [String] = []
        var contextModeOverrides: [String: String] = [:]
        var contextInlineBlocks: [String] = []
        var contextAttachmentPaths: [String] = []

        if contentType.contains("multipart/form-data") {
            let result = try await parseTaskMultipartForm(request: request)
            description = result.description
            providerName = result.providerName
            modelId = result.modelId
            uploadedFilePaths = result.filePaths
            outputDirectory = result.outputDirectory
            planFirst = result.planFirst
            reasoningEnabled = result.reasoningEnabled
            reasoningEffort = result.reasoningEffort
            mentionedSkillNames = result.mentionedSkillNames
            referencedTaskIds = result.referencedTaskIds
            continuationSourceTaskId = result.continuationSourceTaskId
        } else {
            let body = try await request.body.collect(upTo: 1024 * 1024)
            let createRequest = try makeISO8601Decoder().decode(CreateTaskRequest.self, from: body)

            description = createRequest.description
            providerName = createRequest.providerName
            modelId = createRequest.modelId
            outputDirectory = createRequest.outputDirectory
            planFirst = createRequest.planFirst ?? false
            reasoningEnabled = createRequest.reasoningEnabled
            reasoningEffort = createRequest.reasoningEffort
            mentionedSkillNames = createRequest.mentionedSkillNames ?? []
            referencedTaskIds = createRequest.referencedTaskIds ?? []
            continuationSourceTaskId = createRequest.continuationSourceTaskId
            contextPackId = createRequest.contextPackId
            contextSuggestionIds = createRequest.contextSuggestionIds ?? []
            contextModeOverrides = createRequest.contextModeOverrides ?? [:]
            contextInlineBlocks = createRequest.contextInlineBlocks ?? []
            contextAttachmentPaths = createRequest.contextAttachmentPaths ?? []
        }

        guard !description.isEmpty else {
            throw APIError.badRequest("Missing required field: description")
        }
        guard !providerName.isEmpty else {
            throw APIError.badRequest("Missing required field: providerName")
        }
        guard !modelId.isEmpty else {
            throw APIError.badRequest("Missing required field: modelId")
        }

        let task = try await serviceProvider.createTask(
            description: description,
            providerName: providerName,
            modelId: modelId,
            reasoningEnabled: reasoningEnabled,
            reasoningEffort: reasoningEffort,
            attachedFilePaths: uploadedFilePaths,
            outputDirectory: outputDirectory,
            planFirst: planFirst,
            mentionedSkillNames: mentionedSkillNames,
            referencedTaskIds: referencedTaskIds,
            continuationSourceTaskId: continuationSourceTaskId,
            contextPackId: contextPackId,
            contextSuggestionIds: contextSuggestionIds,
            contextModeOverrides: contextModeOverrides,
            contextInlineBlocks: contextInlineBlocks,
            contextAttachmentPaths: contextAttachmentPaths
        )

        return try createJSONResponse(task, status: .created)
    }

    @Sendable
    func createTaskBatch(request: Request, context: APIRequestContext) async throws -> Response {
        let contentType = request.headers[.contentType] ?? ""

        var description = ""
        var targets: [CreateTaskBatchTarget] = []
        var uploadedFilePaths: [String] = []
        var planFirst = false
        var mentionedSkillNames: [String] = []

        if contentType.contains("multipart/form-data") {
            let result = try await parseTaskBatchMultipartForm(request: request)
            description = result.description
            targets = result.targets
            uploadedFilePaths = result.filePaths
            planFirst = result.planFirst
            mentionedSkillNames = result.mentionedSkillNames
        } else {
            let body = try await request.body.collect(upTo: 1024 * 1024)
            let batchRequest = try makeISO8601Decoder().decode(CreateTaskBatchRequest.self, from: body)
            description = batchRequest.description
            targets = batchRequest.targets
            planFirst = batchRequest.planFirst ?? false
            mentionedSkillNames = batchRequest.mentionedSkillNames ?? []
        }

        guard !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw APIError.badRequest("Missing required field: description")
        }

        let expandedTargets = TaskBatchRequestSupport.expandedTargets(
            try TaskBatchRequestSupport.validatedTargets(targets)
        )

        let createdTasks = try await serviceProvider.createTaskBatch(
            description: description,
            targets: expandedTargets,
            attachedFilePaths: uploadedFilePaths,
            planFirst: planFirst,
            mentionedSkillNames: mentionedSkillNames
        )

        return try createJSONResponse(
            CreateTaskBatchResponse(tasks: createdTasks),
            status: .created
        )
    }

    @Sendable
    func listTasks(request: Request, context: APIRequestContext) async throws -> Response {
        let queryItems = parseQueryItems(from: request.uri.string)

        let statusFilter: [APITaskStatus]? = queryItems["status"].flatMap { statusString in
            statusString.split(separator: ",").compactMap { APITaskStatus(rawValue: String($0)) }
        }

        let limit = min(queryItems["limit"].flatMap { Int($0) } ?? 50, 200)
        let offset = queryItems["offset"].flatMap { Int($0) } ?? 0
        let sortBy = queryItems["sort"] ?? "createdAt"
        let order = queryItems["order"] ?? "desc"

        let response = try await serviceProvider.getTasks(
            status: statusFilter,
            limit: limit,
            offset: offset,
            sortBy: sortBy,
            order: order
        )

        return try createJSONResponse(response)
    }

    @Sendable
    func getTask(request: Request, context: APIRequestContext) async throws -> Response {
        guard let taskId = context.parameters.get("id") else {
            throw APIError.badRequest("Missing task ID")
        }

        let task = try await serviceProvider.getTask(id: taskId)
        return try createJSONResponse(task)
    }

    @Sendable
    func updateTask(request: Request, context: APIRequestContext) async throws -> Response {
        guard let taskId = context.parameters.get("id") else {
            throw APIError.badRequest("Missing task ID")
        }

        let body = try await request.body.collect(upTo: 64 * 1024)
        let updateRequest = try JSONDecoder().decode(UpdateTaskRequest.self, from: body)
        let effectiveInstructions = updateRequest.planMarkdown ?? updateRequest.instructions

        let task = try await serviceProvider.performTaskAction(
            id: taskId,
            action: updateRequest.action,
            instructions: effectiveInstructions
        )

        return try createJSONResponse(task)
    }

    @Sendable
    func deleteTask(request: Request, context: APIRequestContext) async throws -> Response {
        guard let taskId = context.parameters.get("id") else {
            throw APIError.badRequest("Missing task ID")
        }

        try await serviceProvider.deleteTask(id: taskId)
        try await fileStorage.deleteTaskFiles(taskId: taskId)
        return Response(status: .noContent)
    }
}
