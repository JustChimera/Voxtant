import AppKit
import SwiftUI
import LectureCore

@main
struct LectureTranslateApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = DemoModel()

    var body: some Scene {
        Window("Voxtant · Demo", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 560, minHeight: 510)
                .onAppear { delegate.model = model }
        }
        .defaultSize(width: 720, height: 680)
        .commands { CommandGroup(replacing: .newItem) {} }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: DemoModel?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model?.busy == true else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Закрыть демку?"
        alert.informativeText = "Перед выходом нажмите Stop и дождитесь обработки. Аудио и готовый текст остаются в локальной папке сессии."
        alert.addButton(withTitle: "Вернуться")
        alert.addButton(withTitle: "Закрыть")
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }
}

struct ContentView: View {
    @ObservedObject var model: DemoModel
    @State private var showConnection = false
    @State private var showOriginal = true
    @State private var follow = true

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if showConnection || !model.keyReady { connection; Divider() }
            controls
            if let message = model.message {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                    Text(message).textSelection(.enabled)
                    Spacer(minLength: 0)
                    Button { model.message = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).accessibilityLabel("Скрыть сообщение")
                }
                .font(.callout).foregroundStyle(.red).padding(12)
                .background(.red.opacity(0.06))
            }
            Divider()
            transcript
            Divider()
            footer
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: model.keyReady) { _, ready in if ready { showConnection = false } }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Voxtant").font(.title2.weight(.semibold))
                Text("English → Русский · 中文 остаётся в оригинале")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button { showConnection.toggle() } label: {
                Label("Подключение", systemImage: model.keyReady ? "key.fill" : "key")
            }.help("Ключ OpenRouter и модели")
        }.padding(20)
    }

    private var connection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SecureField(model.keyReady ? "Новый ключ OpenRouter" : "Ключ OpenRouter", text: $model.keyInput)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.saveKey() }
                Button("Сохранить в Keychain") { model.saveKey() }
                    .disabled(model.keyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.busy)
            }
            Text("Ключ хранится в macOS Keychain. Звук и текст отправляются в OpenRouter только после Start или выбора файла.")
                .font(.caption).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("ASR").foregroundStyle(.secondary)
                    HStack {
                        TextField("Модель ASR", text: $model.asrModel).textFieldStyle(.roundedBorder)
                        Menu("Режим") {
                            Button("Быстрее — Qwen") { model.asrModel = "qwen/qwen3-asr-1.7b" }
                            Button("Китайский — Gemini Flash") { model.asrModel = "google/gemini-2.5-flash" }
                        }.fixedSize()
                    }
                }
                GridRow {
                    Text("Перевод").foregroundStyle(.secondary)
                    TextField("Модель перевода", text: $model.translationModel).textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Порог речи").foregroundStyle(.secondary)
                    HStack {
                        Slider(value: $model.thresholdDB, in: -60 ... -25, step: 1)
                        Text("\(Int(model.thresholdDB)) dB").monospacedDigit().frame(width: 54)
                    }
                }
            }.font(.callout).disabled(model.busy)
        }.padding(.horizontal, 20).padding(.vertical, 16)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Picker("Микрофон", selection: $model.selectedMicrophone) {
                    if model.microphones.isEmpty { Text("Не найден").tag(UInt32(0)) }
                    ForEach(model.microphones) { microphone in Text(microphone.name).tag(microphone.id) }
                }.disabled(model.busy)
                Button { model.refreshDevices() } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(model.busy).help("Обновить микрофоны").accessibilityLabel("Обновить микрофоны")
            }
            HStack(spacing: 10) {
                Button { Task { await model.start() } } label: { Label("Start", systemImage: "mic.fill") }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(model.busy || !model.keyReady || model.selectedMicrophone == 0)
                Button { Task { await model.stop() } } label: { Label("Stop", systemImage: "stop.fill") }
                    .disabled(!model.isRecording || model.isStopping)
                Button("Аудиофайл…") { Task { await model.importAudio() } }
                    .disabled(model.busy || !model.keyReady)
                Spacer()
                Text(clock(model.duration)).monospacedDigit().foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Circle().fill(model.isRecording ? Color.red : Color.secondary).frame(width: 7, height: 7)
                Text(model.state).font(.callout)
                if model.isRecording {
                    ProgressView(value: min(1, Double(model.level) * 12)).frame(width: 70)
                        .tint(.green).accessibilityLabel("Уровень микрофона")
                }
                Spacer()
                Text("В очереди: \(model.pending)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                if model.pending > 0 && !model.isRecording && !model.isStopping && !model.isImporting {
                    Button("Отменить запросы") { model.cancelPending() }.font(.caption)
                }
            }
        }.padding(.horizontal, 20).padding(.vertical, 16)
    }

    private var transcript: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Перевод").font(.headline)
                Spacer()
                Toggle("Оригинал", isOn: $showOriginal).toggleStyle(.checkbox)
                Toggle("Следить", isOn: $follow).toggleStyle(.checkbox)
            }.font(.caption).padding(.horizontal, 20).padding(.vertical, 12)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        if model.segments.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Слушайте лекцию. Читайте перевод.").font(.title3.weight(.medium))
                                Text(model.keyReady ? "Выберите микрофон и нажмите Start. Фрагменты по 1,2–2,8 с отправляются в API по мере записи." : "Добавьте ключ OpenRouter выше, затем выберите микрофон и нажмите Start.")
                                    .foregroundStyle(.secondary)
                                Text("Для проверки: The construction 因为…所以… expresses cause and effect.")
                                    .font(.callout).foregroundStyle(.secondary)
                            }.padding(.top, 24).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        ForEach(model.segments) { segment in
                            segmentView(segment)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }.padding(.horizontal, 20).padding(.bottom, 20)
                }
                .onChange(of: model.segments.map { "\($0.id):\($0.status.rawValue)" }) { _, _ in
                    if follow { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
        }.background(Color(nsColor: .textBackgroundColor))
    }

    private func segmentView(_ segment: Segment) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 10) {
                Text("\(clock(segment.start))–\(clock(segment.end))").monospacedDigit()
                Text(status(segment))
                Spacer()
                if let latency = segment.latencySeconds, model.source == "microphone" {
                    Text(String(format: "+%.1f с", latency)).monospacedDigit()
                }
            }.font(.caption).foregroundStyle(.secondary)
            if !segment.translation.isEmpty {
                Text(segment.translation).font(.system(size: 19)).lineSpacing(5).textSelection(.enabled)
            } else if segment.status != .failed && segment.transcript.isEmpty {
                Text("Распознавание…").foregroundStyle(.secondary)
            } else if segment.status != .failed {
                Text("Перевод…").foregroundStyle(.secondary)
            }
            if (showOriginal || segment.status == .failed), !segment.transcript.isEmpty {
                Text(segment.transcript).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if let error = segment.error {
                Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }
            if let asr = segment.asrSeconds {
                Text("ASR \(String(format: "%.2f", asr)) с" +
                    (segment.translationSeconds.map { " · Перевод \(String(format: "%.2f", $0)) с" } ?? ""))
                    .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 16) {
                Text("Реплик: \(model.completeCount)")
                if let p50 = model.medianLatency, let p95 = model.p95Latency {
                    Text(String(format: "После фрагмента · P50 %.1f с · P95 %.1f с", p50, p95))
                } else { Text(model.source == "file" ? "Файл · пакетный тест" : "Задержка появится после перевода") }
                Spacer(minLength: 0)
            }.font(.caption).monospacedDigit().foregroundStyle(.secondary)
            HStack {
                Button("Save…") { model.export() }.disabled(model.folder == nil || model.busy)
                Button("Папка сессии") { model.revealSession() }.disabled(model.folder == nil)
                if model.failures > 0 {
                    Button("Повторить ошибки (\(model.failures))") { model.retryFailed() }.disabled(model.busy)
                }
                Spacer(minLength: 0)
                Text(model.knownCost > 0 ? String(format: "$%.5f%@", model.knownCost, model.allCostsKnown ? "" : " + ?") : "Стоимость: нет данных")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            Text("Аудио сохраняется автоматически. Stop завершает запись и дожидается очереди.")
                .font(.caption2).foregroundStyle(.secondary)
        }.padding(.horizontal, 20).padding(.vertical, 14)
    }

    private func clock(_ seconds: Double) -> String {
        let value = max(0, Int(seconds))
        return String(format: "%02d:%02d", value / 60, value % 60)
    }

    private func status(_ segment: Segment) -> String {
        switch segment.status {
        case .queued: return "В очереди"
        case .transcribing: return "ASR"
        case .ready: return "Ожидает перевода"
        case .translating: return "Перевод"
        case .complete: return segment.transcript.isEmpty ? "Речь не распознана" : "Готово"
        case .failed: return "Ошибка"
        }
    }
}
