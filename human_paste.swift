import Cocoa
import Darwin
import Carbon
import ApplicationServices
import CoreGraphics
import QuartzCore

// 0 = Mac (⌘←), 1 = Windows VM (Home), 2 = Ctrl+A (terminals / some Windows editors)
enum LineStartEnvironment: Int {
    case macNative = 0
    case windowsHome = 1
    case windowsCtrlA = 2

    var menuLabel: String {
        switch self {
        case .macNative: return "Mac (⌘←)"
        case .windowsHome: return "Windows VM (Home)"
        case .windowsCtrlA: return "Windows / terminal (⌃A)"
        }
    }
}

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
    private var bypassNextCmdV = false
    private let stateQueue = DispatchQueue(label: "HumanPaste.state", attributes: .concurrent)
    /// Called on main when human typing starts/stops (for menu bar animation).
    var typingActivityHandler: ((Bool) -> Void)?
    
    // Typing speed configuration (microseconds) driven by an average WPM with jitter
    private var typingDelayBaseUs: useconds_t = 80_000   // default ~150 WPM => ~80ms/char
    private var typingDelayJitterUs: useconds_t = 40_000 // 50% jitter
    private var wordsPerMinute: Int = 150
    // Hesitation settings
    private var hesitationEnabled: Bool = false
    private var hesitationMaxMs: Int = 500
    // Auto-indent adjustment (after newline: move to line start so editor auto-indent does not stack with pasted leading whitespace)
    private var autoIndentAdjustEnabled: Bool = true
    /// How to jump to line start after newline when correcting editor auto-indent (VMs often need Home or ⌃A, not ⌘←).
    private var lineStartEnvironment: LineStartEnvironment = .macNative

    init() {
        let saved = UserDefaults.standard.integer(forKey: "typing_wpm")
        if saved > 0 { wordsPerMinute = saved }
        hesitationEnabled = UserDefaults.standard.bool(forKey: "hesitation_enabled")
        let savedHes = UserDefaults.standard.integer(forKey: "hesitation_max_ms")
        if savedHes > 0 { hesitationMaxMs = savedHes }
        if UserDefaults.standard.object(forKey: "autoindent_adjust_enabled") != nil {
            autoIndentAdjustEnabled = UserDefaults.standard.bool(forKey: "autoindent_adjust_enabled")
        }
        let savedEnv = UserDefaults.standard.integer(forKey: "line_start_environment")
        if let env = LineStartEnvironment(rawValue: savedEnv) {
            lineStartEnvironment = env
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
    func setLineStartEnvironment(_ env: LineStartEnvironment) {
        lineStartEnvironment = env
        UserDefaults.standard.set(env.rawValue, forKey: "line_start_environment")
    }
    func getLineStartEnvironment() -> LineStartEnvironment { lineStartEnvironment }

    func isInterceptorRunning() -> Bool { isEnabled }

    private func setIsTyping(_ value: Bool) {
        stateQueue.async(flags: .barrier) {
            self.isTyping = value
            DispatchQueue.main.async { self.typingActivityHandler?(value) }
        }
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

    /// Instant paste for ⇧⌘V: macOS apps use ⌘V; Windows/Linux guests in a VM expect ⌃V.
    private func postInstantPaste() {
        let source = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        switch getLineStartEnvironment() {
        case .macNative:
            stateQueue.sync(flags: .barrier) { self.bypassNextCmdV = true }
            down?.flags = .maskCommand
            up?.flags = .maskCommand
        case .windowsHome, .windowsCtrlA:
            // Guest OS paste — do not use ⌘V (often ignored or wrong inside VMs)
            down?.flags = .maskControl
            up?.flags = .maskControl
        }
        down?.post(tap: .cghidEventTap)
        usleep(2_000)
        up?.post(tap: .cghidEventTap)
    }

    private func consumeBypassIfNeededForCmdV(flags: CGEventFlags) -> Bool {
        stateQueue.sync {
            if bypassNextCmdV, flags.contains(.maskCommand), !flags.contains(.maskShift) {
                bypassNextCmdV = false
                return true
            }
            return false
        }
    }

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

        if type == .keyDown {
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            let flags = event.flags
            let hasCmd = flags.contains(.maskCommand)
            let hasShift = flags.contains(.maskShift)

            // ⇧⌘V → instant paste (⌘V on Mac, ⌃V when line-start mode is Windows VM — see menu slider)
            if keyCode == 9 && hasCmd && hasShift {
                if interceptEnabled {
                    postInstantPaste()
                    return nil
                }
                return Unmanaged.passUnretained(event)
            }

            // Synthesized ⌘V must pass through so it is not turned into human paste again
            if keyCode == 9 && hasCmd && consumeBypassIfNeededForCmdV(flags: flags) {
                return Unmanaged.passUnretained(event)
            }
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
            
            // Human paste: ⌘V only (not ⇧⌘V — that is instant paste above)
            if keyCode == 9 && hasCmd && !hasShift {
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
                pressKey(source: source, keyCode: 36) // Return
                
                // After newline, many editors auto-indent; move to true line start before typing
                // the rest of the paste so editor indent is not combined with clipboard leading spaces/tabs.
                if getAutoIndentAdjustEnabled() && i + 1 < chars.count {
                    usleep(45_000) // Let the editor apply auto-indent before we home the caret
                    performLineStartAfterAutoIndent(source: source)
                }
                
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
                pressKey(source: source, keyCode: 48) // Tab
            } else {
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

    private func performLineStartAfterAutoIndent(source: CGEventSource?) {
        switch getLineStartEnvironment() {
        case .macNative:
            pressKeyWithFlags(source: source, keyCode: 123, flags: .maskCommand) // ⌘←
        case .windowsHome:
            pressKey(source: source, keyCode: 115) // Home (common in Windows VMs)
        case .windowsCtrlA:
            pressKeyWithFlags(source: source, keyCode: 0, flags: .maskControl) // ⌃A
        }
    }
    
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
    private var statusBarAnimTimer: Timer?
    private var statusBarPhase: CGFloat = 0
    private var statusTypingActive = false
    private var interceptorRunning = false
    private weak var menuWpmLabel: NSTextField?
    private weak var menuHesitationLabel: NSTextField?
    private weak var menuEnvLabel: NSTextField?
    private weak var menuEnvSlider: NSSlider?
    private weak var menuAiToggle: NSButton?

    /// Total width for custom menu panels (prevents clipped controls and zero-height layout).
    private let menuPanelWidth: CGFloat = 272

    private lazy var statusIconIdle: NSImage? = {
        let img = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "HumanPaste")
        img?.isTemplate = true
        return img
    }()
    private lazy var statusIconActive: NSImage? = {
        let img = NSImage(systemSymbolName: "doc.on.clipboard.fill", accessibilityDescription: "HumanPaste typing")
        img?.isTemplate = true
        return img
    }()

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
        humanPaste.typingActivityHandler = { [weak self] typing in
            self?.statusTypingActive = typing
            DispatchQueue.main.async { self?.refreshStatusBarAnimation() }
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        configureStatusItemButton()
        applyStatusBarVisualState()

        let menu = NSMenu()
        let header = NSMenuItem(title: "HumanPaste", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        let toggleItem = NSMenuItem(title: "Enable interceptor", action: #selector(toggleEnabled(_:)), keyEquivalent: "e")
        toggleItem.state = .off
        toggleItem.target = self
        menu.addItem(toggleItem)

        let pasteHint = NSMenuItem(title: "Regular paste: ⇧⌘V (when interceptor is on)", action: nil, keyEquivalent: "")
        pasteHint.isEnabled = false
        menu.addItem(pasteHint)
        menu.addItem(NSMenuItem.separator())

        // Hesitation — label above slider so values are not crushed against the next section
        let hesItem = NSMenuItem()
        let hesToggle = NSButton(checkboxWithTitle: "Hesitation between lines", target: self, action: #selector(hesitationToggled(_:)))
        hesToggle.state = humanPaste.getHesitationEnabled() ? .on : .off
        hesToggle.setContentHuggingPriority(.required, for: .horizontal)
        let hesLabel = NSTextField(labelWithString: "Max pause: \(humanPaste.getHesitationMaxMs()) ms")
        hesLabel.font = NSFont.systemFont(ofSize: 11)
        hesLabel.textColor = .labelColor
        menuHesitationLabel = hesLabel
        let hesSlider = NSSlider(value: Double(humanPaste.getHesitationMaxMs()), minValue: 100, maxValue: 1500, target: self, action: #selector(hesitationMsChanged(_:)))
        hesSlider.isContinuous = true
        constrainSliderWidth(hesSlider)
        let hesStack = NSStackView(views: [
            menuSectionHeaderField("Line pauses"),
            hesToggle,
            hesLabel,
            hesSlider
        ])
        attachMenuPanel(hesStack, to: hesItem)
        menu.addItem(hesItem)

        // WPM
        let wpmItem = NSMenuItem()
        let valueLabel = NSTextField(labelWithString: "Current: \(humanPaste.getWordsPerMinute()) WPM")
        valueLabel.font = NSFont.systemFont(ofSize: 11)
        valueLabel.textColor = .labelColor
        menuWpmLabel = valueLabel
        let slider = NSSlider(value: Double(humanPaste.getWordsPerMinute()), minValue: 20, maxValue: 300, target: self, action: #selector(wpmChanged(_:)))
        slider.isContinuous = true
        constrainSliderWidth(slider)
        let wpmView = NSStackView(views: [
            menuSectionHeaderField("Typing speed"),
            valueLabel,
            slider
        ])
        attachMenuPanel(wpmView, to: wpmItem)
        menu.addItem(wpmItem)

        // Auto-indent + line-start (Mac vs Windows VM)
        let aiItem = NSMenuItem()
        let aiToggle = NSButton(checkboxWithTitle: "Adjust for editor auto-indent", target: self, action: #selector(autoIndentToggled(_:)))
        aiToggle.state = humanPaste.getAutoIndentAdjustEnabled() ? .on : .off
        aiToggle.setContentHuggingPriority(.required, for: .horizontal)
        menuAiToggle = aiToggle
        let envCaption = menuSectionHeaderField("Line start after newline")
        let envLabel = NSTextField(labelWithString: humanPaste.getLineStartEnvironment().menuLabel)
        envLabel.font = NSFont.systemFont(ofSize: 11)
        envLabel.textColor = .labelColor
        envLabel.preferredMaxLayoutWidth = menuPanelWidth - 28
        menuEnvLabel = envLabel
        let envSlider = NSSlider(
            value: Double(humanPaste.getLineStartEnvironment().rawValue),
            minValue: 0,
            maxValue: 2,
            target: self,
            action: #selector(lineStartEnvChanged(_:))
        )
        envSlider.numberOfTickMarks = 3
        envSlider.allowsTickMarkValuesOnly = true
        envSlider.isContinuous = true
        constrainSliderWidth(envSlider)
        menuEnvSlider = envSlider
        let tickHint = NSTextField(labelWithString: "Ticks: Mac · VM Home · ⌃A")
        tickHint.font = NSFont.systemFont(ofSize: 10)
        tickHint.textColor = .tertiaryLabelColor
        let aiStack = NSStackView(views: [aiToggle, envCaption, envLabel, envSlider, tickHint])
        attachMenuPanel(aiStack, to: aiItem)
        menu.addItem(aiItem)

        menu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit(_:)), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem.menu = menu

        let aiOn = humanPaste.getAutoIndentAdjustEnabled()
        menuEnvSlider?.isEnabled = aiOn
        menuEnvLabel?.textColor = aiOn ? .labelColor : .disabledControlTextColor

        buildMainWindow()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func configureStatusItemButton() {
        guard let button = statusItem.button else { return }
        button.title = ""
        button.image = statusIconIdle
        button.imagePosition = .imageOnly
        button.wantsLayer = true
        button.toolTip = "HumanPaste — ⌘V human typing, ⇧⌘V instant paste"
    }

    private func applyStatusBarVisualState() {
        guard let button = statusItem.button else { return }
        statusBarAnimTimer?.invalidate()
        statusBarAnimTimer = nil
        button.layer?.removeAnimation(forKey: "hp.glow")
        if !interceptorRunning {
            button.image = statusIconIdle
            button.alphaValue = 0.55
            return
        }
        button.alphaValue = 1.0
        button.image = statusIconIdle
        refreshStatusBarAnimation()
    }

    private func refreshStatusBarAnimation() {
        guard interceptorRunning, statusItem.button != nil else { return }
        statusBarAnimTimer?.invalidate()
        statusBarPhase = 0
        let interval: TimeInterval = statusTypingActive ? 0.11 : 0.045
        statusBarAnimTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.statusBarAnimationTick()
        }
        if let t = statusBarAnimTimer {
            RunLoop.main.add(t, forMode: .common)
        }
        startMenuBarLayerPulse(typing: statusTypingActive)
    }

    private func statusBarAnimationTick() {
        guard let button = statusItem.button, interceptorRunning else { return }
        statusBarPhase += statusTypingActive ? 0.65 : 0.22
        let w = sin(Double(statusBarPhase))
        if statusTypingActive {
            button.alphaValue = CGFloat(0.58 + 0.42 * (w * 0.5 + 0.5))
            button.image = (Int(statusBarPhase * 3) % 2 == 0) ? statusIconIdle : statusIconActive
        } else {
            button.alphaValue = CGFloat(0.78 + 0.22 * (w * 0.5 + 0.5))
            button.image = statusIconIdle
        }
    }

    private func startMenuBarLayerPulse(typing: Bool) {
        guard let layer = statusItem.button?.layer else { return }
        layer.removeAnimation(forKey: "hp.glow")
        let pulse = CABasicAnimation(keyPath: "transform.scale")
        pulse.fromValue = typing ? 1.0 : 0.96
        pulse.toValue = typing ? 1.08 : 1.02
        pulse.duration = typing ? 0.28 : 0.9
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(pulse, forKey: "hp.glow")
    }

    private func menuSectionHeaderField(_ string: String) -> NSTextField {
        let f = NSTextField(labelWithString: string)
        f.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        f.textColor = .secondaryLabelColor
        return f
    }

    private func constrainSliderWidth(_ slider: NSSlider) {
        let inner = menuPanelWidth - 28 // matches horizontal edge insets on menu panels
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.widthAnchor.constraint(equalToConstant: inner).isActive = true
    }

    /// Pads and sizes a stack so `NSMenuItem` lays it out reliably (avoids overlapping rows).
    private func attachMenuPanel(_ stack: NSStackView, to item: NSMenuItem) {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 10, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let host = NSView(frame: .zero)
        host.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            stack.topAnchor.constraint(equalTo: host.topAnchor),
            stack.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            stack.widthAnchor.constraint(equalToConstant: menuPanelWidth)
        ])
        host.layoutSubtreeIfNeeded()
        var h = host.fittingSize.height
        if h < 2 { h = stack.fittingSize.height }
        if h < 2 { h = 72 }
        host.frame = NSRect(x: 0, y: 0, width: menuPanelWidth, height: ceil(h))
        item.view = host
    }

    private func buildMainWindow() {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 300),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.title = "HumanPaste"
        win.minSize = NSSize(width: 400, height: 260)

        let root = NSVisualEffectView()
        root.material = .sidebar
        root.blendingMode = .behindWindow
        root.state = .active

        let title = NSTextField(labelWithString: "HumanPaste")
        title.font = NSFont.systemFont(ofSize: 22, weight: .semibold)
        title.textColor = .labelColor
        title.translatesAutoresizingMaskIntoConstraints = false

        let subtitle = NSTextField(wrappingLabelWithString: "⌘V types clipboard text like a human. ⇧⌘V always pastes instantly (system paste). Use the menu bar icon for speed, pauses, and Windows VM line-start options.")
        subtitle.font = NSFont.systemFont(ofSize: 13)
        subtitle.textColor = .secondaryLabelColor
        subtitle.translatesAutoresizingMaskIntoConstraints = false

        let toggle = NSButton(checkboxWithTitle: "Enable interceptor (menu bar)", target: self, action: #selector(toggleFromWindow(_:)))
        toggle.state = .off
        toggle.translatesAutoresizingMaskIntoConstraints = false

        let openMenuHint = NSTextField(wrappingLabelWithString: "Tip: click the clipboard icon in the menu bar for sliders and shortcuts (⌘⇧E enable intercept, ⌘⇧D disable).")
        openMenuHint.font = NSFont.systemFont(ofSize: 12)
        openMenuHint.textColor = .tertiaryLabelColor
        openMenuHint.translatesAutoresizingMaskIntoConstraints = false

        let quitBtn = NSButton(title: "Quit HumanPaste", target: self, action: #selector(quit(_:)))
        quitBtn.bezelStyle = .rounded
        quitBtn.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [title, subtitle, toggle, openMenuHint, quitBtn])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setCustomSpacing(8, after: title)

        let bottomSpacer = NSView()
        bottomSpacer.translatesAutoresizingMaskIntoConstraints = false
        bottomSpacer.setContentHuggingPriority(.defaultLow, for: .vertical)
        bottomSpacer.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        let mainStack = NSStackView(views: [stack, bottomSpacer])
        mainStack.orientation = .vertical
        mainStack.spacing = 0
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(mainStack)

        NSLayoutConstraint.activate([
            mainStack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            mainStack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            mainStack.topAnchor.constraint(equalTo: root.topAnchor, constant: 24),
            mainStack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -24)
        ])

        win.setContentSize(NSSize(width: 440, height: 280))
        win.contentView = root
        root.frame = root.superview?.bounds ?? NSRect(x: 0, y: 0, width: 440, height: 300)
        root.autoresizingMask = [.width, .height]
        windowToggle = toggle
        windowLabel = subtitle
        window = win
        win.center()
        win.makeKeyAndOrderFront(nil)
    }

    @objc private func wpmChanged(_ sender: NSSlider) {
        let wpm = Int(sender.integerValue)
        humanPaste.setWordsPerMinute(wpm)
        menuWpmLabel?.stringValue = "Current: \(wpm) WPM"
    }

    @objc private func hesitationToggled(_ sender: NSButton) {
        humanPaste.setHesitationEnabled(sender.state == .on)
    }

    @objc private func hesitationMsChanged(_ sender: NSSlider) {
        humanPaste.setHesitationMaxMs(Int(sender.integerValue))
        menuHesitationLabel?.stringValue = "Max pause: \(Int(sender.integerValue)) ms"
    }

    @objc private func autoIndentToggled(_ sender: NSButton) {
        humanPaste.setAutoIndentAdjustEnabled(sender.state == .on)
        let on = sender.state == .on
        menuEnvSlider?.isEnabled = on
        menuEnvLabel?.textColor = on ? .labelColor : .disabledControlTextColor
    }

    @objc private func lineStartEnvChanged(_ sender: NSSlider) {
        let raw = Int(round(sender.doubleValue))
        let env = LineStartEnvironment(rawValue: raw) ?? .macNative
        humanPaste.setLineStartEnvironment(env)
        menuEnvLabel?.stringValue = env.menuLabel
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
                interceptorRunning = false
                applyStatusBarVisualState()
            } else {
                interceptorRunning = true
                applyStatusBarVisualState()
            }
        } else {
            humanPaste.stop()
            interceptorRunning = false
            applyStatusBarVisualState()
        }
        if let menu = statusItem.menu,
           let item = menu.items.first(where: { $0.action == #selector(toggleEnabled(_:)) }) {
            item.state = (enabled && humanPaste.isInterceptorRunning()) ? .on : .off
            item.title = (enabled && humanPaste.isInterceptorRunning()) ? "Disable interceptor" : "Enable interceptor"
        }
        windowToggle?.state = (enabled && humanPaste.isInterceptorRunning()) ? .on : .off
    }

    private func showAccessibilityInstructions() {
        if let label = windowLabel {
            label.stringValue = "Grant Accessibility in System Settings → Privacy & Security → Accessibility — add HumanPaste and enable it. Then turn the interceptor on again."
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
        statusBarAnimTimer?.invalidate()
        statusBarAnimTimer = nil
        humanPaste.stop()
        NSApp.terminate(nil)
    }
}
