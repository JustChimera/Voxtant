import AppKit
import LectureCore
import ScreenCaptureKit

@MainActor
enum WidgetSmokeTest {
    static func run(controller: MenuBarController, folder: URL) async {
        var checks: [String: Bool] = [:]
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("{\"passed\":false,\"state\":\"running\"}".utf8).write(to: folder.appendingPathComponent("result.json"), options: .atomic)
            let preferenceSuite = "local.voxtant.model-smoke." + UUID().uuidString
            let modelPreferences = UserDefaults(suiteName: preferenceSuite)!
            defer { modelPreferences.removePersistentDomain(forName: preferenceSuite) }
            let configurable = DemoModel(loadKeychain: false, preferences: modelPreferences)
            configurable.updateASRLanguageHint(.zh)
            let hintRestored = DemoModel(loadKeychain: false, preferences: modelPreferences)
            checks["asr_language_hint_survives_restart"] = hintRestored.asrLanguageHint == .zh
            configurable.isRecording = true
            configurable.updateASRLanguageHint(.en)
            checks["asr_language_hint_is_locked_while_busy"] = configurable.asrLanguageHint == .zh
            configurable.isRecording = false
            var changedLanguages = configurable.translationSettings
            changedLanguages.sources = [.init(.en)]
            configurable.updateTranslationSettings(changedLanguages)
            checks["removed_source_language_clears_asr_hint"] = configurable.asrLanguageHint == nil
            configurable.updateTranslationSettings(TranslationSettings())
            modelPreferences.set("qwen/qwen3-asr-1.7b", forKey: "Voxtant.ASRModel.v1")
            let retiredASR = DemoModel(loadKeychain: false, preferences: modelPreferences)
            checks["removed_qwen_preference_migrates_to_scribe"] = retiredASR.asrModel == "elevenlabs/scribe-v2"
            checks["removed_qwen_migration_is_persisted"] = modelPreferences.string(forKey: "Voxtant.ASRModel.v1") == "elevenlabs/scribe-v2"
            configurable.asrModel = "  qwen/qwen3-asr-1.7b  "
            checks["removed_qwen_cannot_be_reenabled_through_custom_field"] = configurable.asrModel == "elevenlabs/scribe-v2"
            modelPreferences.set("elevenlabs/scribe-v2-realtime", forKey: "Voxtant.ASRModel.v1")
            let openRouterOnly = DemoModel(loadKeychain: false, preferences: modelPreferences)
            checks["removed_direct_realtime_preference_migrates_to_openrouter"] = openRouterOnly.asrModel == "elevenlabs/scribe-v2" && modelPreferences.string(forKey: "Voxtant.ASRModel.v1") == "elevenlabs/scribe-v2"
            configurable.asrModel = "elevenlabs/scribe-v2-realtime"
            checks["direct_realtime_cannot_be_reenabled_through_custom_field"] = configurable.asrModel == "elevenlabs/scribe-v2"
            configurable.asrModel = "elevenlabs/scribe-v2"
            configurable.translationModel = "test/translator"
            let restored = DemoModel(loadKeychain: false, preferences: modelPreferences)
            checks["selected_asr_model_survives_restart"] = restored.asrModel == "elevenlabs/scribe-v2"
            checks["selected_translation_model_survives_restart"] = restored.translationModel == "test/translator"
            configurable.asrModel = "  test/custom-asr  "
            let customRestored = DemoModel(loadKeychain: false, preferences: modelPreferences)
            checks["custom_asr_id_is_saved_without_surrounding_spaces"] = customRestored.asrModel == "test/custom-asr"
            configurable.asrModel = ""
            let afterEmptyEdit = DemoModel(loadKeychain: false, preferences: modelPreferences)
            checks["empty_edit_keeps_last_saved_model"] = afterEmptyEdit.asrModel == "test/custom-asr"
            modelPreferences.set(TranslationDefaults.legacyModelID, forKey: "Voxtant.TranslationModel.v1")
            let migrated = DemoModel(loadKeychain: false, preferences: modelPreferences)
            checks["legacy_translator_migrates_to_selected_default"] = migrated.translationModel == TranslationDefaults.modelID
            checks["translator_migration_is_persisted"] = modelPreferences.string(forKey: "Voxtant.TranslationModel.v1") == TranslationDefaults.modelID
            let previousInput = Microphone(id: 83, name: "Input", uid: "stable-input")
            let reconnectedInput = Microphone(id: 129, name: "Input", uid: "stable-input")
            let differentInput = Microphone(id: 83, name: "Input", uid: "other-input")
            checks["microphone_uid_survives_object_id_change"] = Microphone.resolve(previousInput, from: [differentInput, reconnectedInput]) == reconnectedInput
            checks["disconnected_microphone_never_switches_to_reused_id"] = Microphone.resolve(previousInput, from: [differentInput]) == nil
            checks["microphone_identity_does_not_match_display_name"] = Microphone.resolve(previousInput, from: [Microphone(id: 130, name: "Input", uid: "other-input")]) == nil
            checks.merge(try await StopSmokeTest.run(folder: folder.appendingPathComponent("stop"), preferences: modelPreferences)) { _, new in new }
            let model = controller.model
            model.exchangeRate = USDRUBRate(rublesPerUSD: 90, effectiveDate: "01.01.2026")

            model.microphones = [Microphone(id: 1, name: "Микрофон MacBook")]
            model.selectedMicrophone = 1
            checks["starts_with_no_main_window"] = !controller.panel.isVisible
            controller.statusItem.button?.performClick(nil)
            checks["menu_bar_button_opens_widget"] = controller.panel.isVisible
            controller.statusItem.button?.performClick(nil)
            checks["second_menu_bar_click_hides_widget"] = !controller.panel.isVisible
            controller.statusItem.button?.performClick(nil)
            checks["third_menu_bar_click_reopens_widget"] = controller.panel.isVisible
            var changedSettings = model.translationSettings
            changedSettings.mode = .single
            changedSettings.source = .de
            changedSettings.target = .en
            model.updateTranslationSettings(changedSettings)
            checks["language_settings_can_change_while_idle"] = model.translationSettings == changedSettings
            model.updateTranslationSettings(TranslationSettings())
            checks["stays_visible_when_app_deactivates"] = !controller.panel.hidesOnDeactivate
            checks["above_normal_windows"] = controller.panel.level == .floating
            checks["available_in_spaces_and_fullscreen"] = controller.panel.collectionBehavior.contains([.canJoinAllSpaces, .fullScreenAuxiliary])
            checks["no_standard_window_chrome"] = !controller.panel.styleMask.contains(.titled)
            let initial = controller.panel.frame
            let target = PanelPlacement.clamped(initial.offsetBy(dx: -140, dy: -70), to: NSScreen.screens.map(\.visibleFrame))
            controller.panel.setFrame(target, display: true)
            try await Task.sleep(nanoseconds: 250_000_000)
            checks["moving_panel_saves_position"] = controller.savedFrame() == target
            controller.hideWidget()
            controller.statusItem.button?.performClick(nil)
            checks["reopening_keeps_position"] = controller.panel.frame == target
            checks["widget_has_native_resize_support"] = controller.panel.styleMask.contains(.resizable)
            let large = NSRect(origin: target.origin, size: NSSize(width: 520, height: 540))
            controller.panel.setFrame(large, display: true)
            try await Task.sleep(nanoseconds: 100_000_000)
            let resized = controller.panel.frame
            checks["resizing_persists_full_frame"] = controller.savedFrame() == resized && resized.width == 520
            let frameSuite = "local.voxtant.frame-smoke." + UUID().uuidString
            let framePreferences = UserDefaults(suiteName: frameSuite)!
            defer { framePreferences.removePersistentDomain(forName: frameSuite) }
            framePreferences.set(NSStringFromRect(resized), forKey: "Voxtant.FloatingWidget.Frame")
            let restoredController = MenuBarController(model: model, preferences: framePreferences)
            restoredController.showWidget()
            checks["resized_widget_restores_size_on_restart"] = restoredController.panel.frame.size == resized.size
            restoredController.hideWidget()
            NSStatusBar.system.removeStatusItem(restoredController.statusItem)
            try await capture(controller.panel, to: folder.appendingPathComponent("widget-wide.png"))
            controller.panel.setFrame(NSRect(origin: target.origin, size: NSSize(width: 300, height: 300)), display: true)
            try await capture(controller.panel, to: folder.appendingPathComponent("widget-small.png"))
            controller.panel.setFrame(target, display: true)

            checks["test_does_not_load_keychain"] = !model.keyReady
            model.message = nil
            try await capture(controller.panel, to: folder.appendingPathComponent("widget-empty.png"))
            let lines = ["Сейчас я объясню основной принцип.", "Сначала слушаем собеседника,", "затем переводим его слова.",
                         "Текст появляется постепенно,", "а вы продолжаете разговор…"]
            model.segments = lines.enumerated().map { index, text in
                var segment = Segment(id: index, start: Double(index) * 2, end: Double(index + 1) * 2,
                    file: "", capturedAt: Date(), asrModel: "fixture", translationModel: "fixture")
                segment.status = .complete
                segment.transcript = text
                segment.translation = text
                segment.asrCost = 0.0001
                segment.translationCost = 0.0002
                return segment
            }
            checks["cost_footer_contains_usd_and_rubles"] = model.sessionCost.compactLabel.contains("$") && model.sessionCost.compactLabel.contains("₽") && model.sessionCost.isComplete
            model.isRecording = true
            model.updateTranslationSettings(changedSettings)
            checks["language_settings_cannot_change_during_recording"] = model.translationSettings == TranslationSettings()
            controller.statusItem.button?.performClick(nil)
            checks["hiding_widget_does_not_stop_recording"] = !controller.panel.isVisible && model.isRecording
            controller.statusItem.button?.performClick(nil)
            try await capture(controller.panel, to: folder.appendingPathComponent("widget-recording.png"))
            model.segments[0].translation = ""
            model.segments[0].status = .translating
            model.partialTranslations[0] = "Конструкция 因为…所以… выражает причину"
            try await capture(controller.panel, to: folder.appendingPathComponent("widget-streaming.png"))
            model.partialTranslations.removeAll()
            model.segments[0].translation = lines[0]
            model.isRecording = false
            model.segments[0].status = .translating
            model.updateTranslationSettings(changedSettings)
            checks["language_settings_cannot_change_while_processing"] = model.translationSettings == TranslationSettings()
            model.segments[0].status = .complete
            controller.showSettings()
            checks["gear_settings_window_opens"] = controller.settingsWindow?.isVisible == true
            checks["widget_remains_visible_with_settings_open"] = controller.panel.isVisible
            NSApp.deactivate()
            try await Task.sleep(nanoseconds: 200_000_000)
            checks["widget_is_visible_after_actual_deactivation"] = controller.panel.isVisible
            if let settings = controller.settingsWindow {
                try await capture(settings, to: folder.appendingPathComponent("settings.png"))
                settings.orderOut(nil)
            }
            model.isRecording = false
            model.updateTranslationSettings(changedSettings)
            controller.showSettings()
            if let settings = controller.settingsWindow {
                try await capture(settings, to: folder.appendingPathComponent("settings-single.png"))
                settings.orderOut(nil)
            }
            model.updateTranslationSettings(TranslationSettings())
            model.updateASRLanguageHint(.zh)
            controller.showSettings()
            if let settings = controller.settingsWindow {
                try await capture(settings, to: folder.appendingPathComponent("settings-chinese-priority.png"))
                settings.orderOut(nil)
            }
            let result: [String: Any] = [
                "passed": checks.values.allSatisfy { $0 }, "checks": checks,
                "note": "Only current-process windows are captured. No microphone, network, credentials, or desktop capture.",
                "panelWidth": controller.panel.frame.width, "panelHeight": controller.panel.frame.height
            ]
            try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
                .write(to: folder.appendingPathComponent("result.json"), options: .atomic)
            if !checks.values.allSatisfy({ $0 }) { fputs("Voxtant UI smoke checks failed; see result.json\n", stderr) }
        } catch {
            let text = "Voxtant UI smoke failed: \(error.localizedDescription)\n"
            fputs(text, stderr)
            try? text.write(to: folder.appendingPathComponent("error.txt"), atomically: true, encoding: .utf8)
            if let data = try? JSONSerialization.data(withJSONObject: ["passed": false, "error": text]) {
                try? data.write(to: folder.appendingPathComponent("result.json"), options: .atomic)
            }
        }
        NSApp.terminate(nil)
    }

    private static func capture(_ window: NSWindow, to url: URL) async throws {
        try await Task.sleep(nanoseconds: 450_000_000)
        if #available(macOS 14.4, *) {
            do {
                let ownContent = try await SCShareableContent.currentProcess
                guard let ownWindow = ownContent.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
                    throw LectureError.message("Own window is not available for capture")
                }
                let configuration = SCStreamConfiguration()
                configuration.width = Int(window.frame.width * 2)
                configuration.height = Int(window.frame.height * 2)
                configuration.showsCursor = false
                let image = try await SCScreenshotManager.captureImage(
                    contentFilter: SCContentFilter(desktopIndependentWindow: ownWindow), configuration: configuration)
                guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                    throw LectureError.message("Cannot encode own-window screenshot")
                }
                try png.write(to: url)
                return
            } catch {
                // The system compositor can reject capture for an ad-hoc release process.
                // Fall back to rendering this app's own view, never desktop contents.
            }
        }
        guard let view = window.contentView else { throw LectureError.message("Missing view") }
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw LectureError.message("Cannot create app view bitmap")
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw LectureError.message("Cannot encode screenshot")
        }
        try png.write(to: url)
    }
}
