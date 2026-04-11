# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

A macOS voice dictation tool that uses a global hotkey to record audio, transcribes it locally with Whisper, and pastes the result into the active application. No build system or package manager — just Swift, bash, and Homebrew dependencies.

## Build & Run

```bash
# Compile the hotkey daemon (only needed after editing hotkey.swift)
swiftc hotkey.swift -framework Carbon -framework Cocoa -o hotkey -suppress-warnings

# Restart the LaunchAgent service
launchctl kickstart -k gui/$(id -u)/com.voicedictation.hotkey

# View logs
tail -f hotkey.log
```

Config changes in `config.sh` take effect on service restart without recompilation.

## Architecture

The system has two runtime components connected by process spawning:

**`hotkey.swift` → compiled `hotkey` binary** — A persistent daemon (LaunchAgent) that:
- Parses `config.sh` key=value pairs at startup
- Creates a system-wide CGEvent tap (Carbon/Cocoa) to intercept the configured hotkey
- On hotkey activation: spawns `ffmpeg` to record from `avfoundation` device to `/tmp/vd_recording.wav`
- On hotkey release: sends SIGINT to ffmpeg, then asynchronously calls `transcribe.sh`

**`transcribe.sh`** — Post-recording pipeline that:
- Runs `whisper-cli` on the recorded WAV
- Copies result to clipboard (`pbcopy`) and pastes into active app (`osascript`)
- Shows a macOS notification and plays an audio confirmation

**`config.sh`** — Shared configuration sourced by bash and parsed line-by-line by Swift. Key settings: `HOTKEY_MODE` (hold/double_tap), `HOTKEY_KEYCODE`, `AUDIO_DEVICE`, `MODEL_PATH`, `LANGUAGE`.

## Dependencies

Homebrew: `ffmpeg`, `whisper-cpp` (provides `whisper-cli`). Xcode CLT for `swiftc`. Whisper model at `models/ggml-large-v3-turbo-q5_0.bin` (symlink to HuggingFace cache).

## macOS Permissions Required

The `hotkey` binary needs **Input Monitoring** and **Accessibility** in System Settings > Privacy & Security. Microphone access is prompted on first use.

## LaunchAgent

Installed at `~/Library/LaunchAgents/com.voicedictation.hotkey.plist` by `setup.sh`. Runs at login with KeepAlive. Logs to `hotkey.log` in the project directory.
