HumanPaste

HumanPaste is a small macOS utility that intercepts Cmd+V and “types” your clipboard contents with human‑like keystrokes. It preserves indentation, supports cancellation on a second Cmd+V, and lets you configure typing speed with jitter to feel natural.

Features
- Intercepts Cmd+V globally while enabled and types the clipboard content
- Preserves spaces, tabs, and newlines exactly
- Cancel by pressing Cmd+V again; 2s cooldown after cancel
- Configurable typing speed and randomized per‑keystroke delay
- Simple UI: window checkbox to Enable/Disable; optional menu bar item

Build
1) Requirements: Xcode command line tools (swiftc), macOS 12+
2) Build the .app and a .dmg installer:
```
./build.sh
```
Artifacts will be in `dist/`:
- `dist/HumanPaste.app`
- `dist/HumanPaste.dmg`

Install and first run
Option A — Run from DMG
1) Open `dist/HumanPaste.dmg`
2) Drag `HumanPaste.app` to Applications
3) Open `/Applications/HumanPaste.app`

Option B — Run directly from dist
1) Copy to Applications and clear quarantine so permissions stick
```
cp -R "$(pwd)/dist/HumanPaste.app" /Applications/
xattr -dr com.apple.quarantine "/Applications/HumanPaste.app"
open "/Applications/HumanPaste.app"
```

Permissions (important)
HumanPaste needs the following in System Settings → Privacy & Security:
- Accessibility: enable HumanPaste
- Input Monitoring: enable HumanPaste (some systems label this as “ListenEvent” in tccutil)

If you’ve been rebuilding locally and permissions don’t seem to stick, reset TCC for this bundle id and re‑grant for the copy in `/Applications`:
```
tccutil reset Accessibility dev.local.humanpaste
tccutil reset ListenEvent dev.local.humanpaste
```

Usage
1) Launch HumanPaste; a small window appears with “Enable interceptor”
2) Check “Enable interceptor” to begin intercepting Cmd+V
3) Press Cmd+V in any text field; HumanPaste will type the clipboard text
4) Press Cmd+V again while it’s typing to cancel (2s cooldown)

Local testing
- Build the app and a DMG:
```
./build.sh
```
- Run the built app directly:
```
open "$(pwd)/dist/HumanPaste.app"
```
- Or install from the DMG (recommended for permissions):
```
open "$(pwd)/dist/HumanPaste.dmg"
# Drag HumanPaste.app to /Applications
```
- If Gatekeeper blocks it, follow the instructions on the website (docs/index.html) or right‑click → Open.
- Grant Accessibility and Input Monitoring in System Settings → Privacy & Security.
- Menubar: use the Enable/Disable toggle. A Typing Speed slider (WPM) controls average speed with a natural range.

Notes
- Some secure fields (password fields) ignore simulated keystrokes by design
- If the menu bar item is hidden on your machine, the window checkbox fully controls enable/disable
- Typing speed knobs are in `human_paste.swift`:
  - `typingDelayBaseUs`
  - `typingDelayJitterUs`

License
MIT