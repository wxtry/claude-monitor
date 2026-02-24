# Window Stacking Design

## Goal

Add a button to the header bar that moves all managed terminal windows to the Monitor panel's position, cascaded and right-top aligned, in list order.

## Design

### Button

- **Position:** Header bar, immediately left of the gear icon
- **Icon:** SF Symbol `rectangle.stack` (8pt, white opacity 0.2 — matches gear style)
- **Action:** Move all session terminal windows to cascade near the Monitor panel

### Stacking behavior

1. Get the Monitor panel's frame (right-top corner as anchor)
2. Iterate sessions in list order (same order as displayed in the panel)
3. For each session with a valid `terminal_session_id`:
   - Keep the window's original size
   - Align its right-top corner to the anchor point (below the panel)
   - Offset each subsequent window by 30px left and 30px down (cascade)
4. AppleScript: `set bounds of w to {left, top, right, bottom}` for Terminal.app and iTerm2
5. Do NOT activate/focus the windows — only reposition them

### Execution

- Run all AppleScript calls on a background thread (`DispatchQueue.global`)
- Process windows sequentially (AppleScript doesn't parallelize well)

### Graceful degradation

| Condition | Behavior |
|-----------|----------|
| Window closed/minimized | Skip, continue with next |
| No terminal_session_id | Skip |
| AppleScript error | Skip window, no crash |
| No sessions | Button does nothing |

### Constraints

- No extra permissions needed (same AppleScript authorization as click-to-switch)
- No focus stealing — windows move silently
- Button is always visible (no conditional show/hide)
