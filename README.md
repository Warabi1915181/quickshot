# QuickShot

Native macOS menu bar screenshot app: area / window / display capture, floating thumbnails, annotation, OCR. AppKit only. No history, no cloud.

## Build

```bash
export QUICKSHOT_SIGNING_IDENTITY="Apple Development: Your Name (TEAMID)"
scripts/build-app.sh
open build/QuickShot.app
```

Requires macOS 26 and a Swift 5 toolchain (SwiftPM). No Xcode project.
`QUICKSHOT_SIGNING_IDENTITY` must name a code-signing identity in your keychain.
Find one with `security find-identity -v -p codesigning`. An Apple Development
certificate works for development. For local-only builds, Keychain Access can
create a self-signed Code Signing certificate. Keep the same certificate across
rebuilds: macOS binds Screen Recording access to the signing identity. Ad-hoc
signing binds access to one build and is deliberately rejected by the build script.

## Grant Screen Recording

1. Launch QuickShot and start a capture (⌘⇧4 or the menu).
2. Open **System Settings → Privacy & Security → Screen & System Audio Recording** and enable QuickShot.
3. Relaunch if macOS asks, then capture again. If QuickShot already shows enabled
   but capture still says permission is missing, switch it off and back on for
   the current signed build, then fully quit and relaunch QuickShot.

From code: `x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture`

## Default shortcuts

| Shortcut | Action |
|---|---|
| ⌘⇧4 | Capture area |
| ⌘⇧3 | Capture full display |

Window capture and OCR-region are optional global bindings (unbound by default). During selection: **W** window mode, **O** OCR region, **Esc** cancel.

## Settings

Menu bar icon → **Settings…**

- Capture Area / Capture Display (required)
- Capture Window / OCR (optional; Clear or Backspace to unbind)
- Thumbnail position (Bottom Left default)
- Include window shadows (on)
- Include pointer (off)
- Launch at login

Apply saves and re-registers global shortcuts. On conflict the previous binding stays and fields revert.

## Manual checks

See `Tests/MANUAL_CHECKS.md` for permission, selection, drag, login item, Dock, and appearance checks.

## Notes

- Default shortcuts are Carbon `kVK_ANSI_4` (`0x15`) and `kVK_ANSI_3` (`0x14`) with ⌘⇧ — real ⌘⇧4 / ⌘⇧3.
- `LSUIElement` is `true`. Dock appears via `setActivationPolicy(.regular)` while the annotator is open and returns to `.accessory` on close. If the Dock refuses to appear on your macOS build, flip `LSUIElement` to `false` and keep launch at `.accessory` in `main.swift`.
