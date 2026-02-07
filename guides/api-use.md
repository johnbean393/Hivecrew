# Hivecrew REST API Usage Guide

The Hivecrew REST API allows you to programmatically create and manage computer-use agent tasks.

## Setup

### 1. Enable the API Server

1. Open Hivecrew → Settings → API
2. Toggle **Enable API Server**
3. Note the port (default: 5482)

### 2. Generate an API Key

1. In Settings → API, click **Generate API Key**
2. Copy the key and store it securely
3. Set it as an environment variable:

```bash
export HIVECREW_API_KEY="hc_your_api_key_here"
```

## Authentication

All API requests require a Bearer token in the `Authorization` header:

```bash
curl -H "Authorization: Bearer $HIVECREW_API_KEY" \
  http://localhost:5482/api/v1/tasks
```

## Base URL

```
http://localhost:5482/api/v1
```

For remote access, replace `localhost` with your machine's IP address.

---

## Tasks API

### Create a Task

```bash
POST /api/v1/tasks
```

**Request Body (JSON):**

```json
{
  "description": "Open Safari and search for 'Swift programming'",
  "providerName": "OpenRouter",
  "modelId": "anthropic/claude-sonnet-4.5",
  "outputDirectory": "/Users/me/Desktop/outputs",
  "planFirst": true
}
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `description` | string | Yes | The task description for the agent |
| `providerName` | string | Yes | Name of the LLM provider (e.g., "OpenRouter") |
| `modelId` | string | Yes | Model identifier (e.g., "anthropic/claude-sonnet-4.5") |
| `outputDirectory` | string | No | Absolute path for task output files (overrides app settings) |
| `planFirst` | bool | No | If `true`, the agent generates a plan for review before executing the task (default: `false`) |

**Example:**

```bash
curl -X POST http://localhost:5482/api/v1/tasks \
  -H "Authorization: Bearer $HIVECREW_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "description": "Open Safari and search for Swift programming",
    "providerName": "OpenRouter",
    "modelId": "anthropic/claude-sonnet-4.5"
  }'
```

**Example with plan-first mode:**

```bash
curl -X POST http://localhost:5482/api/v1/tasks \
  -H "Authorization: Bearer $HIVECREW_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "description": "Create a report and save it",
    "providerName": "OpenRouter",
    "modelId": "anthropic/claude-sonnet-4.5",
    "planFirst": true
  }'
```

**Response:**

```json
{
  "id": "A1B2C3D4-E5F6-7890-ABCD-EF1234567890",
  "title": "Open Safari and search...",
  "description": "Open Safari and search for Swift programming",
  "status": "queued",
  "providerName": "OpenRouter",
  "modelId": "anthropic/claude-sonnet-4.5",
  "createdAt": "2026-01-18T10:30:00Z",
  "planFirst": false,
  "inputFiles": [],
  "outputFiles": []
}
```

### Create a Task with File Uploads

Use `multipart/form-data` to upload files:

```bash
curl -X POST http://localhost:5482/api/v1/tasks \
  -H "Authorization: Bearer $HIVECREW_API_KEY" \
  -F "description=Analyze this document and summarize it" \
  -F "providerName=OpenRouter" \
  -F "modelId=anthropic/claude-sonnet-4.5" \
  -F "files=@/path/to/document.pdf" \
  -F "files=@/path/to/data.csv"
```

**With plan-first and custom output directory:**

```bash
curl -X POST http://localhost:5482/api/v1/tasks \
  -H "Authorization: Bearer $HIVECREW_API_KEY" \
  -F "description=Analyze this document and summarize it" \
  -F "providerName=OpenRouter" \
  -F "modelId=anthropic/claude-sonnet-4.5" \
  -F "planFirst=true" \
  -F "outputDirectory=/Users/me/Desktop/analysis-results" \
  -F "files=@/path/to/document.pdf"
