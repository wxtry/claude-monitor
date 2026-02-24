# Click Visual Guidance Design

## Goal

When users click a session row in Claude Monitor to switch to a terminal, provide a visual animation that guides their attention from the monitor panel to the target terminal window — especially useful in multi-screen setups.

## Design

### Animation sequence

1. **Get target window frame** — AppleScript fetches the target terminal window's screen bounds (Terminal.app or iTerm2). If this fails (minimized, closed, etc.), skip animation entirely and fall back to the existing switch behavior.

2. **Light orb flight (~300ms)** — A radial gradient circle (center: session status color, edges: transparent, ~50pt diameter) appears at the click position and flies along a bezier curve toward the target window's center. Easing: ease-in-out.

3. **Arrival feedback (~800ms)** — The orb expands and dissolves. Simultaneously, a same-color rounded-rect border (2-3pt stroke) appears around the target window frame and pulses 1-2 times before fading out.

4. **Terminal switch** — Runs in parallel with the animation (not blocked by it). Uses existing AppleScript activation logic.

5. **Interaction cancel** — A global event monitor (`NSEvent.addGlobalMonitorForEvents`) watches for any mouse click or keystroke. Any event triggers immediate cancellation: quick fade out (~100ms), overlay removal, monitor cleanup. The monitor is also cleaned up when the animation completes naturally.

### Implementation details

- **Overlay window**: A single borderless, transparent `NSWindow` covering the union of all screen frames. `ignoresMouseEvents = true` so clicks pass through to the terminal underneath. Window level above all other windows.
- **Light orb**: Drawn as a radial gradient circle. Color matches session status: cyan (working), green (done), orange (attention), gray (starting/other).
- **Bezier curve**: Slight arc (not a straight line) for a more natural feel. Control point offset perpendicular to the direct path.
- **Border overlay**: Drawn on the same overlay window at the target window's frame position. Rounded corners matching macOS window radius (~10pt).

### Graceful degradation

| Condition | Behavior |
|-----------|----------|
| Can't get window frame | No animation, just switch |
| Target on different screen | Animation crosses screens (overlay covers all) |
| Window minimized | No animation, just switch |
| User interacts during animation | Immediate cancel with quick fade |

### Constraints

- Total animation duration: ~1.1s max
- No blocking of terminal switch
- No mouse hijacking (overlay is click-through)
- Clean resource cleanup (overlay window + event monitor)
