//
//  SessionTraceView+Panels.swift
//  Hivecrew
//
//  Screenshot viewer and trace panel components for SessionTraceView
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import HivecrewShared
import MarkdownView

// MARK: - Screenshot Viewer

extension SessionTraceView {
    
    var screenshotViewer: some View {
        VStack(spacing: 0) {
            // Screenshot display
            if screenshotEvents.isEmpty {
                noScreenshotsView
            } else {
                ZStack {
                    Color.black
                    
                    if let path = currentScreenshotPath,
                       let image = NSImage(contentsOfFile: path) {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .onTapGesture {
                                quickLookURL = URL(fileURLWithPath: path)
                            }
                            .transition(.opacity)
                    } else if let firstScreenshot = screenshotEvents.first?.screenshotPath,
                              let image = NSImage(contentsOfFile: firstScreenshot) {
                        // Fallback to first screenshot
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .onTapGesture {
                                quickLookURL = URL(fileURLWithPath: firstScreenshot)
                            }
                    } else {
                        VStack {
                            Image(systemName: "photo")
                                .font(.largeTitle)
                                .foregroundStyle(.tertiary)
                            Text("Screenshot not available")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .animation(.easeInOut(duration: 0.15), value: currentScreenshotPath)
            }
            
            // Screenshot info bar (minimal, no controls)
            if !screenshotEvents.isEmpty {
                screenshotInfoBar
            }
        }
    }
    
    var noScreenshotsView: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("No screenshots captured")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("This session did not record any screenshots")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
    
    var screenshotInfoBar: some View {
        HStack(spacing: 16) {
            // Current screenshot indicator
            if let currentIndex = screenshotEvents.firstIndex(where: { $0.screenshotPath == currentScreenshotPath }) {
                Text("\(currentIndex + 1) of \(screenshotEvents.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            
            Spacer()
            
            // Export video button
            Button(action: exportVideo) {
                if isExportingVideo {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                } else {
                    Image(systemName: "film")
                }
            }
            .buttonStyle(.plain)
            .disabled(isExportingVideo || screenshotEvents.isEmpty)
            .help("Export as Video")
            
            // Full screen button
            if let path = currentScreenshotPath {
                Button(action: {
                    quickLookURL = URL(fileURLWithPath: path)
                }) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(.plain)
                .help("View Full Size")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

// MARK: - Trace Panel

extension SessionTraceView {
    
    var tracePanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            tracePanelHeader
            
            Divider()
            
            // Trace events with scroll position tracking
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(events.enumerated()), id: \.element.id) { index, event in
                        HistoricalTraceEventRow(
                            event: event,
                            isCurrentScreenshot: event.screenshotPath == currentScreenshotPath
                        )
                        .id(event.id)
                        .background(
                            GeometryReader { geometry in
                                Color.clear.preference(
                                    key: VisibleEventPreferenceKey.self,
                                    value: [EventVisibility(
                                        id: event.id,
                                        index: index,
                                        minY: geometry.frame(in: .named("traceScroll")).minY,
                                        maxY: geometry.frame(in: .named("traceScroll")).maxY
                                    )]
                                )
                            }
                        )
                    }
                    Spacer(minLength: 450)
                }
                .padding()
            }
            .coordinateSpace(name: "traceScroll")
            .onPreferenceChange(VisibleEventPreferenceKey.self) { visibilities in
                updateScreenshotForVisibleEvents(visibilities)
            }
            
            Divider()
            
            // Footer with stats
            tracePanelFooter
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
    
    func updateScreenshotForVisibleEvents(_ visibilities: [EventVisibility]) {
        // Find events that are visible in the scroll view (their top is above center)
        let scrollViewHeight: CGFloat = 400 // Approximate height
        let visibleThreshold = scrollViewHeight * 0.3 // Top 30% of scroll view
        
        // Get the topmost visible event
        let visibleEvents = visibilities
            .filter { $0.minY < visibleThreshold && $0.maxY > 0 }
            .sorted { $0.index < $1.index }
        
        guard let topmostVisibleEvent = visibleEvents.first else { return }
        
        // Find the most recent screenshot at or before this event
        let eventIndex = topmostVisibleEvent.index
        
        // Look backwards from the current event to find the most recent screenshot
        for i in stride(from: eventIndex, through: 0, by: -1) {
            if let screenshotPath = events[safe: i]?.screenshotPath {
                if currentScreenshotPath != screenshotPath {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        currentScreenshotPath = screenshotPath
                        currentScreenshotStep = events[i].step
                    }
                }
                return
            }
        }
        
        // If no screenshot found before, use the first one
        if let firstScreenshot = screenshotEvents.first {
            if currentScreenshotPath != firstScreenshot.screenshotPath {
                withAnimation(.easeInOut(duration: 0.15)) {
                    currentScreenshotPath = firstScreenshot.screenshotPath
                    currentScreenshotStep = firstScreenshot.step
                }
            }
        }
    }
    
    var tracePanelHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Status and step count
            HStack(spacing: 6) {
                // Show checkmark/X icon for completed tasks, dot for others
                if let icon = completionIcon {
                    Image(systemName: icon)
                        .foregroundStyle(statusColor)
                        .font(.system(size: 14))
                } else {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 10, height: 10)
                }
                
                Text(statusDisplayText)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(statusColor)
                    .textSelection(.enabled)
                
                Spacer()
                
                // Total steps
                if let maxStep = events.map({ $0.step }).max(), maxStep > 0 {
                    Text("\(maxStep) steps")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .clipShape(Capsule())
                }
            }
            
            // Task info
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "person.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(task.title)
                        .font(.headline)
                        .lineLimit(2)
                        .textSelection(.enabled)
                    
                    if !task.taskDescription.isEmpty && task.taskDescription != task.title {
                        Text(task.taskDescription)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                            .textSelection(.enabled)
                    }
                    
                    if let error = task.errorMessage {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .lineLimit(2)
                            .textSelection(.enabled)
                    }
                }
            }
            
            // Last LLM text response (displayed in a GroupBox with Markdown)
            if let responseText = lastLLMTextResponse {
                GroupBox {
                    ScrollView {
                        HStack {
                            MarkdownView(responseText)
                                .textSelection(.enabled)
                                .padding(6)
                            Spacer()
                        }
                    }
                    .frame(maxHeight: 200)
                }
            }
        }
        .padding()
    }
    
