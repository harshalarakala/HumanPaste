HumanPaste

HumanPaste is a small macOS utility that intercepts Cmd+V and “types” your clipboard contents with human‑like keystrokes. It preserves indentation, supports cancellation on a second Cmd+V, and lets you configure typing speed with jitter to feel natural.

## Features

- Human-like Cmd+V: types the clipboard with realistic keystrokes
- Preserves spaces, tabs, and newlines
- Cancel on second Cmd+V with a 2s cooldown
- Typing speed slider (WPM) with randomized jitter
- Hesitation between lines: optional “think” pause up to a configurable max
- Burst typing: faster within words, slightly longer between words
- Auto-indent adjustment: compensates for editor auto-indent to avoid doubled indents
- Minimal menu UI + small debug window

## Shortcuts (global while enabled)

- Cmd+Shift+E or Cmd+Option+E: enable intercept
- Cmd+Shift+D or Cmd+Option+D: disable intercept
- Cmd+Shift+] or Cmd+Option+]: increase WPM by 10
- Cmd+Shift+[ or Cmd+Option+[: decrease WPM by 10

## Menu options

- Enable/Disable
- Typing Speed (WPM) slider with current value label
- Hesitation between lines toggle + Max pause (ms) slider
- Adjust for editor auto-indent toggle

## Local testing

- Build the app and a DMG:
```
./build.sh
```
- Run the built app directly:
```
open "$(pwd)/dist/HumanPaste.app"
```
- If Gatekeeper blocks it (downloaded build), see docs/index.html or right‑click → Open.
- Grant Accessibility and Input Monitoring in System Settings → Privacy & Security.
- Use the HP menu to enable and adjust WPM/hesitation/auto-indent.

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