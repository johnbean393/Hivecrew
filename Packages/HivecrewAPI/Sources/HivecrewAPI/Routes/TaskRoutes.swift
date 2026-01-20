//
//  TaskRoutes.swift
//  HivecrewAPI
//
//  Routes for /api/v1/tasks
//

import Foundation
import Hummingbird
import NIOCore
import HTTPTypes

/// Register task routes
public final class TaskRoutes: Sendable {
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
        let tasks = router.group("tasks")
        
        // POST /tasks - Create task
        tasks.post(use: createTask)
        
        // GET /tasks - List tasks
        tasks.get(use: listTasks)
        
        // GET /tasks/:id - Get task
        tasks.get(":id", use: getTask)
        
        // PATCH /tasks/:id - Update task (actions)
        tasks.patch(":id", use: updateTask)
        
        // DELETE /tasks/:id - Delete task
        tasks.delete(":id", use: deleteTask)
        
        // GET /tasks/:id/files - List task files
        tasks.get(":id/files", use: listTaskFiles)
        
        // GET /tasks/:id/files/:filename - Download file
        tasks.get(":id/files/:filename", use: downloadFile)
        
        // Schedule endpoints
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
    func createTask(request: Request, context: APIRequestContext) async throws -> Response {
        let contentType = request.headers[.contentType] ?? ""
        
        var description: String = ""
        var providerName: String = ""
        var modelId: String = ""
        // Note: priority is parsed but not currently used in task creation
        var uploadedFilePaths: [String] = []
        var outputDirectory: String?
        
        if contentType.contains("multipart/form-data") {
            // Handle multipart form data with file uploads
            let result = try await parseMultipartForm(request: request, context: context)
            description = result.description
            providerName = result.providerName
            modelId = result.modelId
            uploadedFilePaths = result.filePaths
            outputDirectory = result.outputDirectory
        } else {
            // Handle JSON request
            let body = try await request.body.collect(upTo: 1024 * 1024) // 1MB limit for JSON
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let createRequest = try decoder.decode(CreateTaskRequest.self, from: body)
            
            description = createRequest.description
            providerName = createRequest.providerName
            modelId = createRequest.modelId
            outputDirectory = createRequest.outputDirectory
        }
        
        // Validate required fields
        guard !description.isEmpty else {
            throw APIError.badRequest("Missing required field: description")
        }
        guard !providerName.isEmpty else {
            throw APIError.badRequest("Missing required field: providerName")
        }
        guard !modelId.isEmpty else {
            throw APIError.badRequest("Missing required field: modelId")
        }
        
        // Create the task
        let task = try await serviceProvider.createTask(
            description: description,
            providerName: providerName,
            modelId: modelId,
            attachedFilePaths: uploadedFilePaths,
            outputDirectory: outputDirectory
        )
        
        return try createJSONResponse(task, status: .created)
    }
    
    @Sendable
    func listTasks(request: Request, context: APIRequestContext) async throws -> Response {
        // Parse query parameters
        let uri = request.uri
        let queryItems = parseQueryItems(from: uri.string)
        
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
        
        let body = try await request.body.collect(upTo: 64 * 1024) // 64KB limit
        let decoder = JSONDecoder()
        let updateRequest = try decoder.decode(UpdateTaskRequest.self, from: body)
        
        let task = try await serviceProvider.performTaskAction(
            id: taskId,
            action: updateRequest.action,
            instructions: updateRequest.instructions
        )
        
        return try createJSONResponse(task)
    }
    