    /// Whether this task can have a skill extracted
    private var canExtractSkill: Bool {
        task.status == .completed &&
        task.wasSuccessful == true &&
        task.sessionId != nil
    }
    
    var tracePanelFooter: some View {
        HStack(spacing: 16) {
            
            // Rerun button for inactive tasks
            if !task.status.isActive {
                Button(action: { Task { try? await taskService.rerunTask(task) } }) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.caption2)
                        Text("Rerun")
                            .font(.caption)
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.blue)
                .help("Create a new task with the same parameters")
            }
            
            // Show deliverables button
            if let outputPaths = task.outputFilePaths, !outputPaths.isEmpty {
                Button(action: showDeliverablesInFinder) {
                    HStack(spacing: 4) {
                        Image(systemName: "folder")
                            .font(.caption2)
                        Text("\(outputPaths.count) deliverable\(outputPaths.count == 1 ? "" : "s")")
                            .font(.caption)
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.blue)
                .help("Show deliverables in Finder")
            }
            
            // Extract skill button (for completed successful tasks)
            if canExtractSkill {
                Button(action: { showingSkillExtraction = true }) {
                    HStack(spacing: 4) {
                        Image(systemName: "sparkles")
                            .font(.caption2)
                        Text("Extract Skill")
                            .font(.caption)
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.purple)
                .help("Create a reusable skill from this task")
            }
            
            Spacer()
            
            // Timestamp range
            if let firstTimestamp = events.first?.timestamp,
               let lastTimestamp = events.last?.timestamp {
                Text("\(formatTimestamp(firstTimestamp)) - \(formatTimestamp(lastTimestamp))")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
    }
    
    func exportVideo() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.canCreateDirectories = true
        
        // Create a sanitized filename from the task title
        let sanitizedTitle = task.title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .prefix(50)
        panel.nameFieldStringValue = "\(sanitizedTitle)-recording.mp4"
        
        panel.begin { [self] response in
            guard response == .OK, let url = panel.url else { return }
            
            Task { @MainActor in
                isExportingVideo = true
                exportProgress = 0
                
                do {
                    let paths = screenshotEvents.compactMap { $0.screenshotPath }
                    try await VideoExporter.exportVideo(from: paths, to: url, fps: 6) { progress in
                        Task { @MainActor in
                            self.exportProgress = progress
                        }
                    }
                    
                    isExportingVideo = false
                    
                    // Reveal the exported file in Finder
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } catch {
                    isExportingVideo = false
                    
                    // Show error alert
                    let alert = NSAlert()
                    alert.messageText = "Export Failed"
                    alert.informativeText = error.localizedDescription
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
            }
        }
    }
    
    func showDeliverablesInFinder() {
        guard let outputPaths = task.outputFilePaths, !outputPaths.isEmpty else { return }
        
        // Convert paths to URLs
        let urls = outputPaths.compactMap { URL(fileURLWithPath: $0) }
        
        // Filter to only existing files
        let existingURLs = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        
        if existingURLs.isEmpty {
            // If no files exist, try to open the output directory instead
            let outputDirectoryPath = UserDefaults.standard.string(forKey: "outputDirectoryPath") ?? ""
            let outputDirectory: URL
            if outputDirectoryPath.isEmpty {
                outputDirectory = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSHomeDirectory())
            } else {
                outputDirectory = URL(fileURLWithPath: outputDirectoryPath)
            }
            NSWorkspace.shared.open(outputDirectory)
        } else {
            // Select the files in Finder
            NSWorkspace.shared.activateFileViewerSelecting(existingURLs)
        }
    }
}
