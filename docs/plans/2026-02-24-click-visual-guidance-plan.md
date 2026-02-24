# Click Visual Guidance Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a light-orb animation + border flash that guides the user's attention from the monitor panel to the target terminal window when clicking a session row.

**Architecture:** A new `ClickGuideAnimator` class manages the full animation lifecycle. On click, it fetches the target terminal window's screen bounds via AppleScript, creates a transparent overlay `NSWindow` covering all screens, animates a radial-gradient orb from click position to target center, then flashes a border at the target. A global event monitor cancels everything on any user interaction.

**Tech Stack:** Swift, AppKit (NSWindow, CALayer, CABasicAnimation, NSEvent global monitor), AppleScript (window bounds)

---

### Task 1: Add AppleScript to get terminal window frame

**Files:**
- Modify: `claude_monitor.swift` (after the existing `switchToTerminal` / `switchToITerm2` functions, around line 710)

**Step 1: Implement `getTerminalWindowFrame` function**

Add after the `switchByTerminalCwd` function (line ~710):

```swift
// MARK: - Terminal Window Frame

/// Returns the screen-space frame of the terminal window containing the given tty/session, or nil if unavailable.
func getTerminalWindowFrame(session: SessionInfo) -> NSRect? {
    let script: String

    if session.terminal == "iterm2" && !session.terminal_session_id.isEmpty {
        let parts = session.terminal_session_id.split(separator: ":")
        guard parts.count >= 2 else { return nil }
        let uniqueId = String(parts[1])
        script = """
        tell application "iTerm2"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if unique id of s is "\(uniqueId)" then
                            set wBounds to bounds of w
                            return {item 1 of wBounds, item 2 of wBounds, item 3 of wBounds, item 4 of wBounds}
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        """
    } else if session.terminal == "terminal" && !session.terminal_session_id.isEmpty {
        script = """
        tell application "Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is "\(session.terminal_session_id)" then
                        set wBounds to bounds of w
                        return {item 1 of wBounds, item 2 of wBounds, item 3 of wBounds, item 4 of wBounds}
                    end if
                end repeat
            end repeat
        end tell
        """
    } else {
        return nil
    }

    guard let appleScript = NSAppleScript(source: script) else { return nil }
    var error: NSDictionary?
    let result = appleScript.executeAndReturnError(&error)
    if error != nil { return nil }

    // AppleScript returns a list of 4 integers: {left, top, right, bottom} in screen coords
    // macOS screen coords: origin at bottom-left, AppleScript bounds: origin at top-left
    guard result.numberOfItems == 4 else { return nil }
    let left = CGFloat(result.atIndex(1)?.int32Value ?? 0)
    let top = CGFloat(result.atIndex(2)?.int32Value ?? 0)
    let right = CGFloat(result.atIndex(3)?.int32Value ?? 0)
    let bottom = CGFloat(result.atIndex(4)?.int32Value ?? 0)

    // Convert from top-left origin (AppleScript) to bottom-left origin (AppKit)
    let screenHeight = NSScreen.screens.map { $0.frame.maxY }.max() ?? 0
    let x = left
    let y = screenHeight - bottom
    let width = right - left
    let height = bottom - top

    return NSRect(x: x, y: y, width: width, height: height)
}
```

**Step 2: Manual test**

Build and run. Add a temporary `NSLog` call in `switchToSession` to verify the frame:

```swift
if let frame = getTerminalWindowFrame(session: session) {
    NSLog("[ClaudeMonitor] target window frame: \(frame)")
}
```

Run: `~/.claude/monitor/build.sh`

Click a session row, check Console.app or `/tmp/claude_monitor.log` for the logged frame. Verify the coordinates make sense (positive width/height, reasonable screen position).

**Step 3: Remove temporary log, commit**

```bash
git add claude_monitor.swift
git commit -m "feat: add AppleScript to get terminal window frame"
```

---

### Task 2: Create ClickGuideAnimator with overlay window

**Files:**
- Modify: `claude_monitor.swift` (add new class before `// MARK: - Main Entry Point`, around line 1464)

**Step 1: Implement ClickGuideAnimator class skeleton**

Add before the `@main` struct:

