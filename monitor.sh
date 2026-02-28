#!/bin/bash
# ~/.claude/hooks/monitor.sh
# Claude Code lifecycle hook — writes session JSON + triggers TTS
# Called by all 5 hook events: SessionStart, UserPromptSubmit, Stop, Notification, SessionEnd
#
# Usage: monitor.sh <event>
# Receives hook JSON on stdin

set -euo pipefail

EVENT="${1:-unknown}"
INPUT=$(cat)

# Debug: log raw hook input
echo "$(date -u +%H:%M:%S) event=$EVENT" >> /tmp/hook_debug.log
echo "$INPUT" | jq '.' >> /tmp/hook_debug.log 2>/dev/null
echo "---" >> /tmp/hook_debug.log

# --- Paths ---
MONITOR_DIR="$HOME/.claude/monitor"
SESSIONS_DIR="$MONITOR_DIR/sessions"
CONFIG_FILE="$MONITOR_DIR/config.json"

mkdir -p "$SESSIONS_DIR"

# --- Extract context from hook JSON ---
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')

# Need a session ID to do anything useful
if [ -z "$SESSION_ID" ]; then
    exit 0
fi

SESSION_FILE="$SESSIONS_DIR/${SESSION_ID}.json"
PROJECT=$(basename "${CWD:-unknown}")
PROJECT_NAME=$(echo "$PROJECT" | sed 's/[-_]/ /g')
NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# --- Detect terminal + session ID for click-to-switch ---
detect_terminal() {
    # iTerm2: has dedicated session ID
    if [ -n "${ITERM_SESSION_ID:-}" ]; then
        echo "iterm2|$ITERM_SESSION_ID"
        return
    fi

    # Walk process tree: find TTY + detect terminal app from ancestor process names
    local pid=$$ tty_name="" term_app="terminal"
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
        [ -z "$pid" ] || [ "$pid" = "1" ] && break
        # Check if ancestor is Ghostty
        local comm
        comm=$(ps -o comm= -p "$pid" 2>/dev/null)
        case "$comm" in *[Gg]hostt*) term_app="ghostty" ;; esac
        # Grab first real TTY found
        if [ -z "$tty_name" ] || [ "$tty_name" = "??" ]; then
            local t
            t=$(ps -o tty= -p "$pid" 2>/dev/null | tr -d ' ')
            if [ -n "$t" ] && [ "$t" != "??" ]; then
                tty_name="$t"
            fi
        fi
    done

    # Env-var override (in case process tree walk didn't reach Ghostty)
    if [ -n "${GHOSTTY_RESOURCES_DIR:-}" ] || [ "${TERM_PROGRAM:-}" = "ghostty" ]; then
        term_app="ghostty"
    fi

    if [ -n "$tty_name" ] && [ "$tty_name" != "??" ]; then
        echo "$term_app|/dev/$tty_name"
    else
        echo "$term_app|"
    fi
}

