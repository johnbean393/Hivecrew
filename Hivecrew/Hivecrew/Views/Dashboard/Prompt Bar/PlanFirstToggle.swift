//
//  PlanFirstToggle.swift
//  Hivecrew
//
//  Segmented picker for plan-first vs direct execution mode
//

import SwiftUI

/// Execution mode for tasks
enum ExecutionMode: String, CaseIterable {
    case direct = "Direct"
    case plan = "Plan"
    
    var localizedName: String {
        switch self {
        case .direct: return String(localized: "Direct")
        case .plan: return String(localized: "Plan")
        }
    }
    
    var iconName: String {
        switch self {
        case .direct: return "bolt.fill"
        case .plan: return "list.bullet.clipboard"
        }
    }
}

/// Segmented picker for plan-first mode in the prompt bar
struct PlanFirstToggle: View {
    @Binding var isEnabled: Bool
    var isFocused: Bool = false
    
    @State private var directWidth: CGFloat = 0
    @State private var planWidth: CGFloat = 0
    @State private var totalHeight: CGFloat = 0
    
    private var selectedMode: ExecutionMode {
        isEnabled ? .plan : .direct
    }
    
    // Colors matching other prompt bar buttons - only use accent when focused
    private var selectedTextColor: Color {
        isFocused ? .accentColor : .primary.opacity(0.5)
    }
    
    private var selectedBackgroundColor: Color {
        isFocused ? .accentColor.opacity(0.3) : .white.opacity(0.0001)
    }
    
    // Colors for unselected segment
    private var unselectedTextColor: Color {
        .secondary.opacity(0.8)
    }
    
    private var unselectedBorderColor: Color {
        .primary.opacity(0.3)
    }
    
    // Border visibility - show full border when not focused (like other buttons)
    private var showPartialBorder: Bool {
        isFocused
    }
    
    private var capsuleOffset: CGFloat {
        isEnabled ? directWidth : 0
    }
    
    private var capsuleWidth: CGFloat {
        isEnabled ? planWidth : directWidth
    }
    
    private var totalWidth: CGFloat {
        directWidth + planWidth
    }
    