    @Sendable
    func deleteTask(request: Request, context: APIRequestContext) async throws -> Response {
        guard let taskId = context.parameters.get("id") else {
            throw APIError.badRequest("Missing task ID")
        }
        
        try await serviceProvider.deleteTask(id: taskId)
        
        // Also cleanup files
        try await fileStorage.deleteTaskFiles(taskId: taskId)
        
        return Response(status: .noContent)
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
        
        // Parse query parameter for file type
        let uri = request.uri
        let queryItems = parseQueryItems(from: uri.string)
        let isInput = queryItems["type"] == "input"
        
        let (data, mimeType) = try await fileStorage.getFileData(
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
    
    @Sendable
    func createScheduledTask(request: Request, context: APIRequestContext) async throws -> Response {
        let body = try await request.body.collect(upTo: 1024 * 1024) // 1MB limit
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let createRequest = try decoder.decode(CreateScheduleRequest.self, from: body)
        
        // Validate
        guard !createRequest.title.isEmpty else {
            throw APIError.badRequest("Missing required field: title")
        }
        guard !createRequest.description.isEmpty else {
            throw APIError.badRequest("Missing required field: description")
        }
        guard !createRequest.providerName.isEmpty else {
            throw APIError.badRequest("Missing required field: providerName")
        }
        guard !createRequest.modelId.isEmpty else {
            throw APIError.badRequest("Missing required field: modelId")
        }
        
        // Validate schedule - need either scheduledAt (one-time) or recurrence (recurring)
        if createRequest.schedule.scheduledAt == nil && createRequest.schedule.recurrence == nil {
            throw APIError.badRequest("Schedule must include either scheduledAt (one-time) or recurrence (recurring)")
        }
        
        if let scheduledAt = createRequest.schedule.scheduledAt, scheduledAt < Date() {
            throw APIError.badRequest("scheduledAt must be in the future")
        }
        
        let scheduledTask = try await serviceProvider.createScheduledTask(
            title: createRequest.title,
            description: createRequest.description,
            providerName: createRequest.providerName,
            modelId: createRequest.modelId,
            outputDirectory: createRequest.outputDirectory,
            schedule: createRequest.schedule
        )
        
        return try createJSONResponse(scheduledTask, status: .created)
    }
    
    @Sendable
    func listScheduledTasks(request: Request, context: APIRequestContext) async throws -> Response {
        let uri = request.uri
        let queryItems = parseQueryItems(from: uri.string)
        
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
        
        let body = try await request.body.collect(upTo: 64 * 1024) // 64KB limit
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let updateRequest = try decoder.decode(UpdateScheduleRequest.self, from: body)
        
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
    
    // MARK: - Helpers
    
    private struct MultipartFormResult {
        let description: String
        let providerName: String
        let modelId: String
        let priority: APITaskPriority
        let filePaths: [String]
        let outputDirectory: String?
    }
    
    private func parseMultipartForm(request: Request, context: APIRequestContext) async throws -> MultipartFormResult {
        // For multipart form data, we need to parse the boundary and parts
        // This is a simplified implementation - Hummingbird has multipart support via plugins
        
        var description = ""
        var providerName = ""
        var modelId = ""
        var priority = APITaskPriority.normal
        var filePaths: [String] = []
        var outputDirectory: String?
        
        // Generate a task ID for file storage
        let taskId = UUID().uuidString
        
        // Collect the body with size limit
        let bodyData = try await request.body.collect(upTo: maxTotalUploadSize)
        
        // Get content type header to extract boundary
        guard let contentTypeHeader = request.headers[.contentType] else {
            throw APIError.badRequest("Missing Content-Type header")
        }
        
        let contentType = String(contentTypeHeader)
        guard let boundaryRange = contentType.range(of: "boundary=") else {
            throw APIError.badRequest("Missing boundary in Content-Type")
        }
        
        var boundary = String(contentType[boundaryRange.upperBound...])
        // Remove quotes if present
        if boundary.hasPrefix("\"") && boundary.hasSuffix("\"") {
            boundary = String(boundary.dropFirst().dropLast())
        }
        
        // Parse multipart data
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
                } else if name == "files" {
                    // This is a file upload
                    let filename = part.filename ?? "file_\(filePaths.count)"
                    
                    // Check file size
                    if part.data.count > maxFileSize {
                        throw APIError.payloadTooLarge("File '\(filename)' exceeds maximum size of \(maxFileSize / 1024 / 1024)MB")
                    }
                    
                    // Save the file
                    let savedURL = try await fileStorage.saveUploadedFile(
                        data: part.data,
                        filename: filename,
                        taskId: taskId
                    )
                    filePaths.append(savedURL.path)
                }
            }
        }
        
        return MultipartFormResult(
            description: description,
            providerName: providerName,
            modelId: modelId,
            priority: priority,
            filePaths: filePaths,
            outputDirectory: outputDirectory
        )
    }
    