# --- TTS announcement ---
announce() {
    local msg="$1"
    local provider voice rate

    # Read config
    if [ ! -f "$CONFIG_FILE" ]; then
        return
    fi

    provider=$(jq -r '.tts_provider // "say"' "$CONFIG_FILE")
    local volume
    volume=$(jq -r '.announce.volume // 0.5' "$CONFIG_FILE")

    if [ "$provider" = "elevenlabs" ]; then
        local env_file model stability similarity
        env_file=$(jq -r '.elevenlabs.env_file // empty' "$CONFIG_FILE")
        env_file="${env_file/#\~/$HOME}"
        model=$(jq -r '.elevenlabs.model // "eleven_multilingual_v2"' "$CONFIG_FILE")
        stability=$(jq -r '.elevenlabs.stability // 0.5' "$CONFIG_FILE")
        similarity=$(jq -r '.elevenlabs.similarity_boost // 0.75' "$CONFIG_FILE")

        if [ -f "$env_file" ]; then
            set -a; source "$env_file"; set +a
        fi

        local config_voice_id
        config_voice_id=$(jq -r '.elevenlabs.voice_id // empty' "$CONFIG_FILE")
        if [ -n "$config_voice_id" ]; then
            ELEVENLABS_VOICE_ID="$config_voice_id"
        fi

        if [ -n "${ELEVENLABS_API_KEY:-}" ] && [ -n "${ELEVENLABS_VOICE_ID:-}" ]; then
            local temp_audio="/tmp/claude_monitor_tts_$$.mp3"
            local json_payload
            json_payload=$(python3 -c "
import json, sys
print(json.dumps({
    'text': sys.argv[1],
    'model_id': sys.argv[2],
    'voice_settings': {'stability': float(sys.argv[3]), 'similarity_boost': float(sys.argv[4])}
}))
" "$msg" "$model" "$stability" "$similarity")

            local http_code
            http_code=$(curl -s --connect-timeout 3 --max-time 10 -w '%{http_code}' -X POST \
                "https://api.elevenlabs.io/v1/text-to-speech/$ELEVENLABS_VOICE_ID" \
                -H "xi-api-key: $ELEVENLABS_API_KEY" \
                -H "Content-Type: application/json" \
                -d "$json_payload" \
                -o "$temp_audio")

            if [ "$http_code" = "200" ] && [ -s "$temp_audio" ]; then
                afplay -v "$volume" "$temp_audio" &
                disown 2>/dev/null
                (sleep 30 && rm -f "$temp_audio") &
                disown 2>/dev/null
            else
                rm -f "$temp_audio"
                say -v "Samantha" -r 200 "$msg" &
                disown 2>/dev/null
            fi
        else
            say -v "Samantha" -r 200 "$msg" &
            disown 2>/dev/null
        fi
    else
        voice=$(jq -r '.say.voice // "Samantha"' "$CONFIG_FILE")
        rate=$(jq -r '.say.rate // 200' "$CONFIG_FILE")
        # osascript say supports volume 0.0-1.0
        osascript -e "say \"${msg}\" using \"${voice}\" speaking rate ${rate} volume ${volume}" &
        disown 2>/dev/null
    fi
}

# --- Should we announce this event? ---
should_announce() {
    local event_type="$1"
    if [ ! -f "$CONFIG_FILE" ]; then
        return 1
    fi

    # Master toggle
    jq -e '.announce.enabled == true' "$CONFIG_FILE" >/dev/null 2>&1 || return 1

    case "$event_type" in
        done)     jq -e '.announce.on_done == true' "$CONFIG_FILE" >/dev/null 2>&1 ;;
        attention) jq -e '.announce.on_attention == true' "$CONFIG_FILE" >/dev/null 2>&1 ;;
        start)    jq -e '.announce.on_start == true' "$CONFIG_FILE" >/dev/null 2>&1 ;;
        *)        return 1 ;;
    esac
}

# --- Detect terminal once for all events ---
TERM_INFO=$(detect_terminal)
TERM_APP=$(echo "$TERM_INFO" | cut -d'|' -f1)
TERM_SID=$(echo "$TERM_INFO" | cut -d'|' -f2)

# Helper: backfill terminal info + update status on existing session file
update_session() {
    local new_status="$1"
    jq \
        --arg status "$new_status" \
        --arg updated "$NOW" \
        --arg terminal "$TERM_APP" \
        --arg term_sid "$TERM_SID" \
        '.status = $status | .updated_at = $updated | .terminal = $terminal | .terminal_session_id = $term_sid' \
        "$SESSION_FILE" > "${SESSION_FILE}.tmp" && mv "${SESSION_FILE}.tmp" "$SESSION_FILE"
}

# Helper: create new session file
create_session() {
    local new_status="$1"
    local prompt="${2:-}"
    jq -n \
        --arg sid "$SESSION_ID" \
        --arg status "$new_status" \
        --arg project "$PROJECT" \
        --arg cwd "${CWD:-}" \
        --arg terminal "$TERM_APP" \
        --arg term_sid "$TERM_SID" \
        --arg started "$NOW" \
        --arg updated "$NOW" \
        --arg prompt "$prompt" \
        '{session_id:$sid,status:$status,project:$project,cwd:$cwd,terminal:$terminal,terminal_session_id:$term_sid,started_at:$started,updated_at:$updated,last_prompt:$prompt}' \
        > "${SESSION_FILE}.tmp" && mv "${SESSION_FILE}.tmp" "$SESSION_FILE"
}

