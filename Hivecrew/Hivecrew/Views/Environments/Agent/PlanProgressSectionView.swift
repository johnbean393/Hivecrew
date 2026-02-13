//
//  PlanProgressSectionView.swift
//  Hivecrew
//
//  Collapsible plan progress section for agent activity
//

import SwiftUI

/// Collapsible section showing plan progress
struct PlanProgressSection: View {
    let planState: PlanState
    @Binding var isExpanded: Bool
    
    private var completionPercentage: Int {
        Int(planState.completionPercentage * 100)
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                    
                    Image(systemName: "list.bullet.clipboard")
                        .foregroundStyle(.blue)
                        .font(.caption)
                    
                    Text("Plan Progress")
                        .font(.caption)
                        .fontWeight(.medium)
                    
                    Spacer()
                    
                    Text("\(planState.completedCount)/\(planState.items.count)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(Color.blue.opacity(0.15))
                        )
                    
                    ProgressView(value: planState.completionPercentage)
                        .frame(width: 50)
                    
                    Text("\(completionPercentage)%")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: 30, alignment: .trailing)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
            
            if isExpanded {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(planState.items) { item in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: itemIcon(for: item))
                                .font(.caption2)
                                .foregroundStyle(itemColor(for: item))
                                .frame(width: 12)
                            
                            Text(item.content)
                                .font(.caption2)
                                .foregroundStyle(item.isCompleted ? .secondary : .primary)
                                .strikethrough(item.isCompleted)
                                .lineLimit(2)
                            
                            Spacer()
                            
                            if item.addedDuringExecution {
                                Text("added")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                    
                    if !planState.deviations.isEmpty {
                        Divider()
                            .padding(.vertical, 4)
                        
                        Text("Deviations: \(planState.deviations.count)")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
    }
    
    private func itemIcon(for item: PlanTodoItem) -> String {
        if item.isCompleted {
            return "checkmark.circle.fill"
        } else if item.wasSkipped {
            return "arrow.right.circle"
        } else {
            return "circle"
        }
    }
    
    private func itemColor(for item: PlanTodoItem) -> Color {
        if item.isCompleted {
            return .green
        } else if item.wasSkipped {
            return .orange
        } else {
            return .secondary
        }
    }
}
