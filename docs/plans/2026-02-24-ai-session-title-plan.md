# AI Session Title Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add AI-generated session titles via Gemini API so each monitor row shows a meaningful summary instead of a folder name.

**Architecture:** A standalone `summarize.sh` script handles Gemini API calls. Swift tracks accumulated prompt text per session in memory, triggers the script once when threshold is met, and writes the result back to session JSON. The refresh button re-triggers summarization for all sessions.

**Tech Stack:** Bash/curl (summarize.sh), Swift/SwiftUI (monitor app), Gemini 2.0 Flash API

---

### Task 1: Create `summarize.sh` script

**Files:**
- Create: `summarize.sh` (installed to `~/.claude/monitor/summarize.sh`)

**Step 1: Write the script**

Create `summarize.sh` in the project repo root:

```bash
#!/bin/bash
# ~/.claude/monitor/summarize.sh
# Standalone summarizer — calls Gemini API to generate a short session title.
# Input: prompt text via stdin
# Output: short summary to stdout (4-8 words)
# Exit 0 on success, 1 on failure (stdout empty on failure)

set -euo pipefail

MONITOR_DIR="$HOME/.claude/monitor"
CONFIG_FILE="$MONITOR_DIR/config.json"

# Read config
if [ ! -f "$CONFIG_FILE" ]; then
    exit 1
fi

ENABLED=$(jq -r '.summary.enabled // false' "$CONFIG_FILE")
if [ "$ENABLED" != "true" ]; then
    exit 1
fi

ENV_FILE=$(jq -r '.summary.env_file // "~/.env"' "$CONFIG_FILE")
ENV_FILE="${ENV_FILE/#\~/$HOME}"
MODEL=$(jq -r '.summary.model // "gemini-2.0-flash"' "$CONFIG_FILE")

# Load API key
if [ -f "$ENV_FILE" ]; then
    set -a; source "$ENV_FILE"; set +a
fi

if [ -z "${GEMINI_API_KEY:-}" ]; then
    exit 1
fi

# Read prompt text from stdin
PROMPT_TEXT=$(cat)
if [ -z "$PROMPT_TEXT" ]; then
    exit 1
fi

# Build request JSON
REQUEST_JSON=$(python3 -c "
import json, sys
text = sys.stdin.read()
print(json.dumps({
    'contents': [
        {
            'role': 'user',
            'parts': [{'text': 'Summarize the following user prompts into a short title (4-8 Chinese words). Output ONLY the title, nothing else.\n\nPrompts:\n' + text}]
        }
    ],
    'generationConfig': {
        'maxOutputTokens': 30,
        'temperature': 0.1
    }
}))
" <<< "$PROMPT_TEXT")

# Call Gemini API
RESPONSE=$(curl -s --max-time 10 \
    "https://generativelanguage.googleapis.com/v1beta/models/${MODEL}:generateContent?key=${GEMINI_API_KEY}" \
    -H "Content-Type: application/json" \
    -d "$REQUEST_JSON")

# Extract text from response
TITLE=$(echo "$RESPONSE" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    print(data['candidates'][0]['content']['parts'][0]['text'].strip())
except:
    sys.exit(1)
" 2>/dev/null)

if [ -n "$TITLE" ]; then
    echo "$TITLE"
else
    exit 1
fi
```

**Step 2: Make executable and verify syntax**

Run: `chmod +x summarize.sh && bash -n summarize.sh`
Expected: no output (syntax OK)

**Step 3: Commit**

```bash
git add summarize.sh
git commit -m "feat: add summarize.sh for Gemini-based session title generation"
```

---

### Task 2: Add `summary` config to `config.json` and `MonitorConfig`

**Files:**
- Modify: `config.json`
- Modify: `claude_monitor.swift` (lines 7-38, MonitorConfig struct)

**Step 1: Add summary block to `config.json`**

Add after the `"voices": []` line, before the closing `}`:

