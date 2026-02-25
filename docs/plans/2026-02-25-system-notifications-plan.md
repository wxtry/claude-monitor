# System Notifications Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add macOS system notifications to Claude Monitor via `UNUserNotificationCenter`, wrapped in a thin Xcode `.app` bundle.

**Architecture:** The existing `claude_monitor.swift` gains ~100 lines: a `NotificationManager` class, state transition tracking in `SessionReader`, a `NotificationConfig` in `MonitorConfig`, and a settings toggle. A new `ClaudeMonitorApp/` directory contains a minimal Xcode project that references `../claude_monitor.swift` as its sole source file, producing a `.app` bundle that enables `UNUserNotificationCenter`.

**Tech Stack:** Swift, SwiftUI, UserNotifications framework, Xcode project (xcodeproj), AppKit

---

### Task 1: Add `NotificationConfig` to `MonitorConfig`

**Files:**
- Modify: `claude_monitor.swift:29-67` (MonitorConfig struct)
- Modify: `config.json` (add notifications section)

**Step 1: Add NotificationConfig struct to MonitorConfig**

In `claude_monitor.swift`, add the new struct and field inside `MonitorConfig` (after line 66, before the closing `}`):

```swift
// Inside MonitorConfig, after `var summary: SummaryConfig?`:
struct NotificationConfig: Codable {
    var enabled: Bool
    var on_starting: Bool
    var on_working: Bool
    var on_done: Bool
    var on_attention: Bool
}
var notifications: NotificationConfig?
```

**Step 2: Add default notifications section to config.json**

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

Add this as a new top-level key in `config.json`, after the `"summary"` section.

**Step 3: Build to verify compilation**

Run: `cd /Users/wxtry/Documents/MyProjects/claude-monitor && bash build.sh`
Expected: "Build successful." — the new optional field doesn't break existing configs.

**Step 4: Commit**

```bash
git add claude_monitor.swift config.json
git commit -m "feat: add NotificationConfig to MonitorConfig"
```

---

### Task 2: Add `NotificationManager` class

**Files:**
- Modify: `claude_monitor.swift` (add new class before `// MARK: - App Delegate`, around line 1650)

**Step 1: Add the import**

At the top of `claude_monitor.swift` (line 1, after existing imports), add:

```swift
import UserNotifications
```

**Step 2: Add NotificationManager class**

Insert before `// MARK: - App Delegate` (before line 1650):

```swift
// MARK: - Notification Manager

class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    private var authorized = false

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
        requestAuthorization()
    }

    private func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            DispatchQueue.main.async {
                self.authorized = granted
                if let error = error {
                    NSLog("[ClaudeMonitor] Notification auth error: %@", error.localizedDescription)
                }
                NSLog("[ClaudeMonitor] Notification authorization: %@", granted ? "granted" : "denied")
            }
        }
    }

    func postStatusChange(session: SessionInfo, oldStatus: String, newStatus: String, config: MonitorConfig.NotificationConfig?) {
        guard authorized else { return }
        guard let config = config, config.enabled else { return }

        // Check per-event toggle
        switch newStatus {
        case "starting":  guard config.on_starting else { return }
        case "working":   guard config.on_working else { return }
        case "done":      guard config.on_done else { return }
        case "attention": guard config.on_attention else { return }
        default: return
        }

        let content = UNMutableNotificationContent()
        content.title = session.displayName
        content.subtitle = statusDescription(newStatus)
        content.sound = .default
        content.threadIdentifier = session.session_id
        content.userInfo = [
            "session_id": session.session_id,
            "terminal": session.terminal,
            "terminal_session_id": session.terminal_session_id
        ]

        let request = UNNotificationRequest(
            identifier: "\(session.session_id)-\(newStatus)-\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil  // deliver immediately
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                NSLog("[ClaudeMonitor] Failed to post notification: %@", error.localizedDescription)
            }
        }
    }

    private func statusDescription(_ status: String) -> String {
        switch status {
        case "starting":  return "Session started"
        case "working":   return "Started working"
        case "done":      return "Finished"
        case "attention": return "Needs permission"
        default:          return status
        }
    }

    // Handle notification click — switch to terminal
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo
        guard let sessionId = userInfo["session_id"] as? String,
              let terminal = userInfo["terminal"] as? String,
              let terminalSessionId = userInfo["terminal_session_id"] as? String else {
            completionHandler()
            return
        }

        // Build a minimal SessionInfo for switching
        let decoder = JSONDecoder()
        let json: [String: String] = [
            "session_id": sessionId,
            "terminal": terminal,
            "terminal_session_id": terminalSessionId
        ]
        if let data = try? JSONSerialization.data(withJSONObject: json),
           let session = try? decoder.decode(SessionInfo.self, from: data) {
            DispatchQueue.global(qos: .userInitiated).async {
                switchToSession(session)
            }
        }

        completionHandler()
    }

    // Show notification even when app is in foreground
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
```