```

### List Tasks

```bash
GET /api/v1/tasks
```

**Query Parameters:**

| Parameter | Type   | Default | Description |
|-----------|--------|---------|-------------|
| `status`  | string | -       | Filter by status (comma-separated): `queued`, `running`, `completed`, `failed`, `cancelled` |
| `limit`   | int    | 50      | Max results (1-200) |
| `offset`  | int    | 0       | Pagination offset |
| `sort`    | string | `createdAt` | Sort field: `createdAt`, `startedAt`, `completedAt` |
| `order`   | string | `desc`  | Sort order: `asc`, `desc` |

**Example:**

```bash
# List running and queued tasks
curl "http://localhost:5482/api/v1/tasks?status=running,queued&limit=10" \
  -H "Authorization: Bearer $HIVECREW_API_KEY"
```

**Response:**

```json
{
  "tasks": [
    {
      "id": "...",
      "title": "...",
      "status": "running",
      "providerName": "OpenRouter",
      "modelId": "anthropic/claude-sonnet-4.5",
      "createdAt": "2026-01-18T10:30:00Z",
      "startedAt": "2026-01-18T10:30:05Z",
      "inputFileCount": 0,
      "outputFileCount": 0
    }
  ],
  "total": 1,
  "limit": 10,
  "offset": 0
}
```

### Get Task Details

```bash
GET /api/v1/tasks/:id
```

**Example:**

```bash
curl http://localhost:5482/api/v1/tasks/A1B2C3D4-E5F6-7890-ABCD-EF1234567890 \
  -H "Authorization: Bearer $HIVECREW_API_KEY"
```

**Response:**

```json
{
  "id": "A1B2C3D4-E5F6-7890-ABCD-EF1234567890",
  "title": "Open Safari and search...",
  "description": "Open Safari and search for Swift programming",
  "status": "completed",
  "providerName": "OpenRouter",
  "modelId": "anthropic/claude-sonnet-4.5",
  "createdAt": "2026-01-18T10:30:00Z",
  "startedAt": "2026-01-18T10:30:05Z",
  "completedAt": "2026-01-18T10:32:15Z",
  "resultSummary": "Successfully opened Safari and searched for Swift programming.",
  "wasSuccessful": true,
  "vmId": "vm-123",
  "duration": 130,
  "stepCount": 8,
  "tokenUsage": {
    "prompt": 5420,
    "completion": 1230,
    "total": 6650
  },
  "planFirst": false,
  "planMarkdown": null,
  "pendingQuestion": null,
  "pendingPermission": null,
  "inputFiles": [],
  "outputFiles": [
    {
      "name": "screenshot.png",
      "size": 245678,
      "mimeType": "image/png"
    }
  ]
}
```

| Field | Type | Description |
|-------|------|-------------|
| `planFirst` | bool | Whether plan-first mode was enabled for this task |
| `planMarkdown` | string? | The generated plan in Markdown format (present when task is in `planning` or `planReview` status) |
| `pendingQuestion` | object? | A pending agent question awaiting a human answer (see [Agent Questions](#agent-questions)) |
| `pendingPermission` | object? | A pending permission request from the agent (see [Agent Permissions](#agent-permissions)) |

### Update Task (Actions)

```bash
PATCH /api/v1/tasks/:id
```

**Request Body:**

```json
{
  "action": "cancel",
  "instructions": null,
  "planMarkdown": null
}
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `action` | string | Yes | The action to perform (see table below) |
| `instructions` | string | No | Additional instructions (used with `resume`) |
| `planMarkdown` | string | No | Edited plan markdown (used with `edit_plan`) |

**Actions:**

| Action | Description |
|--------|-------------|
| `cancel` | Cancel a running or queued task |
| `pause` | Pause a running task |
| `resume` | Resume a paused task (optional: provide new instructions) |
| `rerun` | Re-run a finished task (creates a new task with the same configuration) |
| `approve_plan` | Approve a pending plan so the agent proceeds with execution (task must be in `planReview` status) |
| `edit_plan` | Submit an edited plan for the agent to follow (task must be in `planReview` status; include `planMarkdown`) |
| `cancel_plan` | Cancel a pending plan and stop the task (task must be in `planning` or `planReview` status) |

**Example - Cancel:**

```bash
curl -X PATCH http://localhost:5482/api/v1/tasks/A1B2C3D4... \
  -H "Authorization: Bearer $HIVECREW_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"action": "cancel"}'
```

**Example - Resume with instructions:**

```bash
curl -X PATCH http://localhost:5482/api/v1/tasks/A1B2C3D4... \
  -H "Authorization: Bearer $HIVECREW_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "action": "resume",
    "instructions": "Continue and also take a screenshot"
  }'
```