```json
  "summary": {
    "enabled": true,
    "env_file": "~/.env",
    "model": "gemini-2.0-flash",
    "threshold_chars": 4000
  }
```

**Step 2: Add SummaryConfig to MonitorConfig struct in `claude_monitor.swift`**

Add a new inner struct and field inside `MonitorConfig` (after `SavedVoice` struct, before `var voices`):

```swift
    struct SummaryConfig: Codable {
        var enabled: Bool
        var env_file: String
        var model: String
        var threshold_chars: Int
    }
    var summary: SummaryConfig?
```

**Step 3: Verify the app still compiles**

Run: `~/.claude/monitor/build.sh` (after copying files — or compile in project dir)
Expected: `Build successful.`

**Step 4: Commit**

```bash
git add config.json claude_monitor.swift
git commit -m "feat: add summary config for AI title generation"
```

---

### Task 3: Add `title` field to `SessionInfo`

**Files:**
- Modify: `claude_monitor.swift` (lines 268-296, SessionInfo struct)

**Step 1: Add `title` to SessionInfo**

In the `SessionInfo` struct:

1. Add field after `var last_prompt: String`:
```swift
    var title: String
```

2. Update `CodingKeys` enum to include `title`:
```swift
    enum CodingKeys: String, CodingKey {
        case session_id, status, project, cwd, terminal, terminal_session_id, started_at, updated_at, last_prompt, title
    }
```

3. Add decoding in `init(from decoder:)` after the `last_prompt` line:
```swift
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
```

**Step 2: Add a computed display name**

Add after the `isStale` computed property:

```swift
    var displayName: String {
        title.isEmpty ? project : title
    }
```

**Step 3: Verify compilation**

Run: compile the swift file
Expected: `Build successful.`

**Step 4: Commit**

```bash
git add claude_monitor.swift
git commit -m "feat: add title field and displayName to SessionInfo"
```

---

### Task 4: Update UI to show `displayName`

**Files:**
- Modify: `claude_monitor.swift` (line 650, SessionRowView)

**Step 1: Replace `session.project` with `session.displayName` in SessionRowView**

At line 650, change:
```swift
                    Text(session.project)
```
to:
```swift
                    Text(session.displayName)
```

**Step 2: Verify compilation**

Run: compile the swift file
Expected: `Build successful.`

**Step 3: Commit**

```bash
git add claude_monitor.swift
git commit -m "feat: display AI title in session row when available"
```

---

### Task 5: Add prompt tracking and auto-summarize to SessionReader

**Files:**
- Modify: `claude_monitor.swift` (lines 349-467, SessionReader class)

**Step 1: Add tracking state to SessionReader**

Add these properties after the existing `private let sessionsDir` declaration (around line 357):

```swift
    private var promptAccumulator: [String: String] = [:]  // session_id -> accumulated prompts
    private var lastSeenPrompt: [String: String] = [:]     // session_id -> last known prompt
    private var titleGenerated: Set<String> = []           // sessions that got AI title
    private var summarizeInFlight: Set<String> = []        // sessions currently being summarized
    private var configManager: ConfigManager?

    func setConfigManager(_ cm: ConfigManager) {
        self.configManager = cm
    }
```

**Step 2: Add prompt tracking logic in `readSessions()`**

In `readSessions()`, after decoding a session successfully (after `loaded.append(session)` around line 432), add:

```swift
                // Track prompt accumulation for title generation
                if !session.last_prompt.isEmpty {
                    let prev = lastSeenPrompt[session.session_id]
                    if prev != session.last_prompt {
                        lastSeenPrompt[session.session_id] = session.last_prompt
                        let existing = promptAccumulator[session.session_id] ?? ""
                        promptAccumulator[session.session_id] = existing + "\n" + session.last_prompt
                    }
                }
```

After the main `DispatchQueue.main.async` block that sets `self.sessions = loaded` (after line 444), add:

```swift
        // Check if any session needs auto-summarize
        checkAutoSummarize()
```

