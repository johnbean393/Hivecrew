# AgentVM — Comprehensive Development Plan

## 1. Product Vision & Goals

### Core Concept
A native macOS app that runs AI agents inside isolated macOS 15 virtual machines. Users dispatch tasks from a central dashboard; the app spins up VMs, runs agents autonomously, and lets users supervise, guide, or assist agents at any time.

### Key User Flows
1. **Dispatch a task**: User describes a task in the Dashboard, selects model/timeout (use defaults if unspecified), hits "Run." The app provisions a VM (or reuses an idle one), launches an agent, and begins work.
2. **Supervise agents**: User switches to the Agent Supervision tab to see all active agents, their current state/screenshots, and can click into any one to watch live or intervene.
3. **Intervene / assist**: User takes over mouse/keyboard, adds clarifying instructions, or manually completes a tricky step, then hands control back to the agent.
4. **Review results**: When an agent finishes (or times out / hits budget), results and artifacts appear in the Dashboard history; user can replay the session or export outputs.

### Design Principles
- **Agents are first-class citizens**: The app is about *agents doing work*, not about managing VMs. VMs are infrastructure.
- **Transparent operation**: Users can always see what agents are doing; no black boxes.
- **Safe by default**: Timeouts, explicit permissions, easy kill switch.
- **Hands-on when needed**: Users can seamlessly step in because they know macOS; agents can ask for help.

---

## 2. Platform Constraints

| Constraint | Detail |
|------------|--------|
| Host OS | macOS 15.0+ (Sequoia) and forward (macOS 26) |
| Guest OS | macOS 15 VMs (via Apple Virtualization framework) |
| Hardware | Apple Silicon only (M1/M2/M3/M4 families) |
| Distribution | Notarized direct distribution; requires Virtualization entitlements |
| Background operation | Agents must work when VM viewer is not visible or app is not frontmost |

---

## 3. System Architecture

### 3.1 Process Model

```
┌────────────────────────────────────────────────────────────────────┐
│                      Main App Process (SwiftUI)                    │
│   Dashboard │ Agent Supervision │ Settings │ Onboarding            │
│   ViewModels, Agent Orchestrator client, UI state                  │
└──────────────────────────────┬─────────────────────────────────────┘
                               │ XPC / IPC
┌──────────────────────────────▼─────────────────────────────────────┐
│                    VM Host Service (XPC helper)                    │
│   Owns VZVirtualMachine instances, manages lifecycle, works        │
│   headless, survives UI restarts, exposes RPC to main app          │
└──────────────────────────────┬─────────────────────────────────────┘
                               │ virtio-vsock per VM
┌──────────────────────────────▼─────────────────────────────────────┐
│                GuestAgent (inside each macOS 15 VM)                │
│   Automation: screenshot, click/type/scroll, open app/file/url,   │
│   file ops, shell, clipboard, accessibility tree, heartbeat        │
└────────────────────────────────────────────────────────────────────┘
```

### 3.2 Why This Split?
- **XPC service**: VMs stay alive even if UI crashes/relaunches; better resource isolation; can enforce entitlements separately.
- **GuestAgent**: Only reliable way to automate inside a VM without requiring window focus; enables background operation.

### 3.3 Communication Channels
- **Main App ↔ VM Host Service**: XPC with Codable messages (start/stop VM, attach viewer, query status, relay tool calls).
- **VM Host Service ↔ GuestAgent**: virtio-vsock JSON-RPC (tool requests, observations, heartbeat).
- **Shared files**: VirtioFS mount for file exchange between host and guest.

---

## 4. Data Model

### 4.1 Core Entities

