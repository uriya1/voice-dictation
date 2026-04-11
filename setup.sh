#!/bin/bash
set -euo pipefail

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

# ---- Step 3: Download Whisper model ----
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

    # Verify model is not truncated (should be > 500MB)
    FILE_SIZE=$(stat -f%z "$MODEL_PATH" 2>/dev/null || stat --printf="%s" "$MODEL_PATH" 2>/dev/null || echo "0")
    if [[ "$FILE_SIZE" -lt 500000000 ]]; then
        echo "⚠ WARNING: Model file seems too small ($(( FILE_SIZE / 1048576 ))MB)."
        echo "  It may be corrupted. Re-run setup or download manually."
    fi
fi

# ---- Step 4: Write config.sh ----
# Back up existing config.sh if present
if [[ -f "$SCRIPT_DIR/config.sh" ]]; then
    cp "$SCRIPT_DIR/config.sh" "$SCRIPT_DIR/config.sh.bak"
    echo "  (existing config.sh backed up to config.sh.bak)"
fi

cat > "$SCRIPT_DIR/config.sh" << EOF
# Voice Dictation Configuration
# Edit this file to change settings. Restart the hotkey process after changes.

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
HOTKEY_KEYCODE=61

# Whisper model path
MODEL_PATH="${MODEL_PATH}"

# Script directory (auto-generated)
SCRIPT_DIR="${SCRIPT_DIR}"
EOF

echo "✓ Config written to config.sh"

# ---- Step 5: Compile Swift binary ----
echo ""
echo "→ Compiling hotkey listener..."
swiftc "$SCRIPT_DIR/hotkey.swift" \
    -framework Carbon \
    -framework Cocoa \
    -framework AVFoundation \
    -o "$SCRIPT_DIR/hotkey"

# Also compile into the app bundle
if [[ -d "$SCRIPT_DIR/VoiceDictation.app/Contents/MacOS" ]]; then
    cp "$SCRIPT_DIR/hotkey" "$SCRIPT_DIR/VoiceDictation.app/Contents/MacOS/hotkey"
    echo "✓ Compiled successfully (root + app bundle)"
else
    echo "✓ Compiled successfully"
fi

# ---- Step 6: Set permissions ----
chmod +x "$SCRIPT_DIR/transcribe.sh"
chmod +x "$SCRIPT_DIR/hotkey"
echo "✓ Permissions set"

# ---- Step 7: Create LaunchAgent ----
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

# Unload if already loaded, then load (use modern API)
DOMAIN_TARGET="gui/$(id -u)"
launchctl bootout "$DOMAIN_TARGET/com.voicedictation.hotkey" 2>/dev/null || true
launchctl bootstrap "$DOMAIN_TARGET" "$PLIST_PATH"

echo "✓ LaunchAgent created and loaded (auto-starts on login)"

# ---- Step 8: Print instructions ----
echo ""
echo "================================================"
echo "  Setup Complete!"
echo "================================================"
echo ""
echo "  Hotkey:    Right Option (hold to record, tap to toggle)"
echo "  Model:     large-v3-turbo (547MB, local)"
echo ""
echo "  REQUIRED — Grant permissions:"
echo ""
echo "  1. Input Monitoring (for hotkey to work):"
echo "     System Settings > Privacy & Security > Input Monitoring"
echo "     Click + and add: ${SCRIPT_DIR}/hotkey"
echo ""
echo "  2. Accessibility (for paste to work):"
echo "     System Settings > Privacy & Security > Accessibility"
echo "     Click + and add: ${SCRIPT_DIR}/hotkey"
echo ""
echo "  3. Microphone — will be auto-prompted on first recording"
echo ""
echo "  To test manually:  ${SCRIPT_DIR}/hotkey"
echo "  To view logs:      cat ${SCRIPT_DIR}/hotkey.log"
echo "  To restart:        launchctl kickstart -k gui/\$(id -u)/com.voicedictation.hotkey"
echo "  To stop:           launchctl bootout gui/\$(id -u)/com.voicedictation.hotkey"
echo ""
echo "  Change the hotkey from the menu bar icon, or edit HOTKEY_KEYCODE in config.sh."
echo ""
