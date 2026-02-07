//
//  TaskRoutes.swift
//  HivecrewAPI
//
//  Routes for /api/v1/tasks (CRUD and file operations)
//

import Foundation
import Hummingbird
import NIOCore
import HTTPTypes

/// Register task routes for creating, listing, updating, and deleting tasks.
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
        
        // GET /tasks/:id/screenshot - Latest VM screenshot
        tasks.get(":id/screenshot", use: getScreenshot)
        
        // GET /tasks/:id/question - Pending agent question
        tasks.get(":id/question", use: getPendingQuestion)
        
        // POST /tasks/:id/question/answer - Answer agent question
        tasks.post(":id/question/answer", use: answerQuestion)
        
        // GET /tasks/:id/permission - Pending permission request
        tasks.get(":id/permission", use: getPendingPermission)
        
        // POST /tasks/:id/permission/respond - Respond to permission request
        tasks.post(":id/permission/respond", use: respondToPermission)
        
        // GET /tasks/:id/activity - Poll for activity events
        tasks.get(":id/activity", use: getTaskActivity)
        
        // GET /tasks/:id/files - List task files
        tasks.get(":id/files", use: listTaskFiles)
        
        // GET /tasks/:id/files/:filename - Download file
        tasks.get(":id/files/:filename", use: downloadFile)
    }
    
    // MARK: - Task CRUD
    
    @Sendable
    func createTask(request: Request, context: APIRequestContext) async throws -> Response {
        let contentType = request.headers[.contentType] ?? ""
        
        var description: String = ""
        var providerName: String = ""
        var modelId: String = ""
        // Note: priority is parsed but not currently used in task creation
        var uploadedFilePaths: [String] = []
        var outputDirectory: String?
        var planFirst: Bool = false
        
        if contentType.contains("multipart/form-data") {
            let result = try await parseTaskMultipartForm(request: request)
            description = result.description
            providerName = result.providerName
            modelId = result.modelId
            uploadedFilePaths = result.filePaths
            outputDirectory = result.outputDirectory
            planFirst = result.planFirst
        } else {
            let body = try await request.body.collect(upTo: 1024 * 1024)
            let createRequest = try makeISO8601Decoder().decode(CreateTaskRequest.self, from: body)
            
            description = createRequest.description
            providerName = createRequest.providerName
            modelId = createRequest.modelId
            outputDirectory = createRequest.outputDirectory
            planFirst = createRequest.planFirst ?? false
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
        
        let task = try await serviceProvider.createTask(
            description: description,
            providerName: providerName,
            modelId: modelId,
            attachedFilePaths: uploadedFilePaths,
            outputDirectory: outputDirectory,
            planFirst: planFirst
        )
        
        return try createJSONResponse(task, status: .created)
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
        
        // For editPlan, pass planMarkdown through the instructions parameter;
        // otherwise use the regular instructions field.
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
        
        // Also cleanup files
        try await fileStorage.deleteTaskFiles(taskId: taskId)
        
        return Response(status: .noContent)
    }
    
    // MARK: - Screenshot
    
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
    
    // MARK: - Activity Polling
    
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
    
    // MARK: - Agent Questions
    
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
    
    // MARK: - Agent Permissions
    
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
    
    // MARK: - File Operations
    
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
        let queryItems = parseQueryItems(from: request.uri.string)
        let isInput = queryItems["type"] == "input"
        
        // Get file data from the task's actual stored paths
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
    
    // MARK: - Multipart Parsing
    
    private struct TaskMultipartFormResult {
        let description: String
        let providerName: String
        let modelId: String
        let priority: APITaskPriority
        let filePaths: [String]
        let outputDirectory: String?
        let planFirst: Bool
    }
    
    private func parseTaskMultipartForm(request: Request) async throws -> TaskMultipartFormResult {
        var description = ""
        var providerName = ""
        var modelId = ""
        var priority = APITaskPriority.normal
        var filePaths: [String] = []
        var outputDirectory: String?
        var planFirst = false
        
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
            planFirst: planFirst
        )
    }
}
