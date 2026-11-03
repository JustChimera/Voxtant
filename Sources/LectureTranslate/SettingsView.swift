import SwiftUI
import LectureCore

struct SettingsView: View {
    @ObservedObject var model: DemoModel
    @State private var expanded = false

    var body: some View {
        Form {
            languageSettings
            Section("Модели") {
                Picker("Распознавание речи", selection: $model.asrModel) {
                    Text("Scribe v2").tag("elevenlabs/scribe-v2")
                    Text("GPT Transcribe").tag("openai/gpt-transcribe")
                    if !["elevenlabs/scribe-v2", "openai/gpt-transcribe"].contains(model.asrModel) {
                        Text("Своя модель").tag(model.asrModel)
                    }
                }
                if model.translationSettings.mode == .mixed {
                    Picker("Приоритетный язык", selection: Binding(
                        get: { model.asrLanguageHint }, set: { model.updateASRLanguageHint($0) })) {
                        Text("Автоматически").tag(Optional<SpeechLanguage>.none)
                        ForEach(model.translationSettings.activeRules) { rule in
                            Text(rule.language.title).tag(Optional(rule.language))
                        }
                    }
                    Text("Подсказка распознаванию, когда языки смешиваются. Правила перевода остаются прежними.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                TextField("Модель перевода", text: $model.translationModel)
            }.disabled(model.busy)
            Section("OpenRouter") {
                SecureField(model.keyReady ? "Заменить API-ключ" : "API-ключ", text: $model.keyInput)
                    .onSubmit { if !model.busy { model.saveKey() } }
                    .disabled(model.busy)
                HStack {
                    Label(model.keyReady ? "Ключ сохранён в Keychain" : "Ключ ещё не добавлен",
                          systemImage: model.keyReady ? "checkmark.circle" : "key")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Сохранить") { model.saveKey() }
                        .disabled(model.busy || model.keyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Text("Во время перевода звук и текст отправляются в OpenRouter. Исходная запись сохраняется на Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Аудио") {
                Picker("Микрофон", selection: $model.selectedMicrophone) {
                    if model.microphones.isEmpty { Text("Не найден").tag(UInt32(0)) }
                    ForEach(model.microphones) { Text($0.name).tag($0.id) }
                }.disabled(model.busy)
                Button("Обновить список") { model.refreshDevices() }.disabled(model.busy)
                Text("Для iPhone включите «Камера Continuity» на телефоне и проверьте его наличие в macOS → Звук → Вход.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Записи") {
                Text(model.recordingsRoot.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Button("Открыть папку записей") { NSWorkspace.shared.open(model.recordingsRoot) }
                Text("Дата → отдельная запись → аудио, транскрипция, перевод и метаданные.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            DisclosureGroup("Дополнительно", isExpanded: $expanded) {
                TextField("Модель ASR", text: $model.asrModel).disabled(model.busy)
                HStack {
                    Text("Порог речи")
                    Slider(value: $model.thresholdDB, in: -60 ... -25, step: 1).disabled(model.busy)
                    Text("\(Int(model.thresholdDB)) dB").monospacedDigit().frame(width: 52)
                }
                HStack {
                    Button("Аудиофайл…") { Task { await model.importAudio() } }.disabled(model.busy || !model.keyReady)
                    Button("Экспорт…") { model.export() }.disabled(model.busy || model.folder == nil)
                    Button("Папка сессии") { model.revealSession() }.disabled(model.folder == nil)
                }
                if model.failures > 0 {
                    Button("Повторить ошибки (\(model.failures))") { model.retryFailed() }.disabled(model.busy)
                }
                if model.pending > 0 && !model.isRecording && !model.isImporting && !model.isStopping {
                    Button("Отменить запросы") { model.cancelPending() }
                }
            }
            if let message = model.message {
                Text(message).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
        }.formStyle(.grouped).frame(width: 480, height: 640)
    }

    private var languageSettings: some View {
        Section("Перевод") {
            Picker("Режим", selection: setting(\.mode)) {
                Text("Обычный").tag(TranslationSettings.Mode.single)
                Text("Смешанный").tag(TranslationSettings.Mode.mixed)
            }.pickerStyle(.segmented)
            Picker("Язык перевода", selection: setting(\.target)) {
                ForEach(SpeechLanguage.allCases) { Text($0.title).tag($0) }
            }
            if model.translationSettings.mode == .single {
                Picker("Язык записи", selection: setting(\.source)) {
                    ForEach(SpeechLanguage.allCases) { Text($0.title).tag($0) }
                }
            } else {
                ForEach(model.translationSettings.sources) { rule in
                    HStack {
                        Text(rule.language.title)
                        Spacer()
                        Toggle("Переводить", isOn: Binding(
                            get: { model.translationSettings.sources.first { $0.language == rule.language }?.translate ?? false },
                            set: { value in
                                var settings = model.translationSettings
                                if let index = settings.sources.firstIndex(where: { $0.language == rule.language }) {
                                    settings.sources[index].translate = value
                                    model.updateTranslationSettings(settings)
                                }
                            }))
                            .toggleStyle(.checkbox)
                            .accessibilityLabel("Переводить: " + rule.language.title)
                        Button {
                            var settings = model.translationSettings
                            settings.sources.removeAll { $0.language == rule.language }
                            model.updateTranslationSettings(settings)
                        } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                            .disabled(model.translationSettings.sources.count == 1)
                            .help("Убрать язык: " + rule.language.title)
                            .accessibilityLabel("Убрать язык: " + rule.language.title)
                    }
                }
                Menu("Добавить язык записи") {
                    ForEach(SpeechLanguage.allCases.filter { language in
                        !model.translationSettings.sources.contains { $0.language == language }
                    }) { language in
                        Button(language.title) {
                            var settings = model.translationSettings
                            settings.sources.append(.init(language))
                            model.updateTranslationSettings(settings)
                        }
                    }
                }.disabled(model.translationSettings.sources.count == SpeechLanguage.allCases.count)
                Text("Без галочки — сохранять услышанное на исходном языке. Перевод и оригинальные вставки появляются одним текстом.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if model.busy {
                Text("Остановите запись или отмените обработку, чтобы изменить языки.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.disabled(model.busy)
    }

    private func setting<Value>(_ keyPath: WritableKeyPath<TranslationSettings, Value>) -> Binding<Value> {
        Binding(get: { model.translationSettings[keyPath: keyPath] }, set: { value in
            var settings = model.translationSettings
            settings[keyPath: keyPath] = value
            model.updateTranslationSettings(settings)
        })
    }

}
