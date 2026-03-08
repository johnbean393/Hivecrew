import Foundation
import UserNotifications
import Combine

extension TaskService {
    func sendTaskCompletionNotification(task: TaskRecord) {
        let content = UNMutableNotificationContent()
        let defaults = UserDefaults.standard

        switch task.status {
        case .completed:
            if let success = task.wasSuccessful, success {
                guard defaults.object(forKey: "notifyTaskCompleted") == nil || defaults.bool(forKey: "notifyTaskCompleted") else {
                    return
                }
                content.title = String(localized: "Task Completed")
                content.body = task.title
                if let outputPaths = task.outputFilePaths, !outputPaths.isEmpty {
                    content.subtitle = String(localized: "\(outputPaths.count) deliverable(s) ready")
                }
            } else {
                guard defaults.object(forKey: "notifyTaskIncomplete") == nil || defaults.bool(forKey: "notifyTaskIncomplete") else {
                    return
                }
                content.title = String(localized: "Task Incomplete")
                content.body = task.title
                if let summary = task.resultSummary {
                    content.subtitle = String(summary.prefix(50))
                }
            }
        case .failed:
            guard defaults.object(forKey: "notifyTaskFailed") == nil || defaults.bool(forKey: "notifyTaskFailed") else {
                return
            }
            content.title = String(localized: "Task Failed")
            content.body = task.title
            if let error = task.errorMessage {
                content.subtitle = String(error.prefix(50))
            }
        case .timedOut:
            guard defaults.object(forKey: "notifyTaskTimedOut") == nil || defaults.bool(forKey: "notifyTaskTimedOut") else {
                return
            }
            content.title = String(localized: "Task Timed Out")
            content.body = task.title
        case .maxIterations:
            guard defaults.object(forKey: "notifyTaskMaxIterations") == nil || defaults.bool(forKey: "notifyTaskMaxIterations") else {
                return
            }
            content.title = String(localized: "Task Hit Max Steps")
            content.body = task.title
        default:
            return
        }

        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "task-\(task.id)",
            content: content,
            trigger: nil
        )
        enqueueNotificationRequest(request)
    }

    func observePermissionRequests(for taskId: String, from publisher: AgentStatePublisher) {
        let cancellable = publisher.$pendingPermissionRequest
            .receive(on: DispatchQueue.main)
            .sink { [weak self] request in
                guard let self else { return }
                if let request {
                    pendingPermissions[taskId] = request
                } else {
                    pendingPermissions.removeValue(forKey: taskId)
                }
            }
        cancellables[taskId] = cancellable
    }

    func cleanupTaskObservations(taskId: String) {
        cancellables.removeValue(forKey: taskId)
        pendingPermissions.removeValue(forKey: taskId)
    }

    private func enqueueNotificationRequest(_ request: UNNotificationRequest) {
        let center = UNUserNotificationCenter.current()

        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                center.add(request) { error in
                    if let error {
                        print("TaskService: Failed to send notification: \(error)")
                    }
                }
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
                    if let error {
                        print("TaskService: Notification permission error: \(error)")
                        return
                    }
                    guard granted else { return }
                    center.add(request) { addError in
                        if let addError {
                            print("TaskService: Failed to send notification: \(addError)")
                        }
                    }
                }
            case .denied:
                return
            @unknown default:
                return
            }
        }
    }
}