**Example - Rerun a completed task:**

```bash
curl -X PATCH http://localhost:5482/api/v1/tasks/A1B2C3D4... \
  -H "Authorization: Bearer $HIVECREW_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"action": "rerun"}'
```

**Example - Approve a pending plan:**

```bash
curl -X PATCH http://localhost:5482/api/v1/tasks/A1B2C3D4... \
  -H "Authorization: Bearer $HIVECREW_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"action": "approve_plan"}'
```

**Example - Edit a plan before approving:**

```bash
curl -X PATCH http://localhost:5482/api/v1/tasks/A1B2C3D4... \
  -H "Authorization: Bearer $HIVECREW_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "action": "edit_plan",
    "planMarkdown": "## Updated Plan\n1. Step one\n2. Step two revised\n3. New step three"
  }'
```

### Delete Task

```bash
DELETE /api/v1/tasks/:id
```

**Example:**

```bash
curl -X DELETE http://localhost:5482/api/v1/tasks/A1B2C3D4... \
  -H "Authorization: Bearer $HIVECREW_API_KEY"
```

Returns `204 No Content` on success.

### List Task Files

```bash
GET /api/v1/tasks/:id/files
```

**Response:**

```json
{
  "taskId": "A1B2C3D4...",
  "inputFiles": [
    {
      "name": "document.pdf",
      "size": 102400,
      "mimeType": "application/pdf",
      "uploadedAt": "2026-01-18T10:30:00Z"
    }
  ],
  "outputFiles": [
    {
      "name": "summary.txt",
      "size": 2048,
      "mimeType": "text/plain",
      "createdAt": "2026-01-18T10:35:00Z"
    }
  ]
}
```

### Download Task File

```bash
GET /api/v1/tasks/:id/files/:filename
```

**Query Parameters:**

| Parameter | Type   | Default  | Description |
|-----------|--------|----------|-------------|
| `type`    | string | `output` | File type: `input` or `output` |

**Example:**

```bash
# Download an output file
curl -o summary.txt \
  "http://localhost:5482/api/v1/tasks/A1B2C3D4.../files/summary.txt" \
  -H "Authorization: Bearer $HIVECREW_API_KEY"

# Download an input file
curl -o document.pdf \
  "http://localhost:5482/api/v1/tasks/A1B2C3D4.../files/document.pdf?type=input" \
  -H "Authorization: Bearer $HIVECREW_API_KEY"
```

### Get Task Screenshot

```bash
GET /api/v1/tasks/:id/screenshot
```

Returns the latest VM screenshot for a running task. The response is the raw image data (not JSON).

**Example:**

```bash
curl -o screenshot.png \
  http://localhost:5482/api/v1/tasks/A1B2C3D4.../screenshot \
  -H "Authorization: Bearer $HIVECREW_API_KEY"
```

**Response:**

- `200 OK` with the image body (`Content-Type: image/png` or similar) and `Cache-Control: no-cache`
- `404 Not Found` if no screenshot is currently available (task is not running or has no VM)

### Get Task Activity (Polling)

```bash
GET /api/v1/tasks/:id/activity
```

Returns activity log events for a running task. Use the `since` parameter to fetch only new events since your last poll. This is the recommended way to monitor live task progress.

**Query Parameters:**

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `since`   | int  | 0       | Event offset — pass the `total` from the previous response to get only new events |

**Example:**

```bash
# First poll (get all events)
curl "http://localhost:5482/api/v1/tasks/A1B2C3D4.../activity" \
  -H "Authorization: Bearer $HIVECREW_API_KEY"

# Subsequent polls (get only new events since offset 12)
curl "http://localhost:5482/api/v1/tasks/A1B2C3D4.../activity?since=12" \
  -H "Authorization: Bearer $HIVECREW_API_KEY"
```

**Response:**