```swift
// MARK: - Click Guide Animator

class ClickGuideAnimator {
    private var overlayWindow: NSWindow?
    private var eventMonitor: Any?
    private var cleanupWorkItem: DispatchWorkItem?

    /// Show the guide animation from `fromPoint` (screen coords) to `targetFrame` (screen coords).
    /// `color` is the session status color as NSColor.
    func animate(from fromPoint: NSPoint, to targetFrame: NSRect, color: NSColor) {
        cleanup() // cancel any previous animation

        // 1. Create overlay window covering all screens
        let unionFrame = NSScreen.screens.reduce(NSRect.zero) { $0.union($1.frame) }
        let window = NSWindow(
            contentRect: unionFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.level = .screenSaver
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentView = NSView(frame: unionFrame)
        window.contentView?.wantsLayer = true
        self.overlayWindow = window

        // 2. Set up the orb layer and border layer
        let rootLayer = window.contentView!.layer!
        let localFrom = NSPoint(x: fromPoint.x - unionFrame.origin.x, y: fromPoint.y - unionFrame.origin.y)
        let targetCenter = NSPoint(
            x: targetFrame.midX - unionFrame.origin.x,
            y: targetFrame.midY - unionFrame.origin.y
        )
        let localTargetFrame = NSRect(
            x: targetFrame.origin.x - unionFrame.origin.x,
            y: targetFrame.origin.y - unionFrame.origin.y,
            width: targetFrame.width,
            height: targetFrame.height
        )

        // Orb layer — radial gradient circle
        let orbSize: CGFloat = 50
        let orbLayer = CAGradientLayer()
        orbLayer.type = .radial
        orbLayer.colors = [color.withAlphaComponent(0.8).cgColor, color.withAlphaComponent(0.0).cgColor]
        orbLayer.startPoint = CGPoint(x: 0.5, y: 0.5)
        orbLayer.endPoint = CGPoint(x: 1.0, y: 1.0)
        orbLayer.frame = CGRect(x: localFrom.x - orbSize/2, y: localFrom.y - orbSize/2, width: orbSize, height: orbSize)
        orbLayer.cornerRadius = orbSize / 2
        rootLayer.addSublayer(orbLayer)

        // Border layer — hidden initially, shown on arrival
        let borderLayer = CAShapeLayer()
        let borderPath = NSBezierPath(roundedRect: localTargetFrame, xRadius: 10, yRadius: 10)
        borderLayer.path = borderPath.cgPath
        borderLayer.fillColor = nil
        borderLayer.strokeColor = color.withAlphaComponent(0.8).cgColor
        borderLayer.lineWidth = 3
        borderLayer.opacity = 0
        rootLayer.addSublayer(borderLayer)

        window.orderFrontRegardless()

        // 3. Animate orb flight along bezier curve (~300ms)
        let midPoint = NSPoint(
            x: (localFrom.x + targetCenter.x) / 2 + (targetCenter.y - localFrom.y) * 0.15,
            y: (localFrom.y + targetCenter.y) / 2 - (targetCenter.x - localFrom.x) * 0.15
        )
        let path = CGMutablePath()
        path.move(to: CGPoint(x: localFrom.x, y: localFrom.y))
        path.addQuadCurve(to: CGPoint(x: targetCenter.x, y: targetCenter.y),
                          control: CGPoint(x: midPoint.x, y: midPoint.y))

        let flightAnim = CAKeyframeAnimation(keyPath: "position")
        flightAnim.path = path
        flightAnim.duration = 0.3
        flightAnim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        flightAnim.fillMode = .forwards
        flightAnim.isRemovedOnCompletion = false
        orbLayer.add(flightAnim, forKey: "flight")

        // 4. After flight: orb dissolve + border pulse (delay 0.3s)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard self?.overlayWindow != nil else { return }

            // Orb expand and fade
            let expandAnim = CABasicAnimation(keyPath: "transform.scale")
            expandAnim.fromValue = 1.0
            expandAnim.toValue = 3.0
            expandAnim.duration = 0.4

            let fadeAnim = CABasicAnimation(keyPath: "opacity")
            fadeAnim.fromValue = 1.0
            fadeAnim.toValue = 0.0
            fadeAnim.duration = 0.4

            let orbGroup = CAAnimationGroup()
            orbGroup.animations = [expandAnim, fadeAnim]
            orbGroup.duration = 0.4
            orbGroup.fillMode = .forwards
            orbGroup.isRemovedOnCompletion = false
            orbLayer.add(orbGroup, forKey: "dissolve")

            // Border pulse
            let borderFadeIn = CABasicAnimation(keyPath: "opacity")
            borderFadeIn.fromValue = 0.0
            borderFadeIn.toValue = 1.0
            borderFadeIn.duration = 0.15

            let borderPulse = CAKeyframeAnimation(keyPath: "opacity")
            borderPulse.values = [1.0, 0.3, 1.0, 0.0]
            borderPulse.keyTimes = [0, 0.33, 0.66, 1.0]
            borderPulse.duration = 0.8
            borderPulse.beginTime = 0.15

            let borderGroup = CAAnimationGroup()
            borderGroup.animations = [borderFadeIn, borderPulse]
            borderGroup.duration = 0.95
            borderGroup.fillMode = .forwards
            borderGroup.isRemovedOnCompletion = false
            borderLayer.add(borderGroup, forKey: "pulse")
        }

        // 5. Register global event monitor — cancel on any interaction
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] _ in
            self?.cancelWithFade()
        }

        // 6. Auto-cleanup after animation completes (~1.3s total)
        let workItem = DispatchWorkItem { [weak self] in
            self?.cleanup()
        }
        cleanupWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3, execute: workItem)
    }

    /// Immediate cancel with quick fade
    private func cancelWithFade() {
        cleanupWorkItem?.cancel()
        if let window = overlayWindow {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.1
                window.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                self?.cleanup()
            })
        }
    }

    /// Remove overlay window and event monitor
    func cleanup() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
        overlayWindow?.orderOut(nil)
        overlayWindow = nil
        cleanupWorkItem?.cancel()
        cleanupWorkItem = nil
    }
}
```

