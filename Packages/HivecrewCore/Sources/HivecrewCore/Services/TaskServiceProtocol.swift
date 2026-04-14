import Foundation
import SwiftData

@MainActor
public protocol TaskServiceProtocol: ObservableObject {
    var tasks: [TaskRecord] { get }

    func createTasks(_ requests: [TaskCreationRequest]) async throws -> [TaskRecord]
    func deleteTask(_ task: TaskRecord)
    func renameTask(_ task: TaskRecord, to title: String)
    func cancelTask(_ task: TaskRecord) async
    func pauseTask(_ task: TaskRecord) async
    func resumeTask(_ task: TaskRecord) async
    func sendInstruction(_ instruction: String, to task: TaskRecord) async
    func getTask(byId id: String) -> TaskRecord?
}