```json
{
  "events": [
    {
      "type": "tool_call_start",
      "timestamp": "2026-01-18T10:30:10Z",
      "data": {
        "summary": "Opening Safari",
        "activityType": "tool_call"
      }
    },
    {
      "type": "screenshot",
      "timestamp": "2026-01-18T10:30:12Z",
      "data": {
        "summary": "Captured screen state",
        "activityType": "observation"
      }
    },
    {
      "type": "llm_response",
      "timestamp": "2026-01-18T10:30:15Z",
      "data": {
        "summary": "Analyzing screenshot",
        "activityType": "llm_response",
        "reasoning": "The browser has opened. I need to navigate to..."
      }
    }
  ],
  "total": 15
}
```

| Field | Type | Description |
|-------|------|-------------|
| `events` | array | New events since the `since` offset |
| `total` | int | Total event count on the server — pass this as `since` in your next request |

**Event Types:**

| Event Type | Description |
|------------|-------------|
| `screenshot` | A new screenshot/observation was captured |
| `tool_call_start` | The agent started invoking a tool |
| `tool_call_result` | A tool invocation completed with a result |
| `llm_response` | The LLM returned a response |
| `status_change` | The task status changed (includes `status` and `taskId` in data) |
| `subagent_update` | A sub-agent reported progress (includes `subagentId` in data) |
| `question` | The agent asked a question requiring human input |
| `permission_request` | The agent requested permission for an operation |

**Event Data Fields:**

All events include:

| Field | Type | Description |
|-------|------|-------------|
| `type` | string | The event type |
| `timestamp` | string | ISO 8601 timestamp |
| `data.summary` | string | Human-readable summary of the event |
| `data.activityType` | string | Internal activity category (`tool_call`, `tool_result`, `llm_response`, `llm_request`, `observation`, `error`, `info`, `user_question`, `user_answer`, `subagent`) |

Some events include additional fields:

| Field | Present In | Description |
|-------|-----------|-------------|
| `data.details` | varies | Extended details about the event |
| `data.reasoning` | varies | The agent's reasoning/thinking for the action |
| `data.subagentId` | `subagent_update` | Identifier of the reporting sub-agent |
| `data.status` | `status_change` | The new task status value |
| `data.taskId` | `status_change` | The task identifier |

Returns an empty `events` array with `total: 0` if the task has no active agent (e.g., task is queued or already finished).

---

## Agent Questions

While a task is running, the agent may pause and ask a question that requires a human answer before it can proceed. The pending question (if any) is also included in the task detail response under the `pendingQuestion` field.

### Get Pending Question

```bash
GET /api/v1/tasks/:id/question
```

**Example:**

```bash
curl http://localhost:5482/api/v1/tasks/A1B2C3D4.../question \
  -H "Authorization: Bearer $HIVECREW_API_KEY"
```

**Response (question pending):**

```json
{
  "id": "Q-1234",
  "question": "Which browser should I use for this task?",
  "suggestedAnswers": ["Safari", "Chrome", "Firefox"],
  "createdAt": "2026-01-18T10:31:00Z"
}
```

| Field | Type | Description |
|-------|------|-------------|
| `id` | string | Unique identifier for this question |
| `question` | string | The question text from the agent |
| `suggestedAnswers` | string[]? | Optional list of suggested answers (for multiple-choice questions) |
| `createdAt` | string | ISO 8601 timestamp of when the question was asked |

Returns `204 No Content` if there is no pending question.

### Answer a Question

```bash
POST /api/v1/tasks/:id/question/answer
```

**Request Body:**

```json
{
  "questionId": "Q-1234",
  "answer": "Safari"
}
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `questionId` | string | Yes | The `id` of the pending question being answered |
| `answer` | string | Yes | The answer text |

**Example:**

```bash
curl -X POST http://localhost:5482/api/v1/tasks/A1B2C3D4.../question/answer \
  -H "Authorization: Bearer $HIVECREW_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "questionId": "Q-1234",
    "answer": "Safari"
  }'
```

Returns `204 No Content` on success. Returns `409 Conflict` if the `questionId` does not match the current pending question.

---

## Agent Permissions

The agent may request permission before performing a potentially dangerous operation (e.g., running a shell command, accessing certain resources). The pending permission (if any) is also included in the task detail response under the `pendingPermission` field.

### Get Pending Permission Request

```bash
GET /api/v1/tasks/:id/permission
```

**Example:**

```bash
curl http://localhost:5482/api/v1/tasks/A1B2C3D4.../permission \
  -H "Authorization: Bearer $HIVECREW_API_KEY"
