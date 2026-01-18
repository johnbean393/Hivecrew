<p align="center" width="100%">
<img width="120" alt="Hivecrew app icon" src="https://raw.githubusercontent.com/johnbean393/Hivecrew/main/.github/images/app-icon.png">
</p>

<h1 align="center">Hivecrew</h1>

<p align="center">
A macOS app for running parallel AI computer use agents in sandboxed local VMs
</p>

Hivecrew is a native macOS app that runs AI computer use agents in dedicated macOS virtual machines. Dispatch tasks from a central dashboard, watch agents work autonomously, and step in to guide or assist whenever needed—all while keeping your host system completely isolated and safe.

![Hivecrew Dashboard](https://raw.githubusercontent.com/johnbean393/Hivecrew/main/.github/images/dashboard-screenshot.png)

## Features

- **Fully Isolated Execution**: Each agent runs in its own macOS VM with controlled file access and configurable network restrictions. Your host system stays completely protected.

![Agent Environment View](https://raw.githubusercontent.com/johnbean393/Hivecrew/main/.github/images/agent-environment.png)

- **Parallel Agents**: Run multiple agents concurrently in separate VMs, each with its own task and environment.

- **Real-Time Supervision**: Watch agents work with live screenshots and activity logs. Jump into any agent's environment to observe or review detailed session traces afterward.

- **Human-in-the-Loop**: Pause any agent, take control with your mouse and keyboard, add clarifying instructions, then hand control back seamlessly.

- **Multi-LLM Support**: Works with Anthropic, OpenAI, and any OpenAI-compatible local LLM provider. Easy provider switching in settings.

- **File Handover**: Attach input files to tasks and specify output directories for deliverables. Agents work with files through a secure shared folder system.

- **Safety Controls**: Built-in timeouts, iteration limits, tool permission controls, and emergency stop switches keep agents under control.

- **Native Performance**: Built entirely in Swift with Apple's Virtualization framework. Optimized for Apple Silicon (M1/M2/M3/M4/M5).

## Architecture

Hivecrew is built on three modular Swift packages:

- **HivecrewAgentProtocol**: Communication protocol between host and guest agents via virtio-vsock
- **HivecrewLLM**: Multi-provider LLM client supporting OpenAI-compatible APIs with tool calling and tracing
- **HivecrewShared**: Shared types and VM management protocols

The app runs agents in macOS Tahoe VMs with a lightweight guest agent that provides automation tools including:
- Screenshot capture and UI observation
- File operations with controlled scope
- App launching and native automation
- Mouse/keyboard control for UI-only workflows
- Shell command execution

## Requirements

- macOS Tahoe (26.0) or later
- Apple Silicon Mac (M1 or newer)
- At least 16GB RAM recommended for running concurrent agents
- ~64GB free disk space per VM

## Build from Source

1. Clone the repository:
```bash
git clone https://github.com/johnbean393/Hivecrew.git
cd Hivecrew
```

2. Open the workspace:
```bash
open Hivecrew.xcworkspace
```

3. Build and run from Xcode (requires signing with appropriate entitlements)

Note: The Virtualization framework requires specific entitlements that must be granted via provisioning profiles or notarization.

## API

Hivecrew includes a REST API for programmatic task control. Enable it in **Settings → API** and generate an API key.

### Python SDK

```bash
pip install hivecrew
```

**Example: Automated UI Testing**

```python
from hivecrew import HivecrewClient

client = HivecrewClient()  # Uses HIVECREW_API_KEY env var

result = client.tasks.run(
    description="""
    Test the login flow:
    1. Open Safari and go to https://staging.example.com
    2. Click "Sign In" and enter test@example.com / testpass123
    3. Verify the dashboard loads and shows "Welcome back"
    4. Take a screenshot and save it to the outbox
    """,
    provider_name="OpenRouter",
    model_id="anthropic/claude-sonnet-4.5",
    output_directory="./test-results",
    timeout=600.0
)

if result.was_successful:
    print(f"Test passed: {result.result_summary}")
else:
    print(f"Test failed: {result.result_summary}")
```

See the [hivecrew-python](https://github.com/johnbean393/hivecrew-python) repository for full documentation.

## Contributing

Contributions are welcome! Areas where help would be particularly valuable:

- Additional automation tools and capabilities
- UI/UX improvements
- Testing and reliability
- Documentation

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

MIT License
