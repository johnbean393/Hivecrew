//
//  AgentPreviewStripView.swift
//  Hivecrew
//
//  Horizontal preview strip for active agents
//

import SwiftUI
import Combine

struct AgentPreviewStripView: View {
    @EnvironmentObject var taskService: TaskService
    @State private var sortEpoch: Int = 0
    
    private let cardWidth: CGFloat = 320
    private let cardHeight: CGFloat = 280
    private let previewHeight: CGFloat = 120
    
    var body: some View {
        let items = sortedItems()
        let itemIDs = items.map(\.id)
        
        if items.isEmpty {
            EmptyView()
        } else {
            ScrollView(.horizontal) {
                LazyHStack(spacing: 16) {
                    ForEach(items) { item in
                        if let publisher = item.statePublisher {
                            AgentPreviewCardObserved(
                                task: item.task,
                                statePublisher: publisher,
                                cardWidth: cardWidth,
                                cardHeight: cardHeight,
                                previewHeight: previewHeight
                            )
                        } else {
                            AgentPreviewCardStatic(
                                task: item.task,
                                cardWidth: cardWidth,
                                cardHeight: cardHeight,
                                previewHeight: previewHeight
                            )
                        }
                    }
                }
                .padding(.horizontal, 40)
                .padding(.vertical, 8)
                .animation(.spring(response: 0.35, dampingFraction: 0.85), value: itemIDs)
            }
            .scrollIndicators(.never)
            .frame(height: cardHeight + 32)
            .onReceive(refreshPublisher) { _ in
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    sortEpoch += 1
                }
            }
        }
    }
    
    private func sortedItems() -> [AgentPreviewItem] {
        let activeTasks = taskService.tasks.filter { taskService.isTaskEffectivelyActive($0) }
        let items = activeTasks.map { task in
            let publisher = taskService.statePublishers[task.id]
            return AgentPreviewItem(
                task: task,
                statePublisher: publisher,
                interventionTimestamp: interventionTimestamp(for: publisher)
            )
        }
        
        return items.sorted { lhs, rhs in
            let lhsKey = sortKey(for: lhs)
            let rhsKey = sortKey(for: rhs)
            if lhsKey.group != rhsKey.group {
                return lhsKey.group < rhsKey.group
            }
            if lhsKey.date != rhsKey.date {
                return lhsKey.date < rhsKey.date
            }
            return lhs.task.createdAt < rhs.task.createdAt
        }
    }
    
    private func sortKey(for item: AgentPreviewItem) -> (group: Int, date: Date) {
        if let interventionTimestamp = item.interventionTimestamp {
            return (0, interventionTimestamp)
        }
        
        let effectiveStatus = taskService.effectiveStatus(for: item.task)
        if effectiveStatus == .planReview {
            return (0, item.task.createdAt)
        }
        
        switch effectiveStatus {
        case .running:
            return (1, item.task.startedAt ?? item.task.createdAt)
        case .paused:
            return (2, item.task.createdAt)
        case .queued, .waitingForVM, .planning:
            return (3, item.task.createdAt)
        case .planReview:
            return (0, item.task.createdAt)
        case .completed, .failed, .cancelled, .timedOut, .maxIterations, .planFailed:
            return (4, item.task.createdAt)
        }
    }
    
    private func interventionTimestamp(for publisher: AgentStatePublisher?) -> Date? {
        guard let publisher = publisher else { return nil }
        var timestamps: [Date] = []
        if let question = publisher.pendingQuestion {
            timestamps.append(question.createdAt)
        }
        if let permission = publisher.pendingPermissionRequest {
            timestamps.append(permission.createdAt)
        }
        return timestamps.min()
    }
    
    private var refreshPublisher: AnyPublisher<Void, Never> {
        let publishers = taskService.statePublishers.values.flatMap { publisher in
            [
                publisher.$pendingQuestion.map { _ in () }.eraseToAnyPublisher(),
                publisher.$pendingPermissionRequest.map { _ in () }.eraseToAnyPublisher(),
                publisher.$lastScreenshot.map { _ in () }.eraseToAnyPublisher()
            ]
        }
        
        guard !publishers.isEmpty else {
            return Empty().eraseToAnyPublisher()
        }
        
        return Publishers.MergeMany(publishers).eraseToAnyPublisher()
    }
}

private struct AgentPreviewItem: Identifiable {
    let task: TaskRecord
    let statePublisher: AgentStatePublisher?
    let interventionTimestamp: Date?
    
    var id: String { task.id }
}

private extension AgentQuestion {
    var createdAt: Date {
        switch self {
        case .text(let question):
            return question.createdAt
        case .multipleChoice(let question):
            return question.createdAt
        case .intervention(let request):
            return request.createdAt
        }
    }
}