**Step 3: Add `checkAutoSummarize()` method**

Add this method to SessionReader:

```swift
    private func checkAutoSummarize() {
        guard let config = configManager?.config?.summary, config.enabled else { return }
        let threshold = config.threshold_chars

        for (sessionId, accumulated) in promptAccumulator {
            if accumulated.count >= threshold
                && !titleGenerated.contains(sessionId)
                && !summarizeInFlight.contains(sessionId) {
                summarizeInFlight.insert(sessionId)
                runSummarize(sessionId: sessionId, promptText: accumulated)
            }
        }
    }
```

**Step 4: Add `runSummarize()` method**

Add this method to SessionReader:

```swift
    func runSummarize(sessionId: String, promptText: String) {
        let scriptPath = "\(FileManager.default.homeDirectoryForCurrentUser.path)/.claude/monitor/summarize.sh"
        let sessionFilePath = "\(sessionsDir)/\(sessionId).json"

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }

            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/bash")
            task.arguments = [scriptPath]

            let inputPipe = Pipe()
            let outputPipe = Pipe()
            task.standardInput = inputPipe
            task.standardOutput = outputPipe
            task.standardError = FileHandle.nullDevice

            do {
                try task.run()
                inputPipe.fileHandleForWriting.write(promptText.data(using: .utf8) ?? Data())
                inputPipe.fileHandleForWriting.closeFile()
                task.waitUntilExit()

                let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
                let title = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                if !title.isEmpty && task.terminationStatus == 0 {
                    // Write title back to session JSON
                    self.writeTitleToSession(sessionId: sessionId, title: title, filePath: sessionFilePath)
                    DispatchQueue.main.async {
                        self.titleGenerated.insert(sessionId)
                        self.summarizeInFlight.remove(sessionId)
                    }
                    NSLog("[ClaudeMonitor] Generated title for %@: %@", sessionId, title)
                } else {
                    DispatchQueue.main.async {
                        self.summarizeInFlight.remove(sessionId)
                    }
                    NSLog("[ClaudeMonitor] Summarize returned empty for %@", sessionId)
                }
            } catch {
                DispatchQueue.main.async {
                    self.summarizeInFlight.remove(sessionId)
                }
                NSLog("[ClaudeMonitor] Summarize failed for %@: %@", sessionId, error.localizedDescription)
            }
        }
    }

    private func writeTitleToSession(sessionId: String, title: String, filePath: String) {
        let fm = FileManager.default
        guard let data = fm.contents(atPath: filePath) else { return }
        do {
            var json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            json["title"] = title
            let updated = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted])
            let tmpPath = filePath + ".tmp"
            try updated.write(to: URL(fileURLWithPath: tmpPath))
            try fm.moveItem(atPath: tmpPath, toPath: filePath)
        } catch {
            NSLog("[ClaudeMonitor] Failed to write title for %@: %@", sessionId, error.localizedDescription)
        }
    }
```

**Step 5: Clean up stale tracking data**

In the existing `readSessions()`, after computing `loaded`, add cleanup for sessions that no longer exist. Before the sort line (around line 439):

```swift
        // Clean up tracking for removed sessions
        let activeIds = Set(loaded.map { $0.session_id })
        for key in promptAccumulator.keys where !activeIds.contains(key) {
            promptAccumulator.removeValue(forKey: key)
            lastSeenPrompt.removeValue(forKey: key)
            titleGenerated.remove(key)
            summarizeInFlight.remove(key)
        }
```

**Step 6: Verify compilation**

Run: compile the swift file
Expected: `Build successful.`

**Step 7: Commit**

```bash
git add claude_monitor.swift
git commit -m "feat: auto-summarize session titles when prompt threshold reached"
```

---

### Task 6: Wire up refresh button to regenerate titles

**Files:**
- Modify: `claude_monitor.swift` (SettingsPopover around line 723, and SessionReader)

**Step 1: Add `regenerateTitles()` to SessionReader**

Add this method:

