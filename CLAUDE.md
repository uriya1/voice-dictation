# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

A macOS voice dictation tool that uses a global hotkey to record audio, transcribes it locally with Whisper, and pastes the result into the active application. No build system or package manager — just Swift, bash, and Homebrew dependencies.

## Build & Run

```bash
# Compile the hotkey binary (only needed after editing hotkey.swift)
swiftc hotkey.swift -framework Carbon -framework Cocoa -framework AVFoundation -o hotkey

# Copy into app bundle too
cp hotkey VoiceDictation.app/Contents/MacOS/hotkey

# Restart the LaunchAgent service
launchctl kickstart -k gui/$(id -u)/com.voicedictation.hotkey

# View logs
tail -f hotkey.log
```

Config changes in `config.sh` take effect on service restart without recompilation.

## Architecture

The system has two runtime components connected by process spawning:

**`hotkey.swift` -> compiled `hotkey` binary** — A persistent daemon (LaunchAgent) that:
- Parses `config.sh` key=value pairs at startup (only `HOTKEY_KEYCODE` and `SCRIPT_DIR`)
- Creates a system-wide CGEvent tap (Carbon/Cocoa) to intercept the configured hotkey
- Records audio via `AVAudioRecorder` (16kHz, mono, 16-bit PCM) to `/tmp/vd_recording.wav`
- On hotkey release or second tap: stops recording, spawns `transcribe.sh`, then injects Cmd+V via CGEvent
- Runs as a menu bar app (`NSApplication` with `.accessory` policy) with status icons and hotkey picker

**`transcribe.sh`** — Post-recording pipeline that:
- Runs `whisper-cli` with auto language detection, retries with Hebrew then English on failure
- Copies the transcribed text to clipboard via `pbcopy`
- Shows a macOS notification (paste is handled by the Swift binary)

**`config.sh`** — Shared configuration sourced by bash and parsed line-by-line by Swift. Key settings: `HOTKEY_KEYCODE`, `MODEL_PATH`, `SCRIPT_DIR`.

## Dependencies

Homebrew: `whisper-cpp` (provides `whisper-cli`). Xcode CLT for `swiftc`. Whisper model at `models/ggml-large-v3-turbo-q5_0.bin`.

## macOS Permissions Required

The `hotkey` binary needs **Input Monitoring** and **Accessibility** in System Settings > Privacy & Security. Microphone access is prompted on first use.

## LaunchAgent

Installed at `~/Library/LaunchAgents/com.voicedictation.hotkey.plist` by `setup.sh`. Runs at login with KeepAlive. Logs to `hotkey.log` in the project directory.