**Step 2: Add NSBezierPath.cgPath helper**

The `NSBezierPath.cgPath` property is not built-in on macOS. Add this extension near the top of the file (after imports):

```swift
extension NSBezierPath {
    var cgPath: CGPath {
        let path = CGMutablePath()
        var points = [CGPoint](repeating: .zero, count: 3)
        for i in 0..<elementCount {
            let type = element(at: i, associatedPoints: &points)
            switch type {
            case .moveTo: path.move(to: points[0])
            case .lineTo: path.addLine(to: points[0])
            case .curveTo: path.addCurve(to: points[2], control1: points[0], control2: points[1])
            case .closePath: path.closeSubpath()
            @unknown default: break
            }
        }
        return path
    }
}
```

**Step 3: Build to verify compilation**

Run: `~/.claude/monitor/build.sh`
Expected: Compiles without errors.

**Step 4: Commit**

```bash
git add claude_monitor.swift
git commit -m "feat: add ClickGuideAnimator with overlay window, orb flight and border pulse"
```

---

### Task 3: Wire up animator to session row click

**Files:**
- Modify: `claude_monitor.swift`
  - `MonitorContentView` (around line 1168) — add animator instance
  - Button action (around line 1184) — call animator

**Step 1: Add animator and NSColor helper**

In `MonitorContentView`, add a property:

```swift
@StateObject private var reader: SessionReader
// ... existing properties ...
private let guideAnimator = ClickGuideAnimator()
```

Add a helper to convert SwiftUI Color to NSColor (add near the `SessionInfo` struct):

```swift
extension SessionInfo {
    var statusNSColor: NSColor {
        switch status {
        case "starting":  return .gray
        case "working":   return .cyan
        case "done":      return .systemGreen
        case "attention": return .orange
        default:          return .gray
        }
    }
}
```

**Step 2: Update the button action**

Change the button action at line ~1184 from:

```swift
Button {
    switchToSession(session)
} label: {
```

To:

```swift
Button {
    // Get click position in screen coordinates
    let mouseLocation = NSEvent.mouseLocation
    // Get target window frame before switching
    if let targetFrame = getTerminalWindowFrame(session: session) {
        guideAnimator.animate(
            from: mouseLocation,
            to: targetFrame,
            color: session.statusNSColor
        )
    }
    switchToSession(session)
} label: {
```

**Step 3: Build and test manually**

Run: `~/.claude/monitor/build.sh`

1. Open a Claude Code session in Terminal.app
2. Click the session row in the monitor panel
3. Expected: A colored orb flies from the click position to the terminal window, border pulses, then fades. Terminal tab activates.

**Step 4: Commit**

```bash
git add claude_monitor.swift
git commit -m "feat: wire up click guide animation to session row"
```

---

### Task 4: Edge cases and polish

**Files:**
- Modify: `claude_monitor.swift`

**Step 1: Run AppleScript on background thread**

The `getTerminalWindowFrame` AppleScript call blocks the main thread. Move it to background:

```swift
Button {
    let mouseLocation = NSEvent.mouseLocation
    let sessionCopy = session
    DispatchQueue.global(qos: .userInitiated).async {
        let targetFrame = getTerminalWindowFrame(session: sessionCopy)
        DispatchQueue.main.async {
            if let frame = targetFrame {
                guideAnimator.animate(
                    from: mouseLocation,
                    to: frame,
                    color: sessionCopy.statusNSColor
                )
            }
        }
    }
    switchToSession(session)
} label: {
```

**Step 2: Handle rapid clicks**

Already handled — `animate()` calls `cleanup()` first, cancelling any previous animation.

**Step 3: Build and test edge cases**

Run: `~/.claude/monitor/build.sh`

Test:
- Click a session → animation plays, terminal switches ✓
- Click rapidly on different sessions → previous animation cancels, new one starts ✓
- Click during animation → animation cancels quickly ✓
- Session with no terminal info → no animation, just switches ✓
- Test with terminal on a different screen (if available) → orb flies across screens ✓

**Step 4: Commit**

```bash
git add claude_monitor.swift
git commit -m "feat: move AppleScript to background thread, handle edge cases"
```
