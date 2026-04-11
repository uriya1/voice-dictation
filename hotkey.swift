import Cocoa
import Carbon
import AVFoundation

// MARK: - Configuration

struct Config {
    var hotkeyMode: String = "hold"       // "hold" or "double_tap"
    var hotkeyKeycode: UInt16 = 96        // 96=F5, 59=Left Ctrl, 58=Left Option, 61=Right Option
    var audioDevice: String = ":0"
    var scriptDir: String = ""
}

func loadConfig() -> Config {
    var config = Config()
    let binaryPath = (CommandLine.arguments[0] as NSString).deletingLastPathComponent
    // If running inside .app bundle (Contents/MacOS/), go up to project dir
    if binaryPath.hasSuffix("Contents/MacOS") {
        config.scriptDir = (binaryPath as NSString).deletingLastPathComponent
        config.scriptDir = (config.scriptDir as NSString).deletingLastPathComponent
        config.scriptDir = (config.scriptDir as NSString).deletingLastPathComponent
    } else {
        config.scriptDir = binaryPath
    }
    let configPath = "\(config.scriptDir)/config.sh"

    guard let contents = try? String(contentsOfFile: configPath, encoding: .utf8) else {
        print("Warning: Could not read \(configPath), using defaults")
        return config
    }

    for line in contents.components(separatedBy: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.hasPrefix("#"), !trimmed.isEmpty else { continue }

        let parts = trimmed.components(separatedBy: "=")
        guard parts.count >= 2 else { continue }

        let key = parts[0].trimmingCharacters(in: .whitespaces)
        var value = parts.dropFirst().joined(separator: "=")
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "\"", with: "")
        value = value.replacingOccurrences(of: "$HOME", with: NSHomeDirectory())

        switch key {
        case "HOTKEY_MODE": config.hotkeyMode = value
        case "HOTKEY_KEYCODE": config.hotkeyKeycode = UInt16(value) ?? 96
        case "AUDIO_DEVICE": config.audioDevice = value
        case "SCRIPT_DIR": config.scriptDir = value
        default: break
        }
    }
    return config
}

func saveConfigValue(_ key: String, value: String) {
    let configPath = "\(config.scriptDir)/config.sh"
    guard var contents = try? String(contentsOfFile: configPath, encoding: .utf8) else { return }
    let lines = contents.components(separatedBy: "\n")
    var newLines: [String] = []
    var replaced = false
    for line in lines {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("\(key)=") {
            newLines.append("\(key)=\(value)")
            replaced = true
        } else {
            newLines.append(line)
        }
    }
    if !replaced {
        newLines.append("\(key)=\(value)")
    }
    contents = newLines.joined(separator: "\n")
    try? contents.write(toFile: configPath, atomically: true, encoding: .utf8)
}

// MARK: - Global State

nonisolated(unsafe) var config = Config()
nonisolated(unsafe) var isRecording = false
nonisolated(unsafe) var recordingStartTime: CFAbsoluteTime = 0
nonisolated(unsafe) var audioRecorder: AVAudioRecorder?
nonisolated(unsafe) var lastTapTime: CFAbsoluteTime = 0
nonisolated(unsafe) var hotkeyPressTime: CFAbsoluteTime = 0
nonisolated(unsafe) var isToggleRecording = false // true = started by tap, ignore release
nonisolated(unsafe) var doubleTapWindow: TimeInterval = 0.4
nonisolated(unsafe) var appDelegate: AppDelegate?
nonisolated(unsafe) var isPaused = false
nonisolated(unsafe) var waitingForHotkey = false

// MARK: - Audio Feedback

func playSound(_ name: String) {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
    proc.arguments = ["/System/Library/Sounds/\(name).aiff"]
    proc.standardOutput = FileHandle.nullDevice
    proc.standardError = FileHandle.nullDevice
    try? proc.run()
}

// MARK: - Keyboard Simulation via CGEvent

func simulatePaste() {
    let src = CGEventSource(stateID: .hidSystemState)
    let keyDown = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: true)
    keyDown?.flags = .maskCommand
    keyDown?.post(tap: .cghidEventTap)
    let keyUp = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: false)
    keyUp?.flags = .maskCommand
    keyUp?.post(tap: .cghidEventTap)
}

