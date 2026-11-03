# Voxtant floating widget

Selected visual: `docs/design/floating-widget-reference.png`. The user chose the third concept and requested a detached, always-visible, freely movable panel. This reference supersedes the original anchored popover.

## Surface and behavior

- Native macOS menu-bar utility, no main window and no Dock icon. Left click toggles the existing panel; right click offers hide, settings, quit.
- Borderless, resizable nonactivating NSPanel (initially 340 × 420 pt, minimum 300 × 300 pt), floating level, hidesOnDeactivate false. Header/grip drags use native window dragging. The full frame (position and size) persists in UserDefaults; removed-display recovery clamps to visible screen bounds.
- A separate conventional settings window owns language rules, the OpenRouter key, microphone setup and collapsed advanced/session controls. Hiding the widget does not stop recording.

## Tokens

- Surface: SwiftUI `glassEffect(.regular, in: .rect(cornerRadius: 26))` on macOS 26+. Older macOS uses active NSVisualEffectView popover material. No bitmap or wallpaper is baked into the interface.
- Theme: light widget, adaptive system settings window. The actual glass is OS-composited and varies with the desktop and accessibility settings.
- Size 340 × 420 pt; horizontal inset 24; corner radius 26; grip 32 × 4; top grip region 24; header bottom gap 22; transcript item gap 13; line spacing 5; footer top gap 17, controls bottom gap 8, cost caption 10 pt with 14 pt bottom inset. A 24 pt lower-right resize grip remains separate from the record button.
- Typography: SF system, title 19 semibold, transcript 18 regular, status 12 medium. Latest text black; previous text black at 0.68 opacity.
- Icons: SF Symbols waveform, gearshape, mic, chevron.down, record.circle, stop.fill. Settings and record hit areas are named for accessibility.
- Microphone capsule 58 × 36 pt; stop/start control 38 × 38 pt. Green dot indicates actual recording; a quiet red tint identifies Stop.

## Content and states

The main panel contains only title/grip, status dot, gear, scrolling translated text, microphone selector and record/stop. Empty, key-missing, preparing, translating, error and active states use the same surface. The gear remains usable while processing; microphone/model changes are disabled while busy. Audio capture remains independent of requests. Only the integrated translated/preserved text is displayed; source transcripts remain in exports. The 480 × 640 pt scrollable settings window starts with a segmented single/mixed mode, target language, and either one source selector or removable source rows with translation checkboxes. Disabled language controls explain that Stop or cancellation unlocks editing. Stop cancels queued/in-flight requests, clears provisional text and preserves completed text/audio without waiting for server replies. Language preferences persist in UserDefaults and are frozen per session, including retries. In mixed mode the Models section offers a priority-language picker (Automatic or configured source languages), with helper text separating recognition hints from translation rules. The hint is disabled while busy and survives restart.

## Verification

`make verify` runs local unit tests and builds. `make ui-smoke` creates fixture-only windows without credentials, microphone or network. The smoke check covers status-item activation, persistence, level/Spaces configuration, settings and actual deactivation. It does not synthesize user mouse dragging or activate a different desktop/fullscreen app. See `design-qa.md` for visual-review scope.

The cost footer is a single quiet monospaced USD/RUB line. A hover/accessibility
explanation names partial billing and the dated CBR reference. The screen is
resizable without resizing type; longer transcripts scroll within the available
space. Settings expose the Desktop recordings path and an Open Folder action.
