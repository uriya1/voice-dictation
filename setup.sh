#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

echo "================================================"
echo "  Voice Dictation — Setup"
echo "================================================"
echo ""

# ---- Step 1: Check Homebrew ----
if ! command -v brew &>/dev/null; then
    echo "ERROR: Homebrew is not installed."
    echo "Install it from https://brew.sh"
    exit 1
fi
echo "✓ Homebrew found"

# ---- Step 2: Install whisper-cpp ----
if command -v whisper-cli &>/dev/null; then
    echo "✓ whisper-cpp already installed"
else
    echo "→ Installing whisper-cpp..."
    brew install whisper-cpp
    echo "✓ whisper-cpp installed"
fi

# ---- Step 3: Check ffmpeg ----
if command -v ffmpeg &>/dev/null; then
    echo "✓ ffmpeg found"
else
    echo "→ Installing ffmpeg..."
    brew install ffmpeg
    echo "✓ ffmpeg installed"
fi

# ---- Step 4: Download Whisper model ----
MODEL_FILE="ggml-large-v3-turbo-q5_0.bin"
MODEL_PATH="$SCRIPT_DIR/models/$MODEL_FILE"

if [[ -f "$MODEL_PATH" ]]; then
    echo "✓ Model already downloaded ($MODEL_FILE)"
else
    echo "→ Downloading Whisper model ($MODEL_FILE, ~547MB)..."
    echo "  This may take a few minutes..."
    mkdir -p models

    # Try huggingface-cli first, fall back to curl
    if command -v huggingface-cli &>/dev/null; then
        huggingface-cli download ggerganov/whisper.cpp "$MODEL_FILE" --local-dir ./models
    else
        curl -L -o "$MODEL_PATH" \
            "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/$MODEL_FILE"
    fi

    if [[ -f "$MODEL_PATH" ]]; then
        echo "✓ Model downloaded"
    else
        echo "ERROR: Model download failed."
        echo "You can manually download it:"
        echo "  curl -L -o $MODEL_PATH \\"
        echo "    https://huggingface.co/ggerganov/whisper.cpp/resolve/main/$MODEL_FILE"
        exit 1
    fi
fi

# ---- Step 5: Detect audio input device ----
echo ""
echo "→ Detecting audio input devices..."
echo ""

# List audio input devices
DEVICE_LIST=$(ffmpeg -f avfoundation -list_devices true -i "" 2>&1 || true)

# Show audio input section
echo "$DEVICE_LIST" | grep -A 50 "audio devices" | head -20
echo ""

# Try to auto-detect built-in microphone
AUDIO_IDX=$(echo "$DEVICE_LIST" \
    | grep -i "macbook\|built-in\|internal\|microphone" \
    | grep -oE '\[[0-9]+\]' | tr -d '[]' | head -1)

if [[ -z "$AUDIO_IDX" ]]; then
    AUDIO_IDX="0"
    echo "⚠ Could not auto-detect microphone, defaulting to device :0"
    echo "  Edit config.sh AUDIO_DEVICE if this is wrong."
else
    echo "✓ Detected microphone at index :$AUDIO_IDX"
fi

AUDIO_DEVICE=":${AUDIO_IDX}"

# ---- Step 6: Write config.sh ----
cat > "$SCRIPT_DIR/config.sh" << EOF
# Voice Dictation Configuration
# Edit this file to change settings. Restart the hotkey process after changes.

# Hotkey mode: "hold" = hold key to record, "double_tap" = tap twice to toggle
HOTKEY_MODE="hold"

# Key codes (common ones):
#   96  = F5 (mic key)
#   97  = F6
#   98  = F7
#   59  = Left Control
#   62  = Right Control
#   58  = Left Option
#   61  = Right Option
#   55  = Left Command
#   54  = Right Command
HOTKEY_KEYCODE=96

# Audio input device (from ffmpeg avfoundation)
AUDIO_DEVICE="${AUDIO_DEVICE}"

# Whisper model path
MODEL_PATH="${MODEL_PATH}"

# Language for transcription ("he" = Hebrew, "en" = English, "auto" = auto-detect)
LANGUAGE="he"

# Script directory (auto-generated)
SCRIPT_DIR="${SCRIPT_DIR}"

# Double-tap window in seconds (only used in double_tap mode)
DOUBLE_TAP_WINDOW=0.4
EOF

echo "✓ Config written to config.sh"

# ---- Step 7: Compile Swift binary ----
echo ""
echo "→ Compiling hotkey listener..."
swiftc "$SCRIPT_DIR/hotkey.swift" \
    -framework Carbon \
    -framework Cocoa \
    -o "$SCRIPT_DIR/hotkey" \
    -suppress-warnings

echo "✓ Compiled successfully"

# ---- Step 8: Set permissions ----
chmod +x "$SCRIPT_DIR/transcribe.sh"
chmod +x "$SCRIPT_DIR/hotkey"
echo "✓ Permissions set"

# ---- Step 9: Create LaunchAgent ----
PLIST_PATH="$HOME/Library/LaunchAgents/com.voicedictation.hotkey.plist"

cat > "$PLIST_PATH" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.voicedictation.hotkey</string>
    <key>ProgramArguments</key>
    <array>
        <string>${SCRIPT_DIR}/hotkey</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${SCRIPT_DIR}/hotkey.log</string>
    <key>StandardErrorPath</key>
    <string>${SCRIPT_DIR}/hotkey.log</string>
</dict>
</plist>
EOF

# Unload if already loaded, then load
launchctl unload "$PLIST_PATH" 2>/dev/null || true
launchctl load "$PLIST_PATH"

echo "✓ LaunchAgent created and loaded (auto-starts on login)"

# ---- Step 10: Print instructions ----
echo ""
echo "================================================"
echo "  Setup Complete!"
echo "================================================"
echo ""
echo "  Hotkey:    Hold F5 (mic key) to record, release to transcribe"
echo "  Language:  Hebrew (change in config.sh)"
echo "  Model:     large-v3-turbo (547MB, local)"
echo ""
echo "  ⚠ REQUIRED — Grant permissions:"
echo ""
echo "  1. Input Monitoring (for hotkey to work):"
echo "     System Settings → Privacy & Security → Input Monitoring"
echo "     Click + and add: ${SCRIPT_DIR}/hotkey"
echo ""
echo "  2. Accessibility (for paste to work):"
echo "     System Settings → Privacy & Security → Accessibility"
echo "     Click + and add: ${SCRIPT_DIR}/hotkey"
echo ""
echo "  3. Microphone — will be auto-prompted on first recording"
echo ""
echo "  To test manually:  ${SCRIPT_DIR}/hotkey"
echo "  To view logs:      cat ${SCRIPT_DIR}/hotkey.log"
echo "  To restart:        launchctl kickstart -k gui/\$(id -u)/com.voicedictation.hotkey"
echo "  To stop:           launchctl unload ${PLIST_PATH}"
echo ""
echo "  To change hotkey:  Edit HOTKEY_MODE and HOTKEY_KEYCODE in config.sh"
echo "                     Then restart the service."
echo ""
echo "  Tip: If F5 triggers macOS Dictation instead, either:"
echo "    - Disable macOS Dictation in System Settings → Keyboard → Dictation"
echo "    - Or change HOTKEY_KEYCODE in config.sh to another key (e.g., 59 for Left Ctrl)"
echo ""