**Step 3: Build to verify compilation**

Run: `cd /Users/wxtry/Documents/MyProjects/claude-monitor && bash build.sh`
Expected: "Build successful." — note that `build.sh` needs the `-framework UserNotifications` flag added.

**Step 4: Add UserNotifications framework to build.sh**

In `build.sh`, add `-framework UserNotifications` to the `swiftc` command:

```bash
swiftc "$SWIFT_FILE" \
    -o "$BINARY" \
    -framework Cocoa \
    -framework SwiftUI \
    -framework Combine \
    -framework UserNotifications \
    -parse-as-library \
    -suppress-warnings \
    2>&1
```

**Step 5: Build again to verify**

Run: `cd /Users/wxtry/Documents/MyProjects/claude-monitor && bash build.sh`
Expected: "Build successful."

**Step 6: Commit**

```bash
git add claude_monitor.swift build.sh
git commit -m "feat: add NotificationManager with UNUserNotificationCenter"
```

---

### Task 3: Add state transition detection to `SessionReader`

**Files:**
- Modify: `claude_monitor.swift:395-523` (SessionReader class)

**Step 1: Add state tracking properties and notification manager reference**

In `SessionReader`, after the `private var configManager: ConfigManager?` line (around line 409), add:

```swift
private var lastKnownStatus: [String: String] = [:]
private var isFirstPoll = true
var notificationManager: NotificationManager?
```

**Step 2: Add a setter for notificationManager**

After the `setConfigManager` method (around line 413), add:

```swift
func setNotificationManager(_ nm: NotificationManager) {
    self.notificationManager = nm
}
```

**Step 3: Add state transition detection in readSessions()**

In `readSessions()`, after the sorting (line 515) and before `DispatchQueue.main.async { self.sessions = loaded }` (line 517), add:

```swift
// Detect state transitions and fire notifications
if !isFirstPoll {
    for session in loaded {
        let oldStatus = lastKnownStatus[session.session_id]
        if let old = oldStatus, old != session.status {
            notificationManager?.postStatusChange(
                session: session,
                oldStatus: old,
                newStatus: session.status,
                config: configManager?.config?.notifications
            )
        }
        // New session (no previous status) — also notify if not "starting"
        // (starting is the initial state, not interesting unless toggled on)
        if oldStatus == nil && session.status != "starting" {
            notificationManager?.postStatusChange(
                session: session,
                oldStatus: "",
                newStatus: session.status,
                config: configManager?.config?.notifications
            )
        }
    }
}

// Update lastKnownStatus
lastKnownStatus = [:]
for session in loaded {
    lastKnownStatus[session.session_id] = session.status
}
isFirstPoll = false
```

**Step 4: Build to verify**

Run: `cd /Users/wxtry/Documents/MyProjects/claude-monitor && bash build.sh`
Expected: "Build successful."

**Step 5: Commit**

```bash
git add claude_monitor.swift
git commit -m "feat: add state transition detection to SessionReader"
```

---

### Task 4: Wire up NotificationManager in AppDelegate

**Files:**
- Modify: `claude_monitor.swift:1652-1702` (AppDelegate class)

**Step 1: Add notification manager property to AppDelegate**

In `AppDelegate`, after `var sizeObserver: AnyCancellable?` (around line 1656), add:

```swift
let notificationManager = NotificationManager()
```

**Step 2: Wire it up in applicationDidFinishLaunching**

In `applicationDidFinishLaunching`, after `reader.setConfigManager(configManager)` (around line 1661), add:

