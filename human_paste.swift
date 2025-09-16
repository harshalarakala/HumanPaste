import Cocoa
import Darwin
import Carbon
import ApplicationServices
import CoreGraphics

class HumanPaste {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var eventRunLoop: CFRunLoop?
    private var eventThread: Thread?
    private var isEnabled = false
    private var isTyping = false
    private var interceptEnabled = true
    private var cooldownUntil: Date?
    private var cancelRequested = false
    private let stateQueue = DispatchQueue(label: "HumanPaste.state", attributes: .concurrent)
    
    // Typing speed configuration (microseconds) driven by an average WPM with jitter
    private var typingDelayBaseUs: useconds_t = 80_000   // default ~150 WPM => ~80ms/char
    private var typingDelayJitterUs: useconds_t = 40_000 // 50% jitter
    private var wordsPerMinute: Int = 150
    // Hesitation settings
    private var hesitationEnabled: Bool = false
    private var hesitationMaxMs: Int = 500
    // Auto-indent adjustment
    private var autoIndentAdjustEnabled: Bool = false

    init() {
        let saved = UserDefaults.standard.integer(forKey: "typing_wpm")
        if saved > 0 { wordsPerMinute = saved }
        hesitationEnabled = UserDefaults.standard.bool(forKey: "hesitation_enabled")
        let savedHes = UserDefaults.standard.integer(forKey: "hesitation_max_ms")
        if savedHes > 0 { hesitationMaxMs = savedHes }
        if UserDefaults.standard.object(forKey: "autoindent_adjust_enabled") != nil {
            autoIndentAdjustEnabled = UserDefaults.standard.bool(forKey: "autoindent_adjust_enabled")
        }
        updateDelaysForWpm()
    }

    private func updateDelaysForWpm() {
        let wpm = max(20, min(300, wordsPerMinute))
        // Average delay per character in microseconds: 12/WPM seconds per char (5 chars per word)
        let base = max(5_000, 12_000_000 / wpm)
        typingDelayBaseUs = useconds_t(base)
        typingDelayJitterUs = useconds_t(base / 2)
    }

    func setWordsPerMinute(_ wpm: Int) {
        wordsPerMinute = max(20, min(300, wpm))
        UserDefaults.standard.set(wordsPerMinute, forKey: "typing_wpm")
        updateDelaysForWpm()
    }

    func getWordsPerMinute() -> Int { wordsPerMinute }

