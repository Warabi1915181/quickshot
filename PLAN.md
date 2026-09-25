# QuickShot implementation plan

Breakdown of SPEC.md into buildable work. Contracts in `Sources/QuickShotCore` are frozen before UI work starts.

## Build layout

SwiftPM only. No Xcode project.

```
Package.swift
Sources/QuickShotCore/          # models, adapters (protocol + live), CaptureWorkflow
Sources/QuickShot/              # AppKit UI + main
Tests/QuickShotCoreTests/       # workflow tests against mock adapters
scripts/build-app.sh            # swift build + assemble QuickShot.app
Resources/Info.plist
Resources/Assets/               # template app icon only if needed
```

- Platform: macOS 26 (`platforms: [.macOS(.v26)]`; fall back to `.macOS("26.0")` if toolchain rejects enum).
- Swift language mode: `v5` (avoid Swift 6 concurrency friction in UI code).
- Product: executable `QuickShot` + library `QuickShotCore`.
- App bundle: `build-app.sh` writes `build/QuickShot.app` with `Contents/MacOS/QuickShot` and `Info.plist`.
  - `LSUIElement = true` at launch (menu bar only).
  - Annotator open → `NSApp.setActivationPolicy(.regular)` (Dock icon).
  - Annotator close → `.accessory`.
  - `LSMinimumSystemVersion = 26.0`.

## Architecture (SPEC Implementation Decisions)

One `CaptureWorkflow` owns app state. Menu, global shortcuts, thumbnail buttons, annotator commands all `dispatch(Event)`.

System I/O behind adapters. This is the test seam.

| Adapter | Live impl | Duty |
|---|---|---|
| `CaptureServicing` | `ScreenCaptureService` | display / window / area frames, permission |
| `OCRServicing` | `VisionOCRService` | `VNRecognizeTextRequest`, any language, keep line breaks |
| `ClipboardServicing` | `PasteboardService` | image + text copy |
| `FileServicing` | `FileService` | collision-safe PNG names, Downloads save, Save As |
| `ShortcutServicing` | `CarbonShortcutService` | global hotkey register/unregister |

UI observes `CaptureWorkflow` via `onStateChange` / `onEffect`. UI never talks to adapters directly except for pointer plumbing (drag file promise, sheet dismissal).

### Workflow events (commands)

`startAreaCapture`, `startWindowCapture`, `startDisplayCapture`, `startOCRSelection`, `ocrImage(URL)`, `ocrAnnotatorImage`, `selectionModeChanged`, `selectionCancelled`, `areaSelected(CGRect)`, `windowSelected(CGWindowID)`, `copy`, `save`, `saveAs(URL)`, `discard`, `openAnnotator`, `closeAnnotatorWithoutOutput`, `annotatorCopied`, `annotatorSaved`, `dragCompleted`, `dragFailed(Error)`, `ocrReviewCopy`, `ocrReviewDismiss`, `permissionDenied`.

Pending item actions take `PendingCapture.ID`.

### Workflow effects (to UI)

`showThumbnail`, `hideThumbnail`, `showAnnotator`, `hideAnnotator`, `showOCRReview`, `hideOCRReview`, `showError(message, captureStillAvailable:)`, `requestCapturePermission`, `setDockVisible(Bool)`, `beginSelection(SelectionSession)`, `endSelection`.

### State transitions that must not lose an image (Testing Decisions)

- Multiple pending items stack; each owns one thumbnail.
- Copy / Save / Save As / successful drag / Discard remove that item and its thumbnail.
- Failed Copy / Save / drag / OCR keeps the item; `showError` with `captureStillAvailable: true`.
- Annotator close without output → same pending item returns to thumbnail (edit buffer discarded, original capture kept).
- Annotator Copy / Save → item removed, Dock hidden, transient UI cleared (story 51).
- Quit / restart → all pending discarded (no persistence).

## Layer map

### 1. Core contracts (planner-owned, frozen)

`Sources/QuickShotCore/`
- `Models.swift` — `CapturedImage`, `PendingCapture`, `CaptureKind`, `AnnotationTool`, `Mark`, `AnnotatorDocument`, `OCRResult`, `ThumbnailPosition`, `AppPreferences`, `WorkflowError`
- `Adapters.swift` — five protocols above + `SystemAdapters` bundle
- `CaptureWorkflow.swift` — state machine skeleton (types complete; logic filled by core agent)
- `Effects` live with workflow types

