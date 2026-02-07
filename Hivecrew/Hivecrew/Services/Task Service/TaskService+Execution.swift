//
//  TaskService+Execution.swift
//  Hivecrew
//
//  Task execution, cancellation, pause/resume functionality
//

import Foundation
import SwiftData
import TipKit
import Virtualization
import Combine
import HivecrewLLM
import HivecrewShared

// MARK: - Task Execution

extension TaskService {
    
    /// Start executing a task with an ephemeral VM
    func startTask(_ task: TaskRecord) async {
        guard let context = modelContext else { return }
        
        // Check if this task is already being processed (prevents duplicate processing)
        guard !tasksInProgress.contains(task.id) else {
            print("TaskService: Task '\(task.title)' is already being processed, skipping duplicate call")
            return
        }
        
        // MARK: - Plan First Mode
        // If plan mode is enabled and no plan exists yet, generate a plan BEFORE checking VM capacity.
        // Planning does not require a VM, so it should proceed even when VMs are at capacity.
        if task.planFirstEnabled && task.planMarkdown == nil {
            tasksInProgress.insert(task.id)
            await runPlanningPhase(task: task, context: context)
            tasksInProgress.remove(task.id)
            return // Planning phase complete, wait for user to execute
        }
        
        // Check if we can create a new VM (within concurrency limit)
        // Count running agents, pending VMs, AND running developer VMs
        let maxConcurrent = UserDefaults.standard.integer(forKey: "maxConcurrentVMs")
        let effectiveMax = maxConcurrent > 0 ? maxConcurrent : 2
        let runningDeveloperVMs = countRunningDeveloperVMs()
        let pendingCount = syncPendingVMCount()
        let currentlyActive = runningAgents.count + pendingCount + runningDeveloperVMs
        
        print("TaskService: Concurrency check for '\(task.title)': running=\(runningAgents.count), pending=\(pendingCount), developerVMs=\(runningDeveloperVMs), inProgress=\(tasksInProgress.count), max=\(effectiveMax)")
        
        if currentlyActive >= effectiveMax {
            // At capacity - keep task as queued, will be picked up when a slot opens
            if task.status != .queued {
                task.status = .queued
                try? context.save()
                objectWillChange.send()
            }
            print("TaskService: At max concurrent VMs (\(effectiveMax), active: \(currentlyActive)). Task '\(task.title)' remains queued.")
            return
        }
        
        // Mark this task as in-progress to prevent duplicate processing
        tasksInProgress.insert(task.id)
        
        // Reserve a slot for this VM
        pendingVMCount += 1
        print("TaskService: Reserved VM slot for task '\(task.title)' (pending: \(pendingVMCount), running: \(runningAgents.count))")
        
        // Now update status to waiting for VM (we're actually processing it now)
        task.status = .waitingForVM
        try? context.save()
        objectWillChange.send()
        
        // Get the default template ID from settings
        let templateId = getDefaultTemplateId()
        print("TaskService: Retrieved defaultTemplateId = '\(templateId ?? "nil")'")
        
        guard let templateId = templateId, !templateId.isEmpty else {
            // Release the reserved slot and remove from in-progress tracking
            pendingVMCount = max(0, pendingVMCount - 1)
            tasksInProgress.remove(task.id)
            
            task.status = .failed
            task.errorMessage = "No default template configured. Please set a template in Settings → Environment."
            task.completedAt = Date()
            try? context.save()
            objectWillChange.send()
            print("TaskService: Task failed - no template configured")
            return
        }
        
        var vmId: String?
        var connection: GuestAgentConnection?
        var skillMatchingTask: Task<[Skill], Never>?
        var llmClientTask: Task<any LLMClientProtocol, Error>?
        var vmCreationTask: Task<String?, Error>?
        
        func abortIfInactive(stage: String) async -> Bool {
            guard task.status.isActive else {
                print("TaskService: Task '\(task.title)' became inactive during \(stage). Aborting start flow.")
                
                if tasksInProgress.contains(task.id) && runningAgents[task.id] == nil {
                    pendingVMCount = max(0, pendingVMCount - 1)
                    print("TaskService: Released pending slot after cancellation (pending: \(pendingVMCount))")
                }
                
                tasksInProgress.remove(task.id)
                cleanupTaskObservations(taskId: task.id)
                connection?.disconnect()
                skillMatchingTask?.cancel()
                llmClientTask?.cancel()
                vmCreationTask?.cancel()
                
                if let createdVmId = vmId {
                    await deleteEphemeralVM(vmId: createdVmId)
                }
                return true
            }
            
            return false
        }
        
        do {
            // Start VM creation immediately, while LLM client creation + skill matching run in parallel
            let vmName = generateVMName(for: task)
            print("TaskService: Creating ephemeral VM '\(vmName)' from template '\(templateId)'...")
            
            vmCreationTask = Task {
                try await vmServiceClient.createVMFromTemplate(templateId: templateId, name: vmName)
            }
            
            llmClientTask = Task {
                try await createLLMClient(providerId: task.providerId, modelId: task.modelId)
            }
            
            // Start skill matching concurrently with VM boot
            // This runs in parallel while the VM is being created and started
            skillMatchingTask = Task { () -> [Skill] in
                var skillsToUse: [Skill] = []
                let allSkills = skillManager.skills
                
                // First, add explicitly mentioned skills (user typed @skill-name)
                if let mentionedNames = task.mentionedSkillNames, !mentionedNames.isEmpty {
                    let mentionedSkills = allSkills.filter { mentionedNames.contains($0.name) }
                    if !mentionedSkills.isEmpty {
                        skillsToUse.append(contentsOf: mentionedSkills)
                        print("TaskService: Using \(mentionedSkills.count) mentioned skill(s): \(mentionedSkills.map { $0.name }.joined(separator: ", "))")
                    }
                }
                
                // Then, auto-match additional skills from enabled skills (if automatic matching is enabled)
                let automaticSkillMatching = UserDefaults.standard.object(forKey: "automaticSkillMatching") as? Bool ?? true
                
                if automaticSkillMatching {
                    let enabledSkills = skillManager.enabledSkills
                    let alreadyIncluded = Set(skillsToUse.map { $0.name })
                    let availableForMatching = enabledSkills.filter { !alreadyIncluded.contains($0.name) }
                    
                    if !availableForMatching.isEmpty {
                        do {
                            guard let llmClient = try await llmClientTask?.value else {
                                print("TaskService: Skill matching skipped (LLM client unavailable)")
                                return skillsToUse
                            }
                            print("TaskService: Matching skills for task (concurrent with VM boot)...")
                            let skillMatcher = SkillMatcher(llmClient: llmClient, embeddingService: skillManager.embeddingService)
                            let matchedSkills = try await skillMatcher.matchSkills(
                                forTask: task.taskDescription,
                                availableSkills: availableForMatching
                            )
                            if !matchedSkills.isEmpty {
                                skillsToUse.append(contentsOf: matchedSkills)
                                print("TaskService: Auto-matched \(matchedSkills.count) skill(s): \(matchedSkills.map { $0.name }.joined(separator: ", "))")
                            } else {
                                print("TaskService: No additional skills matched")
                            }
                        } catch {
                            // Skill matching is non-fatal, continue with just mentioned skills
                            print("TaskService: Skill matching failed (non-fatal): \(error.localizedDescription)")
                        }
                    }
                }
                
                return skillsToUse
            }
            
            // Await VM creation (already running in parallel with skill matching + LLM client creation)
            guard let vmCreationTask = vmCreationTask else {
                throw TaskServiceError.vmCreationFailed("VM creation task missing")
            }
            vmId = try await vmCreationTask.value
            print("TaskService: VM created successfully with ID: \(vmId ?? "nil")")
            if await abortIfInactive(stage: "VM creation") { return }
            
            // Store the VM ID on the task immediately
            task.assignedVMId = vmId
            try? context.save()
            objectWillChange.send()
            
            print("TaskService: Created VM \(vmId!), starting...")
            
            // Start the VM
            try await vmRuntime.startVM(id: vmId!)
            if await abortIfInactive(stage: "VM start") { return }
            
            // Wait for VM to be ready
            let vm = try await waitForVMReady(vmId: vmId!)
            if await abortIfInactive(stage: "VM readiness") { return }
            
            // Connect to GuestAgent
            connection = try await connectToGuestAgent(vm: vm, vmId: vmId!)
            guard let connection = connection else { return }
            if await abortIfInactive(stage: "GuestAgent connection") { return }
            
            // Prepare shared folder (inbox/outbox/workspace) on the HOST
            let inputFileNames = try prepareSharedFolder(vmId: vmId!, attachedFilePaths: task.attachedFilePaths)
            
            // Prepare Desktop inbox/outbox on the GUEST and copy attachments
            // This avoids VirtioFS issues with GUI apps saving files
            print("TaskService: Setting up guest Desktop inbox/outbox...")
            do {
                let setupResult = try await connection.runShell(command: """
                    mkdir -p ~/Desktop/inbox ~/Desktop/outbox && \
                    rm -rf ~/Desktop/inbox/* ~/Desktop/outbox/* 2>/dev/null; \
                    cp -R /Volumes/Shared/inbox/* ~/Desktop/inbox/ 2>/dev/null; \
                    echo "Setup complete. Inbox contents:" && ls -la ~/Desktop/inbox/
                    """, timeout: 30)
                print("TaskService: Guest setup result:\n\(setupResult.stdout)")
                if !setupResult.stderr.isEmpty {
                    print("TaskService: Guest setup stderr: \(setupResult.stderr)")
                }
            } catch {
                print("TaskService: Failed to setup guest inbox/outbox (non-fatal): \(error)")
            }
            if await abortIfInactive(stage: "guest setup") { return }
            
            // Update task status to running
            task.status = .running
            task.startedAt = Date()
            try? context.save()
            objectWillChange.send()
            
            // Create session
            let sessionId = UUID().uuidString
            let sessionPath = AppPaths.sessionPath(id: sessionId)
            try FileManager.default.createDirectory(at: sessionPath, withIntermediateDirectories: true)
            
            task.sessionId = sessionId
            
            // Copy attachments to session directory (files < 250MB)
            if !task.attachmentInfos.isEmpty {
                do {
                    let updatedInfos = try AttachmentManager.copyAttachmentsToSession(
                        infos: task.attachmentInfos,
                        sessionId: sessionId
                    )
                    task.attachmentInfos = updatedInfos
                    print("TaskService: Copied \(updatedInfos.filter { $0.wasCopied }.count) attachment(s) to session directory")
                } catch {
                    print("TaskService: Failed to copy attachments to session (non-fatal): \(error)")
                }
            }
            
            try? context.save()
            
            // Create session record
            let sessionRecord = AgentSessionRecord(
                id: sessionId,
                taskId: task.id,
                vmId: vmId!,
                tracePath: sessionPath.path
            )
            context.insert(sessionRecord)
            try? context.save()
            
            // Create state publisher
            let statePublisher = AgentStatePublisher(taskId: task.id, taskTitle: task.title)
            statePublisher.sessionId = sessionId
            statePublisher.status = .running
            statePublishers[task.id] = statePublisher
            
            // Observe permission requests from this state publisher
            observePermissionRequests(for: task.id, from: statePublisher)
            
            // LLM client should be ready by now (created in parallel with VM boot)
            guard let llmClientTask = llmClientTask else {
                throw TaskServiceError.missingLLMClient
            }
            let llmClient = try await llmClientTask.value
            if await abortIfInactive(stage: "LLM client creation") { return }
            
            // Wait for skill matching to complete (should be done by now since VM boot takes longer)
            let skillsToUse = await (skillMatchingTask?.value ?? [])
            if await abortIfInactive(stage: "skill matching") { return }
            
            // Log matched skills through the state publisher
            if !skillsToUse.isEmpty {
                let mentionedNames = task.mentionedSkillNames ?? []
                let mentionedSkills = skillsToUse.filter { mentionedNames.contains($0.name) }
                let autoMatchedSkills = skillsToUse.filter { !mentionedNames.contains($0.name) }
                
                if !mentionedSkills.isEmpty {
                    statePublisher.logInfo("Using \(mentionedSkills.count) mentioned skill(s): \(mentionedSkills.map { $0.name }.joined(separator: ", "))")
                }
                if !autoMatchedSkills.isEmpty {
                    statePublisher.logInfo("Auto-matched \(autoMatchedSkills.count) skill(s): \(autoMatchedSkills.map { $0.name }.joined(separator: ", "))")
                }
            }
            
            // Copy skill files to the VM inbox (if any skills have additional files)
            if !skillsToUse.isEmpty {
                let inboxPath = AppPaths.vmInboxDirectory(id: vmId!)
                do {
                    let copiedSkills = try skillManager.copySkillFiles(for: skillsToUse, to: inboxPath)
                    if !copiedSkills.isEmpty {
                        statePublisher.logInfo("Copied files for \(copiedSkills.count) skill(s) to inbox")
                        
                        // Copy skill files from shared folder to guest Desktop
                        let copyFilesResult = try await connection.runShell(command: """
                            for skill_dir in /Volumes/Shared/inbox/*/; do
                                if [ -d "$skill_dir" ]; then
                                    skill_name=$(basename "$skill_dir")
                                    mkdir -p ~/Desktop/inbox/"$skill_name"
                                    cp -R "$skill_dir"/* ~/Desktop/inbox/"$skill_name"/ 2>/dev/null
                                    echo "Copied files for skill: $skill_name"
                                fi
                            done
                            """, timeout: 30)
                        if !copyFilesResult.stdout.isEmpty {
                            print("TaskService: Skill files copy result: \(copyFilesResult.stdout)")
                        }
                    }
                } catch {
                    statePublisher.logInfo("Failed to copy skill files (non-fatal): \(error.localizedDescription)")
                }
            }
            
            // Get timeout and max iterations from settings
            let timeoutMinutes = UserDefaults.standard.integer(forKey: "defaultTaskTimeoutMinutes")
            let maxIterations = UserDefaults.standard.integer(forKey: "defaultMaxIterations")
            
            // Create and run agent
            if await abortIfInactive(stage: "agent startup") { return }
            let agent = try AgentRunner(
                task: task,
                vmId: vmId!,
                llmClient: llmClient,
                connection: connection,
                sessionPath: sessionPath,
                statePublisher: statePublisher,
                inputFileNames: inputFileNames,
                matchedSkills: skillsToUse,
                maxSteps: maxIterations > 0 ? maxIterations : 100,
                timeoutMinutes: timeoutMinutes > 0 ? timeoutMinutes : 30,
                taskService: self
            )
            runningAgents[task.id] = agent
            
            // VM is now running and tracked in runningAgents, release the pending slot
            pendingVMCount = max(0, pendingVMCount - 1)
            print("TaskService: VM started, released pending slot (pending: \(pendingVMCount), running: \(runningAgents.count))")
            
            // Run the agent
            let result = try await agent.run()
            
            // Handle task completion
            await handleTaskCompletion(task: task, result: result, connection: connection, vmId: vmId!, sessionId: sessionId, context: context)
            
        } catch {
            // Handle failure
            await handleTaskFailure(task: task, error: error, vmId: vmId, context: context)
        }
        
        objectWillChange.send()
        
        // Check if there are queued tasks waiting for a VM
        await processQueuedTasks()
    }
    