```swift
reader.setNotificationManager(notificationManager)
```

**Step 3: Build to verify**

Run: `cd /Users/wxtry/Documents/MyProjects/claude-monitor && bash build.sh`
Expected: "Build successful."

**Step 4: Commit**

```bash
git add claude_monitor.swift
git commit -m "feat: wire NotificationManager into AppDelegate"
```

---

### Task 5: Add notifications toggle to ConfigManager and SettingsPopover

**Files:**
- Modify: `claude_monitor.swift:211-293` (ConfigManager class)
- Modify: `claude_monitor.swift:1091-1287` (SettingsPopover view)

**Step 1: Add notifications toggle method to ConfigManager**

In `ConfigManager`, after the `toggleVoice()` method (around line 243), add:

```swift
func toggleNotifications() {
    if config?.notifications == nil {
        config?.notifications = MonitorConfig.NotificationConfig(
            enabled: true, on_starting: false, on_working: true, on_done: true, on_attention: true
        )
    }
    config?.notifications?.enabled.toggle()
    save()
}

var notificationsEnabled: Bool {
    config?.notifications?.enabled ?? true
}
```

**Step 2: Add notifications toggle to SettingsPopover**

In `SettingsPopover`, after the voice toggle button (after the `}.buttonStyle(.plain)` on ~line 1137, before the `if configManager.voiceEnabled {` block), add:

```swift
// Notifications toggle
Button {
    configManager.toggleNotifications()
} label: {
    HStack(spacing: 6) {
        Image(systemName: configManager.notificationsEnabled ? "bell.badge.fill" : "bell.slash.fill")
            .font(.system(size: 10))
            .foregroundColor(configManager.notificationsEnabled ? .yellow : .gray)
        Text(configManager.notificationsEnabled ? "Notifications on" : "Notifications off")
            .font(.system(size: 11))
            .foregroundColor(configManager.notificationsEnabled ? .white : .white.opacity(0.4))
        Spacer()
    }
}
.buttonStyle(.plain)
```

**Step 3: Build to verify**

Run: `cd /Users/wxtry/Documents/MyProjects/claude-monitor && bash build.sh`
Expected: "Build successful."

**Step 4: Commit**

```bash
git add claude_monitor.swift
git commit -m "feat: add notifications toggle to settings popover"
```

---

### Task 6: Create Xcode project wrapper

**Files:**
- Create: `ClaudeMonitorApp/ClaudeMonitorApp.xcodeproj/project.pbxproj`
- Create: `ClaudeMonitorApp/Info.plist`
- Create: `ClaudeMonitorApp/ClaudeMonitorApp.entitlements`
- Create: `ClaudeMonitorApp/build-app.sh`

**Step 1: Create directory structure**

```bash
mkdir -p ClaudeMonitorApp/ClaudeMonitorApp.xcodeproj
```

**Step 2: Create Info.plist**

Create `ClaudeMonitorApp/Info.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>ClaudeMonitorApp</string>
    <key>CFBundleIdentifier</key>
    <string>com.claude.monitor</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Claude Monitor</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
```

**Step 3: Create entitlements file**

Create `ClaudeMonitorApp/ClaudeMonitorApp.entitlements`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <false/>
</dict>
</plist>
```

**Step 4: Create build-app.sh**

Create `ClaudeMonitorApp/build-app.sh`:

```bash
#!/bin/bash
# Build Claude Monitor as a .app bundle using swiftc directly (no Xcode project needed)
# Produces ClaudeMonitorApp.app with proper Info.plist for UNUserNotificationCenter

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
SWIFT_FILE="$REPO_DIR/claude_monitor.swift"
APP_DIR="$SCRIPT_DIR/build/ClaudeMonitorApp.app"
MACOS_DIR="$APP_DIR/Contents/MacOS"
INSTALL_DIR="$HOME/.claude/monitor"

echo "Building Claude Monitor app bundle..."

# Clean previous build
rm -rf "$SCRIPT_DIR/build"
mkdir -p "$MACOS_DIR"

# Compile
swiftc "$SWIFT_FILE" \
    -o "$MACOS_DIR/ClaudeMonitorApp" \
    -framework Cocoa \
    -framework SwiftUI \
    -framework Combine \
    -framework UserNotifications \
    -parse-as-library \
    -suppress-warnings \
    2>&1

