#!/bin/bash
# summarize.sh — Generate a short Chinese title for Claude session prompts
# Called by Claude Monitor Swift app via Process()
# Reads prompts from stdin, outputs title to stdout
#
# Config: ~/.claude/monitor/config.json
#   summary.enabled    — must be true
#   summary.env_file   — path to file containing GEMINI_API_KEY
#   summary.model      — Gemini model name (e.g. gemini-2.0-flash)

set -euo pipefail

# --- Config ---
CONFIG_FILE="$HOME/.claude/monitor/config.json"

if [ ! -f "$CONFIG_FILE" ]; then
    exit 1
fi

# Check if summary is enabled
ENABLED=$(jq -r '.summary.enabled // false' "$CONFIG_FILE")
if [ "$ENABLED" != "true" ]; then
    exit 1
fi

# Read model and env file path from config
MODEL=$(jq -r '.summary.model // empty' "$CONFIG_FILE")
ENV_FILE=$(jq -r '.summary.env_file // empty' "$CONFIG_FILE")

if [ -z "$MODEL" ] || [ -z "$ENV_FILE" ]; then
    exit 1
fi

# Expand ~ in env file path
ENV_FILE="${ENV_FILE/#\~/$HOME}"

if [ ! -f "$ENV_FILE" ]; then
    exit 1
fi

# Read optional proxy from config
PROXY=$(jq -r '.summary.proxy // empty' "$CONFIG_FILE")
CURL_PROXY_ARGS=()
if [ -n "$PROXY" ]; then
    CURL_PROXY_ARGS=(--proxy "$PROXY")
fi

# Load GEMINI_API_KEY from env file
set -a
source "$ENV_FILE"
set +a

if [ -z "${GEMINI_API_KEY:-}" ]; then
    exit 1
fi

# --- Read prompts from stdin ---
PROMPTS=$(cat)
if [ -z "$PROMPTS" ]; then
    exit 1
fi

# --- Detect system language ---
SYS_LANG=$(defaults read -g AppleLocale 2>/dev/null | cut -d'_' -f1)
case "$SYS_LANG" in
    zh) LANG_INSTRUCTION="用中文" ;;
    ja) LANG_INSTRUCTION="日本語で" ;;
    ko) LANG_INSTRUCTION="한국어로" ;;
    *)  LANG_INSTRUCTION="in English" ;;
esac

# --- Build request JSON with python3 ---
SYSTEM_PROMPT="You will receive context from a coding session: project name, working directory, and user prompts. Infer what this project/repo is fundamentally about — its purpose, not the user's current action. Write a concise title (4-8 words) ${LANG_INSTRUCTION} describing the project's core purpose. If the project name or path already reveals the purpose, use that. Ignore transient actions like 'sync', 'push', 'fix typo'. Output ONLY the title, nothing else."

REQUEST_JSON=$(python3 -c "
import json, sys
system_prompt = sys.argv[1]
user_text = sys.argv[2]
body = {
    'contents': [{'role': 'user', 'parts': [{'text': system_prompt + '\n\n' + user_text}]}],
    'generationConfig': {'maxOutputTokens': 30, 'temperature': 0.1}
}
print(json.dumps(body))
" "$SYSTEM_PROMPT" "$PROMPTS")

# --- Call Gemini API ---
API_URL="https://generativelanguage.googleapis.com/v1beta/models/${MODEL}:generateContent"

RESPONSE=$(curl -s --max-time 10 -X POST "$API_URL" \
    -H "Content-Type: application/json" \
    -H "X-goog-api-key: ${GEMINI_API_KEY}" \
    "${CURL_PROXY_ARGS[@]}" \
    -d "$REQUEST_JSON")

# --- Parse response with python3 ---
TITLE=$(python3 -c "
import json, sys
resp = json.loads(sys.argv[1])
text = resp['candidates'][0]['content']['parts'][0]['text']
print(text.strip())
" "$RESPONSE")

if [ -z "$TITLE" ]; then
    exit 1
fi

echo "$TITLE"