### 2. Core logic + tests (Agent CORE)

- Fill `CaptureWorkflow` dispatch paths exactly per this plan and SPEC stories.
- Collation-safe save name: `Downloads/QuickShot YYYY-MM-dd at HH.mm.ss.SSS.png`, bump `.SSS` then ` (2)`, ` (3)`… until unique.
- Mock adapters in tests (`MockCaptureService` etc. record calls, return scripted results).
- Tests cover every row in "state transitions" + annotation flatten output + OCR review copy equality + shortcut dispatch observability + thumbnail non-focus (workflow-level: never emits key-window request) + OCR review keyboard contract.
- Tests assert user-visible state / adapter calls / effects only. No view hierarchy, no animation, no `#selector` call counts.

### 3. Live adapters (Agent SYS)

- `ScreenCaptureService` via ScreenCaptureKit (`SCScreenshotManager` / `SCStream` fallback as needed). Window capture includes shadow when `includeWindowShadows`. Pointer excluded unless `includePointer`.
- Area + full display from display image; area crop in display points → pixels.
- Permission: `CGPreflightScreenCaptureAccess` / `CGRequestScreenCaptureAccess`. Deny → `requestCapturePermission` effect.
- `VisionOCRService`: `VNRecognizeTextRequest` with `recognitionLevel = .accurate`, `usesLanguageCorrection = true`, no fixed `recognitionLanguages` (story 48). Join lines with `\n`.
- `PasteboardService`: `NSPasteboard` `writeObjects` / png types.
- `FileService`: atomic PNG write (`CGImageDestination`), unique names as above.
- `CarbonShortcutService`: `RegisterEventHotKey`, keycode + modifiers model, unregister all on quit. Conflict detection: register fails → error effect, previous binding kept.

### 4. Capture selection UI (Agent CAP)

Files under `Sources/QuickShot/Selection/`.
- Freeze: grab display frame first, show it full-screen as the selection surface (story 10). No magnifier (out of scope).
- Area: drag rectangle, live readout optional (not required). Release completes. Esc cancels (story 11).
- During selection: `W` → window mode, `O` → OCR mode (stories 12, 44). Mode is a workflow event so tests see it.
- Window: highlight window under pointer (`CGWindowListCopyWindowInfo` + bounds), click captures that window id.
- OCR mode: selection completes as `ocrRegion`, no thumbnail; OCR review opens.
- Overlay windows: borderless, `NSWindow.Level.screenSaver`, ignore mouse elsewhere, do not steal key from other apps after session starts (accept key for the session only).
- Cancel leaves no pending item.

### 5. Thumbnail UI (Agent THUMB)

Files under `Sources/QuickShot/Thumbnail/`.
- `NSPanel`: `.borderless` + `.nonactivatingPanel`, `level = .floating`, `canBecomeKey = false`, `canBecomeMain = false` (story 23). Clicks/drags still work.
- Default position bottom-left of the screen with live cursor (story 20). `AppPreferences.thumbnailPosition`: bottomLeading (default), bottomTrailing, topLeading, topTrailing. New thumbs stack offset from existing (story 24).
- Controls on hover / always-visible compact bar (CleanShot-like): Copy, Save, Save As…, Annotate, Discard, plus drag-the-image (stories 26–33).
- Drag: `NSFilePromiseProvider` + in-memory PNG promise; on success `dragCompleted` (story 31); on failure `dragFailed` and thumbnail stays (story 55).
- No auto-dismiss ever (story 22).
- Global shortcuts remain live while thumbs open (do not swallow key events; panels non-key).
- Save = one click to Downloads. Save As = `NSSavePanel`.
- Discard is explicit control only.

### 6. Annotator UI (Agent ANNO)

