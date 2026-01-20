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
  "outputDirectory": "/Users/me/Desktop/outputs"
}
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `description` | string | Yes | The task description for the agent |
| `providerName` | string | Yes | Name of the LLM provider (e.g., "OpenRouter") |
| `modelId` | string | Yes | Model identifier (e.g., "anthropic/claude-sonnet-4.5") |
| `outputDirectory` | string | No | Absolute path for task output files (overrides app settings) |

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

**Example with custom output directory:**

```bash
curl -X POST http://localhost:5482/api/v1/tasks \
  -H "Authorization: Bearer $HIVECREW_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "description": "Create a report and save it",
    "providerName": "OpenRouter",
    "modelId": "anthropic/claude-sonnet-4.5",
    "outputDirectory": "/Users/me/Desktop/reports"
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

**With custom output directory:**

```bash
curl -X POST http://localhost:5482/api/v1/tasks \
  -H "Authorization: Bearer $HIVECREW_API_KEY" \
  -F "description=Analyze this document and summarize it" \
  -F "providerName=OpenRouter" \
  -F "modelId=anthropic/claude-sonnet-4.5" \
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

### Update Task (Actions)

```bash
PATCH /api/v1/tasks/:id
```

**Actions:**

| Action   | Description |
|----------|-------------|
| `cancel` | Cancel a running or queued task |
| `pause`  | Pause a running task |
| `resume` | Resume a paused task (optional: provide new instructions) |

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