    /// Handle successful task completion
    private func handleTaskCompletion(
        task: TaskRecord,
        result: AgentResult,
        connection: GuestAgentConnection,
        vmId: String,
        sessionId: String,
        context: ModelContext
    ) async {
        // Update task with result based on termination reason
        task.completedAt = Date()
        task.resultSummary = result.summary
        
        // Store verified success status
        task.wasSuccessful = result.success
        
        switch result.terminationReason {
        case .completed:
            task.status = .completed
            // Track task completion for tips
            await MainActor.run {
                TipStore.shared.donateTaskCompleted()
                if result.success == true {
                    TipStore.shared.successfulTaskCompleted()
                }
            }
        case .failed:
            task.status = .failed
            task.errorMessage = result.errorMessage
            await MainActor.run {
                TipStore.shared.donateTaskCompleted()
            }
        case .cancelled:
            task.status = .cancelled
            task.errorMessage = result.errorMessage
        case .timedOut:
            task.status = .timedOut
            task.errorMessage = result.errorMessage
            await MainActor.run {
                TipStore.shared.donateTaskCompleted()
            }
        case .maxIterations:
            task.status = .maxIterations
            task.errorMessage = result.errorMessage
            await MainActor.run {
                TipStore.shared.donateTaskCompleted()
            }
        }
        
        // Move files from ~/Desktop/outbox to /Volumes/Shared/outbox
        print("TaskService: Moving deliverables from guest Desktop to shared folder...")
        do {
            // First show what's in the guest Desktop outbox
            let lsResult = try await connection.runShell(command: "ls -la ~/Desktop/outbox/ 2>&1", timeout: 30)
            print("TaskService: Guest ~/Desktop/outbox contents:\n\(lsResult.stdout)")
            
            // Move files from ~/Desktop/outbox to /Volumes/Shared/outbox
            let moveResult = try await connection.runShell(command: """
                if [ "$(ls -A ~/Desktop/outbox 2>/dev/null)" ]; then
                    cp -R ~/Desktop/outbox/* /Volumes/Shared/outbox/ && \
                    rm -rf ~/Desktop/outbox/* && \
                    echo "Moved files to shared outbox"
                else
                    echo "No files in ~/Desktop/outbox to move"
                fi && \
                sync; sync; sync && \
                echo "=== /Volumes/Shared/outbox contents ===" && \
                ls -la /Volumes/Shared/outbox/
                """, timeout: 60)
            print("TaskService: Move result:\n\(moveResult.stdout)")
            if !moveResult.stderr.isEmpty {
                print("TaskService: Move stderr: \(moveResult.stderr)")
            }
        } catch {
            print("TaskService: Failed to move deliverables (non-fatal): \(error)")
        }
        
        // Wait for VirtioFS to propagate writes to host
        try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
        
        // Copy outbox files to output directory BEFORE deleting the VM
        // Files are saved into a subfolder named after the task title + timestamp
        if result.terminationReason != .cancelled {
            task.outputFilePaths = copyOutboxFiles(vmId: vmId, taskTitle: task.title, customOutputDirectory: task.outputDirectory)
            
            // Donate deliverable received event if files were produced
            if let paths = task.outputFilePaths, !paths.isEmpty {
                await MainActor.run {
                    TipStore.shared.donateDeliverableReceived()
                }
            }
        }
        
        // Update session record
        if let session = try? context.fetch(FetchDescriptor<AgentSessionRecord>(predicate: #Predicate { $0.id == sessionId })).first {
            session.endedAt = Date()
            session.status = result.terminationReason.rawValue
            session.stepCount = result.stepCount
            session.promptTokens = result.promptTokens
            session.completionTokens = result.completionTokens
        }
        
        try? context.save()
        
        // Send completion notification
        sendTaskCompletionNotification(task: task)
        
        // Cleanup agent state
        runningAgents.removeValue(forKey: task.id)
        tasksInProgress.remove(task.id)
        cleanupTaskObservations(taskId: task.id)
        connection.disconnect()
        
        print("TaskService: Task '\(task.title)' completed. Cleanup done: running=\(runningAgents.count), pending=\(pendingVMCount), inProgress=\(tasksInProgress.count)")
        
        // Delete the ephemeral VM in background (so queue processing isn't blocked)
        let vmIdToDelete = vmId
        Task {
            await deleteEphemeralVM(vmId: vmIdToDelete)
        }
    }
    
    /// Handle task failure
    private func handleTaskFailure(
        task: TaskRecord,
        error: Error,
        vmId: String?,
        context: ModelContext
    ) async {
        print("TaskService: Task '\(task.title)' failed with error: \(error)")
        print("TaskService: Error type: \(type(of: error)), localizedDescription: \(error.localizedDescription)")
        
        // Release the pending VM slot only if not already released
        if tasksInProgress.contains(task.id) && runningAgents[task.id] == nil {
            pendingVMCount = max(0, pendingVMCount - 1)
            print("TaskService: VM creation failed, released pending slot (pending: \(pendingVMCount))")
        } else {
            print("TaskService: Pending slot was already released (pending: \(pendingVMCount))")
        }
        
        task.status = .failed
        task.errorMessage = error.localizedDescription
        task.completedAt = Date()
        try? context.save()
        
        // Send failure notification
        sendTaskCompletionNotification(task: task)
        
        runningAgents.removeValue(forKey: task.id)
        tasksInProgress.remove(task.id)
        cleanupTaskObservations(taskId: task.id)
        statePublishers[task.id]?.status = .failed
        statePublishers[task.id]?.logError(error.localizedDescription)
        
        print("TaskService: Task '\(task.title)' failed. Cleanup done: running=\(runningAgents.count), pending=\(pendingVMCount), inProgress=\(tasksInProgress.count)")
        
        // Clean up the VM in background if it was created (so queue processing isn't blocked)
        if let createdVmId = vmId {
            Task {
                await deleteEphemeralVM(vmId: createdVmId)
            }
        }
    }
    
    /// Cancel a running task
    func cancelTask(_ task: TaskRecord) async {
        // Cancel the agent if running
        if let agent = runningAgents[task.id] {
            await agent.cancel()
        }
        
        // Check if this task was in the pending/startup phase (not yet in runningAgents)
        // If so, we need to release the pending slot
        let wasInProgress = tasksInProgress.contains(task.id)
        let hadRunningAgent = runningAgents[task.id] != nil
        
        task.status = .cancelled
        task.completedAt = Date()
        try? modelContext?.save()
        
        runningAgents.removeValue(forKey: task.id)
        tasksInProgress.remove(task.id)
        cleanupTaskObservations(taskId: task.id)
        statePublishers[task.id]?.status = .cancelled
        
        // If task was in progress but didn't have a running agent yet, it was still using a pending slot
        if wasInProgress && !hadRunningAgent {
            pendingVMCount = max(0, pendingVMCount - 1)
            print("TaskService: Cancelled task '\(task.title)' was in pending state, released slot (pending: \(pendingVMCount))")
        }
        
        print("TaskService: Task '\(task.title)' cancelled. Cleanup done: running=\(runningAgents.count), pending=\(pendingVMCount), inProgress=\(tasksInProgress.count)")
        
        objectWillChange.send()
        
        // Process queued tasks immediately - slot is now free
        await processQueuedTasks()
        
        // Delete the ephemeral VM in the background (can be slow, shouldn't block queue processing)
        if let vmId = task.assignedVMId {
            Task {
                await deleteEphemeralVM(vmId: vmId)
            }
        }
    }
    
    /// Pause a running task
    func pauseTask(_ task: TaskRecord) {
        guard let agent = runningAgents[task.id] else { return }
        
        agent.pause()
        task.status = .paused
        try? modelContext?.save()
        
        objectWillChange.send()
    }
    
    /// Resume a paused task with optional instructions
    func resumeTask(_ task: TaskRecord, withInstructions instructions: String? = nil) {
        guard let agent = runningAgents[task.id] else { return }
        
        agent.resume(withInstructions: instructions)
        task.status = .running
        try? modelContext?.save()
        
        objectWillChange.send()
    }
    
    /// Re-queue a running task (used when app is terminating)
    func requeueTask(_ task: TaskRecord, reason: String) async {
        guard let context = modelContext else { return }
        
        // Cancel the agent if it's running
        if let agent = runningAgents[task.id] {
            await agent.cancel()
            runningAgents.removeValue(forKey: task.id)
        }
        
        // Clean up observations
        cleanupTaskObservations(taskId: task.id)
        
        // Delete the ephemeral VM if one was assigned
        if let vmId = task.assignedVMId {
            await deleteEphemeralVM(vmId: vmId)
        }
        
        // Clear any state publisher
        statePublishers.removeValue(forKey: task.id)
        
        // Reset task to queued state
        task.status = .queued
        task.startedAt = nil
        task.completedAt = nil
        task.assignedVMId = nil
        task.errorMessage = reason
        task.resultSummary = nil
        
        try? context.save()
        
        print("TaskService: Re-queued task '\(task.title)': \(reason)")
        objectWillChange.send()
    }
    
    /// Remove a queued task from the queue without running it
    func removeFromQueue(_ task: TaskRecord) async {
        guard let context = modelContext else { return }
        
        // Only allow removing queued/waiting tasks
        guard task.status == .queued || task.status == .waitingForVM else {
            print("TaskService: Cannot remove non-queued task '\(task.title)' from queue")
            return
        }

        if task.status == .waitingForVM {
            pendingVMCount = max(0, pendingVMCount - 1)
            tasksInProgress.remove(task.id)
            print("TaskService: Released pending slot for removed task '\(task.title)' (pending: \(pendingVMCount))")
        }
        
        // Mark as cancelled
        task.status = .cancelled
        task.completedAt = Date()
        task.errorMessage = "Removed from queue by user"
        
        try? context.save()
        
        print("TaskService: Removed task '\(task.title)' from queue")
        objectWillChange.send()
    }
    
    /// Delete a task and its associated session data
    func deleteTask(_ task: TaskRecord) async {
        guard let context = modelContext else { return }
        
        // Cancel if still running
        if task.status.isActive {
            await cancelTask(task)
        }
        
        // Delete session directory if it exists
        if let sessionId = task.sessionId {
            let sessionPath = AppPaths.sessionPath(id: sessionId)
            do {
                if FileManager.default.fileExists(atPath: sessionPath.path) {
                    try FileManager.default.removeItem(at: sessionPath)
                    print("TaskService: Deleted session directory: \(sessionPath.path)")
                }
            } catch {
                print("TaskService: Failed to delete session directory: \(error)")
            }
            
            // Also delete AgentSessionRecord if it exists
            let sessionDescriptor = FetchDescriptor<AgentSessionRecord>(
                predicate: #Predicate { $0.id == sessionId }
            )
            if let sessionRecord = try? context.fetch(sessionDescriptor).first {
                context.delete(sessionRecord)
            }
        }
        
        // Note: Copied attachments are stored in the session directory (Sessions/{sessionId}/Attachments/)
        // They are automatically deleted when the session directory is removed above
        
        // Remove from local state
        tasks.removeAll { $0.id == task.id }
        statePublishers.removeValue(forKey: task.id)
        
        // Delete from SwiftData
        context.delete(task)
        try? context.save()
        
        print("TaskService: Deleted task: \(task.title)")
        objectWillChange.send()
    }
    
    /// Process queued tasks when a VM becomes available
    func processQueuedTasks() async {
        // Find queued tasks that aren't already being processed, sorted by creation time (oldest first)
        let queuedTasks = tasks
            .filter { $0.status == .queued && !tasksInProgress.contains($0.id) }
            .sorted { $0.createdAt < $1.createdAt }
        
        guard !queuedTasks.isEmpty else { return }
        
        // Calculate available capacity
        let maxConcurrent = UserDefaults.standard.integer(forKey: "maxConcurrentVMs")
        let effectiveMax = maxConcurrent > 0 ? maxConcurrent : 2
        let runningDeveloperVMs = countRunningDeveloperVMs()
        let pendingCount = syncPendingVMCount()
        let currentlyActive = runningAgents.count + pendingCount + runningDeveloperVMs
        let availableSlots = max(0, effectiveMax - currentlyActive)
        
        guard availableSlots > 0 else {
            print("TaskService: No available slots for queued tasks (running=\(runningAgents.count), pending=\(pendingCount), developerVMs=\(runningDeveloperVMs), max=\(effectiveMax))")
            return
        }
        
        // Start as many queued tasks as we have slots for
        // Use Task { } to run them concurrently (startTask blocks until the entire task completes)
        let tasksToStart = Array(queuedTasks.prefix(availableSlots))
        print("TaskService: Processing \(tasksToStart.count) queued task(s) (available slots: \(availableSlots))")
        
        for task in tasksToStart {
            Task {
                await startTask(task)
            }
        }
    }

    /// Keep pendingVMCount aligned with task state to avoid stale capacity checks.
    @discardableResult
    private func syncPendingVMCount() -> Int {
        let actualPending = tasks.filter { task in
            guard task.status == .waitingForVM else { return false }
            return runningAgents[task.id] == nil
        }.count
        if pendingVMCount != actualPending {
            print("TaskService: pendingVMCount out of sync (stored=\(pendingVMCount), actual=\(actualPending)). Resyncing.")
            pendingVMCount = actualPending
        }
        return actualPending
    }
    
    // MARK: - Plan First Mode
    
    /// Run the planning phase for a task
    private func runPlanningPhase(task: TaskRecord, context: ModelContext) async {
        print("TaskService: Starting planning phase for task '\(task.title)'")
        
        // Update status to planning
        task.status = .planning
        try? context.save()
        objectWillChange.send()
        
        // Create planning state publisher
        let planningPublisher = PlanningStatePublisher()
        activePlanningPublishers[task.id] = planningPublisher
        
        do {
            // Create LLM client
            let llmClient = try await createLLMClient(providerId: task.providerId, modelId: task.modelId)
            
            // Create planning agent
            let planningAgent = PlanningAgent(llmClient: llmClient, embeddingService: skillManager.embeddingService)
            
            // Generate the plan
            let attachedFiles = task.attachedFilePaths.map { URL(fileURLWithPath: $0) }
            let (planMarkdown, selectedSkills) = try await planningAgent.generatePlan(
                task: task,
                attachedFiles: attachedFiles,
                availableSkills: skillManager.enabledSkills,
                statePublisher: planningPublisher
            )
            
            // Store the plan and selected skills
            task.planMarkdown = planMarkdown
            task.planSelectedSkillNames = selectedSkills.map(\.name)
            task.status = .planReview
            try? context.save()
            
            // Clean up the planning publisher now that generation is complete
            activePlanningPublishers.removeValue(forKey: task.id)
            
            print("TaskService: Plan generated for task '\(task.title)' (\(selectedSkills.count) skills selected)")
            
        } catch {
            print("TaskService: Planning failed for task '\(task.title)': \(error)")
            
            task.status = .planFailed
            task.errorMessage = "Planning failed: \(error.localizedDescription)"
            try? context.save()
            
            planningPublisher.failGeneration(with: error)
        }
        
        objectWillChange.send()
    }
    
    /// Execute a task's plan (called when user confirms execution from plan review)
    func executePlan(for task: TaskRecord) async {
        guard task.status == .planReview, task.planMarkdown != nil else {
            print("TaskService: Cannot execute plan - task is not in planReview state or has no plan")
            return
        }
        
        print("TaskService: Executing plan for task '\(task.title)'")
        
        // Clean up planning publisher
        activePlanningPublishers.removeValue(forKey: task.id)
        
        // Start the task (will now use the plan since planMarkdown is set)
        await startTask(task)
    }
    
    /// Cancel planning for a task
    func cancelPlanning(for task: TaskRecord) async {
        guard task.status == .planning || task.status == .planReview || task.status == .planFailed else {
            return
        }
        
        print("TaskService: Cancelling planning for task '\(task.title)'")
        
        // Cancel the planning publisher
        if let publisher = activePlanningPublishers[task.id] {
            publisher.cancelGeneration()
        }
        activePlanningPublishers.removeValue(forKey: task.id)
        
        // Mark task as cancelled
        task.status = .cancelled
        task.completedAt = Date()
        task.errorMessage = "Planning cancelled by user"
        try? modelContext?.save()
        
        objectWillChange.send()
    }
}