func simulateEnter() {
    let src = CGEventSource(stateID: .hidSystemState)
    let keyDown = CGEvent(keyboardEventSource: src, virtualKey: 0x24, keyDown: true) // 0x24 = Return
    keyDown?.post(tap: .cghidEventTap)
    let keyUp = CGEvent(keyboardEventSource: src, virtualKey: 0x24, keyDown: false)
    keyUp?.post(tap: .cghidEventTap)
}

// MARK: - Menu Bar App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var statusMenuItem: NSMenuItem!
    var autoEnterMenuItem: NSMenuItem!
    var pauseMenuItem: NSMenuItem!
    var hotkeyMenu: NSMenu!

    // Available hotkey options: (display name, keycode)
    static let hotkeyOptions: [(String, UInt16)] = [
        ("Right Option", 61),
        ("Left Option", 58),
        ("Right Control", 62),
        ("Left Control", 59),
        ("Right Command", 54),
        ("F5", 96),
        ("F6", 97),
        ("F7", 98),
        ("F8", 100),
    ]

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Create menu bar icon
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setIcon(symbolName: "mic.fill", customIcon: "icon-idle.png")
        statusItem.button?.toolTip = "Voice Dictation"

        // Build menu
        let menu = NSMenu()

        statusMenuItem = NSMenuItem(title: "Idle — Ready", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)

        menu.addItem(NSMenuItem.separator())

        pauseMenuItem = NSMenuItem(title: "Enabled", action: #selector(togglePause), keyEquivalent: "")
        pauseMenuItem.target = self
        updatePauseMenuItem()
        menu.addItem(pauseMenuItem)

        autoEnterMenuItem = NSMenuItem(title: "Auto-Enter after paste", action: #selector(toggleAutoEnter), keyEquivalent: "")
        autoEnterMenuItem.target = self
        updateAutoEnterMenuItem()
        menu.addItem(autoEnterMenuItem)

        // Hotkey submenu
        let hotkeyItem = NSMenuItem(title: "Hotkey", action: nil, keyEquivalent: "")
        hotkeyMenu = NSMenu()
        for (name, keycode) in AppDelegate.hotkeyOptions {
            let item = NSMenuItem(title: name, action: #selector(selectHotkey(_:)), keyEquivalent: "")
            item.target = self
            item.tag = Int(keycode)
            item.state = keycode == config.hotkeyKeycode ? .on : .off
            hotkeyMenu.addItem(item)
        }
        hotkeyMenu.addItem(NSMenuItem.separator())
        let customItem = NSMenuItem(title: "Custom Key...", action: #selector(startCustomHotkey), keyEquivalent: "")
        customItem.target = self
        hotkeyMenu.addItem(customItem)

        hotkeyItem.submenu = hotkeyMenu
        menu.addItem(hotkeyItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit Voice Dictation", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    @objc func toggleAutoEnter() {
        let current = UserDefaults.standard.bool(forKey: "autoEnter")
        UserDefaults.standard.set(!current, forKey: "autoEnter")
        updateAutoEnterMenuItem()
        print("Auto-Enter: \(!current ? "ON" : "OFF")")
    }

    func updateAutoEnterMenuItem() {
        let on = UserDefaults.standard.bool(forKey: "autoEnter")
        autoEnterMenuItem.title = on ? "Auto-Enter: ON" : "Auto-Enter: OFF"
        autoEnterMenuItem.state = on ? .on : .off
    }

    @objc func togglePause() {
        isPaused = !isPaused
        updatePauseMenuItem()
        // If pausing while recording, stop the recording
        if isPaused && isRecording {
            isRecording = false
            audioRecorder?.stop()
            audioRecorder = nil
            try? FileManager.default.removeItem(at: recordingURL)
        }
        if isPaused {
            setStatus("Paused", symbolName: "mic.slash.fill", customIcon: "icon-paused.png")
        } else {
            setStatus("Idle — Ready", symbolName: "mic.fill", customIcon: "icon-idle.png")
        }
        print("Voice Dictation: \(isPaused ? "PAUSED" : "ENABLED")")
    }

    func updatePauseMenuItem() {
        pauseMenuItem.title = isPaused ? "Disabled — Click to Enable" : "Enabled — Click to Disable"
        pauseMenuItem.state = isPaused ? .off : .on
    }

    @objc func selectHotkey(_ sender: NSMenuItem) {
        let newKeycode = UInt16(sender.tag)
        applyHotkey(keycode: newKeycode, name: sender.title)
    }

    @objc func startCustomHotkey() {
        waitingForHotkey = true
        setStatus("Press any key...", symbolName: "keyboard")
        // Show notification
        DispatchQueue.main.async {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            proc.arguments = ["-e", "display notification \"Press any key to set as hotkey...\" with title \"Voice Dictation\""]
            try? proc.run()
        }
    }

    func applyHotkey(keycode: UInt16, name: String) {
        config.hotkeyKeycode = keycode

        // Update checkmarks — uncheck all preset items
        for item in hotkeyMenu.items {
            if item.action == #selector(selectHotkey(_:)) {
                item.state = item.tag == Int(keycode) ? .on : .off
            }
        }

        // Check if it matches a known key, otherwise show keycode
        let matched = AppDelegate.hotkeyOptions.first { $0.1 == keycode }
        let displayName = matched?.0 ?? name

        // Update or add "Current: ..." item
        let customItems = hotkeyMenu.items.filter { $0.action == #selector(selectHotkey(_:)) }
        let isPreset = AppDelegate.hotkeyOptions.contains { $0.1 == keycode }
        // Remove old custom entry if it exists
        if let existing = hotkeyMenu.items.first(where: { $0.title.hasPrefix("Custom:") }) {
            hotkeyMenu.removeItem(existing)
        }
        if !isPreset {
            let sepIndex = hotkeyMenu.items.firstIndex(where: { $0.isSeparatorItem }) ?? hotkeyMenu.items.count
            let customDisplay = NSMenuItem(title: "Custom: \(displayName) (\(keycode))", action: #selector(selectHotkey(_:)), keyEquivalent: "")
            customDisplay.target = self
            customDisplay.tag = Int(keycode)
            customDisplay.state = .on
            hotkeyMenu.insertItem(customDisplay, at: sepIndex)
        }

        saveConfigValue("HOTKEY_KEYCODE", value: "\(keycode)")
        setStatus("Idle — Ready", symbolName: "mic.fill", customIcon: "icon-idle.png")
        print("Hotkey changed to: \(displayName) (keycode \(keycode))")
    }

    @objc func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    // MARK: - Status Updates

    func resourcePath(_ name: String) -> String {
        let binaryPath = (CommandLine.arguments[0] as NSString).deletingLastPathComponent
        if binaryPath.hasSuffix("Contents/MacOS") {
            return "\((binaryPath as NSString).deletingLastPathComponent)/Resources/\(name)"
        }
        return "\(binaryPath)/VoiceDictation.app/Contents/Resources/\(name)"
    }

    func setIcon(symbolName: String, tint: NSColor? = nil, customIcon: String? = nil) {
        // Try custom PNG first
        if let iconName = customIcon, let img = NSImage(contentsOfFile: resourcePath(iconName)) {
            img.isTemplate = (tint == nil) // colored icons (recording) stay as-is
            img.size = NSSize(width: 18, height: 18)
            statusItem.button?.image = img
            return
        }
        // Fall back to SF Symbol
        if let img = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Voice Dictation") {
            if let color = tint {
                img.isTemplate = false
                let config = NSImage.SymbolConfiguration(paletteColors: [color])
                let tinted = img.withSymbolConfiguration(config) ?? img
                statusItem.button?.image = tinted
            } else {
                img.isTemplate = true
                statusItem.button?.image = img
            }
        }
    }

    func setStatus(_ text: String, symbolName: String, tint: NSColor? = nil, customIcon: String? = nil) {
        DispatchQueue.main.async { [self] in
            setIcon(symbolName: symbolName, tint: tint, customIcon: customIcon)
            statusMenuItem.title = text
        }
    }
}

// MARK: - Recording (using AVAudioRecorder)

let recordingURL = URL(fileURLWithPath: "/tmp/vd_recording.wav")

func startRecording() {
    guard !isRecording, !isPaused else { return }

    try? FileManager.default.removeItem(at: recordingURL)

    let settings: [String: Any] = [
        AVFormatIDKey: Int(kAudioFormatLinearPCM),
        AVSampleRateKey: 16000.0,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
    ]

    do {
        audioRecorder = try AVAudioRecorder(url: recordingURL, settings: settings)
        audioRecorder?.record()
        isRecording = true
        recordingStartTime = CFAbsoluteTimeGetCurrent()
        print("🎙 Recording started...")
        appDelegate?.setStatus("Recording...", symbolName: "mic.circle.fill", tint: .red, customIcon: "icon-recording.png")
        playSound("Tink")
    } catch {
        print("❌ Failed to start recording: \(error)")
    }
}

func stopRecordingAndTranscribe() {
    guard isRecording else { return }
    isRecording = false
    let duration = CFAbsoluteTimeGetCurrent() - recordingStartTime
    print("⏹ Recording stopped after \(String(format: "%.2f", duration))s, transcribing...")

    audioRecorder?.stop()
    audioRecorder = nil

    let attrs = try? FileManager.default.attributesOfItem(atPath: recordingURL.path)
    let fileSize = attrs?[.size] as? UInt64 ?? 0
    if fileSize < 1000 {
        print("⚠️ Recording too short or empty (\(fileSize) bytes).")
        appDelegate?.setStatus("Idle — Ready", symbolName: "mic.fill", customIcon: "icon-idle.png")
        return
    }
    print("   Recorded \(fileSize / 1024) KB audio")

    appDelegate?.setStatus("Transcribing...", symbolName: "ellipsis.circle", customIcon: "icon-transcribing.png")
    playSound("Pop")

    DispatchQueue.global(qos: .userInitiated).async {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = ["\(config.scriptDir)/transcribe.sh"]
        proc.environment = ProcessInfo.processInfo.environment
        try? proc.run()
        proc.waitUntilExit()

        // Paste from clipboard
        simulatePaste()

        // Auto-Enter if enabled
        if UserDefaults.standard.bool(forKey: "autoEnter") {
            usleep(500_000) // 500ms delay to let paste render (WhatsApp is slow)
            simulateEnter()
        }

        appDelegate?.setStatus("Idle — Ready", symbolName: "mic.fill", customIcon: "icon-idle.png")
        print("✅ Transcription complete")
    }
}

func cancelRecording() {
    guard isRecording else { return }
    isRecording = false
    audioRecorder?.stop()
    audioRecorder = nil
    try? FileManager.default.removeItem(at: recordingURL)
    appDelegate?.setStatus("Cancelled", symbolName: "xmark.circle")
    playSound("Basso")
    print("❌ Recording cancelled")
    // Reset icon after a moment
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
        if !isRecording {
            appDelegate?.setStatus("Idle — Ready", symbolName: "mic.fill", customIcon: "icon-idle.png")
        }
    }
}

// MARK: - Event Tap Callback

// Map keycodes to readable names
func keycodeName(_ keycode: UInt16) -> String {
    let names: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
        31: "O", 32: "U", 34: "I", 35: "P", 37: "L", 38: "J", 40: "K", 45: "N", 46: "M",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 25: "9", 26: "7", 28: "8", 29: "0",
        36: "Return", 48: "Tab", 49: "Space", 51: "Delete", 53: "Escape",
        54: "Right Cmd", 55: "Left Cmd", 56: "Left Shift", 57: "Caps Lock",
        58: "Left Option", 59: "Left Control", 60: "Right Shift",
        61: "Right Option", 62: "Right Control", 63: "Fn",
        96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8",
        101: "F9", 103: "F11", 105: "F13", 107: "F14",
        109: "F10", 111: "F12", 113: "F15", 118: "F4",
        120: "F2", 122: "F1",
    ]
    return names[keycode] ?? "Key \(keycode)"
}

let eventCallback: CGEventTapCallBack = { proxy, type, event, userInfo in

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap = userInfo?.assumingMemoryBound(to: CFMachPort.self).pointee {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        return Unmanaged.passRetained(event)
    }

    let keycode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))

    // Custom hotkey capture mode
    if waitingForHotkey {
        // Accept on keyDown or flagsChanged (press only, not release)
        if type == .keyDown || (type == .flagsChanged && event.flags.rawValue & (
            CGEventFlags.maskAlternate.rawValue | CGEventFlags.maskControl.rawValue |
            CGEventFlags.maskShift.rawValue | CGEventFlags.maskCommand.rawValue) != 0) {
            waitingForHotkey = false
            let name = keycodeName(keycode)
            DispatchQueue.main.async {
                appDelegate?.applyHotkey(keycode: keycode, name: name)
            }
            return nil
        }
        return Unmanaged.passRetained(event)
    }

    // Cancel recording: Left Arrow (keycode 123) while recording
    if isRecording && type == .keyDown && keycode == 123 {
        cancelRecording()
        isToggleRecording = false
        return nil
    }

    // Unified hotkey logic — auto-detects hold vs tap:
    //   Hold > 300ms then release → hold-to-record (stops on release)
    //   Quick tap < 300ms → toggle mode (tap again to stop)
    let holdThreshold: CFAbsoluteTime = 0.3

    guard keycode == config.hotkeyKeycode else {
        return Unmanaged.passRetained(event)
    }

    // Detect press and release for both modifier and regular keys
    let isPress: Bool
    let isRelease: Bool

    if type == .flagsChanged {
        let flags = event.flags.rawValue
        let modifierActive = (flags & (CGEventFlags.maskAlternate.rawValue |
                          CGEventFlags.maskControl.rawValue |
                          CGEventFlags.maskShift.rawValue |
                          CGEventFlags.maskCommand.rawValue)) != 0
        isPress = modifierActive
        isRelease = !modifierActive
    } else if type == .keyDown {
        isPress = true
        isRelease = false
    } else if type == .keyUp {
        isPress = false
        isRelease = true
    } else {
        return Unmanaged.passRetained(event)
    }

    if isPress && !isRecording {
        // Start recording and note the time
        hotkeyPressTime = CFAbsoluteTimeGetCurrent()
        isToggleRecording = false
        startRecording()
        return nil
    } else if isPress && isRecording && isToggleRecording {
        // Second tap in toggle mode → stop recording
        isToggleRecording = false
        stopRecordingAndTranscribe()
        return nil
    } else if isRelease && isRecording {
        let held = CFAbsoluteTimeGetCurrent() - hotkeyPressTime
        if held >= holdThreshold {
            // Held long enough → hold mode, stop on release
            isToggleRecording = false
            stopRecordingAndTranscribe()
        } else {
            // Quick tap → toggle mode, keep recording
            isToggleRecording = true
        }
        return nil
    }

    return Unmanaged.passRetained(event)
}

