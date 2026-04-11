#!/bin/bash
set -e

# Load config
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config.sh"

AUDIO="/tmp/vd_recording.wav"

# Guard: audio file must exist and be non-empty
if [[ ! -f "$AUDIO" || ! -s "$AUDIO" ]]; then
    echo "No audio file found, skipping."
    exit 0
fi

# Helper: run whisper with a given language and clean output
run_whisper() {
    whisper-cli \
        --model "$MODEL_PATH" \
        --language "$1" \
        --no-timestamps \
        "$AUDIO" 2>/dev/null \
      | sed 's/^[[:space:]]*//' \
      | sed '/^$/d' \
      | tr '\n' ' ' \
      | sed 's/[[:space:]]*$//'
}

# Check if text contains non-Hebrew/English characters (Chinese, Japanese, Korean, Arabic, etc.)
has_unexpected_chars() {
    python3 -c "
import sys, unicodedata
text = sys.argv[1]
for ch in text:
    cat = unicodedata.category(ch)
    if cat.startswith('L'):
        name = unicodedata.name(ch, '')
        if not any(x in name for x in ['LATIN', 'HEBREW']):
            sys.exit(0)  # found unexpected
sys.exit(1)  # all OK
" "$1"
}

# First pass: auto-detect language
TEXT=$(run_whisper "auto")

# If result contains unexpected characters (Chinese etc.), retry with Hebrew
if [[ -n "$TEXT" ]] && has_unexpected_chars "$TEXT"; then
    echo "Detected non-Hebrew/English text, retrying with Hebrew..."
    TEXT=$(run_whisper "he")
fi

# If still empty, try English explicitly
if [[ -z "$TEXT" ]]; then
    TEXT=$(run_whisper "en")
fi

# Guard: skip if nothing was transcribed
if [[ -z "$TEXT" ]]; then
    echo "No text transcribed."
    afplay /System/Library/Sounds/Basso.aiff &
    exit 0
fi

echo "Transcribed: $TEXT"

# Copy to clipboard
printf '%s' "$TEXT" | pbcopy

# Paste is handled by the Swift binary via CGEvent (more reliable across apps)

# Notification
osascript -e "display notification \"${TEXT:0:80}\" with title \"Voice Dictation\""

# Done sound
afplay /System/Library/Sounds/Glass.aiff &

# Clean up
rm -f "$AUDIO"