    func setHesitationEnabled(_ enabled: Bool) {
        hesitationEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "hesitation_enabled")
    }
    func getHesitationEnabled() -> Bool { hesitationEnabled }
    func setHesitationMaxMs(_ ms: Int) {
        hesitationMaxMs = max(50, min(1_500, ms))
        UserDefaults.standard.set(hesitationMaxMs, forKey: "hesitation_max_ms")
    }
    func getHesitationMaxMs() -> Int { hesitationMaxMs }
    func setAutoIndentAdjustEnabled(_ enabled: Bool) {
        autoIndentAdjustEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "autoindent_adjust_enabled")
    }
    func getAutoIndentAdjustEnabled() -> Bool { autoIndentAdjustEnabled }

    private func setIsTyping(_ value: Bool) {
        stateQueue.async(flags: .barrier) { self.isTyping = value }
    }
    private func getIsTyping() -> Bool {
        stateQueue.sync { isTyping }
    }
    private func requestCancel() {
        stateQueue.async(flags: .barrier) { self.cancelRequested = true }
    }
    private func clearCancel() {
        stateQueue.async(flags: .barrier) { self.cancelRequested = false }
    }
    private func isCancelRequested() -> Bool {
        stateQueue.sync { cancelRequested }
    }
    
    func start() -> Bool {
        if isEnabled { return true }
        // Check Accessibility trust and prompt if needed
        if !HumanPaste.isAccessibilityTrusted(prompt: true) {
            NSLog("HumanPaste: Accessibility not trusted. Prompted user.")
            isEnabled = false
            return false
        }
        isEnabled = true
        let thread = Thread { [weak self] in
            self?.startOnCurrentRunLoop()
        }
        eventThread = thread
        thread.start()
        return true
    }

    // Detect if a browser is frontmost (web editors often bind Cmd+Enter and handle Shift+Tab specially)
    private func isFrontmostBrowser() -> Bool {
        if let bid = NSWorkspace.shared.frontmostApplication?.bundleIdentifier {
            if bid == "com.apple.Safari" { return true }
            if bid.hasPrefix("com.google.Chrome") { return true }
            if bid.hasPrefix("org.mozilla.firefox") { return true }
            if bid.hasPrefix("com.microsoft.edgemac") { return true }
        }
        return false
    }

    func setInterceptEnabled(_ enabled: Bool) {
        interceptEnabled = enabled
    }
    func getInterceptEnabled() -> Bool { interceptEnabled }

    private func startOnCurrentRunLoop() {
        print("Human Paste enabled. Press Cmd+V to intercept paste operations.")
        
        let eventMask = (1 << CGEventType.keyDown.rawValue)
        eventTap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { proxy, type, event, refcon in
                return Unmanaged<HumanPaste>.fromOpaque(refcon!).takeUnretainedValue().handleEvent(proxy: proxy, type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )
        
        guard let eventTap = eventTap else {
            NSLog("HumanPaste: Failed to create event tap. Check Accessibility permissions.")
            isEnabled = false
            return
        }
        
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        let rl = CFRunLoopGetCurrent()
        eventRunLoop = rl
        CFRunLoopAddSource(rl, runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        CFRunLoopRun()
    }

    func stop() {
        requestCancel()
        if let eventTap = eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }
        if let rl = eventRunLoop, let src = runLoopSource {
            CFRunLoopRemoveSource(rl, src, .commonModes)
        }
        if let rl = eventRunLoop {
            CFRunLoopStop(rl)
        }
        eventTap = nil
        runLoopSource = nil
        eventRunLoop = nil
        eventThread = nil
        isEnabled = false
        print("Human Paste disabled.")
    }
    
    func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            NSLog("HumanPaste: event tap disabled (\(type.rawValue)), re-enabling")
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        // Skip if we're currently typing to avoid feedback loops
        if getIsTyping() {
            // Allow cancellation on second Cmd+V
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            let flags = event.flags
            if type == .keyDown && keyCode == 9 && flags.contains(.maskCommand) {
                print("Cmd+V detected during typing. Cancelling...")
                cancelTyping()
                cooldownUntil = Date().addingTimeInterval(2)
                // Suppress original Cmd+V event
                return nil
            }
            // Suppress Cmd+Enter while typing to avoid triggering Run/Submit in editors
            if type == .keyDown && keyCode == 36 && flags.contains(.maskCommand) {
                print("Suppressing Cmd+Enter during typing")
                return nil
            }
            return Unmanaged.passUnretained(event)
        }
        
        if type == .keyDown {
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            let flags = event.flags
            let hasCmd = flags.contains(.maskCommand)
            let hasShift = flags.contains(.maskShift)
            let hasOption = flags.contains(.maskAlternate)

            // Global shortcuts (active while tap is running)
            if hasCmd && (hasShift || hasOption) {
                switch keyCode {
                case 14: // E
                    setInterceptEnabled(true)
                    print("HumanPaste: Intercept enabled")
                    return nil
                case 2: // D
                    setInterceptEnabled(false)
                    print("HumanPaste: Intercept disabled (system paste will pass through)")
                    return nil
                case 30: // ] faster (or Cmd+Option+])
                    setWordsPerMinute(getWordsPerMinute() + 10)
                    print("HumanPaste: WPM -> \(getWordsPerMinute())")
                    return nil
                case 33: // [ slower (or Cmd+Option+[)
                    setWordsPerMinute(getWordsPerMinute() - 10)
                    print("HumanPaste: WPM -> \(getWordsPerMinute())")
                    return nil
                default:
                    break
                }
            }
            
            // Check for Cmd+V (keyCode 9 is 'v', kCGEventFlagMaskCommand is Cmd)
            if keyCode == 9 && hasCmd {
                // Enforce cooldown after a cancellation
                if let until = cooldownUntil, Date() < until {
                    print("Cmd+V ignored: cooldown active")
                    return nil
                }
                // If intercept disabled, allow normal paste
                if !interceptEnabled {
                    return Unmanaged.passUnretained(event)
                }
                print("Cmd+V detected! Intercepting paste...")
                
                // Get clipboard contents
                let pasteboard = NSPasteboard.general
                if let clipboardString = pasteboard.string(forType: .string) {
                    print("Typing out: \(String(clipboardString.prefix(50)))\(clipboardString.count > 50 ? "..." : "")")
                    
                    // Type the text in a separate queue to avoid blocking
                    DispatchQueue.global(qos: .userInteractive).async {
                        self.typeText(clipboardString)
                    }
                } else {
                    print("Clipboard is empty")
                }
                
                // Return nil to suppress the original Cmd+V event
                return nil
            }
        }
        
        // Pass through all other events
        return Unmanaged.passUnretained(event)
    }
    
    func typeText(_ text: String) {
        setIsTyping(true)
        clearCancel()
        defer { setIsTyping(false) }

        // Normalize newlines to \n for consistent handling
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let source = CGEventSource(stateID: .hidSystemState)

        var isStartOfLine = true
        var recentWordChars = 0
        let chars = Array(normalized)
        var i = 0
        while i < chars.count {
            if isCancelRequested() { break }
            var ch = chars[i]

            if ch == "\n" {
                print("DEBUG: Processing newline at position \(i)")
                pressKey(source: source, keyCode: 36) // Return
                // Note: Auto-indent adjustment disabled by default due to cursor positioning issues
                // Users can re-enable in menu if needed for specific editors
                
                // Hesitation between lines (think pause)
                if getHesitationEnabled() {
                    let maxMs = getHesitationMaxMs()
                    let pause = Int.random(in: 0...maxMs)
                    usleep(useconds_t(pause * 1000))
                }
                isStartOfLine = true
                i += 1
                continue
            } else if ch == "\t" {
                print("DEBUG: Processing tab at position \(i)")
                pressKey(source: source, keyCode: 48) // Tab
            } else {
                if ch == " " {
                    print("DEBUG: Processing space at position \(i)")
                }
                typeCharacter(source: source, char: ch)
                if ch.isLetter || ch.isNumber || ch == "_" {
                    recentWordChars += 1
                } else {
                    recentWordChars = 0
                }
                isStartOfLine = false
            }

            pthread_yield_np()
            if isCancelRequested() { break }
            // Burst typing within words; extra pause at word boundaries
            if ch == " " || ch == "," || ch == ";" || ch == ")" || ch == "(" || ch == ":" {
                let base = Int(typingDelayBaseUs)
                let jitter = Int(typingDelayJitterUs)
                let delay = min(base + (jitter > 0 ? Int.random(in: 0...jitter) : 0) + base/2, base*4)
                usleep(useconds_t(delay))
                recentWordChars = 0
            } else {
                // Faster while in a word
                let base = Int(typingDelayBaseUs)
                let jitter = Int(typingDelayJitterUs)
                let fast = max(2_000, base - base/3)
                let delay = max(2_000, min(fast + (jitter > 0 ? Int.random(in: 0...(jitter/2)) : 0), base*2))
                usleep(useconds_t(delay))
            }
            i += 1
        }

        print(isCancelRequested() ? "Cancelled typing" : "Finished typing")
    }
    
    func pressKey(source: CGEventSource?, keyCode: CGKeyCode) {
        let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
    
    func typeCharacter(source: CGEventSource?, char: Character) {
        let string = String(char)
        let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
        
        down?.flags = []
        up?.flags = []
        
        let chars = Array(string.utf16)
        down?.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: chars)
        up?.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: chars)
        
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
    
    func pressKeyWithFlags(source: CGEventSource?, keyCode: CGKeyCode, flags: CGEventFlags) {
        let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        down?.flags = flags
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        usleep(1000) // Very short delay between key down and up
        up?.post(tap: .cghidEventTap)
    }

    private func moveToLineStart(source: CGEventSource?) {
        // Use Ctrl+A to move to beginning of line (key code 0 is 'A')
        pressKeyWithFlags(source: source, keyCode: 0, flags: .maskControl) // Ctrl+A
    }

    // Removed deletion-based line clearing by request; we only reposition to line start now.
    
    private func cancelTyping() {
        requestCancel()
    }
    
    private func sleepBetweenKeystrokes() {
        let base = Int(typingDelayBaseUs)
        let jitter = Int(typingDelayJitterUs)
        let delay = base + (jitter > 0 ? Int.random(in: 0...jitter) : 0)
        usleep(useconds_t(delay))
    }
    
    static func isAccessibilityTrusted(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options: NSDictionary = [key: prompt]
        return AXIsProcessTrustedWithOptions(options)
    }
    
    deinit {
        stop()
    }
}