**Task**
- `id`, `createdAt`, `status` (queued / running / paused / completed / failed / cancelled / timed_out / budget_exceeded)
- `description` (user's natural language task)
- `modelConfig` (provider, model ID, temperature, etc.)
- `budgetConfig` (max duration)
- `assignedVMID` (nullable; set when running)
- `sessionID` (agent session reference)
- `result` (success/failure, summary, artifact paths)

**AgentSession**
- `id`, `taskID`, `vmID`
- `status`, `startedAt`, `endedAt`
- `tracePath` (directory containing screenshots, tool log, conversation)
- `tokenUsage`, `estimatedCost`
- `interventions` (list of user interventions with timestamps)

**VM**
- `id`, `status` (stopped / booting / ready / busy / suspending / error)
- `createdAt`, `lastUsedAt`
- `templateID`
- `bundlePath`
- `currentTaskID` (nullable)
- `guestAgentStatus` (disconnected / connected / unhealthy)

**Template**
- `id`, `name`, `macOSVersion`, `diskImagePath`
- `preinstalledApps` (list)
- `guestAgentVersion`

**LLMProvider**
- `id`, `type` (anthropic / openai / local)
- `displayName`, `baseURL`, `modelOptions`
- `apiKeyRef` (Keychain reference)

### 4.2 Persistence Strategy
- **SwiftData**: Task queue, session metadata, VM registry, settings, provider configs.
- **File bundles**: VM disk images, templates, session traces (screenshots, JSON logs).
- **Keychain**: API keys only.

### 4.3 On-Disk Layout

```
~/Library/Application Support/AgentVM/
├── Templates/
│   └── <template-id>/
│       ├── config.json
│       ├── disk.img
│       └── auxiliary/
├── VMs/
│   └── <vm-id>/
│       ├── config.json
│       ├── disk.img (cloned from template)
│       ├── auxiliary/
│       ├── shared/           ← VirtioFS mount root
│       │   ├── inbox/        ← files for agent to process
│       │   ├── outbox/       ← agent outputs
│       │   └── workspace/    ← scratch area
│       └── logs/
├── Sessions/
│   └── <session-id>/
│       ├── trace.json
│       ├── screenshots/
│       └── artifacts/
└── Logs/
```

---

## 5. VM Management Subsystem

### 5.1 VM Lifecycle
- **Provisioning**: Clone template disk (APFS clonefile for speed), generate unique machine identifier, write config.
- **Boot**: Load config into `VZVirtualMachineConfiguration`, start `VZVirtualMachine`.
- **Ready detection**: Wait for GuestAgent to connect via vsock and report healthy.
- **Task assignment**: Mark VM busy, hand off to agent orchestrator.
- **Idle / pool**: After task completes, VM can remain warm for fast reuse or be stopped to free resources.
- **Shutdown**: Graceful ACPI shutdown via GuestAgent; fallback to force stop.

### 5.2 VM Pool Strategy
- Maintain a small pool of **warm, idle VMs** (configurable: 0–N) for instant task dispatch.
- **Cold start** (clone + boot + GuestAgent ready) target: < 90 seconds.
- **Warm dispatch** (assign task to idle VM): < 2 seconds.
- Auto-stop idle VMs after configurable timeout to reclaim resources.

### 5.3 Resource Management
- Enforce global limits: max concurrent VMs, total RAM cap, CPU cap.
- Per-VM defaults: 2 CPU cores, 4 GB RAM, 32 GB disk (configurable).
- Expose metrics: per-VM CPU/memory, GuestAgent latency, aggregate utilization.

### 5.4 Display Attachment
- VMs run headless by default; `VZVirtualMachineView` attached on-demand when user opens supervision view.
- Detaching viewer does not stop VM or agent.

---

## 6. Shared Filesystem & Network Configuration

### 6.1 Shared Filesystem (VirtioFS)

**Mount Structure Inside Guest**
```
/Volumes/Shared/
├── inbox/       ← Host places input files here before task starts
├── outbox/      ← Agent writes outputs here; host collects after task
├── workspace/   ← Agent scratch space; cleared between tasks (optional)
```

**Safety Rules**
- Host-side directory is per-VM, sandboxed under `VMs/<vm-id>/shared/`.
- No access to broader host filesystem; agent cannot escape this root.
- Permissions: host configures read/write per subdirectory if finer control needed.
- Sensitive files: user explicitly copies files into `inbox/`; nothing automatic.

**Agent Awareness**
- GuestAgent is told the mount path at startup (via config or convention).
- Tools like `read_file`, `write_file`, `list_directory` are scoped to `/Volumes/Shared/` by default; attempts to escape are rejected.
- Task description can reference files: "Process the PDF in inbox/report.pdf and save results to outbox/."

**File Lifecycle**
1. Before task: host copies input files to `shared/inbox/`.
2. During task: agent reads inputs, writes intermediates to `workspace/`, writes final outputs to `outbox/`.
3. After task: host moves `outbox/` contents to session artifacts; optionally clears `inbox/` and `workspace/`.

### 6.2 Network Configuration

**Default: NAT with Outbound Internet**
- Guest can reach the internet (for web research, API calls, downloads).
- Host cannot be reached from guest except via vsock (intentional isolation).

**Optional: No Internet Mode**
- Network device removed or firewall rules applied inside guest.
- Use case: sensitive tasks where agent should not exfiltrate data.
- Configured per-task or per-VM via policy.

**Host Services Access**
- If agent needs to call host-side services (e.g., local LLM server), expose via a specific vsock port or configure a known host IP.

**DNS / Proxy**
- Inherit host DNS by default.
- Optional: configure proxy for logging/filtering agent web traffic.

**Agent Awareness**
- Agent is told network mode in task context ("You have internet access" vs. "You are offline; work only with local files").

---

## 7. GuestAgent Design

### 7.1 What It Is
A lightweight Swift daemon (LaunchAgent) running inside each macOS 15 VM that:
- Connects to host via virtio-vsock on boot.
- Exposes a JSON-RPC API for automation.
- Handles heartbeat/health checks.

### 7.2 Tool Categories

**Observation Tools**
- `screenshot()` → PNG image data
- `get_frontmost_app()` → bundle ID, window title
- `list_running_apps()` → list of app info
- `accessibility_snapshot()` → UI element tree (optional, powerful)

**Native Automation Tools (Preferred)**
- `open_app(bundle_id | app_name)`
- `open_file(path, with_app?)` — path relative to shared folder or absolute
- `open_url(url)`
- `activate_app(bundle_id)`
- `run_shell(command, timeout?)` → stdout, stderr, exit code
- `read_file(path)` → contents
- `write_file(path, contents)`
- `list_directory(path)` → entries
- `move_file(src, dst)`
- `clipboard_read()` / `clipboard_write(text)`

**CUA Tools (Fallback for UI-Only Workflows)**
- `mouse_move(x, y)`
- `mouse_click(x, y, button?, click_type?)` — single/double/triple
- `mouse_drag(from, to)`
- `keyboard_type(text)`
- `keyboard_key(key, modifiers?)`
- `scroll(x, y, dx, dy)`

**Accessibility Tools (Advanced, High Reliability)**
- `click_element(selector | element_id)`
- `set_element_value(element_id, value)`
- `get_element_properties(element_id)`

**System Tools**
- `wait(seconds)`
- `health_check()` → status, permissions, shared folder mounted
- `shutdown()` — graceful ACPI shutdown

### 7.3 Permissions Inside Guest
GuestAgent needs:
- **Accessibility permission** (for UI automation, accessibility tree).
- **Screen recording permission** (for screenshot if using certain APIs).

Template setup should pre-grant these or guide user through first-boot approval. Health check reports missing permissions.

### 7.4 Communication Protocol
- **Transport**: virtio-vsock, single persistent connection per VM.
- **Format**: JSON-RPC 2.0 (request/response/notification).
- **Features**: request IDs, cancellation (special "cancel" method), streaming (for long-running shell commands).
- **Heartbeat**: GuestAgent sends periodic pings; host detects disconnect and marks unhealthy.

---

## 8. Agent Orchestrator (Host-Side)

### 8.1 Responsibilities
- Accept tasks from Dashboard.
- Acquire a VM (from pool or provision new).
- Run the agent loop until completion, timeout, or user cancellation.
- Handle user interventions (pause agent, relay new instructions, resume).
- Persist traces and results.

### 8.2 Agent Loop (Per Task)
1. **Initialize**: Send task context to LLM (system prompt, task description, available tools, file context, network mode).
2. **Observe**: Request screenshot (+ optional accessibility snapshot) from GuestAgent.
3. **Decide**: Send observation + conversation history to LLM; receive reasoning + tool calls.
4. **Execute**: Run tool calls via GuestAgent; collect results.
5. **Record**: Append step to trace (tool call, result, screenshot, timestamp, tokens used).
6. **Check timeout**: If exceeded, finalize with appropriate status.
7. **Check completion**: If LLM signals done, finalize with success.
8. **Repeat** from step 2.

### 8.3 User Intervention Handling
- **Pause**: Agent loop halts after current step; VM remains running.
- **Add instructions**: User message appended to conversation; agent resumes with new context.
- **Take over**: User controls VM directly via viewer; agent loop paused; user clicks "Resume Agent" when done.
- **Cancel**: Agent loop terminates; task marked cancelled.

### 8.4 LLM Client Abstraction
Protocol with implementations for:
- **Anthropic** (Claude with computer use)
- **OpenAI** (GPT-4o with function calling)
- **Local** (Ollama, LM Studio, or similar)

Features: streaming, tool/function calling, token counting, rate limit handling, retries, context compression.

### 8.5 Timeout Enforcement
- Track cumulative tokens
- Background timer for wall-clock timeout; triggers graceful pause
- Alert user on timeout, allow resumption

---

## 9. UI Structure

### 9.1 App Window & Tabs

**Primary Window (Tab-Based)**
```
┌─────────────────────────────────────────────────────────────┐
│  [Dashboard]   [Agent Supervision]   [Settings ⚙️]          │
├─────────────────────────────────────────────────────────────┤
│                     (Tab Content)                           │
└─────────────────────────────────────────────────────────────┘
```

### 9.2 Dashboard Tab

**Purpose**: Command center for dispatching tasks and reviewing results.

**Sections**:

1. **New Task Panel**
   - Large text field for task description
   - Model selector (provider + model)
   - Budget controls: max duration (minutes)
   - Input files picker (copies to VM's inbox)
   - Advanced options (expand): specific VM, network mode, tool permissions
   - **"Run Task"** button

2. **Active Tasks**
   - Card per running task: description snippet, status, elapsed time, assigned VM, live thumbnail (updates periodically)
   - Click card → jumps to Agent Supervision with that VM focused
   - Quick actions: Pause, Cancel

3. **Completed Tasks (History)**
   - Filterable/searchable list
   - Status badges: completed, failed, cancelled, timed out
   - Each row: task description, duration, timestamp
   - Expand/click: summary, output files, "View Session Replay"

### 9.3 Agent Supervision Tab

**Purpose**: Live view into all VMs; watch agents work; intervene when needed.

**Layout**:

1. **VM Sidebar (Left)**
   - List of VMs with status indicators: 🟢 busy (agent working), 🟡 idle, ⚪ stopped, 🔴 error
   - Shows current task name if busy
   - Click to select; multi-select for bulk actions (stop all, etc.)

2. **Selected VM Detail (Right)**

   **Top: VM Display**
   - Embedded `VZVirtualMachineView` (interactive when focused)
   - Toolbar: Start/Stop VM, Pause/Resume Agent, Take Over / Hand Back, Screenshot, Fullscreen

   **Bottom: Agent Panel (Collapsible/Resizable)**
   - **Current Task**: description, model, elapsed time
   - **Activity Stream**: real-time log of agent steps
     - Each step: timestamp, tool name, short summary, expandable details
     - Clicking a step shows its screenshot
   - **Intervention Box**: text field to add instructions; "Send to Agent" button
   - **Status Bar**: GuestAgent connection, VM CPU/memory

### 9.4 Settings (Separate Window or Tab)

**Tabs/Sections**:

1. **LLM Providers**
   - Add/edit/remove providers
   - API key entry (stored in Keychain; masked display)
   - Default model selection
   - Test connection button

2. **VM Defaults**
   - CPU cores, RAM, disk size for new VMs
   - VM pool size (warm VMs to keep ready)
   - Idle timeout before auto-stop

3. **Task Defaults**
   - Default budget (cost, duration)
   - Default tool permissions
   - Screenshot capture frequency

4. **Templates**
   - List installed templates
   - Create new template (from IPSW or by customizing existing)
   - Update GuestAgent in template
   - Pre-installed apps editor (for new templates)

5. **Shared Folder & Network**
   - View/change shared folder location
   - Default network mode (internet / offline)

6. **Safety & Privacy**
   - Require confirmation for destructive tools (delete files, send network requests in certain contexts)
   - Session trace retention policy
   - Redact screenshots option

7. **Advanced**
   - Debug logging toggle
   - Export diagnostics
   - Reset GuestAgent in all VMs

### 9.5 Additional Flows

**Onboarding (First Launch)**
1. Welcome & overview
2. Download macOS 15 restore image (or select existing)
3. Create base template (progress UI; installs GuestAgent, LibreOffice, etc.)
4. Configure at least one LLM provider
5. Guided first task walkthrough

**Template Creation Wizard**
- Source selection: fresh IPSW install or clone existing template
- Customization phase: boot VM, let user install apps, then "seal" as template
- GuestAgent installation verification
- Name and save

**Session Replay View**
- Timeline scrubber synced to screenshots
- Step list with tool calls and results
- Conversation transcript view
- Export options (video, JSON, markdown report)

---

## 10. Templates & Provisioning

### 10.1 Base Template Contents
- macOS 15 installed and configured (auto-login optional, reduce setup prompts)
- GuestAgent installed as LaunchAgent, permissions pre-granted
- Shared folder mount configured (`/Volumes/Shared`)
- Pre-installed apps:
  - LibreOffice (documents, spreadsheets, presentations)
  - Default browser (Safari)
  - Text editor
  - Terminal access configured
- Optional: additional apps per user customization

### 10.2 VM Creation from Template
1. Clone template disk (APFS clonefile; instant, copy-on-write).
2. Generate new machine identifier.
3. Write VM config.
4. Boot; GuestAgent connects; mark ready.

### 10.3 Template Updates
- To update GuestAgent or apps: boot template VM, make changes, re-seal.
- Existing VMs don't auto-update; provide "Rebuild VM from Template" option.

---

## 11. Safety, Control & Reliability

### 11.1 Timeout Enforcement
- Hard caps enforced in agent loop; cannot be bypassed by LLM.

### 11.2 Tool Permissions
- Default permission set; user can customize per task or globally.
- Dangerous tools (e.g., `run_shell`) can require confirmation or be disabled.

### 11.3 Kill Switch
- Global "Stop All Agents" button in toolbar (always visible).
- Per-task cancel.
- Keyboard shortcut (e.g., Cmd+Shift+Escape) to emergency stop all.

### 11.4 Isolation & Sandboxing
- VMs are fully isolated; GuestAgent cannot access host filesystem beyond shared folder.
- Shared folder is per-VM, scoped, and user-controlled.
- Network access can be disabled per-task.

### 11.5 Observability
- All agent actions logged with timestamps.
- Screenshots at each step (or configurable frequency).
- Full conversation history preserved.
- Session replay for debugging.

### 11.6 Error Recovery
- GuestAgent disconnect: agent loop pauses, attempts reconnect, surfaces error to user.
- VM crash: task marked failed, VM restarted or replaced, user notified.
- LLM API errors: retry with backoff; after N failures, pause and notify user.

---

## 12. Technical Risks & Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| virtio-vsock reliability | High | Prototype early; implement heartbeat and reconnect logic |
| GuestAgent permission prompts | High | Pre-grant in template; provide guided setup; health check reports missing permissions |
| Headless screenshot capture | High | Use in-guest capture (GuestAgent), not host-side view capture |
| macOS 15 VM boot time | Medium | Keep warm VM pool; optimize boot sequence; suspend/resume if beneficial |
| Multi-VM resource contention | Medium | Enforce global limits; auto-pause idle VMs; surface metrics |
| Template drift (GuestAgent version mismatch) | Low | Version check on connect; prompt to rebuild VM |

---

## 13. Implementation Phases

### Phase 1: Foundation
- Project setup, entitlements, signing
- VM creation from IPSW, boot, shutdown
- Basic XPC service for VM lifecycle
- Minimal Dashboard and Agent Supervision UI (list VMs, start/stop)
- SwiftData persistence for VMs

**Milestone**: Can create, boot, interact with, and stop a macOS 15 VM from the app.

### Phase 2: GuestAgent & Communication
- GuestAgent daemon for macOS 15 guest
- virtio-vsock JSON-RPC communication
- Core tools: screenshot, open_app, open_file, click, type
- Health check and heartbeat
- Install GuestAgent in a template manually

**Milestone**: Host can send tool commands; GuestAgent executes; screenshot returned; works with VM viewer closed.

### Phase 3: Agent Loop MVP
- LLMClient abstraction + Anthropic implementation
- AgentRunner with basic loop (observe → decide → execute)
- Dashboard: new task form, run task, see status
- Agent Supervision: live activity log, screenshot updates
- Basic tracing (JSON log + screenshots saved)

**Milestone**: Can dispatch a simple task from Dashboard; agent runs autonomously; user watches in Supervision tab.

### Phase 4: Shared Filesystem, Intervention
- VirtioFS shared folder integration
- File-aware task flow (inbox/outbox)
- Timeout enforcement
- User intervention: pause, add instructions, take over, resume
- Session history in Dashboard

**Milestone**: End-to-end task with file inputs/outputs; user can intervene mid-task; timeouts work.

### Phase 5: Templates, Pooling, Multi-Agent
- Template creation wizard
- APFS clone-based fast VM provisioning
- Warm VM pool with configurable size
- Run multiple tasks/agents in parallel
- Resource manager with global limits

**Milestone**: Spin up task in < 5 seconds (warm) or < 90 seconds (cold); 3+ concurrent agents stable.

### Phase 6: Polish, Safety, Onboarding
- Full Settings implementation
- Onboarding flow
- Session replay view
- Safety features: permissions, kill switch, confirmations
- Additional LLM providers (OpenAI, local)
- Error handling, edge cases, reliability hardening
- Performance tuning

**Milestone**: App ready for beta users.

---

## 14. Success Metrics

| Metric | Target |
|--------|--------|
| Cold start to agent working | < 90 seconds |
| Warm dispatch to agent working | < 5 seconds |
| Agent step latency (tool execution, excluding LLM) | < 500 ms |
| Concurrent agents supported | 4+ on M1 Pro, 6+ on M2 Max |
| Task success rate (well-defined tasks) | > 90% |
| User intervention latency (pause to interactive) | < 2 seconds |
| Session trace completeness | 100% steps logged with screenshots |

---

## 15. Open Questions / Future Considerations

- **Suspend/resume VMs**: Could speed up "warm" dispatch further; depends on Virtualization framework support and stability.
- **Agent collaboration**: Multiple agents working on sub-tasks of a larger goal.
- **Scheduled tasks**: Run agents on a schedule (e.g., daily report generation).
- **Agent templates/presets**: Pre-defined agent behaviors for common workflows.
- **Plugin system**: Let users add custom tools beyond the built-in set.
- **Cloud sync**: Sync templates, settings, or session history across machines.