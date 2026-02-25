# System Notifications via Xcode App Bundle Wrapper

## Problem

Claude Monitor currently has no way to send macOS system notifications. The floating panel and TTS announcements are useful when you're at your desk, but system notifications would provide persistent, clickable alerts in Notification Center — especially valuable when you step away or have the panel obscured.

The blocker: `UNUserNotificationCenter` requires the process to have a valid bundle identifier, which means running inside a `.app` bundle.

## Solution

Two-part approach:

1. **Thin Xcode project** that wraps the existing `claude_monitor.swift` as an `.app` bundle
2. **Notification support** added directly to `claude_monitor.swift` (works in both bare binary and `.app` contexts)

## Part 1: Xcode App Bundle Wrapper

### Structure

```
claude-monitor/
├── claude_monitor.swift          # THE source file (unchanged, standalone-compilable)
├── build.sh                      # Still works for bare binary development
├── ...
└── ClaudeMonitorApp/
    ├── ClaudeMonitorApp.xcodeproj/
    │   └── project.pbxproj       # References ../claude_monitor.swift
    ├── Info.plist                 # LSUIElement=true, CFBundleIdentifier
    ├── ClaudeMonitorApp.entitlements
    └── build-app.sh              # xcodebuild wrapper for CLI builds
```

### Key Decisions

- Xcode project references `../claude_monitor.swift` directly — no code duplication
- The core Swift file continues to iterate independently
- `LSUIElement = true` — no Dock icon, same utility style as today
- `CFBundleIdentifier`: `com.claude.monitor`
- No code signing required for local development use
- `build-app.sh` runs `xcodebuild` and copies output to `~/.claude/monitor/ClaudeMonitorApp.app`
- Existing `build.sh` continues to produce bare binary for quick dev iteration

## Part 2: Notification Integration

### State Transition Detection

Add to `SessionReader`:

- `private var lastKnownStatus: [String: String]` dictionary
- On each poll in `readSessions()`, compare current status against `lastKnownStatus`
- On status change, call `NotificationManager.postStatusChange()`
- First poll on app launch: populate `lastKnownStatus` silently (no notification burst)
- Clean up entries when sessions are removed

### NotificationManager Class

New class added to `claude_monitor.swift` (~60 lines):

- Requests `UNUserNotificationCenter` authorization on init
- `postStatusChange(session:oldStatus:newStatus:)`:
  - Checks config flags before posting
  - Title: AI-generated session title (falls back to folder name)
  - Subtitle: Status description ("Needs permission", "Finished", "Started working", "Session started")
  - `threadIdentifier = session_id` for grouping
  - `userInfo` contains `session_id` for click handling
- `UNUserNotificationCenterDelegate.didReceive`:
  - Extracts `session_id` from notification
  - Triggers existing AppleScript terminal-switch logic

### Notification Content

| Field | Content |
|-------|---------|
| Title | AI session title, or folder name if unavailable |
| Subtitle | Status change description |
| Thread ID | `session_id` (groups notifications per session) |
| Click action | Switch to terminal (same as clicking panel row) |

### Configuration

Extends `config.json` with a new section:

```json
{
  "notifications": {
    "enabled": true,
    "on_starting": false,
    "on_working": true,
    "on_done": true,
    "on_attention": true
  }
}
```

Defaults: `on_attention` and `on_done` are `true` (most critical). `on_working` is `true`. `on_starting` is `false` (too noisy).

Settings UI: Add a "Notifications" toggle in the existing settings popover.

## Error Handling

- **Permission denied**: Silent no-op, log via `NSLog`
- **Not in `.app` bundle**: Authorization fails gracefully, notifications disabled, app works fine
- **First launch**: Suppress notifications for already-existing sessions
- **Session removed**: Clean up `lastKnownStatus`, no notification
- **TTS coexistence**: Independent of notifications — both can fire for the same event, controlled by separate config sections

## Scope

### Included (MVP)

- Xcode project wrapper for existing Swift file
- `build-app.sh` convenience script
- State transition detection in `SessionReader`
- `NotificationManager` with `UNUserNotificationCenter`
- Per-event config toggles
- Click-to-switch on notification click
- Settings UI toggle

### Deferred

- Custom notification sounds
- Notification action buttons (e.g., "Approve" directly from notification)
- Rich notification content (previews, images)

## Estimated Changes

- ~100 lines added to `claude_monitor.swift`
- New Xcode project files (`.xcodeproj`, `Info.plist`, entitlements)
- New `build-app.sh` script
- Config schema extension