```

**Response (permission pending):**

```json
{
  "id": "P-5678",
  "toolName": "bash",
  "details": "Run command: rm -rf /tmp/old-cache",
  "createdAt": "2026-01-18T10:31:30Z"
}
```

| Field | Type | Description |
|-------|------|-------------|
| `id` | string | Unique identifier for this permission request |
| `toolName` | string | The tool or operation requesting permission |
| `details` | string | Human-readable description of what the agent wants to do |
| `createdAt` | string | ISO 8601 timestamp of when permission was requested |

Returns `204 No Content` if there is no pending permission request.

### Respond to Permission Request

```bash
POST /api/v1/tasks/:id/permission/respond
```

**Request Body:**

```json
{
  "permissionId": "P-5678",
  "approved": true
}
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `permissionId` | string | Yes | The `id` of the pending permission request |
| `approved` | bool | Yes | `true` to allow, `false` to deny |

**Example:**

```bash
curl -X POST http://localhost:5482/api/v1/tasks/A1B2C3D4.../permission/respond \
  -H "Authorization: Bearer $HIVECREW_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "permissionId": "P-5678",
    "approved": true
  }'
```

Returns `204 No Content` on success. Returns `409 Conflict` if the `permissionId` does not match the current pending request.

---

## Event Streaming (SSE) — Experimental

> **Note:** The SSE endpoint is experimental and may not work reliably in all environments. For production use, the [activity polling endpoint](#get-task-activity-polling) (`GET /tasks/:id/activity`) is recommended — it uses the same event format and is fully supported.

### Subscribe to Task Events

```bash
GET /api/v1/tasks/:id/events
```

Opens a long-lived SSE connection. Existing activity log entries are emitted immediately as an initial burst, followed by live events as they occur. The stream ends automatically when the task reaches a terminal state (`completed`, `failed`, or `cancelled`).

**Example:**

```bash
curl -N http://localhost:5482/api/v1/tasks/A1B2C3D4.../events \
  -H "Authorization: Bearer $HIVECREW_API_KEY"
```

**Response Headers:**

```
Content-Type: text/event-stream
Cache-Control: no-cache
Connection: keep-alive
```

**Event Format:**

Each event follows the standard SSE format:

```
event: <event_type>
data: <json_payload>

```

**Example event stream:**

```
event: tool_call_start
data: {"type":"tool_call_start","timestamp":"2026-01-18T10:30:10Z","data":{"summary":"Opening Safari","activityType":"tool_call"}}

event: screenshot
data: {"type":"screenshot","timestamp":"2026-01-18T10:30:12Z","data":{"summary":"Captured screen state","activityType":"observation"}}

event: status_change
data: {"type":"status_change","timestamp":"2026-01-18T10:32:15Z","data":{"status":"completed","taskId":"A1B2C3D4..."}}

```

The event types and data fields are identical to those documented in the [activity polling endpoint](#get-task-activity-polling).

---

## Schedules API

Scheduled tasks are task templates that run at specified times. They are separate from regular tasks - when a scheduled task triggers, it creates a new task that runs immediately.

### Create Scheduled Task

```bash
POST /api/v1/schedules
```

**Request Body (JSON):**

```json
{
  "title": "Daily Backup Check",
  "description": "Check that all backups completed successfully",
  "providerName": "OpenRouter",
  "modelId": "anthropic/claude-sonnet-4.5",
  "schedule": {
    "scheduledAt": "2026-01-21T09:00:00Z"
  }
}
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `title` | string | Yes | Title for the scheduled task |
| `description` | string | Yes | Task description for the agent |
| `providerName` | string | Yes | Name of the LLM provider |
| `modelId` | string | Yes | Model identifier |
| `outputDirectory` | string | No | Custom output directory |
| `schedule` | object | Yes | Schedule configuration |

**Schedule Object:**

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `scheduledAt` | string | For one-time | ISO 8601 datetime for one-time schedules |
| `recurrence` | object | For recurring | Recurrence configuration |

**Recurrence Object:**

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `type` | string | Yes | `daily`, `weekly`, or `monthly` |
| `daysOfWeek` | int[] | For weekly | Days of week (1=Sunday, 7=Saturday) |
| `dayOfMonth` | int | For monthly | Day of month (1-31) |
| `hour` | int | Yes | Hour of day (0-23) |
| `minute` | int | Yes | Minute of hour (0-59) |

**Example - One-time schedule:**

```bash
curl -X POST http://localhost:5482/api/v1/schedules \
  -H "Authorization: Bearer $HIVECREW_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "title": "Generate Report",
    "description": "Generate the weekly status report",
    "providerName": "OpenRouter",
    "modelId": "anthropic/claude-sonnet-4.5",
    "schedule": {
      "scheduledAt": "2026-01-21T09:00:00Z"
    }
  }'
```

**Example - Recurring schedule (every Monday at 9am):**

```bash
curl -X POST http://localhost:5482/api/v1/schedules \
  -H "Authorization: Bearer $HIVECREW_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "title": "Weekly Email Summary",
    "description": "Check emails and create a summary",
    "providerName": "OpenRouter",
    "modelId": "anthropic/claude-sonnet-4.5",
    "schedule": {
      "recurrence": {
        "type": "weekly",
        "daysOfWeek": [2],
        "hour": 9,
        "minute": 0
      }
    }
  }'
