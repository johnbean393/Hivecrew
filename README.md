<p align="center" width="100%">
<img width="120" alt="Hivecrew app icon" src="https://raw.githubusercontent.com/YOUR_USERNAME/Hivecrew/main/.github/images/app-icon.png">
</p>

<h1 align="center">Hivecrew</h1>

<p align="center">
AI agents that do real work inside isolated macOS virtual machines
</p>

Hivecrew is a native macOS app that runs AI agents in dedicated macOS Sequoia virtual machines. Dispatch tasks from a central dashboard, watch agents work autonomously, and step in to guide or assist whenever needed—all while keeping your host system completely isolated and safe.

- **Fully isolated**: Each agent runs in its own VM; no risk to your host system
- **Transparent operation**: Real-time screenshots and activity logs show exactly what agents are doing
- **Hands-on when needed**: Pause any agent, take control, add instructions, then hand back
- **Multiple LLM support**: Works with Anthropic, OpenAI, and local LLM providers

![Hivecrew Dashboard](https://raw.githubusercontent.com/YOUR_USERNAME/Hivecrew/main/.github/images/dashboard-screenshot.png)

## Key Features

### Safe by Design
Agents work inside fully isolated macOS virtual machines with controlled file access and optional network restrictions. Your host system stays protected.

### Transparent & Supervisable
Every agent action is logged with screenshots. Jump into any running agent's environment to watch live progress or review detailed session traces afterward.

### Built for macOS
Native Swift app leveraging Apple's Virtualization framework. Optimized for Apple Silicon (M1/M2/M3/M4).

![Agent Environment View](https://raw.githubusercontent.com/YOUR_USERNAME/Hivecrew/main/.github/images/agent-environment.png)

## Architecture

Hivecrew is built on three modular Swift packages:

- **HivecrewAgentProtocol**: Communication protocol between host and guest agents via virtio-vsock
- **HivecrewLLM**: Multi-provider LLM client supporting OpenAI-compatible APIs with tool calling and tracing
- **HivecrewShared**: Shared types and VM management protocols

The app runs agents in macOS Sequoia VMs with a lightweight guest agent that provides automation tools including:
- Screenshot capture and UI observation
- File operations with controlled scope
- App launching and native automation
- Mouse/keyboard control for UI-only workflows
- Shell command execution

## Requirements

- macOS Sequoia (15.0) or later
- Apple Silicon Mac (M1 or newer)
- At least 16GB RAM recommended for running concurrent agents
- ~40GB free disk space per VM

## Current Status

🚧 **Early Development** - Core infrastructure complete, agent loop in progress

**Completed:**
- ✅ Modular package architecture
- ✅ Multi-provider LLM client with tool calling
- ✅ Agent protocol design and tooling
- ✅ Request tracing and logging infrastructure
- ✅ OpenAI-compatible client with streaming support

**In Progress:**
- 🔨 VM host service and lifecycle management
- 🔨 Guest agent implementation
- 🔨 Agent orchestration loop
- 🔨 Dashboard and UI

## Build from Source

1. Clone the repository:
```bash
git clone https://github.com/YOUR_USERNAME/Hivecrew.git
cd Hivecrew
```

2. Open the workspace:
```bash
open Hivecrew.xcworkspace
```

3. Build and run from Xcode (requires signing with appropriate entitlements)

Note: The Virtualization framework requires specific entitlements that must be granted via provisioning profiles or notarization.

## Project Goals

The main goal of Hivecrew is to make AI agents practical, safe, and transparent for real-world tasks.

- **Agents as appliances**: Just describe a task and let the agent work—no complex setup required
- **Safety first**: Isolated VMs, explicit timeouts, easy kill switches, controlled permissions
- **Transparency**: Always know what agents are doing; no black boxes
- **Native performance**: Built with Swift and optimized for Apple Silicon
- **Open source**: Audit the code, contribute improvements, understand how your agents work

## Roadmap

### Foundation (Current Phase)
- [ ] Complete VM lifecycle management with XPC service
- [ ] Implement guest agent with core automation tools
- [ ] Build agent orchestration loop
- [ ] Create Dashboard and Agent Environments UI

### MVP Agent Loop
- [ ] Task dispatch and execution
- [ ] Real-time observation and screenshots
- [ ] Activity logging and traces
- [ ] Basic user intervention (pause/resume/cancel)

### File-Aware Tasks
- [ ] Inbox/outbox file handling
- [ ] Task timeout enforcement
- [ ] User questions and confirmations
- [ ] Enhanced intervention controls

### Templates & Pooling
- [ ] Template creation and management
- [ ] Warm VM pooling for fast dispatch
- [ ] Multi-agent concurrent execution
- [ ] Resource management and limits

### Polish & Release
- [ ] Onboarding flow
- [ ] Complete settings UI
- [ ] Session replay viewer
- [ ] Beta testing and hardening

## Contributing

Contributions are welcome! This project is in active development. Areas where help would be particularly valuable:

- VM lifecycle optimization
- Guest agent automation tools
- UI/UX improvements
- Testing and reliability

## Technical Details

### Communication
- Host ↔ VM Host Service: XPC with Codable messages
- VM Host Service ↔ Guest Agent: virtio-vsock JSON-RPC
- Shared files: VirtioFS mount for controlled file exchange

### Persistence
- SwiftData for task queue, sessions, VM registry
- File bundles for VM images, templates, and session traces
- Keychain for API keys

### Safety Features
- Per-VM isolated shared folders
- Configurable network access (internet, offline, or host-only)
- Tool permission controls
- Timeout enforcement
- Emergency stop controls

## License

[Add your license here]

## Credits

Built by [Your Name]

This project leverages:
- Apple's Virtualization framework
- Swift concurrency for async operations
- SwiftUI for native macOS interface

---

**Note**: Hivecrew is under active development. The current codebase reflects the foundational architecture. Agent execution capabilities are being built incrementally.