    private struct MultipartPart {
        let name: String?
        let filename: String?
        let data: Data
    }
    
    private func parseMultipartData(data: Data, boundary: String) -> [MultipartPart] {
        var parts: [MultipartPart] = []
        let boundaryData = "--\(boundary)".data(using: .utf8)!
        let endBoundaryData = "--\(boundary)--".data(using: .utf8)!
        let crlfData = "\r\n".data(using: .utf8)!
        let doubleCrlfData = "\r\n\r\n".data(using: .utf8)!
        
        var currentIndex = data.startIndex
        
        while currentIndex < data.endIndex {
            // Find next boundary
            guard let boundaryRange = data.range(of: boundaryData, in: currentIndex..<data.endIndex) else {
                break
            }
            
            // Move past boundary and CRLF
            var partStart = boundaryRange.upperBound
            if data[partStart..<min(partStart + 2, data.endIndex)] == crlfData {
                partStart = data.index(partStart, offsetBy: 2)
            }
            
            // Check for end boundary
            if data[boundaryRange.lowerBound..<min(data.index(boundaryRange.lowerBound, offsetBy: endBoundaryData.count), data.endIndex)] == endBoundaryData {
                break
            }
            
            // Find headers/body separator
            guard let headerEndRange = data.range(of: doubleCrlfData, in: partStart..<data.endIndex) else {
                currentIndex = boundaryRange.upperBound
                continue
            }
            
            // Parse headers
            let headersData = data[partStart..<headerEndRange.lowerBound]
            let headersString = String(data: headersData, encoding: .utf8) ?? ""
            
            var name: String?
            var filename: String?
            
            for line in headersString.split(separator: "\r\n") {
                let lineStr = String(line)
                if lineStr.lowercased().hasPrefix("content-disposition:") {
                    // Parse Content-Disposition header
                    if let nameMatch = lineStr.range(of: "name=\"") {
                        let start = nameMatch.upperBound
                        if let end = lineStr[start...].firstIndex(of: "\"") {
                            name = String(lineStr[start..<end])
                        }
                    }
                    if let filenameMatch = lineStr.range(of: "filename=\"") {
                        let start = filenameMatch.upperBound
                        if let end = lineStr[start...].firstIndex(of: "\"") {
                            filename = String(lineStr[start..<end])
                        }
                    }
                }
            }
            
            // Find part end (next boundary)
            let bodyStart = headerEndRange.upperBound
            var bodyEnd = data.endIndex
            
            if let nextBoundaryRange = data.range(of: boundaryData, in: bodyStart..<data.endIndex) {
                // Remove trailing CRLF before boundary
                bodyEnd = nextBoundaryRange.lowerBound
                if bodyEnd > bodyStart && data[data.index(bodyEnd, offsetBy: -2)..<bodyEnd] == crlfData {
                    bodyEnd = data.index(bodyEnd, offsetBy: -2)
                }
            }
            
            let partData = data[bodyStart..<bodyEnd]
            parts.append(MultipartPart(name: name, filename: filename, data: Data(partData)))
            
            currentIndex = bodyEnd
        }
        
        return parts
    }
    
    private func parseQueryItems(from urlString: String) -> [String: String] {
        var items: [String: String] = [:]
        
        guard let queryStart = urlString.firstIndex(of: "?") else {
            return items
        }
        
        let queryString = String(urlString[urlString.index(after: queryStart)...])
        let pairs = queryString.split(separator: "&")
        
        for pair in pairs {
            let keyValue = pair.split(separator: "=", maxSplits: 1)
            if keyValue.count == 2 {
                let key = String(keyValue[0]).removingPercentEncoding ?? String(keyValue[0])
                let value = String(keyValue[1]).removingPercentEncoding ?? String(keyValue[1])
                items[key] = value
            }
        }
        
        return items
    }
    
    private func createJSONResponse<T: Encodable>(_ value: T, status: HTTPResponse.Status = .ok) throws -> Response {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        
        var headers = HTTPFields()
        headers[.contentType] = "application/json"
        
        return Response(
            status: status,
            headers: headers,
            body: .init(byteBuffer: ByteBuffer(data: data))
        )
    }
}
