//
//  TaskRoutes.swift
//  HivecrewAPI
//
//  Routes for /api/v1/tasks (CRUD and file operations)
//

import Foundation
import Hummingbird

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

        // POST /tasks/batch - Create multiple prompt-bar tasks from one submission
        tasks.post("batch", use: createTaskBatch)
        
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

        // GET /tasks/:id/writeback - Pending staged local change review
        tasks.get(":id/writeback", use: getTaskWritebackReview)
        
        // GET /tasks/:id/files - List task files
        tasks.get(":id/files", use: listTaskFiles)
        
        // GET /tasks/:id/files/:filename - Download file
        tasks.get(":id/files/:filename", use: downloadFile)
    }
}
