# Manual macOS checks

Adapter tests cannot prove these. Run after `scripts/build-app.sh` and first launch.

1. **Screen Recording permission** — first capture shows QuickShot guidance; button opens System Settings. Deny path reports permission error and creates no thumbnail. Enable and retry succeeds.
2. **Area capture** — ⌘⇧4 freezes the screen. Drag selects. Release captures. Esc cancels with no thumbnail. W switches to window mode; O switches to OCR region.
3. **Window capture** — pointer outlines the window under the cursor. Click captures it. Toggle "Include window shadows" and confirm tight vs shadowed frame.
4. **Full display** — ⌘⇧3 captures the whole display. Pointer appears only when "Include pointer" is on.
5. **Thumbnail** — appears bottom-left by default. Never times out. Stacks when a second capture arrives. Does not steal keyboard focus from the frontmost app. ⌘⇧3/⌘⇧4 still work while thumbnails are open.
6. **Thumbnail actions** — Copy puts the image on the clipboard. Save writes `QuickShot yyyy-MM-dd at HH.mm.ss.SSS.png` to Downloads; two rapid saves never collide. Save As opens a save panel. Discard removes the thumbnail. Annotate opens the editor.
7. **Drag out** — drag a thumbnail into Notes/TextEdit. Success closes that thumbnail. Cancelling the drag leaves it open and reports an error if the drop failed.
8. **Annotator** — arrows, text, transparent-center rectangle, ellipse, highlight (content still visible), blur (content concealed), crop. Undo/redo corrects mistakes. Close without Copy/Save returns the capture to its thumbnail. Copy/Save flatten edits into PNG and clear the thumbnail. Dock icon is visible only while the annotator is open.
9. **OCR** — O during selection, menu "OCR Image…", and annotator OCR each show a review. Return copies the recognized text. Escape closes without copying. Line breaks survive. Multiple languages are accepted (no fixed language).
10. **Login item** — app launches at login and the menu bar icon is present without opening the app manually.
11. **Appearance** — light/dark, Reduce Motion, VoiceOver labels on thumbnail and toolbar controls.
12. **Quit** — open two thumbnails, quit. Relaunch: no pending captures reappear. No history browser exists.
