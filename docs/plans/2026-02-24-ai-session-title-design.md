# AI Session Title Design

## Goal

Replace the static folder-name title in Claude Monitor with an AI-generated summary that reflects actual session content.

## Current Behavior

Each session row shows `session.project` (the working directory basename, e.g. "claude-monitor") as the title, with `last_prompt` as a secondary preview line below.

## New Behavior

- **Before threshold**: show `project` folder name (unchanged).
- **After accumulated prompts exceed ~1k tokens (~4000 chars)**: auto-call `summarize.sh` once, write result to session JSON `title` field. UI shows `title` instead of `project`.
- **After auto-generation**: no more automatic calls. User can click the existing refresh button to regenerate titles for all sessions.

## Architecture

```
monitor.sh (unchanged) → writes session JSON with last_prompt
        ↓
Swift app polls sessions/ dir every 500ms
        ↓
Swift tracks per-session accumulated prompt text in memory
        ↓
Accumulated chars > 4000 → async Process() calls summarize.sh
        ↓
summarize.sh calls Gemini API → returns short summary to stdout
        ↓
Swift writes title to session JSON, updates UI
```

## Changes

### 1. New file: `~/.claude/monitor/summarize.sh`

Standalone script. Input: prompt text via stdin or argument. Output: short summary (4-10 words) to stdout.

- Reads `GEMINI_API_KEY` from env file specified in config.json (`summary.env_file`)
- Calls Gemini API (gemini-2.0-flash free tier)
- System prompt: "Summarize the user's task in 4-8 Chinese words. Output only the summary, nothing else."
- Falls back to empty string on any error (Swift keeps showing project name)

### 2. Modified: `claude_monitor.swift`

SessionInfo struct:
- Add `title: String` field (default empty, decoded from JSON)

SessionMonitor (the polling/data class):
- Add `promptAccumulator: [String: String]` — maps session_id to accumulated prompt text
- Add `titleGenerated: Set<String>` — tracks sessions that already got AI title
- On each poll: if a session's `last_prompt` changed, append new prompt to accumulator
- If accumulator length > 4000 and session not in `titleGenerated`: trigger async summarize
- Async summarize: run `Process()` with `summarize.sh`, read stdout, write `title` to session JSON file, add to `titleGenerated`

UI (SessionRowView):
- Title line: show `session.title` if non-empty, else `session.project`

Refresh button:
- Existing refresh action additionally: clear `titleGenerated`, re-trigger summarize for all sessions that have accumulated prompts

### 3. Modified: `config.json`

Add `summary` block:

```json
{
  "summary": {
    "enabled": true,
    "env_file": "~/.env",
    "model": "gemini-2.0-flash",
    "threshold_chars": 4000
  }
}
```

### 4. Modified: `~/.env`

Add `GEMINI_API_KEY=<key>` (user provides).

## Not Changed

- `monitor.sh` — no modifications
- Hook timing — no impact on Claude Code flow
- Existing UI layout — title replaces project name in same position
