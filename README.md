<p align="center" width="100%">
<img width="120" alt="Hivecrew app icon" src="https://raw.githubusercontent.com/johnbean393/Hivecrew/main/.github/images/app-icon.png">
</p>

<h1 align="center">Hivecrew</h1>

<p align="center">
A macOS app for running safe, parallel AI computer-use workers in isolated environments
</p>

<p align="center">
  <a href="https://github.com/johnbean393/Hivecrew/releases/latest">
    <img src="https://img.shields.io/badge/Download_DMG-Latest_Release-blue?style=for-the-badge&logo=apple&logoColor=white" alt="Download DMG">
  </a>
</p>

Hivecrew is a native macOS app for delegating real desktop work to AI workers running inside dedicated macOS virtual machines.

You can hand off work from a central dashboard, watch workers operate live, step in when needed, and review exactly what happened afterward. The goal is not just "agent demos." The goal is to make AI workers practical for real, recurring work on your Mac.

Hivecrew is built around five core ideas:

- **Safe**: workers stay isolated from your host, sensitive actions can require approval, and local file changes can be reviewed before they are applied
- **Capable**: workers can use files, web tools, skills, retrieval-backed context, voice coordination, and external tools to complete real workflows
- **Intuitive**: you describe the work in plain language, review plans visually, and manage everything from one dashboard
- **Parallel**: multiple workers can run at once, the same task can be compared across models, and recurring work can be scheduled to run automatically
- **Transparent**: live screenshots, activity feeds, session traces, and review flows make agent behavior visible instead of opaque

<p align="center">
  <a href="https://youtu.be/l4D6Jj5ukHA">
    <img src="https://raw.githubusercontent.com/johnbean393/Hivecrew/main/.github/images/dashboard-screenshot.png" alt="Hivecrew dashboard" width="720">
  </a>
  <br>
  <em>Central dashboard for dispatching work, reviewing runs, and supervising active agents</em>
</p>

## Table of Contents

