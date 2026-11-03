# Voxtant floating widget — visual and interaction QA

final result: passed

## Scope and evidence

The target is the third displayed generated concept, revised per the user's request into a detached draggable panel: `docs/design/floating-widget-reference.png`. The implementation is the native macOS utility, not a web prototype. The source is a desktop crop; the implementation screenshots contain only app-owned windows.

Comparison input: `docs/design/qa/comparison.png`. The source panel crop is x=139, y=152, width=812, height=936 pixels from the generated reference, normalized to 680 pixels wide with its aspect ratio preserved. The implementation is 340 × 420 logical points at 2×, 680 × 840 pixels. The 28-point extra height, native text wrapping and OS-controlled material are accepted adaptations for a real utility with errors/empty states, not an attempt to stretch the image.

Native evidence: `docs/design/qa/widget-recording.png`, `widget-empty.png`, `settings.png`; interaction evidence: `docs/design/qa/result.json`.

## Findings and fixes

- Resolved P2: SwiftUI's standard macOS menu style collapsed the microphone capsule to a bare icon. It is now a real native popup menu triggered by an explicit 58 × 36 pt glass control; the revised recording capture includes both microphone and chevron.
- Resolved P2: older text was not visually distinct enough from the newest line. The latest result is black; previous results use black at 0.68 opacity. Revised capture demonstrates the hierarchy.
- Accepted material limitation of isolated captures: system window-only capture renders the sampled desktop backdrop as a neutral surface. It does not include the user's wallpaper. Native SwiftUI `glassEffect(.regular)` supplies the real surface on macOS 26. The user explicitly confirmed on 2026-11-02 that the running panel is translucent and the glass is visible. The neutral capture is not used as proof that wallpaper refraction matches the source pixel-for-pixel.

No unresolved P0/P1/P2 findings within this comparison and interaction scope. No additional polish loop is planned.

## Required fidelity surfaces

- Fonts/typography: native SF system, 19 pt semibold title, 18 pt regular translated text, 5 pt line spacing, 12 pt status; readable Cyrillic, no clipping. Native line breaking differs from the raster reference and is accepted.
- Spacing/layout: one surface, 24 pt horizontal insets, 26 pt corners, compact header/grip, transcript-first middle, microphone/status/record footer. No tail or main-window chrome. Real panel dimensions are documented above.
- Colors/tokens: light widget, black/secondary text, green recording dot, muted red Stop, real OS Liquid Glass. Desktop-dependent tint/refraction is checked by the user's live confirmation, not reconstructed with an image or fake gradient. Settings follows the system appearance.
- Image/asset quality: the app uses no rasterized interface or wallpaper. Icons are sharp native SF Symbols. The generated image is a reference/documentation asset only; its prompt is stored alongside it.
- Copy/content: fixture transcript matches the selected mock. Production shows actual model translations; the smoke fixture is available only via an explicit test launch argument. No API key, costs, queue counts or model configuration are on the main panel.

## Interaction coverage and limits

The initial native smoke test passed 12 checks: status item opens the panel, no initial main window, floating level, hidesOnDeactivate false, Spaces/fullscreen configuration, no titlebar, moved-frame persistence, reopening at the same position, no test Keychain load, settings opening, widget retention while settings is open, and visibility after actual app deactivation.

Five unit tests cover visible positions, screen edges, negative-coordinate secondary screens, removed displays, and small display bounds. Existing audio/API tests also pass.

Mouse dragging delegates to AppKit `performDrag(with:)`; the smoke test changes the real window frame and verifies persistence but does not synthesize a user mouse gesture. Real Spaces/fullscreen transitions and macOS 14–15 fallback appearance are not automated in this run. New live microphone/API testing is outside this UI check; the smoke test never records or sends audio.


## Language configuration and menu-bar toggle follow-up

Final result: passed within the local UI/API-contract scope.

- Left-click now toggles visibility. The 18-check native smoke report also covers a second click hiding, a third reopening, recording remaining active while hidden, editable idle language rules, and refusal to change rules during recording or queue drain.
- Settings now uses a scrollable 480 × 640 pt native grouped form. The first section is translation: single/mixed segmented mode, common target, and either a source picker or per-source translation checkboxes. Mixed and single snapshots were inspected at 2x; labels and controls fit, and the form scrolls to remaining settings. The main glass surface is unchanged.
- The mixed default has English checked, Chinese unchecked and Russian as target. Single mode can translate Chinese normally. The integrated result is the only main-panel text; source transcripts remain in exports.
- All 31 local unit tests pass, including selected STT language, Chinese translation on/off, target languages using Han, other source-language prompts, preference persistence, invalid rules rejected before networking, and optional language metadata compatibility with old reports.
- API tests use an HTTP stub. No new live microphone or paid API run was performed for these language settings. Preserving languages other than Chinese, or distinguishing Chinese from Japanese in one source set, relies on the model prompt and has no local exact-text guarantee. This is documented in README.

Latest evidence: `docs/design/qa/settings.png`, `settings-single.png`, and `result.json` (18/18).
