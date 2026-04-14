#!/bin/bash
set -euo pipefail

# Ensure Homebrew binaries are on PATH and UTF-8 encoding for clipboard
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
export LANG="${LANG:-en_US.UTF-8}"

# Load config
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config.sh"

AUDIO="/tmp/vd_recording.wav"

# Guard: audio file must exist and be non-empty
if [[ ! -f "$AUDIO" || ! -s "$AUDIO" ]]; then
    echo "No audio file found, skipping."
    exit 0
fi

# Parse LANGUAGE from config into an array of language codes
IFS=',' read -ra LANG_CODES <<< "${LANGUAGE:-auto}"

# Helper: run whisper with a given language and clean output
run_whisper() {
    local lang="$1"
    whisper-cli \
        --model "$MODEL_PATH" \
        --language "$lang" \
        --no-timestamps \
        "$AUDIO" 2>/dev/null \
      | sed 's/^[[:space:]]*//' \
      | sed '/^$/d' \
      | tr '\n' ' ' \
      | sed 's/[[:space:]]*$//' \
      || true
}

# Check if text contains only characters from the expected language scripts.
# Returns 0 (match) if all letter characters belong to acceptable scripts.
# Returns 1 (mismatch) if unexpected scripts are found.
text_matches_languages() {
    local text="$1"
    shift
    local langs=("$@")
    python3 - "$text" "${langs[@]}" << 'PYEOF'
import sys, unicodedata

SCRIPT_SIGS = {
    'en': ['LATIN'],
    'es': ['LATIN'],
    'fr': ['LATIN'],
    'de': ['LATIN'],
    'pt': ['LATIN'],
    'he': ['HEBREW'],
    'ar': ['ARABIC'],
    'zh': ['CJK'],
    'ja': ['HIRAGANA', 'KATAKANA', 'CJK'],
    'ko': ['HANGUL'],
    'hi': ['DEVANAGARI'],
    'ru': ['CYRILLIC'],
}

text = sys.argv[1]
langs = sys.argv[2:]

# Build set of acceptable Unicode script signatures
acceptable = set()
for lang in langs:
    for sig in SCRIPT_SIGS.get(lang, []):
        acceptable.add(sig)

# If no mappings found, accept everything
if not acceptable:
    sys.exit(0)

ALL_SIGS = ['LATIN', 'HEBREW', 'ARABIC', 'CJK', 'HIRAGANA', 'KATAKANA',
            'HANGUL', 'DEVANAGARI', 'CYRILLIC']

for ch in text:
    if unicodedata.category(ch).startswith('L'):
        name = unicodedata.name(ch, '')
        for sig in ALL_SIGS:
            if sig in name:
                if sig not in acceptable:
                    sys.exit(1)  # unexpected script found
                break

sys.exit(0)  # all letter chars are in acceptable scripts
PYEOF
}

# ---- Transcription strategy ----

NUM_LANGS=${#LANG_CODES[@]}
FIRST_LANG="${LANG_CODES[0]}"

if [[ "$FIRST_LANG" == "auto" ]]; then
    # Auto mode: single pass with whisper auto-detect
    TEXT=$(run_whisper "auto")

elif [[ "$NUM_LANGS" -eq 1 ]]; then
    # Single specific language: pass directly to whisper
    TEXT=$(run_whisper "$FIRST_LANG")

else
    # Multiple languages selected:
    # Step 1 — run whisper auto to get a raw candidate
    TEXT=$(run_whisper "auto")

    # Step 2 — if empty or script mismatch, retry with each selected language
    if [[ -z "$TEXT" ]] || ! text_matches_languages "$TEXT" "${LANG_CODES[@]}"; then
        [[ -n "$TEXT" ]] && echo "Script mismatch detected, retrying with selected languages..."
        [[ -z "$TEXT" ]] && echo "Auto returned empty, trying selected languages..."
        TEXT=""
        for lang in "${LANG_CODES[@]}"; do
            ATTEMPT=$(run_whisper "$lang")
            if [[ -n "$ATTEMPT" ]]; then
                TEXT="$ATTEMPT"
                break
            fi
        done
    fi
fi

# Guard: skip if nothing was transcribed (exit 2 = no text, tells Swift to skip paste)
if [[ -z "$TEXT" ]]; then
    echo "No text transcribed."
    afplay /System/Library/Sounds/Basso.aiff &
    exit 2
fi

echo "Transcribed: $TEXT"

# Copy to clipboard
printf '%s' "$TEXT" | pbcopy

# Paste is handled by the Swift binary via CGEvent (more reliable across apps)

# Notification — use heredoc to avoid shell/AppleScript injection from transcribed text
NOTIFICATION_TEXT="${TEXT:0:80}"
osascript <<APPLESCRIPT
display notification "$( printf '%s' "$NOTIFICATION_TEXT" | sed 's/[\\\"]/\\&/g' )" with title "Voice Dictation"
APPLESCRIPT

# Done sound
afplay /System/Library/Sounds/Glass.aiff &

# Clean up
rm -f "$AUDIO"
