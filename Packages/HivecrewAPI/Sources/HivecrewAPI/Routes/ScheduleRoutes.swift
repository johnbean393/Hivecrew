//
//  ScheduleRoutes.swift
//  HivecrewAPI
//
//  Routes for /api/v1/schedules
//

import Foundation
import Hummingbird
import NIOCore
import HTTPTypes

/// Register schedule routes for managing scheduled/recurring tasks.
public final class ScheduleRoutes: Sendable {
    let serviceProvider: APIServiceProvider
    let fileStorage: TaskFileStorage
    let maxFileSize: Int
    let maxTotalUploadSize: Int
    
    public init(
        serviceProvider: APIServiceProvider,
        fileStorage: TaskFileStorage,
        maxFileSize: Int = 100 * 1024 * 1024,
        maxTotalUploadSize: Int = 500 * 1024 * 1024
    ) {
        self.serviceProvider = serviceProvider
        self.fileStorage = fileStorage
        self.maxFileSize = maxFileSize
        self.maxTotalUploadSize = maxTotalUploadSize
    }
    
    public func register(with router: any RouterMethods<APIRequestContext>) {
        let schedules = router.group("schedules")
        
        // POST /schedules - Create scheduled task
        schedules.post(use: createScheduledTask)
        
        // GET /schedules - List scheduled tasks
        schedules.get(use: listScheduledTasks)
        
        // GET /schedules/:id - Get scheduled task
        schedules.get(":id", use: getScheduledTask)
        
        // PATCH /schedules/:id - Update scheduled task
        schedules.patch(":id", use: updateScheduledTask)
        
        // DELETE /schedules/:id - Delete scheduled task
        schedules.delete(":id", use: deleteScheduledTask)
        
        // POST /schedules/:id/run - Run scheduled task now
        schedules.post(":id/run", use: runScheduledTaskNow)
    }
    
    // MARK: - Route Handlers
    