# --- Deduplicate by TTY or CWD ---
# Find existing session file for the same TTY (to handle subagents)
find_session_by_tty() {
    local tty="$1"
    [ -z "$tty" ] && return
    for f in "$SESSIONS_DIR"/*.json; do
        [ -f "$f" ] || continue
        local f_tty
        f_tty=$(jq -r '.terminal_session_id // empty' "$f" 2>/dev/null)
        if [ "$f_tty" = "$tty" ]; then
            echo "$f"
            return
        fi
    done
}

# Find existing active session by CWD (matches exact, parent, or child paths)
find_session_by_cwd() {
    local target_cwd="$1"
    [ -z "$target_cwd" ] && return
    for f in "$SESSIONS_DIR"/*.json; do
        [ -f "$f" ] || continue
        local f_cwd f_status
        f_cwd=$(jq -r '.cwd // empty' "$f" 2>/dev/null)
        f_status=$(jq -r '.status // empty' "$f" 2>/dev/null)
        [ "$f_status" = "done" ] && continue
        # Match if either is a prefix of the other (parent/child relationship)
        case "$target_cwd" in "$f_cwd"*) echo "$f"; return ;; esac
        case "$f_cwd" in "$target_cwd"*) echo "$f"; return ;; esac
    done
}

# Find existing session: prefer TTY match, fallback to CWD match
find_existing_session() {
    if [ -n "$TERM_SID" ]; then
        find_session_by_tty "$TERM_SID"
    else
        find_session_by_cwd "${CWD:-}"
    fi
}

# --- Handle events ---
case "$EVENT" in
    SessionStart)
        # Skip if same TTY (or same CWD when TTY unknown) already has an active session
        EXISTING=$(find_existing_session)
        if [ -n "$EXISTING" ] && [ "$EXISTING" != "$SESSION_FILE" ]; then
            exit 0
        fi
        # If session file already exists (e.g. compact restart), preserve it — just update timestamp
        if [ -f "$SESSION_FILE" ]; then
            jq --arg updated "$NOW" '.updated_at = $updated' \
                "$SESSION_FILE" > "${SESSION_FILE}.tmp" && mv "${SESSION_FILE}.tmp" "$SESSION_FILE"
        else
            create_session "starting"
            if should_announce start; then
                announce "$PROJECT_NAME starting" </dev/null >/dev/null 2>&1 &
            fi
        fi
        ;;

    UserPromptSubmit)
        PROMPT_TEXT=$(echo "$INPUT" | jq -r '.prompt // empty' | head -c 200)
        if [ -f "$SESSION_FILE" ]; then
            jq \
                --arg status "working" \
                --arg updated "$NOW" \
                --arg prompt "$PROMPT_TEXT" \
                --arg terminal "$TERM_APP" \
                --arg term_sid "$TERM_SID" \
                '.status = $status | .updated_at = $updated | .last_prompt = $prompt | .terminal = $terminal | .terminal_session_id = $term_sid' \
                "$SESSION_FILE" > "${SESSION_FILE}.tmp" && mv "${SESSION_FILE}.tmp" "$SESSION_FILE"
        else
            EXISTING=$(find_existing_session)
            if [ -n "$EXISTING" ]; then
                jq \
                    --arg status "working" \
                    --arg updated "$NOW" \
                    --arg prompt "$PROMPT_TEXT" \
                    '.status = $status | .updated_at = $updated | .last_prompt = $prompt' \
                    "$EXISTING" > "${EXISTING}.tmp" && mv "${EXISTING}.tmp" "$EXISTING"
            else
                create_session "working" "$PROMPT_TEXT"
            fi
        fi
        ;;

    Stop)
        if [ -f "$SESSION_FILE" ]; then
            update_session "done"
        else
            EXISTING=$(find_existing_session)
            if [ -n "$EXISTING" ]; then
                jq --arg status "done" --arg updated "$NOW" \
                    '.status = $status | .updated_at = $updated' \
                    "$EXISTING" > "${EXISTING}.tmp" && mv "${EXISTING}.tmp" "$EXISTING"
            else
                create_session "done"
            fi
        fi
        if should_announce done; then
            announce "$PROJECT_NAME done" </dev/null >/dev/null 2>&1 &
        fi
        ;;

    Notification)
        if [ -f "$SESSION_FILE" ]; then
            update_session "attention"
        else
            EXISTING=$(find_existing_session)
            if [ -n "$EXISTING" ]; then
                jq --arg status "attention" --arg updated "$NOW" \
                    '.status = $status | .updated_at = $updated' \
                    "$EXISTING" > "${EXISTING}.tmp" && mv "${EXISTING}.tmp" "$EXISTING"
            else
                create_session "attention"
            fi
        fi
        if should_announce attention; then
            announce "$PROJECT_NAME needs attention" </dev/null >/dev/null 2>&1 &
        fi
        ;;

    PostToolUse)
        # After tool execution: restore "attention" → "working" (permission granted),
        # or "starting" → "working" (compact restart, tool use implies active work)
        TARGET="$SESSION_FILE"
        if [ ! -f "$TARGET" ]; then
            TARGET=$(find_existing_session)
        fi
        if [ -n "$TARGET" ] && [ -f "$TARGET" ]; then
            current_status=$(jq -r '.status' "$TARGET" 2>/dev/null)
            if [ "$current_status" = "attention" ] || [ "$current_status" = "starting" ]; then
                jq --arg status "working" --arg updated "$NOW" \
                    '.status = $status | .updated_at = $updated' \
                    "$TARGET" > "${TARGET}.tmp" && mv "${TARGET}.tmp" "$TARGET"
            fi
        fi
        ;;

    SessionEnd)
        if [ -f "$SESSION_FILE" ]; then
            (sleep 5 && rm -f "$SESSION_FILE") &
            disown 2>/dev/null
        fi
        # Don't clean up other TTY sessions here — subagent ends shouldn't kill parent
        ;;
esac

exit 0