```

### Create Scheduled Task with File Attachments

Use `multipart/form-data` to upload files that will be available each time the scheduled task runs:

```bash
curl -X POST http://localhost:5482/api/v1/schedules \
  -H "Authorization: Bearer $HIVECREW_API_KEY" \
  -F "title=Weekly Sales Report" \
  -F "description=Process the attached sales data and generate a summary report" \
  -F "providerName=OpenRouter" \
  -F "modelId=anthropic/claude-sonnet-4.5" \
  -F 'schedule={"recurrence":{"type":"weekly","daysOfWeek":[2],"hour":9,"minute":0}}' \
  -F "files=@/path/to/sales_template.xlsx" \
  -F "files=@/path/to/report_format.docx"
```

**With one-time schedule and custom output directory:**

```bash
curl -X POST http://localhost:5482/api/v1/schedules \
  -H "Authorization: Bearer $HIVECREW_API_KEY" \
  -F "title=Analyze Q4 Data" \
  -F "description=Analyze the attached Q4 data files and create visualizations" \
  -F "providerName=OpenRouter" \
  -F "modelId=anthropic/claude-sonnet-4.5" \
  -F "outputDirectory=/Users/me/Desktop/q4-analysis" \
  -F 'schedule={"scheduledAt":"2026-01-21T09:00:00Z"}' \
  -F "files=@/path/to/q4_revenue.csv" \
  -F "files=@/path/to/q4_expenses.csv"
