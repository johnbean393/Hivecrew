//
//  CompactCallManager.swift
//  Hivecrew
//
//  Manages the compact in-call HUD lifecycle: entering/exiting compact mode,
//  choosing between NSPanel and DynamicNotch presentations, and observing
//  video source changes for automatic transitions.
//

import SwiftUI
import Combine
import DynamicNotchKit
import HivecrewVoice
import HivecrewCore

// MARK: - Compact HUD Style

enum CompactHUDStyle: String, CaseIterable {
    case panel = "panel"
    case notch = "notch"

    var displayName: String {
        switch self {
        case .panel: "Floating Window"
        case .notch: "Dynamic Notch"
        }
    }
}

// MARK: - Task Change Entry

struct TaskChangeEntry: Identifiable {
    let id = UUID()
    let taskTitle: String
    let status: TaskStatus
    let timestamp: Date
}

// MARK: - Compact Call Manager

@MainActor
final class CompactCallManager: ObservableObject {

    @Published private(set) var isCompact = false
    @Published var recentTaskChanges: [TaskChangeEntry] = []

    @AppStorage("voice_compact_hud_style") var style: String = CompactHUDStyle.notch.rawValue

    private weak var orchestrator: VoiceOrchestrator?
    private weak var taskService: TaskService?

    private var hudPanel: CompactShareHUDPanel?
    private var dynamicNotch: DynamicNotch<NotchExpandedContent, NotchLeadingContent, NotchCompactTrailing>?

    private var cancellables = Set<AnyCancellable>()
    private var notchHoverCancellable: AnyCancellable?
    private var taskPollTimer: Timer?
    private var cachedStatuses: [String: TaskStatus] = [:]

    // MARK: - Configuration

    func configure(orchestrator: VoiceOrchestrator, taskService: TaskService) {
        self.orchestrator = orchestrator
        self.taskService = taskService

        observeVideoSource(orchestrator: orchestrator)
        observeCallEnd()
        observeCaptureAnimation()
    }