@main
class AppDelegate: NSObject, NSApplicationDelegate {
    private let humanPaste = HumanPaste()
    private var statusItem: NSStatusItem!
    private var window: NSWindow?
    private var windowToggle: NSButton?
    private var windowLabel: NSTextField?
    private var trustCheckTimer: Timer?
    
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        let ok = app.setActivationPolicy(.regular)
        NSLog("HumanPaste: setActivationPolicy(.regular) => \(ok)")
        app.activate(ignoringOtherApps: true)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("HumanPaste: applicationDidFinishLaunching")
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.title = "HP"
        }
        let menu = NSMenu()
        let toggleItem = NSMenuItem(title: "Enable", action: #selector(toggleEnabled(_:)), keyEquivalent: "e")
        toggleItem.state = .off
        toggleItem.target = self
        menu.addItem(toggleItem)
        // Hesitation controls
        let hesItem = NSMenuItem()
        let hesToggle = NSButton(checkboxWithTitle: "Hesitation between lines", target: self, action: #selector(hesitationToggled(_:)))
        hesToggle.state = humanPaste.getHesitationEnabled() ? .on : .off
        let hesSlider = NSSlider(value: Double(humanPaste.getHesitationMaxMs()), minValue: 100, maxValue: 1500, target: self, action: #selector(hesitationMsChanged(_:)))
        hesSlider.isContinuous = true
        let hesLabel = NSTextField(labelWithString: "Max pause: \(humanPaste.getHesitationMaxMs()) ms")
        let hesStack = NSStackView(views: [hesToggle, hesSlider, hesLabel])
        hesStack.orientation = .vertical
        hesStack.spacing = 6
        hesItem.view = hesStack
        menu.addItem(hesItem)
        // WPM slider
        let wpmItem = NSMenuItem()
        let slider = NSSlider(value: Double(humanPaste.getWordsPerMinute()), minValue: 20, maxValue: 300, target: self, action: #selector(wpmChanged(_:)))
        slider.isContinuous = true
        slider.widthAnchor.constraint(equalToConstant: 180).isActive = true
        let valueLabel = NSTextField(labelWithString: "Current: \(humanPaste.getWordsPerMinute()) WPM")
        valueLabel.alignment = .left
        let wpmView = NSStackView(views: [NSTextField(labelWithString: "Typing Speed (WPM)"), slider, valueLabel])
        wpmView.orientation = .vertical
        wpmView.spacing = 6
        wpmItem.view = wpmView
        menu.addItem(wpmItem)
        // Auto-indent adjust toggle
        let aiItem = NSMenuItem()
        let aiToggle = NSButton(checkboxWithTitle: "Adjust for editor auto-indent", target: self, action: #selector(autoIndentToggled(_:)))
        aiToggle.state = humanPaste.getAutoIndentAdjustEnabled() ? .on : .off
        aiItem.view = aiToggle
        menu.addItem(aiItem)
        menu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit(_:)), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem.menu = menu

        // Debug: show a small window so we can see the app is running
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 140),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.title = "HumanPaste"
        let label = NSTextField(labelWithString: "Toggle interceptor below. Cmd+V will be intercepted when enabled.")
        label.frame = NSRect(x: 20, y: 84, width: 320, height: 20)
        win.contentView?.addSubview(label)

        let toggle = NSButton(checkboxWithTitle: "Enable interceptor", target: self, action: #selector(toggleFromWindow(_:)))
        toggle.frame = NSRect(x: 20, y: 48, width: 200, height: 20)
        toggle.state = .off
        win.contentView?.addSubview(toggle)

        let quitBtn = NSButton(title: "Quit", target: self, action: #selector(quit(_:)))
        quitBtn.frame = NSRect(x: 20, y: 16, width: 80, height: 24)
        win.contentView?.addSubview(quitBtn)

        windowToggle = toggle
        windowLabel = label
        window = win
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func wpmChanged(_ sender: NSSlider) {
        let wpm = Int(sender.integerValue)
        humanPaste.setWordsPerMinute(wpm)
        if let stack = (statusItem.menu?.items.first { ($0.view as? NSStackView) != nil })?.view as? NSStackView,
           stack.views.count >= 3, let label = stack.views[2] as? NSTextField {
            label.stringValue = "Current: \(wpm) WPM"
        }
    }

    @objc private func hesitationToggled(_ sender: NSButton) {
        humanPaste.setHesitationEnabled(sender.state == .on)
    }

    @objc private func hesitationMsChanged(_ sender: NSSlider) {
        humanPaste.setHesitationMaxMs(Int(sender.integerValue))
        // Update label under the slider
        if let item = statusItem.menu?.items.first(where: { ($0.view as? NSStackView)?.views.contains(sender) == true }),
           let stack = item.view as? NSStackView, stack.views.count >= 3,
           let label = stack.views[2] as? NSTextField {
            label.stringValue = "Max pause: \(Int(sender.integerValue)) ms"
        }
    }

    @objc private func autoIndentToggled(_ sender: NSButton) {
        humanPaste.setAutoIndentAdjustEnabled(sender.state == .on)
    }
    
    @objc private func toggleEnabled(_ sender: NSMenuItem) {
        if sender.state == .off {
            setEnabled(true)
        } else {
            setEnabled(false)
        }
    }

    @objc private func toggleFromWindow(_ sender: NSButton) {
        setEnabled(sender.state == .on)
    }

    private func setEnabled(_ enabled: Bool) {
        if enabled {
            if !humanPaste.start() {
                showAccessibilityInstructions()
                beginTrustPolling()
            }
        } else {
            humanPaste.stop()
        }
        if let menu = statusItem.menu, let item = menu.items.first {
            item.state = enabled ? .on : .off
            item.title = enabled ? "Disable" : "Enable"
        }
        windowToggle?.state = enabled ? .on : .off
    }

    private func showAccessibilityInstructions() {
        if let label = windowLabel {
            label.stringValue = "Grant Accessibility: System Settings → Privacy & Security → Accessibility → add HumanPaste (this copy) and enable it."
        }
        if let toggle = windowToggle {
            toggle.state = .off
            toggle.isEnabled = true
        }
        // Open Accessibility settings pane for convenience
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    static func isAccessibilityTrusted(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options: NSDictionary = [key: prompt]
        return AXIsProcessTrustedWithOptions(options)
    }
    
    private func beginTrustPolling() {
        trustCheckTimer?.invalidate()
        trustCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] t in
            guard let self = self else { return }
            if HumanPaste.isAccessibilityTrusted(prompt: false) {
                t.invalidate()
                DispatchQueue.main.async {
                    self.windowLabel?.stringValue = "Accessibility granted. You can enable the interceptor now."
                    self.setEnabled(true)
                }
            }
        }
        RunLoop.main.add(trustCheckTimer!, forMode: .common)
    }
    
    @objc private func quit(_ sender: Any?) {
        humanPaste.stop()
        NSApp.terminate(nil)
    }
}
