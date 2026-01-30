//
//  PromptCopyCountButton.swift
//  Hivecrew
//
//  Capsule-style button for selecting task copy count with native NSMenu dropdown
//

import SwiftUI

/// Options for number of task copies to create
enum TaskCopyCount: Int, CaseIterable, Identifiable {

    case one = 1
    case two = 2
    case three = 3
    case four = 4
    case five = 5
    case six = 6
    case seven = 7
    case eight = 8
    
    var id: Int { rawValue }
    
    var description: String {
        return "×\(rawValue)"
    }

    var symbolName: String {
        switch self {
            case .one:
                return "person.fill"
            case .two:
                return "person.2.fill"
            default:
                return "person.3.fill"
        }
    }

}

// MARK: - MenuOptions Protocol

protocol CopyCountMenuOptions: Identifiable, Equatable, CaseIterable {
    var description: String { get }
}

extension TaskCopyCount: CopyCountMenuOptions {}

// MARK: - PromptCopyCountButton

/// A capsule-styled button for selecting task copy count with native NSMenu dropdown
struct PromptCopyCountButton: View {
    
    @Binding var copyCount: TaskCopyCount
    var isFocused: Bool = false
    
    @State private var anchorView: NSView?
    
    private var textColor: Color {
        isFocused ? .accentColor : .primary.opacity(0.5)
    }
    
    private var menuLabelColor: NSColor {
        isFocused ? .controlAccentColor : NSColor(Color.primary.opacity(0.5))
    }
    
    private var bubbleColor: Color {
        isFocused ? Color.accentColor.opacity(0.3) : .white.opacity(0.0001)
    }
    
    private var bubbleBorderColor: Color {
        isFocused ? bubbleColor : .primary.opacity(0.3)
    }
    
    private var options: [TaskCopyCount] {
        return TaskCopyCount.allCases.map { $0 }
    }
    
    var body: some View {
        HStack(spacing: 0) {
            CopyCountAnchorRepresentable(view: $anchorView)
                .frame(width: 0.1, height: 0.1)
            
            // Left side: label showing current count
            buttonLeft
            
            // Divider
            Rectangle()
                .fill(bubbleBorderColor)
                .frame(width: 0.5, height: 18)
            
            // Right side: dropdown menu
            menuRight
        }
        .background {
            capsuleBackground
        }
    }
    
    private var buttonLeft: some View {
        Button {
            return
        } label: {
            HStack(spacing: 4) {
                Image(systemName: copyCount.symbolName)
                    .contentTransition(.symbolEffect(.replace))
                    .font(.caption)
                Text(copyCount.description)
                    .contentTransition(.numericText())
                    .font(.caption)
            }
            .foregroundStyle(textColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
        }
        .animation(.easeInOut(duration: 0.1), value: copyCount)
        .buttonStyle(.plain)
    }
    
    private var menuRight: some View {
        CopyCountMenuIcon(
            iconName: "chevron.down",
            color: menuLabelColor,
            menu: NSMenu.fromCopyCountOptions(
                options: options
            ) { option in
                copyCount = option
            },
            anchorViewProvider: {
                anchorView
            }
        )
        .frame(width: 18, height: 18)
        .padding(.trailing, 2)
    }
    
    private var capsuleBackground: some View {
        ZStack {
            Capsule()
                .fill(bubbleColor)
            Capsule()
                .stroke(style: StrokeStyle(lineWidth: 0.3))
                .fill(bubbleBorderColor)
        }
    }
}

// MARK: - CopyCountMenuIcon (NSViewRepresentable)

struct CopyCountMenuIcon: NSViewRepresentable {
    
    let iconName: String
    let color: NSColor
    let menu: NSMenu
    let anchorViewProvider: () -> NSView?
    
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(frame: .zero)
        button.bezelStyle = .texturedRounded
        if let image = NSImage(
            systemSymbolName: iconName,
            accessibilityDescription: nil
        ) {
            button.image = image
        }
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.cornerRadius = 6.0
        button.layer?.backgroundColor = NSColor.clear.cgColor
        button.contentTintColor = color
        button.target = context.coordinator
        button.action = #selector(Coordinator.showMenu(_:))
        button.sendAction(on: [.leftMouseDown])
        return button
    }
    
    func updateNSView(_ nsView: NSButton, context: Context) {
        nsView.image = NSImage(
            systemSymbolName: iconName,
            accessibilityDescription: nil
        )
        nsView.contentTintColor = color
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(
            menu: menu,
            anchorViewProvider: anchorViewProvider
        )
    }
    
    class Coordinator: NSObject {
        
        let menu: NSMenu
        let anchorViewProvider: () -> NSView?
        
        init(
            menu: NSMenu,
            anchorViewProvider: @escaping () -> NSView?
        ) {
            self.menu = menu
            self.anchorViewProvider = anchorViewProvider
        }
        
        @objc func showMenu(_ sender: NSButton) {
            let buttonRect = sender.bounds
            guard let anchor = anchorViewProvider() else {
                // Fallback: show menu below button
                menu.popUp(
                    positioning: nil,
                    at: NSPoint(x: 0, y: buttonRect.height + 5),
                    in: sender
                )
                return
            }
            let anchorOriginInSender = sender.convert(
                anchor.bounds.origin,
                from: anchor
            )
            let xOffset = anchorOriginInSender.x
            let yOffset = buttonRect.midY + (buttonRect.height + 15) / 2
            let menuOrigin = NSPoint(x: xOffset, y: yOffset)
            menu.popUp(positioning: nil, at: menuOrigin, in: sender)
        }
    }
}

// MARK: - CopyCountAnchorRepresentable

struct CopyCountAnchorRepresentable: NSViewRepresentable {
    
    @Binding var view: NSView?
    
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { self.view = view }
        return view
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - NSMenu Extension

extension NSMenu {
    
    static func fromCopyCountOptions(
        options: [TaskCopyCount],
        selectionHandler: @escaping (TaskCopyCount) -> Void
    ) -> NSMenu {
        let menu = NSMenu()
        for option in options {
            let item = NSMenuItem(
                title: option.description,
                action: #selector(CopyCountMenuHandler.handleMenu(_:)),
                keyEquivalent: ""
            )
            item.target = CopyCountMenuHandler.shared
            item.representedObject = CopyCountMenuHandler.OptionWrapper(
                option: option,
                handler: selectionHandler
            )
            menu.addItem(item)
        }
        return menu
    }
}

// MARK: - CopyCountMenuHandler

/// Helper class to bring Swift closures to AppKit menu actions
fileprivate class CopyCountMenuHandler: NSObject {
    
    static let shared = CopyCountMenuHandler()
    
    struct OptionWrapper {
        let option: TaskCopyCount
        let handler: (TaskCopyCount) -> Void
    }
    
    @objc func handleMenu(_ sender: NSMenuItem) {
        if let wrapper = sender.representedObject as? OptionWrapper {
            wrapper.handler(wrapper.option)
        }
    }
}

// MARK: - Preview

#Preview {
    struct PreviewWrapper: View {
        @State private var copyCount: TaskCopyCount = .one
        
        var body: some View {
            VStack(spacing: 20) {
                PromptCopyCountButton(copyCount: $copyCount, isFocused: false)
                PromptCopyCountButton(copyCount: $copyCount, isFocused: true)
                
                Text("Selected: \(copyCount.rawValue) copies")
                    .font(.caption)
            }
            .padding()
        }
    }
    
    return PreviewWrapper()
}
