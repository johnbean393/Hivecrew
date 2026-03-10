//
//  TaskRoutes+Interactions.swift
//  HivecrewAPI
//

import Foundation
import Hummingbird
import HTTPTypes
import NIOCore

extension TaskRoutes {
    @Sendable
    func getScreenshot(request: Request, context: APIRequestContext) async throws -> Response {
        guard let taskId = context.parameters.get("id") else {
            throw APIError.badRequest("Missing task ID")
        }

        guard let (data, mimeType) = try await serviceProvider.getTaskScreenshot(id: taskId) else {
            throw APIError.notFound("No screenshot available for task '\(taskId)'")
        }

        var headers = HTTPFields()
        headers[.contentType] = mimeType
        headers[.contentLength] = "\(data.count)"
        headers[.cacheControl] = "no-cache"

        return Response(
            status: .ok,
            headers: headers,
            body: .init(byteBuffer: ByteBuffer(data: data))
        )
    }

    @Sendable
    func getTaskActivity(request: Request, context: APIRequestContext) async throws -> Response {
        guard let taskId = context.parameters.get("id") else {
            throw APIError.badRequest("Missing task ID")
        }

        let queryItems = parseQueryItems(from: request.uri.string)
        let since = queryItems["since"].flatMap(Int.init) ?? 0
        let activity = try await serviceProvider.getTaskActivity(id: taskId, since: since)
        return try createJSONResponse(activity)
    }

    @Sendable
    func getPendingQuestion(request: Request, context: APIRequestContext) async throws -> Response {
        guard let taskId = context.parameters.get("id") else {
            throw APIError.badRequest("Missing task ID")
        }

        guard let question = try await serviceProvider.getPendingQuestion(taskId: taskId) else {
            return Response(status: .noContent)
        }

        return try createJSONResponse(question)
    }

    @Sendable
    func answerQuestion(request: Request, context: APIRequestContext) async throws -> Response {
        guard let taskId = context.parameters.get("id") else {
            throw APIError.badRequest("Missing task ID")
        }

        let body = try await request.body.collect(upTo: 64 * 1024)
        let answerRequest = try makeISO8601Decoder().decode(AnswerQuestionRequest.self, from: body)

        try await serviceProvider.answerQuestion(
            taskId: taskId,
            questionId: answerRequest.questionId,
            answer: answerRequest.answer
        )

        return Response(status: .noContent)
    }

    @Sendable
    func getPendingPermission(request: Request, context: APIRequestContext) async throws -> Response {
        guard let taskId = context.parameters.get("id") else {
            throw APIError.badRequest("Missing task ID")
        }

        guard let permission = try await serviceProvider.getPendingPermission(taskId: taskId) else {
            return Response(status: .noContent)
        }

        return try createJSONResponse(permission)
    }

    @Sendable
    func respondToPermission(request: Request, context: APIRequestContext) async throws -> Response {
        guard let taskId = context.parameters.get("id") else {
            throw APIError.badRequest("Missing task ID")
        }

        let body = try await request.body.collect(upTo: 64 * 1024)
        let respondRequest = try makeISO8601Decoder().decode(RespondToPermissionRequest.self, from: body)

        try await serviceProvider.respondToPermission(
            taskId: taskId,
            permissionId: respondRequest.permissionId,
            approved: respondRequest.approved
        )

        return Response(status: .noContent)
    }

    @Sendable
    func getTaskWritebackReview(request: Request, context: APIRequestContext) async throws -> Response {
        guard let taskId = context.parameters.get("id") else {
            throw APIError.badRequest("Missing task ID")
        }

        guard let review = try await serviceProvider.getTaskWritebackReview(id: taskId) else {
            return Response(status: .noContent)
        }

        return try createJSONResponse(review)
    }

    @Sendable
    func listTaskFiles(request: Request, context: APIRequestContext) async throws -> Response {
        guard let taskId = context.parameters.get("id") else {
            throw APIError.badRequest("Missing task ID")
        }

        let filesResponse = try await serviceProvider.getTaskFiles(id: taskId)
        return try createJSONResponse(filesResponse)
    }

    @Sendable
    func downloadFile(request: Request, context: APIRequestContext) async throws -> Response {
        guard let taskId = context.parameters.get("id") else {
            throw APIError.badRequest("Missing task ID")
        }
        guard let filename = context.parameters.get("filename") else {
            throw APIError.badRequest("Missing filename")
        }

        let queryItems = parseQueryItems(from: request.uri.string)
        let isInput = queryItems["type"] == "input"

        let (data, mimeType) = try await serviceProvider.getTaskFileData(
            taskId: taskId,
            filename: filename,
            isInput: isInput
        )

        var headers = HTTPFields()
        headers[.contentType] = mimeType
        headers[.contentDisposition] = "attachment; filename=\"\(filename)\""
        headers[.contentLength] = "\(data.count)"

        return Response(
            status: .ok,
            headers: headers,
            body: .init(byteBuffer: ByteBuffer(data: data))
        )
    }
}