    @Sendable
    func createScheduledTask(request: Request, context: APIRequestContext) async throws -> Response {
        let contentType = request.headers[.contentType] ?? ""
        
        var title: String = ""
        var description: String = ""
        var providerName: String = ""
        var modelId: String = ""
        var outputDirectory: String?
        var schedule: APISchedule?
        var uploadedFilePaths: [String] = []
        
        if contentType.contains("multipart/form-data") {
            let result = try await parseScheduleMultipartForm(request: request)
            title = result.title
            description = result.description
            providerName = result.providerName
            modelId = result.modelId
            outputDirectory = result.outputDirectory
            schedule = result.schedule
            uploadedFilePaths = result.filePaths
        } else {
            let body = try await request.body.collect(upTo: 1024 * 1024)
            let createRequest = try makeISO8601Decoder().decode(CreateScheduleRequest.self, from: body)
            
            title = createRequest.title
            description = createRequest.description
            providerName = createRequest.providerName
            modelId = createRequest.modelId
            outputDirectory = createRequest.outputDirectory
            schedule = createRequest.schedule
        }
        
        // Validate required fields
        guard !title.isEmpty else {
            throw APIError.badRequest("Missing required field: title")
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
        guard let schedule = schedule else {
            throw APIError.badRequest("Missing required field: schedule")
        }
        
        // Validate schedule — need either scheduledAt (one-time) or recurrence (recurring)
        if schedule.scheduledAt == nil && schedule.recurrence == nil {
            throw APIError.badRequest("Schedule must include either scheduledAt (one-time) or recurrence (recurring)")
        }
        if let scheduledAt = schedule.scheduledAt, scheduledAt < Date() {
            throw APIError.badRequest("scheduledAt must be in the future")
        }
        
        let scheduledTask = try await serviceProvider.createScheduledTask(
            title: title,
            description: description,
            providerName: providerName,
            modelId: modelId,
            attachedFilePaths: uploadedFilePaths,
            outputDirectory: outputDirectory,
            schedule: schedule
        )
        
        return try createJSONResponse(scheduledTask, status: .created)
    }
    
    @Sendable
    func listScheduledTasks(request: Request, context: APIRequestContext) async throws -> Response {
        let queryItems = parseQueryItems(from: request.uri.string)
        
        let limit = min(queryItems["limit"].flatMap { Int($0) } ?? 50, 200)
        let offset = queryItems["offset"].flatMap { Int($0) } ?? 0
        
        let response = try await serviceProvider.getScheduledTasks(
            limit: limit,
            offset: offset
        )
        
        return try createJSONResponse(response)
    }
    
    @Sendable
    func getScheduledTask(request: Request, context: APIRequestContext) async throws -> Response {
        guard let scheduleId = context.parameters.get("id") else {
            throw APIError.badRequest("Missing schedule ID")
        }
        
        let scheduledTask = try await serviceProvider.getScheduledTask(id: scheduleId)
        return try createJSONResponse(scheduledTask)
    }
    
    @Sendable
    func updateScheduledTask(request: Request, context: APIRequestContext) async throws -> Response {
        guard let scheduleId = context.parameters.get("id") else {
            throw APIError.badRequest("Missing schedule ID")
        }
        
        let body = try await request.body.collect(upTo: 64 * 1024)
        let updateRequest = try makeISO8601Decoder().decode(UpdateScheduleRequest.self, from: body)
        
        // Validate scheduled time if provided
        if let scheduledAt = updateRequest.scheduledAt, scheduledAt < Date() {
            throw APIError.badRequest("scheduledAt must be in the future")
        }
        
        let scheduledTask = try await serviceProvider.updateScheduledTask(
            id: scheduleId,
            request: updateRequest
        )
        
        return try createJSONResponse(scheduledTask)
    }
    
    @Sendable
    func deleteScheduledTask(request: Request, context: APIRequestContext) async throws -> Response {
        guard let scheduleId = context.parameters.get("id") else {
            throw APIError.badRequest("Missing schedule ID")
        }
        
        try await serviceProvider.deleteScheduledTask(id: scheduleId)
        return Response(status: .noContent)
    }
    
    @Sendable
    func runScheduledTaskNow(request: Request, context: APIRequestContext) async throws -> Response {
        guard let scheduleId = context.parameters.get("id") else {
            throw APIError.badRequest("Missing schedule ID")
        }
        
        let task = try await serviceProvider.runScheduledTaskNow(id: scheduleId)
        return try createJSONResponse(task)
    }
    
    // MARK: - Multipart Parsing
    
    private struct ScheduleMultipartFormResult {
        let title: String
        let description: String
        let providerName: String
        let modelId: String
        let outputDirectory: String?
        let schedule: APISchedule?
        let filePaths: [String]
    }
    
    private func parseScheduleMultipartForm(request: Request) async throws -> ScheduleMultipartFormResult {
        var title = ""
        var description = ""
        var providerName = ""
        var modelId = ""
        var outputDirectory: String?
        var scheduleJSON: String?
        var filePaths: [String] = []
        
        let scheduleId = UUID().uuidString
        let bodyData = try await request.body.collect(upTo: maxTotalUploadSize)
        let boundary = try extractMultipartBoundary(from: request)
        let parts = parseMultipartData(data: Data(buffer: bodyData), boundary: boundary)
        
        for part in parts {
            if let name = part.name {
                switch name {
                case "title":
                    title = String(data: part.data, encoding: .utf8) ?? ""
                case "description":
                    description = String(data: part.data, encoding: .utf8) ?? ""
                case "providerName":
                    providerName = String(data: part.data, encoding: .utf8) ?? ""
                case "modelId":
                    modelId = String(data: part.data, encoding: .utf8) ?? ""
                case "outputDirectory":
                    outputDirectory = String(data: part.data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                case "schedule":
                    scheduleJSON = String(data: part.data, encoding: .utf8)
                case "files":
                    let filename = part.filename ?? "file_\(filePaths.count)"
                    if part.data.count > maxFileSize {
                        throw APIError.payloadTooLarge("File '\(filename)' exceeds maximum size of \(maxFileSize / 1024 / 1024)MB")
                    }
                    let savedURL = try await fileStorage.saveUploadedFile(
                        data: part.data,
                        filename: filename,
                        taskId: scheduleId
                    )
                    filePaths.append(savedURL.path)
                default:
                    break
                }
            }
        }
        
        // Parse schedule JSON
        var schedule: APISchedule?
        if let scheduleJSON = scheduleJSON, let scheduleData = scheduleJSON.data(using: .utf8) {
            schedule = try? makeISO8601Decoder().decode(APISchedule.self, from: scheduleData)
        }
        
        return ScheduleMultipartFormResult(
            title: title,
            description: description,
            providerName: providerName,
            modelId: modelId,
            outputDirectory: outputDirectory,
            schedule: schedule,
            filePaths: filePaths
        )
    }
}