    private func observeVideoSource(orchestrator: VoiceOrchestrator) {
        orchestrator.videoSourceManager.$activeSource
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] source in
                guard let self else { return }
                switch source {
                case .screen:
                    let state = orchestrator.callState
                    if !self.isCompact && (state == .active || state == .idleTimeout) {
                        self.enterCompactMode()
                    }
                default:
                    if self.isCompact {
                        self.exitCompactMode()
                    }
                }
            }
            .store(in: &cancellables)
    }

    private func observeCallEnd() {
        NotificationCenter.default.publisher(for: .compactCallDidEnd)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.isCompact else { return }
                self.exitCompactMode(restoreCallState: false)
            }
            .store(in: &cancellables)
    }

    private func observeCaptureAnimation() {
        NotificationCenter.default.publisher(for: .screenCaptureAnimationRequested)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let self else { return }
                guard let imageData = notification.userInfo?["imageData"] as? Data else { return }
                self.playCaptureAnimation(imageData: imageData)
            }
            .store(in: &cancellables)
    }

    // MARK: - Enter / Exit

    func enterCompactMode() {
        guard !isCompact, let orchestrator, let taskService else { return }
        let callState = orchestrator.callState
        guard callState == .active || callState == .idleTimeout || callState == .compactShare else { return }

        orchestrator.callState = .compactShare
        isCompact = true

        hideMainWindow()
        startTaskPolling()

        let resolvedStyle = CompactHUDStyle(rawValue: style) ?? .notch

        switch resolvedStyle {
        case .panel:
            showPanel(orchestrator: orchestrator, taskService: taskService)
        case .notch:
            showNotch(orchestrator: orchestrator, taskService: taskService)
        }
    }

    /// Exit compact mode and restore the main window.
    /// - Parameter restoreCallState: When `true` (default), sets `callState`
    ///   back to `.active`. Pass `false` when the call is already ending so
    ///   we don't overwrite the orchestrator's `.idle` state.
    func exitCompactMode(restoreCallState: Bool = true) {
        guard isCompact else { return }

        stopTaskPolling()
        recentTaskChanges.removeAll()

        let resolvedStyle = CompactHUDStyle(rawValue: style) ?? .notch

        switch resolvedStyle {
        case .panel:
            hudPanel?.close()
            hudPanel = nil
        case .notch:
            notchHoverCancellable?.cancel()
            notchHoverCancellable = nil
            if let notch = dynamicNotch {
                Task { await notch.hide() }
            }
            dynamicNotch = nil
        }

        restoreMainWindow()
        if restoreCallState {
            orchestrator?.callState = .active
        }
        isCompact = false
    }

    // MARK: - NSPanel Presentation

    private func showPanel(orchestrator: VoiceOrchestrator, taskService: TaskService) {
        let targetScreen = screenForSharing() ?? NSScreen.main
        let panel = CompactShareHUDPanel(
            orchestrator: orchestrator,
            taskService: taskService,
            compactCallManager: self,
            targetScreen: targetScreen
        )
        panel.orderFrontRegardless()
        hudPanel = panel
    }

    // MARK: - DynamicNotch Presentation

    private func showNotch(orchestrator: VoiceOrchestrator, taskService: TaskService) {
        let notch = makeCompactCallNotch(
            orchestrator: orchestrator,
            taskService: taskService,
            compactCallManager: self
        )
        dynamicNotch = notch

        let screen = screenForSharing() ?? NSScreen.screens[0]
        Task {
            await notch.compact(on: screen)
        }

        notchHoverCancellable = notch.$isHovering
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak notch] hovering in
                guard let self, let notch, self.isCompact else { return }
                let screen = self.screenForSharing() ?? NSScreen.screens[0]
                Task {
                    if hovering {
                        await notch.expand(on: screen)
                    } else {
                        await notch.compact(on: screen)
                    }
                }
            }
    }

    // MARK: - Window Management

    private func hideMainWindow() {
        if let mainWindow = NSApp.windows.first(where: { !($0 is NSPanel) && $0.isVisible }) {
            mainWindow.orderOut(nil)
        }
    }

    private func restoreMainWindow() {
        if let mainWindow = NSApp.windows.first(where: { !($0 is NSPanel) }) {
            mainWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func screenForSharing() -> NSScreen? {
        guard let orchestrator,
              case .screen(let displayID) = orchestrator.videoSourceManager.activeSource else {
            return nil
        }
        return NSScreen.screens.first { $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID == displayID }
    }

    // MARK: - Capture Animation

    /// Returns the screen-coordinate rect the capture animation should target.
    /// For the panel this is the panel's frame; for the notch this is the
    /// physical notch area (not the large backing window).
    var hudScreenRect: NSRect? {
        let resolvedStyle = CompactHUDStyle(rawValue: style) ?? .notch
        switch resolvedStyle {
        case .panel:
            return hudPanel?.frame
        case .notch:
            guard let screen = dynamicNotch?.windowController?.window?.screen
                              ?? screenForSharing()
                              ?? NSScreen.main else { return nil }
            return Self.notchRect(on: screen)
        }
    }

    /// The physical notch rect in screen coordinates, falling back to the
    /// menu-bar area on non-notch Macs.
    private static func notchRect(on screen: NSScreen) -> NSRect {
        if let leftPad = screen.auxiliaryTopLeftArea?.width,
           let rightPad = screen.auxiliaryTopRightArea?.width {
            let notchW = screen.frame.width - leftPad - rightPad
            let notchH = screen.safeAreaInsets.top
            return NSRect(
                x: screen.frame.midX - notchW / 2,
                y: screen.frame.maxY - notchH,
                width: notchW,
                height: notchH
            )
        }
        let menuH = screen.frame.maxY - screen.visibleFrame.maxY
        let w: CGFloat = 200
        return NSRect(
            x: screen.frame.midX - w / 2,
            y: screen.frame.maxY - menuH,
            width: w,
            height: menuH
        )
    }

    private func playCaptureAnimation(imageData: Data) {
        guard let screen = screenForSharing() ?? NSScreen.main else { return }

        let sinkRect: NSRect
        if let hudRect = hudScreenRect {
            sinkRect = hudRect
        } else {
            // Fallback: top-center of screen (notch area)
            let w: CGFloat = 200
            sinkRect = NSRect(
                x: screen.frame.midX - w / 2,
                y: screen.frame.maxY - 40,
                width: w,
                height: 30
            )
        }

        ScreenCaptureAnimationController.shared.playCaptureAnimation(
            imageData: imageData,
            sinkRect: sinkRect,
            screen: screen
        )
    }

    // MARK: - Task Status Polling

    private func startTaskPolling() {
        guard let taskService else { return }

        cachedStatuses = [:]
        for task in taskService.tasks {
            cachedStatuses[task.id] = taskService.effectiveStatus(for: task)
        }

        taskPollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pollTaskChanges()
            }
        }
    }

    private func stopTaskPolling() {
        taskPollTimer?.invalidate()
        taskPollTimer = nil
        cachedStatuses.removeAll()
    }

    private func pollTaskChanges() {
        guard let taskService else { return }

        var newStatuses: [String: TaskStatus] = [:]
        for task in taskService.tasks {
            let status = taskService.effectiveStatus(for: task)
            newStatuses[task.id] = status

            if let old = cachedStatuses[task.id], old != status {
                let entry = TaskChangeEntry(
                    taskTitle: task.title,
                    status: status,
                    timestamp: Date()
                )
                withAnimation(.easeInOut(duration: 0.25)) {
                    recentTaskChanges.append(entry)
                }
                scheduleRemoval(of: entry.id)
            }
        }
        cachedStatuses = newStatuses
    }

    private func scheduleRemoval(of entryId: UUID) {
        Task {
            try? await Task.sleep(for: .seconds(4))
            withAnimation(.easeInOut(duration: 0.25)) {
                recentTaskChanges.removeAll { $0.id == entryId }
            }
        }
    }
}

// MARK: - Notification Name

extension Notification.Name {
    static let compactCallDidEnd = Notification.Name("compactCallDidEnd")
    static let screenCaptureAnimationRequested = Notification.Name("screenCaptureAnimationRequested")
}