Files under `Sources/QuickShot/Annotator/`.
- Window opens centered, editable canvas showing capture + marks (story 33).
- Dock visible while open (story 4) via effect `setDockVisible(true/false)`.
- Tools: Arrow, Text, Rectangle (transparent fill + visible stroke — story 37), Ellipse, Highlight (multiply/lighten over content, not opaque cover — story 40), Blur (pixelate/gaussian region — story 39), Crop (story 38).
- Undo/redo stack of mark/crop commands (story 41).
- Toolbar: tool picker, stroke color well, stroke width, Undo, Redo, OCR, Copy, Save, Save As, close.
- Close without Copy/Save → `closeAnnotatorWithoutOutput`; pending capture returns to thumbnail (story 34).
- Copy / Save render flattened PNG of visible (cropped) result (stories 42–43). Edits are in-memory only; no project files.
- OCR in annotator uses current flattened visible image (story 46).
- Text tool: click places insertion, type to edit, commit on Enter/click-away.
- Crop: drag rect + apply/cancel.
- Respect Reduce Motion, dark/light `NSAppearance`, `NSVisualEffectView` materials where appropriate (story 56).

### 7. OCR review (Agent OCR, shares THUMB panel style)

Files under `Sources/QuickShot/OCR/`.
- Focused panel/popover with text view of recognized text (story 47).
- **This surface is key** (unlike thumbnails). Return = copy text + dismiss (story 50). Escape = dismiss without copy.
- Entry points: selection `O`, menu "OCR Image…", annotator OCR button (stories 44–46).
- Menu OCR Image… = `NSOpenPanel` → `ocrImage(URL)`.
- Show error on OCR failure; leave source pending capture untouched.

### 8. App shell (Agent SHELL)

Files under `Sources/QuickShot/App/`.
- `NSStatusItem` menu: Area, Window, Display, OCR Image…, Settings…, separator, Quit. Same commands as shortcuts (story 8).
- Defaults (stories 5–6): area = ⌘⇧4, display = ⌘⇧3. Optional unbound-by-default window + OCR shortcuts, user can bind (story 7).
- Settings window: shortcut recorder fields (area / display / window / OCR), thumbnail position, include pointer, include window shadows.
- Login item via `SMAppService.mainApp.register()` on launch or a Settings toggle (story 2). Default: register at first launch.
- Quit discards pending items (story 53). No history store (story 52).
- First-use permission sheet with clear guidance + button to open System Settings (story 54).
- Errors: `NSAlert` or non-key banner that states whether capture is still in the thumbnail (story 55).

## Parallelization

Contracts first (planner). Then:

| Wave | Agent | Depends | Files |
|---|---|---|---|
| 1 | CORE | contracts | `CaptureWorkflow*.swift`, `Tests/QuickShotCoreTests/**` |
| 2a | SYS | contracts | `Sources/QuickShotCore/Adapters/**` live impls |
| 2b | CAP | contracts | `Sources/QuickShot/Selection/**` |
| 2c | THUMB | contracts | `Sources/QuickShot/Thumbnail/**` |
| 2d | ANNO | contracts | `Sources/QuickShot/Annotator/**` |
| 2e | OCR | contracts | `Sources/QuickShot/OCR/**` |
| 3 | SHELL | 1+2 | `Sources/QuickShot/App/**`, `main.swift`, `Resources/Info.plist`, `scripts/build-app.sh` |
| 4 | VERIFY | 3 | fix compile/test gaps, fill remaining tests, `Tests/MANUAL_CHECKS.md` |

Wave 2 agents get protocol + model signatures verbatim in-prompt. They write self-contained view/controller files against `CaptureWorkflow.dispatch`. No agent edits another's folder.

SHELL wires everything and is the only agent allowed to edit `Sources/QuickShot/App` + `main.swift`.

## Manual checks (not adapter-testable)

`Tests/MANUAL_CHECKS.md` will list:
1. Real Screen Recording prompt + System Settings path.
2. Area select, freeze, W window outline + capture with/without shadow.
3. Full display capture.
4. Drag thumbnail into another app (e.g. TextEdit / Notes) → thumb closes on success.
5. Launch at login.
6. Dock hidden normally / visible with annotator.
7. Light/dark, Reduce Motion, VoiceOver sees thumbnail buttons (labels).
8. ⌘⇧3 / ⌘⇧4 work while a thumbnail is open; W/O during selection; Return/Escape in OCR review.
9. Quit with pending thumbs → next launch starts clean.

## Out of scope guardrails

No recording, scrolling, timed capture, multi-monitor, magnifier, cloud, history, project files, older macOS, CleanShot branding.

## Open item from SPEC Further Notes

Single application-level workflow test seam is used here as already written in Testing Decisions. Flag for user before any issue-tracker publication; not a build blocker.
