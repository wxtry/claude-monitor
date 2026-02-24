# Window Stacking Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a header bar button that moves all managed terminal windows to cascade near the Monitor panel, right-top aligned, in list order.

**Architecture:** A new top-level function `stackWindows(sessions:panelFrame:)` uses AppleScript `set bounds` to reposition each session's terminal window. The function runs on a background thread. A new button in `HeaderBar` (left of the gear icon) triggers it.

**Tech Stack:** Swift, AppKit, AppleScript

---

### Task 1: Add `moveTerminalWindow` function

**Files:**
- Modify: `claude_monitor.swift` (after `getTerminalWindowFrame` function, around line 808)

**Step 1: Implement the function**

Add after the `getTerminalWindowFrame` function (line ~808):

```swift
// MARK: - Terminal Window Mover

/// Moves a terminal window to the specified bounds (AppKit coordinates, bottom-left origin).
/// Does not activate/focus the window.
func moveTerminalWindow(session: SessionInfo, to rect: NSRect) {
    guard !session.terminal.isEmpty, !session.terminal_session_id.isEmpty else { return }

    // Convert AppKit coords (bottom-left origin) to AppleScript coords (top-left origin)
    let screenHeight = NSScreen.screens.first?.frame.height ?? 0
    let left = Int(rect.origin.x)
    let top = Int(screenHeight - rect.origin.y - rect.height)
    let right = Int(rect.origin.x + rect.width)
    let bottom = Int(screenHeight - rect.origin.y)

    let script: String

    if session.terminal == "iterm2" {
        let parts = session.terminal_session_id.split(separator: ":")
        guard parts.count >= 2 else { return }
        let uniqueId = String(parts[1])

        script = """
        tell application "iTerm2"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if unique id of s is "\(uniqueId)" then
                            set bounds of w to {\(left), \(top), \(right), \(bottom)}
                            return
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        """
    } else if session.terminal == "terminal" {
        let ttyPath = session.terminal_session_id

        script = """
        tell application "Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is "\(ttyPath)" then
                        set bounds of w to {\(left), \(top), \(right), \(bottom)}
                        return
                    end if
                end repeat
            end repeat
        end tell
        """
    } else {
        return
    }

    guard let appleScript = NSAppleScript(source: script) else { return }
    var error: NSDictionary?
    appleScript.executeAndReturnError(&error)
}
```

**Step 2: Build to verify compilation**

Run: `~/.claude/monitor/build.sh`
Expected: Compiles without errors.

**Step 3: Commit**

```bash
git add claude_monitor.swift
git commit -m "feat: add moveTerminalWindow function for repositioning windows via AppleScript"
```

---

### Task 2: Add `stackWindows` function

**Files:**
- Modify: `claude_monitor.swift` (after `moveTerminalWindow`, around line 870)

**Step 1: Implement the function**

Add after `moveTerminalWindow`:

```swift
/// Stacks all session terminal windows in cascade, right-top aligned to the panel.
/// `sessions` should be in display order (same as list). `panelFrame` is the Monitor panel's frame in AppKit coords.
func stackWindows(sessions: [SessionInfo], panelFrame: NSRect) {
    let cascadeOffset: CGFloat = 30

    // Anchor: right-top corner of the panel, starting just below the panel
    let anchorRight = panelFrame.maxX
    let anchorTop = panelFrame.origin.y  // AppKit: origin.y is the bottom of the panel = top anchor for windows below

    for (index, session) in sessions.enumerated() {
        guard !session.terminal.isEmpty, !session.terminal_session_id.isEmpty else { continue }

        // Get current window size (keep original size)
        guard let currentFrame = getTerminalWindowFrame(session: session) else { continue }

        let offset = CGFloat(index) * cascadeOffset
        // Right-top aligned: right edge matches anchorRight - offset, top edge matches anchorTop - offset
        let newX = anchorRight - currentFrame.width - offset
        let newY = anchorTop - currentFrame.height - offset  // AppKit: y is bottom edge

        let newRect = NSRect(x: newX, y: newY, width: currentFrame.width, height: currentFrame.height)
        moveTerminalWindow(session: session, to: newRect)
    }
}
```

**Step 2: Build to verify compilation**

Run: `~/.claude/monitor/build.sh`
Expected: Compiles without errors.

**Step 3: Commit**

```bash
git add claude_monitor.swift
git commit -m "feat: add stackWindows function for cascading windows near panel"
```

---

### Task 3: Add stack button to HeaderBar

**Files:**
- Modify: `claude_monitor.swift` — `HeaderBar` struct (lines 1191-1260)

**Step 1: Add the button**

In `HeaderBar.body`, inside the right-side `HStack(spacing: 8)` (line 1214), add the stack button just before the gear button (before line 1244). Insert between the session count text (`Text("\(sessions.count)")`) and the gear button:

Change from:

```swift
                Text("\(sessions.count)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.white.opacity(0.4))

                Button {
                    showSettings.toggle()
```

To:

```swift
                Text("\(sessions.count)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.white.opacity(0.4))

                Button {
                    let panelFrame = NSApp.windows.first(where: { $0 is MonitorPanel })?.frame ?? .zero
                    let orderedSessions = sessions
                    DispatchQueue.global(qos: .userInitiated).async {
                        stackWindows(sessions: orderedSessions, panelFrame: panelFrame)
                    }
                } label: {
                    Image(systemName: "rectangle.stack")
                        .font(.system(size: 8))
                        .foregroundColor(.white.opacity(0.2))
                }
                .buttonStyle(.plain)

                Button {
                    showSettings.toggle()
```

**Step 2: Build and test manually**

Run: `~/.claude/monitor/build.sh`

1. Open 2+ Claude Code sessions in Terminal.app
2. Click the stack button (left of gear icon)
3. Expected: All terminal windows move to cascade near the Monitor panel, right-top aligned, in list order. Windows keep their original size. Monitor panel stays in place.

**Step 3: Commit**

```bash
git add claude_monitor.swift
git commit -m "feat: add stack button to header bar for cascading windows"
```