// MARK: - Main

func main() {
    config = loadConfig()
    print("Voice Dictation — Listening for hotkey (mode: \(config.hotkeyMode), keycode: \(config.hotkeyKeycode))")
    print("Press Ctrl+C to quit\n")

    // Request microphone permission
    let semaphore = DispatchSemaphore(value: 0)
    AVCaptureDevice.requestAccess(for: .audio) { granted in
        if granted {
            print("✓ Microphone access granted")
        } else {
            print("⚠️ Microphone access DENIED — recording won't work!")
            print("  System Settings → Privacy & Security → Microphone → enable Voice Dictation")
        }
        semaphore.signal()
    }
    semaphore.wait()

    // Request accessibility permission
    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
    if AXIsProcessTrustedWithOptions(options) {
        print("✓ Accessibility access granted")
    } else {
        print("⚠️ Accessibility access needed — paste won't work until granted.")
    }

    // Set up event tap — listen for all event types so hotkey can be changed at runtime
    let eventMask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)
        | (1 << CGEventType.keyDown.rawValue)
        | (1 << CGEventType.keyUp.rawValue)

    guard let tap = CGEvent.tapCreate(
        tap: .cgSessionEventTap,
        place: .headInsertEventTap,
        options: .defaultTap,
        eventsOfInterest: eventMask,
        callback: eventCallback,
        userInfo: nil
    ) else {
        print("ERROR: Failed to create event tap.")
        print("Please grant Input Monitoring permission:")
        print("  System Settings > Privacy & Security > Input Monitoring")
        print("  Add the 'hotkey' binary to the list.")
        exit(1)
    }

    let tapPtr = UnsafeMutablePointer<CFMachPort>.allocate(capacity: 1)
    tapPtr.initialize(to: tap)

    CGEvent.tapEnable(tap: tap, enable: false)
    let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)

    print("Ready! Hotkey is active.\n")

    // Launch as menu bar app using NSApplication
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory) // No dock icon, menu bar only
    let delegate = AppDelegate()
    appDelegate = delegate
    app.delegate = delegate
    app.run()
}

main()