```swift
    func regenerateTitles() {
        guard let config = configManager?.config?.summary, config.enabled else { return }

        for session in sessions {
            let accumulated = promptAccumulator[session.session_id] ?? ""
            guard !accumulated.isEmpty else { continue }
            guard !summarizeInFlight.contains(session.session_id) else { continue }
            summarizeInFlight.insert(session.session_id)
            // Allow re-generation by removing from titleGenerated
            titleGenerated.remove(session.session_id)
            runSummarize(sessionId: session.session_id, promptText: accumulated)
        }
    }
```

**Step 2: Update the refresh button in SettingsPopover**

In the refresh button action (around line 723-726), add a call to regenerate titles. Change:

```swift
            Button {
                sessionReader?.discoverSessions()
                refreshed = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { refreshed = false }
            }
```

to:

```swift
            Button {
                sessionReader?.discoverSessions()
                sessionReader?.regenerateTitles()
                refreshed = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { refreshed = false }
            }
```

**Step 3: Verify compilation**

Run: compile the swift file
Expected: `Build successful.`

**Step 4: Commit**

```bash
git add claude_monitor.swift
git commit -m "feat: refresh button regenerates AI titles for all sessions"
```

---

### Task 7: Wire ConfigManager into SessionReader and install files

**Files:**
- Modify: `claude_monitor.swift` (app initialization, around line 980+)

**Step 1: Find where SessionReader and ConfigManager are created and connect them**

Look for where `SessionReader()` and `ConfigManager()` are instantiated (in the App struct or AppDelegate). Add the `setConfigManager` call right after both are created. The exact location depends on the app entry point — likely in the `@main` struct or `MonitorContentView` init.

In `MonitorContentView`, add an `.onAppear` to wire them up. After the existing view body (around line 1028), add before the closing of `MonitorContentView`:

```swift
        .onAppear {
            reader.setConfigManager(configManager)
        }
```

**Step 2: Copy updated files to install location**

```bash
cp summarize.sh ~/.claude/monitor/summarize.sh
cp config.json ~/.claude/monitor/config.json
cp claude_monitor.swift ~/.claude/monitor/claude_monitor.swift
chmod +x ~/.claude/monitor/summarize.sh
```

**Step 3: Add `GEMINI_API_KEY` to `~/.env`**

Check if `~/.env` exists. If not, create it. Add:
```
GEMINI_API_KEY=<user provides key>
```

**Step 4: Build and launch**

Run: `~/.claude/monitor/build.sh`
Expected: `Build successful. Launching Claude Monitor...`

**Step 5: Commit**

```bash
git add claude_monitor.swift
git commit -m "feat: wire ConfigManager into SessionReader, complete integration"
```

---

### Task 8: Update `.env.example` and update `build.sh` to copy `summarize.sh`

**Files:**
- Modify: `.env.example`
- Modify: `build.sh` (optional, for install convenience)

**Step 1: Update `.env.example`**

Add the Gemini key line:
```
ELEVENLABS_API_KEY=sk_your_api_key_here
GEMINI_API_KEY=your_gemini_api_key_here
```

**Step 2: Commit**

```bash
git add .env.example
git commit -m "docs: add GEMINI_API_KEY to .env.example"
```

---

### Task 9: End-to-end verification

**Step 1: Ensure the app is running**

Run: `pgrep -f claude_monitor` — should return a PID.

**Step 2: Verify session title generation**

1. Open a new Claude Code session and send several prompts (enough to exceed 4000 chars total)
2. Watch the monitor panel — title should change from folder name to an AI-generated summary
3. Click the refresh button (gear icon → Refresh sessions) — titles should regenerate

**Step 3: Verify fallback**

1. Start a new session with just one short prompt
2. Title should show the project folder name (old behavior)

**Step 4: Verify error handling**

1. Temporarily set an invalid API key in `~/.env`
2. The title should remain as the project folder name (graceful fallback)
3. Restore the correct key