    var body: some View {
        HStack(spacing: 0) {
            segmentButton(for: .direct)
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: DirectWidthKey.self, value: geo.size.width)
                    }
                )
            
            segmentButton(for: .plan)
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: PlanWidthKey.self, value: geo.size.width)
                    }
                )
        }
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: TotalHeightKey.self, value: geo.size.height)
            }
        )
        .background(alignment: .leading) {
            // Sliding capsule indicator (only visible when focused)
            if isFocused {
                Capsule()
                    .fill(selectedBackgroundColor)
                    .frame(width: capsuleWidth > 0 ? capsuleWidth : nil, height: totalHeight > 0 ? totalHeight : nil)
                    .offset(x: capsuleOffset)
            }
        }
        .background {
            if isFocused {
                // Partial border that excludes the selected capsule area (when focused)
                let strokeWidth: CGFloat = 0.5
                let inset = strokeWidth / 2
                PartialCapsuleBorder(
                    totalWidth: totalWidth,
                    totalHeight: totalHeight - strokeWidth,
                    selectedOffset: capsuleOffset,
                    selectedWidth: capsuleWidth,
                    cornerRadius: (totalHeight - strokeWidth) / 2,
                    yOffset: inset
                )
                .stroke(unselectedBorderColor, lineWidth: strokeWidth)
            } else {
                // Full capsule border (when not focused, like other buttons)
                Capsule()
                    .stroke(unselectedBorderColor, lineWidth: 0.5)
            }
        }
        .onPreferenceChange(DirectWidthKey.self) { directWidth = $0 }
        .onPreferenceChange(PlanWidthKey.self) { planWidth = $0 }
        .onPreferenceChange(TotalHeightKey.self) { totalHeight = $0 }
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isEnabled)
    }
    
    private func segmentButton(for mode: ExecutionMode) -> some View {
        let isSelected = selectedMode == mode
        
        return Button {
            isEnabled = (mode == .plan)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: mode.iconName)
                    .font(.caption)
                Text(mode.localizedName)
                    .font(.caption)
            }
            .foregroundStyle(isSelected ? selectedTextColor : unselectedTextColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Partial Capsule Border Shape

/// A shape that draws only the unselected portion of the capsule border
struct PartialCapsuleBorder: Shape {
    var totalWidth: CGFloat
    var totalHeight: CGFloat
    var selectedOffset: CGFloat
    var selectedWidth: CGFloat
    var cornerRadius: CGFloat
    var yOffset: CGFloat = 0
    
    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(selectedOffset, selectedWidth) }
        set {
            selectedOffset = newValue.first
            selectedWidth = newValue.second
        }
    }
    
    func path(in rect: CGRect) -> Path {
        var path = Path()
        
        guard totalWidth > 0 && totalHeight > 0 && selectedWidth > 0 else {
            // Fallback: draw full capsule border
            path.addRoundedRect(in: rect, cornerSize: CGSize(width: cornerRadius, height: cornerRadius))
            return path
        }
        
        // Use our measured dimensions, not rect (which may differ)
        let width = totalWidth
        let height = totalHeight
        let r = min(cornerRadius, height / 2, width / 2)
        let top = yOffset
        let bottom = yOffset + height
        let selectedStart = selectedOffset
        let selectedEnd = selectedOffset + selectedWidth
        
        // The selected capsule has rounded ends, so at y=0 and y=height,
        // the actual edge is inset by the radius. We extend the border
        // until it touches the capsule's curved edge.
        let selectedCapsuleLeftEdge = selectedStart + r  // where left curve meets flat top/bottom
        let selectedCapsuleRightEdge = selectedEnd - r   // where right curve meets flat top/bottom
        
        // Determine if selection is on left or right
        let isLeftSelected = selectedOffset < 1 // effectively 0
        let isRightSelected = selectedEnd >= totalWidth - 1 // effectively at the end
        
        if isLeftSelected {
            // Left is selected - draw border for right portion only
            // Extend horizontal lines until they touch the selected capsule's right curve
            
            // Top edge from where it touches the selected capsule to right corner
            path.move(to: CGPoint(x: selectedCapsuleRightEdge, y: top))
            path.addLine(to: CGPoint(x: width - r, y: top))
            
            // Top-right corner
            path.addArc(
                center: CGPoint(x: width - r, y: top + r),
                radius: r,
                startAngle: .degrees(-90),
                endAngle: .degrees(0),
                clockwise: false
            )
            
            // Right edge
            path.addLine(to: CGPoint(x: width, y: bottom - r))
            
            // Bottom-right corner
            path.addArc(
                center: CGPoint(x: width - r, y: bottom - r),
                radius: r,
                startAngle: .degrees(0),
                endAngle: .degrees(90),
                clockwise: false
            )
            
            // Bottom edge back to where it touches the selected capsule
            path.addLine(to: CGPoint(x: selectedCapsuleRightEdge, y: bottom))
            
        } else if isRightSelected {
            // Right is selected - draw border for left portion only
            // Extend horizontal lines until they touch the selected capsule's left curve
            
            // Start from where it touches the selected capsule, go around the left side
            path.move(to: CGPoint(x: selectedCapsuleLeftEdge, y: bottom))
            path.addLine(to: CGPoint(x: r, y: bottom))
            
            // Bottom-left corner
            path.addArc(
                center: CGPoint(x: r, y: bottom - r),
                radius: r,
                startAngle: .degrees(90),
                endAngle: .degrees(180),
                clockwise: false
            )
            
            // Left edge
            path.addLine(to: CGPoint(x: 0, y: top + r))
            
            // Top-left corner
            path.addArc(
                center: CGPoint(x: r, y: top + r),
                radius: r,
                startAngle: .degrees(180),
                endAngle: .degrees(270),
                clockwise: false
            )
            
            // Top edge to where it touches the selected capsule
            path.addLine(to: CGPoint(x: selectedCapsuleLeftEdge, y: top))
        }
        
        return path
    }
}

// MARK: - Preference Keys

private struct DirectWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct PlanWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct TotalHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

#Preview {
    struct PreviewWrapper: View {
        @State private var planEnabled1 = false
        @State private var planEnabled2 = true
        
        var body: some View {
            VStack(spacing: 20) {
                HStack(spacing: 12) {
                    PlanFirstToggle(isEnabled: $planEnabled1, isFocused: false)
                    PlanFirstToggle(isEnabled: $planEnabled2, isFocused: false)
                }
                
                HStack(spacing: 12) {
                    PlanFirstToggle(isEnabled: $planEnabled1, isFocused: true)
                    PlanFirstToggle(isEnabled: $planEnabled2, isFocused: true)
                }
                
                Button("Toggle") {
                    planEnabled1.toggle()
                    planEnabled2.toggle()
                }
            }
            .padding()
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }
    
    return PreviewWrapper()
}