- [What Hivecrew Is Good At](#what-hivecrew-is-good-at)
- [Featured Experiences](#featured-experiences)
- [Core Values](#core-values)
  - [Safe](#safe)
  - [Capable](#capable)
  - [Intuitive](#intuitive)
  - [Parallel](#parallel)
  - [Transparent](#transparent)
- [A Typical Workflow](#a-typical-workflow)
- [Requirements](#requirements)
- [Installation](#installation)
- [Build from Source](#build-from-source)
- [API](#api)
  - [Python SDK](#python-sdk)
- [Contributing](#contributing)
- [License](#license)

## What Hivecrew Is Good At

Hivecrew is best for high-leverage work where you want a capable worker to turn intent into a polished outcome while you stay in the loop.

- Voice or video-guided creation, like "Create a 3D model of this bottle of champagne"
- Turning rough briefs into polished deliverables, like decks, reports, and strategy docs
- High-context research and analysis that combines browsing, local files, and synthesis
- Parallel creative or operational work across multiple workers, models, or devices

## Featured Experiences

### Voice-First Coordination

Hivecrew has a dedicated Call tab for live voice coordination.

- To get work done, just talk, no need to type out verbose instructions
- Talk exclusively with a coordinator, not directly to workers
- See transcript, status, and active workers together
- Answer worker questions without dropping back into a text-only flow

<p align="center">
  <img src="https://raw.githubusercontent.com/johnbean393/Hivecrew/main/.github/images/voice-mode.png" alt="Voice mode in Hivecrew" width="720">
  <br>
  <em>Use the Call tab to coordinate active workers conversationally while seeing transcript, status, and task context together</em>
</p>

### Browser QA And Live Supervision

Use Hivecrew when you want to watch work unfold live, whether that is testing a web app, building a deliverable, or supervising a longer task.

<p align="center">
  <img src="https://raw.githubusercontent.com/johnbean393/Hivecrew/main/.github/images/agent-environment.png" alt="Live agent environment view" width="720">
  <br>
  <em>Watch active workers live while they operate inside isolated environments</em>
</p>

### Recurring Operational Work

Hivecrew also fits recurring work like weekly reports, scheduled audits, and routine checks.

<p align="center">
  <img src="https://raw.githubusercontent.com/johnbean393/Hivecrew/main/.github/images/scheduling.png" alt="Scheduling view" width="720">
  <br>
  <em>Turn repeatable workflows into scheduled or recurring runs</em>
</p>

### Model Comparison And Workflow Tuning

For ambiguous or high-value work, Hivecrew lets you compare providers and models instead of trusting a single run.

<p align="center">
  <img src="https://raw.githubusercontent.com/johnbean393/Hivecrew/main/.github/images/provider-settings.png" alt="Provider settings" width="720">
  <br>
  <em>Configure multiple providers and compare outcomes across different models</em>
</p>

## Core Values

### Safe

- Isolated macOS VMs keep agent activity off your host.
- Approvals, intervention, and direct takeover keep humans in control.
- Local file changes can be reviewed before they are applied.

<p align="center">
  <img src="https://raw.githubusercontent.com/johnbean393/Hivecrew/main/.github/images/human-in-the-loop.png" alt="Human in the loop controls" width="720">
  <br>
  <em>Pause, intervene, answer questions, approve actions, and keep a human in the loop</em>
</p>

### Capable

- Voice mode is a first-class way to coordinate workers.
- Workers can use files, retrieval-backed context, skills, web tools, and image generation.
- Browser access, API access, and a Python SDK extend Hivecrew beyond the desktop app.

<p align="center">
  <img src="https://raw.githubusercontent.com/johnbean393/Hivecrew/main/.github/images/skills-browser.png" alt="Skills browser" width="720">
  <br>
  <em>Reusable skills help workers take on more specialized tasks without rewriting instructions every time</em>
</p>

### Intuitive

- The dashboard is the command center for creating, tracking, and reviewing work.
- Plan-first mode makes the agent's approach visible before execution.
- Voice and web access make supervision easier away from the main prompt bar.

<p align="center">
  <img src="https://raw.githubusercontent.com/johnbean393/Hivecrew/main/.github/images/web-ui-mobile.png" alt="Hivecrew web UI on mobile" width="420">
  <br>
  <em>Remote browser access makes it practical to monitor and manage work away from your desk</em>
</p>

### Parallel

- Run multiple workers at once.
- Compare the same task across models or repeated attempts.
- Use scheduling and remote machines to extend ongoing execution capacity.

<p align="center">
  <img src="https://raw.githubusercontent.com/johnbean393/Hivecrew/main/.github/images/agent-environment.png" alt="Live agent environment view" width="720">
  <br>
  <em>Active environments make it easy to watch several workers operate at once</em>
</p>

### Transparent

- Live screenshots and activity streams show what workers are doing.
- Session traces show what happened after the run.
- Review flows make approvals, questions, and file changes explicit.

<p align="center">
  <img src="https://raw.githubusercontent.com/johnbean393/Hivecrew/main/.github/images/session-trace.png" alt="Session trace view" width="720">
  <br>
  <em>Session traces provide a readable audit trail instead of a black box</em>
</p>

## A Typical Workflow

1. Describe the task in plain English from the dashboard.
2. Attach files, accept suggested context from your own indexed materials, or reference previous work.
3. Choose whether to execute directly or review a plan first.
4. Let one worker or several workers run in parallel.
5. Watch progress live, answer questions, or step in if the worker needs help.
6. Review the result, inspect the trace, apply file changes if needed, and rerun or continue from the task if you want another pass.

## Requirements

- macOS Sequoia (15.0) or later
- Apple Silicon Mac (M1 or newer)
- At least 16GB RAM recommended for running concurrent agents
- Roughly 64GB free disk space per VM (total 192GB free disk space)

## Installation

1. Download the latest release from the [releases](https://github.com/johnbean393/Hivecrew/releases) page
2. Double-click the downloaded `Hivecrew.dmg` file
3. Drag the `Hivecrew` app into `Applications`
4. Open Hivecrew and complete onboarding

## Build from Source

1. Clone the repository:

```bash
git clone https://github.com/johnbean393/Hivecrew.git
cd Hivecrew
```

2. Open the workspace in Xcode:

```bash
open Hivecrew.xcworkspace
```

3. Build from Xcode or from the command line:

```bash
xcodebuild -workspace Hivecrew.xcworkspace -scheme Hivecrew -configuration Debug -destination 'platform=macOS' build
```

Note: Building requires the Virtualization entitlements needed for macOS VMs. The bundled `cloudflared` binary lives at `Hivecrew/Hivecrew/Resources/cloudflared/cloudflared`; if you need to replace it, see `Hivecrew/Hivecrew/Resources/cloudflared/README.md`.

## API

Hivecrew includes a REST API for programmatic task control and remote workflows. Enable it in **Settings → Connect**, then generate an API key.

For endpoint-by-endpoint examples, including schedules, provider management, web UI auth, and event streaming, see [guides/api-use.md](guides/api-use.md).

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
    model_id="your-provider/model-id",
    output_directory="./test-results",
    timeout=600.0
)

if result.was_successful:
    print(f"Test passed: {result.result_summary}")
else:
    print(f"Test failed: {result.result_summary}")
```

**Example: Scheduled Task with File Attachments**

```python
from hivecrew import HivecrewClient

client = HivecrewClient()

schedule = client.schedules.create(
    title="Weekly Sales Report",
    description="""
    Process the attached sales data files:
    1. Open the CSV files and analyze the data
    2. Create a summary report with key metrics
    3. Generate charts for revenue trends
    4. Save the report as PDF to the outbox
    """,
    provider_name="OpenRouter",
    model_id="your-provider/model-id",
    files=["./data/sales_q1.csv", "./data/sales_q2.csv"],
    recurrence={
        "type": "weekly",
        "days_of_week": [2],  # Monday (1=Sunday, 7=Saturday)
        "hour": 9,
        "minute": 0
    }
)

print(f"Scheduled task created: {schedule.id}")
print(f"Next run: {schedule.next_run_at}")
```

See the [hivecrew-python](https://github.com/johnbean393/hivecrew-python) repository for full documentation.

## Contributing

Contributions are welcome. Areas where help would be especially valuable:

- Additional tools and integrations
- Reliability and testing improvements
- UX improvements around supervision, review, and scheduling
- Documentation and examples

For internal release operations, the golden template publishing workflow and the current fastest verified R2 upload command are documented in [guides/new-template.md](guides/new-template.md).

## License

MIT License