```

The attached files will be available in the agent's inbox folder when the scheduled task runs.

**Response:**

```json
{
  "id": "A1B2C3D4...",
  "title": "Weekly Email Summary",
  "description": "Check emails and create a summary",
  "providerName": "OpenRouter",
  "modelId": "anthropic/claude-sonnet-4.5",
  "isEnabled": true,
  "scheduleType": "recurring",
  "recurrence": {
    "type": "weekly",
    "daysOfWeek": [2],
    "hour": 9,
    "minute": 0
  },
  "nextRunAt": "2026-01-27T09:00:00Z",
  "createdAt": "2026-01-20T10:00:00Z",
  "inputFiles": [],
  "inputFileCount": 0
}
```

**Response (with file attachments):**

```json
{
  "id": "B2C3D4E5...",
  "title": "Weekly Sales Report",
  "description": "Process the attached sales data and generate a summary report",
  "providerName": "OpenRouter",
  "modelId": "anthropic/claude-sonnet-4.5",
  "isEnabled": true,
  "scheduleType": "recurring",
  "recurrence": {
    "type": "weekly",
    "daysOfWeek": [2],
    "hour": 9,
    "minute": 0
  },
  "nextRunAt": "2026-01-27T09:00:00Z",
  "createdAt": "2026-01-20T10:00:00Z",
  "inputFiles": [
    {
      "name": "sales_template.xlsx",
      "size": 45678,
      "mimeType": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
    },
    {
      "name": "report_format.docx",
      "size": 23456,
      "mimeType": "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
    }
  ],
  "inputFileCount": 2
}
```

### List Scheduled Tasks

```bash
GET /api/v1/schedules
```

**Query Parameters:**

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `limit` | int | 50 | Max results (1-200) |
| `offset` | int | 0 | Pagination offset |

**Response:**

```json
{
  "schedules": [
    {
      "id": "A1B2C3D4...",
      "title": "Daily Backup Check",
      "description": "Check that all backups completed",
      "providerName": "OpenRouter",
      "modelId": "anthropic/claude-sonnet-4.5",
      "isEnabled": true,
      "scheduleType": "recurring",
      "recurrence": {
        "type": "daily",
        "hour": 6,
        "minute": 0
      },
      "nextRunAt": "2026-01-21T06:00:00Z",
      "lastRunAt": "2026-01-20T06:00:00Z",
      "createdAt": "2026-01-15T10:00:00Z",
      "inputFiles": [],
      "inputFileCount": 0
    }
  ],
  "total": 1,
  "limit": 50,
  "offset": 0
}
```

### Get Scheduled Task

```bash
GET /api/v1/schedules/:id
```

### Update Scheduled Task

```bash
PATCH /api/v1/schedules/:id
```

**Request Body:**

```json
{
  "title": "Updated Title",
  "isEnabled": false
}
```

| Field | Type | Description |
|-------|------|-------------|
| `title` | string | New title |
| `description` | string | New description |
| `scheduledAt` | string | New scheduled time (one-time) |
| `recurrence` | object | New recurrence configuration |
| `isEnabled` | bool | Enable/disable the schedule |

### Delete Scheduled Task

```bash
DELETE /api/v1/schedules/:id
```

Returns `204 No Content` on success.

### Run Scheduled Task Now

```bash
POST /api/v1/schedules/:id/run
```

Triggers the scheduled task to run immediately, creating a new task. Does not affect the schedule's next run time.

**Response:**

Returns the created task object.

---

## Providers API

### List Providers

```bash
GET /api/v1/providers
```

**Example:**

```bash
curl http://localhost:5482/api/v1/providers \
  -H "Authorization: Bearer $HIVECREW_API_KEY"
```

**Response:**

```json
{
  "providers": [
    {
      "id": "provider-123",
      "displayName": "OpenRouter",
      "baseURL": "https://openrouter.ai/api/v1",
      "isDefault": true,
      "hasAPIKey": true,
      "createdAt": "2026-01-10T08:00:00Z"
    }
  ]
}
```

### Get Provider Details

```bash
GET /api/v1/providers/:id
```

### List Provider Models

```bash
GET /api/v1/providers/:id/models
```

**Response:**

```json
{
  "models": [
    {
      "id": "anthropic/claude-sonnet-4.5",
      "name": "anthropic/claude-sonnet-4.5",
      "contextLength": 200000
    },
    {
      "id": "openai/gpt-4o",
      "name": "openai/gpt-4o",
      "contextLength": 128000
    }
  ]
}
```

---

## Templates API

### List Templates

```bash
GET /api/v1/templates
```

**Response:**

```json
{
  "templates": [
    {
      "id": "golden-v3",
      "name": "Hivecrew Golden Image",
      "description": "Pre-configured macOS with agent software",
      "isDefault": true,
      "cpuCount": 4
    }
  ],
  "defaultTemplateId": "golden-v3"
}
```

### Get Template Details

```bash
GET /api/v1/templates/:id
```

---

## System API

### Get System Status

```bash
GET /api/v1/system/status
```

**Response:**

```json
{
  "status": "healthy",
  "version": "1.2.0",
  "uptime": 3600,
  "agents": {
    "running": 2,
    "paused": 0,
    "queued": 3,
    "maxConcurrent": 4
  },
  "vms": {
    "active": 2,
    "pending": 1,
    "available": 1
  },
  "resources": {
    "memoryTotalGB": 32.0
  }
}
```

### Get System Configuration

```bash
GET /api/v1/system/config
```

**Response:**

```json
{
  "maxConcurrentVMs": 4,
  "defaultTimeoutMinutes": 30,
  "defaultMaxIterations": 100,
  "defaultTemplateId": "golden-v3",
  "apiPort": 5482
}
```

---

## Health Check

The `/health` endpoint does not require authentication:

```bash
curl http://localhost:5482/health
```

Returns `OK` if the server is running.

---

## Error Responses

All errors return a consistent JSON structure:

```json
{
  "error": {
    "code": "not_found",
    "message": "Task with ID 'xyz' not found"
  }
}
```

**Error Codes:**

| Code | HTTP Status | Description |
|------|-------------|-------------|
| `bad_request` | 400 | Invalid request parameters |
| `unauthorized` | 401 | Missing or invalid API key |
| `not_found` | 404 | Resource not found |
| `conflict` | 409 | Action not allowed for current state |
| `payload_too_large` | 413 | File upload too large |
| `internal_error` | 500 | Server error |

---

## Task Status Values

| Status | Description |
|--------|-------------|
| `queued` | Waiting to start |
| `waitingForVM` | Waiting for a VM to become available |
| `planning` | Agent is generating a plan (when `planFirst` is enabled) |
| `planReview` | Plan is ready for human review (approve, edit, or cancel) |
| `running` | Currently executing |
| `paused` | Paused, waiting for user action |
| `completed` | Finished successfully |
| `failed` | Failed with an error |
| `cancelled` | Cancelled by user |
| `timedOut` | Exceeded time limit |
| `maxIterations` | Exceeded iteration limit |

---

## Rate Limits

There are currently no rate limits on the API. However, task concurrency is limited by the `maxConcurrentVMs` setting.

---

## Example: Poll for Task Completion

```bash
#!/bin/bash