if [ $? -ne 0 ]; then
    echo "Build failed!"
    exit 1
fi

# Copy Info.plist
cp "$SCRIPT_DIR/Info.plist" "$APP_DIR/Contents/Info.plist"

echo "Build successful: $APP_DIR"

# Kill existing instance if running
pkill -f "ClaudeMonitorApp$" 2>/dev/null || true
sleep 0.5

# Install to ~/.claude/monitor/
echo "Installing to $INSTALL_DIR..."
rm -rf "$INSTALL_DIR/ClaudeMonitorApp.app"
cp -R "$APP_DIR" "$INSTALL_DIR/ClaudeMonitorApp.app"

# Launch
echo "Launching Claude Monitor app..."
open "$INSTALL_DIR/ClaudeMonitorApp.app"

echo "Claude Monitor app is running."
```

**Step 5: Make build-app.sh executable**

```bash
chmod +x ClaudeMonitorApp/build-app.sh
```

**Step 6: Create the Xcode project**

Use `xcodebuild` to verify the manual build works first, then create a minimal `project.pbxproj`. However, since the `build-app.sh` script handles compilation without requiring Xcode IDE, the Xcode project file is optional for initial delivery. We use the direct `swiftc` approach in `build-app.sh` for simplicity.

If users want to open in Xcode later, they can create the project via Xcode's "New Project" and add `../claude_monitor.swift` as a reference.

**Step 7: Test the app bundle build**

Run: `cd /Users/wxtry/Documents/MyProjects/claude-monitor && bash ClaudeMonitorApp/build-app.sh`
Expected: "Build successful" → "Installing" → "Launching" → app appears as floating panel. macOS should prompt for notification permission.

**Step 8: Verify notification permission prompt appears**

After launch, macOS should show a notification permission dialog. Click "Allow". Verify in System Settings > Notifications that "Claude Monitor" appears.

**Step 9: Commit**

```bash
git add ClaudeMonitorApp/
git commit -m "feat: add app bundle wrapper with build-app.sh for notifications support"
```

---

### Task 7: Manual integration test

**Files:** None (testing only)

**Step 1: Start the app bundle version**

```bash
cd /Users/wxtry/Documents/MyProjects/claude-monitor && bash ClaudeMonitorApp/build-app.sh
```

**Step 2: Verify notifications on session state changes**

1. Open a terminal and start a Claude Code session
2. Watch for a system notification when the session transitions to "working"
3. Wait for it to finish or need permission
4. Verify the notification shows:
   - Title: project folder name (or AI title if available)
   - Subtitle: "Started working", "Finished", or "Needs permission"
5. Click the notification → verify it switches to the correct terminal tab

**Step 3: Verify settings toggle**

1. Open settings popover in the floating panel
2. Click "Notifications on" → should toggle to "Notifications off"
3. Trigger another state change → verify NO notification appears
4. Toggle back on → verify notifications resume

**Step 4: Verify bare binary still works**

```bash
cd /Users/wxtry/Documents/MyProjects/claude-monitor && bash build.sh
```

Expected: Compiles and runs. Notifications won't work (no bundle), but everything else functions normally.

**Step 5: Commit any fixes**

```bash
git add -A
git commit -m "fix: integration test fixes for system notifications"
```

(Only if fixes were needed.)

---

### Task 8: Update documentation

**Files:**
- Modify: `README.md` (add notifications section)
- Modify: `docs/CONFIGURATION.md` (add notifications config reference)

**Step 1: Add notifications section to README.md**

Add a section under Features describing system notifications, the `.app` bundle, and how to enable.

**Step 2: Add notifications config to CONFIGURATION.md**

Document the `notifications` config section:
- `enabled`: Master toggle (default: true)
- `on_starting`: Notify on session start (default: false)
- `on_working`: Notify when session starts working (default: true)
- `on_done`: Notify when session finishes (default: true)
- `on_attention`: Notify when permission needed (default: true)

**Step 3: Commit**

```bash
git add README.md docs/CONFIGURATION.md
git commit -m "docs: add system notifications to README and config reference"
```