TASK_ID="$1"
API_KEY="$HIVECREW_API_KEY"
BASE_URL="http://localhost:5482/api/v1"

while true; do
  STATUS=$(curl -s "$BASE_URL/tasks/$TASK_ID" \
    -H "Authorization: Bearer $API_KEY" | jq -r '.status')
  
  echo "Status: $STATUS"
  
  case $STATUS in
    completed|failed|cancelled|timedOut|maxIterations)
      echo "Task finished with status: $STATUS"
      break
      ;;
  esac
  
  sleep 5
done
```

## Example: Monitor Activity in Real Time

```bash
#!/bin/bash

TASK_ID="$1"
API_KEY="$HIVECREW_API_KEY"
BASE_URL="http://localhost:5482/api/v1"
SINCE=0

# Poll activity log every second
while true; do
  RESPONSE=$(curl -s "$BASE_URL/tasks/$TASK_ID/activity?since=$SINCE" \
    -H "Authorization: Bearer $API_KEY")
  
  # Print new events
  echo "$RESPONSE" | jq -r '.events[] | "\(.timestamp) [\(.type)] \(.data.summary)"'
  
  # Update offset
  SINCE=$(echo "$RESPONSE" | jq -r '.total')
  
  # Check if task is still active
  STATUS=$(curl -s "$BASE_URL/tasks/$TASK_ID" \
    -H "Authorization: Bearer $API_KEY" | jq -r '.status')
  
  case $STATUS in
    completed|failed|cancelled|timedOut|maxIterations)
      echo "Task finished with status: $STATUS"
      break
      ;;
  esac
  
  sleep 1
done
```

## Example: Create a Plan-First Task and Approve

```bash
#!/bin/bash

API_KEY="$HIVECREW_API_KEY"
BASE_URL="http://localhost:5482/api/v1"

# 1. Create task with planFirst enabled
TASK_ID=$(curl -s -X POST "$BASE_URL/tasks" \
  -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "description": "Research competitors and create a summary report",
    "providerName": "OpenRouter",
    "modelId": "anthropic/claude-sonnet-4.5",
    "planFirst": true
  }' | jq -r '.id')

echo "Created task: $TASK_ID"

# 2. Wait for planReview status
while true; do
  STATUS=$(curl -s "$BASE_URL/tasks/$TASK_ID" \
    -H "Authorization: Bearer $API_KEY" | jq -r '.status')
  
  if [ "$STATUS" = "planReview" ]; then
    echo "Plan ready for review!"
    curl -s "$BASE_URL/tasks/$TASK_ID" \
      -H "Authorization: Bearer $API_KEY" | jq '.planMarkdown'
    break
  fi
  sleep 2
done

# 3. Approve the plan
curl -X PATCH "$BASE_URL/tasks/$TASK_ID" \
  -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"action": "approve_plan"}'
```