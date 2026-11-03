import AppKit
import AVFoundation
import Combine
import LectureCore

@MainActor
final class DemoModel: ObservableObject {
    @Published var microphones: [Microphone] = []
    @Published var selectedMicrophone: UInt32 = 0
    @Published var keyInput = ""
    @Published var keyReady = false
    private static let retiredASRModels: Set<String> = ["qwen/qwen3-asr-1.7b", "elevenlabs/scribe-v2-realtime"]
    private static let asrPreferenceKey = "Voxtant.ASRModel.v1"
    private static let asrLanguagePreferenceKey = "Voxtant.ASRLanguageHint.v1"
    @Published private(set) var asrLanguageHint: SpeechLanguage?
    private(set) var frozenASRLanguageHint: SpeechLanguage?
    private static let translationPreferenceKey = "Voxtant.TranslationModel.v1"
    @Published var asrModel = "elevenlabs/scribe-v2" {
        didSet {
            if Self.retiredASRModels.contains(asrModel.trimmingCharacters(in: .whitespacesAndNewlines)) { asrModel = "elevenlabs/scribe-v2" }
            saveModelPreference(asrModel, key: Self.asrPreferenceKey)
        }
    }
    @Published var translationModel = TranslationDefaults.modelID {
        didSet { saveModelPreference(translationModel, key: Self.translationPreferenceKey) }
    }
    @Published private(set) var translationSettings: TranslationSettings
    @Published var thresholdDB = -48.0
    @Published var isRecording = false
    @Published var isPreparing = false
    @Published var isStopping = false
    @Published var isImporting = false
    @Published private var activeWorkers = 0
    @Published var segments: [Segment] = []
    @Published var partialTranslations: [Int: String] = [:]
    private var partialUpdatedAt: [Int: Date] = [:]
    private var deferredASR = Set<Int>()
    private var recoveringASR = Set<Int>()
    private var speechGateNotes: [Int: String] = [:]
    @Published var level: Float = 0
    @Published var duration = 0.0
    @Published var message: String?
    @Published var folder: URL?
    @Published var source = "microphone"
    private var apiKey = ""
    private var capture: AudioCapture?
    private var asrTasks: [Int: Task<Void, Never>] = [:]
    private var translationTasks: [Int: Task<Void, Never>] = [:]
    private var createdAt = Date()
    private var recordingName = "recording.caf"
    private let preferences: UserDefaults
    private(set) var frozenSettings = TranslationSettings()
    private var frozenASR = ""
    private var frozenTranslation = ""
    let recordingsRoot: URL
    @Published var exchangeRate: USDRUBRate?
    private var sessionExchangeRate: USDRUBRate?
    private var frozenMicrophoneName: String?
    private var frozenThresholdDB = -48.0
    private var deviceMonitor: MicrophoneDeviceMonitor?
    private static let ratePreferenceKey = "Voxtant.USDRUBRate.v1"
    var sessionCost: SessionCostSummary { SessionCostSummary(segments: segments, rate: sessionExchangeRate ?? exchangeRate) }

    private var suspendScheduling = false
    private var processingGeneration = UUID()
    @Published private(set) var processingStopped = false
    private let clientFactory: ((RetryPolicy) -> OpenRouterClient)?

    var pending: Int { segments.filter { ![.complete, .failed].contains($0.status) }.count }
    var failures: Int { segments.filter { $0.status == .failed }.count }
    var busy: Bool { isRecording || isPreparing || isStopping || isImporting || pending > 0 || activeWorkers > 0 }
    var completeCount: Int { segments.filter { $0.status == .complete && $0.translationMode != "cancelled-by-user" }.count }
    var state: String {
        if isPreparing { return "Подготовка" }
        if isRecording { return pending > 3 ? "Запись · обработка отстаёт" : "Запись" }
        if isStopping { return "Остановка" }
        if isImporting || pending > 0 || activeWorkers > 0 { return "Обработка" }
        if processingStopped { return "Остановлено" }
        if failures > 0 { return "Есть ошибки" }
        return segments.isEmpty ? "Готов к записи" : "Завершено"
    }
    var knownCost: Double { sessionCost.reportedUSD }
    var allCostsKnown: Bool { sessionCost.isComplete }
    var medianLatency: Double? { percentile(0.5) }
    var p95Latency: Double? { percentile(0.95) }

    init(loadKeychain: Bool = true, preferences: UserDefaults = .standard,
         clientFactory: ((RetryPolicy) -> OpenRouterClient)? = nil, recordingsRoot: URL? = nil) {
        self.preferences = preferences
        self.recordingsRoot = recordingsRoot ?? RecordingLibrary.defaultRoot
        if let cached = preferences.data(forKey: Self.ratePreferenceKey),
           let rate = try? JSONDecoder().decode(USDRUBRate.self, from: cached), rate.isValid { exchangeRate = rate }
        self.clientFactory = clientFactory
        translationSettings = TranslationPreferences.load(from: preferences)
        if let code = preferences.string(forKey: Self.asrLanguagePreferenceKey), let language = SpeechLanguage(rawValue: code),
           translationSettings.activeRules.contains(where: { $0.language == language }) { asrLanguageHint = language }
        if let saved = preferences.string(forKey: Self.asrPreferenceKey)?.trimmingCharacters(in: .whitespacesAndNewlines), !saved.isEmpty {
            asrModel = Self.retiredASRModels.contains(saved) ? "elevenlabs/scribe-v2" : saved
            if Self.retiredASRModels.contains(saved) { preferences.set(asrModel, forKey: Self.asrPreferenceKey) }
        }
        if let saved = preferences.string(forKey: Self.translationPreferenceKey)?.trimmingCharacters(in: .whitespacesAndNewlines), !saved.isEmpty {
            translationModel = saved == TranslationDefaults.legacyModelID ? TranslationDefaults.modelID : saved
            if saved == TranslationDefaults.legacyModelID { preferences.set(TranslationDefaults.modelID, forKey: Self.translationPreferenceKey) }
        }
        if loadKeychain, let key = KeychainStore.read(), !key.isEmpty { apiKey = key; keyReady = true }
        refreshDevices()
        if loadKeychain {
            do { try FileManager.default.createDirectory(at: self.recordingsRoot, withIntermediateDirectories: true) }
            catch { message = "Не удалось создать папку записей на рабочем столе: " + error.localizedDescription }
            deviceMonitor = MicrophoneDeviceMonitor { [weak self] in
                guard let self, !self.busy else { return }
                self.refreshDevices()
            }
            Task { [weak self] in await self?.refreshExchangeRate() }
        }
    }

    func refreshExchangeRate() async {
        if let rate = exchangeRate, Date().timeIntervalSince(rate.fetchedAt) < 6 * 3600 { return }
        do {
            let rate = try await USDRUBRate.fetch()
            exchangeRate = rate
            if let data = try? JSONEncoder().encode(rate) { preferences.set(data, forKey: Self.ratePreferenceKey) }
            if folder != nil, sessionExchangeRate == nil { sessionExchangeRate = rate; persist() }
        } catch { /* USD remains available; a previous dated cache is retained. */ }
    }

    private func saveModelPreference(_ value: String, key: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        preferences.set(trimmed, forKey: key)
    }

    func updateASRLanguageHint(_ language: SpeechLanguage?) {
        guard !busy, language == nil || translationSettings.activeRules.contains(where: { $0.language == language }) else { return }
        asrLanguageHint = language
        if let language { preferences.set(language.rawValue, forKey: Self.asrLanguagePreferenceKey) }
        else { preferences.removeObject(forKey: Self.asrLanguagePreferenceKey) }
    }

    func updateTranslationSettings(_ settings: TranslationSettings) {
        guard !busy else { return }
        do {
            try settings.validate()
            translationSettings = settings
            if let hint = asrLanguageHint, !settings.activeRules.contains(where: { $0.language == hint }) { updateASRLanguageHint(nil) }
            TranslationPreferences.save(settings, to: preferences)
        } catch { message = error.localizedDescription }
    }

    func refreshDevices() {
        let selected = microphones.first { $0.id == selectedMicrophone }
        microphones = Microphone.available()
        if let current = Microphone.resolve(selected, from: microphones) {
            selectedMicrophone = current.id
        } else if !microphones.contains(where: { $0.id == selectedMicrophone }) {
            selectedMicrophone = microphones.first?.id ?? 0
        }
    }

    func saveKey() {
        let key = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !busy else { return }
        do {
            try KeychainStore.save(key)
            apiKey = key
            keyInput = ""
            keyReady = true
            message = nil
        } catch { message = error.localizedDescription }
    }

    func start() async {
        guard !busy else { return }
        guard keyReady else { message = "Введите ключ OpenRouter в настройках подключения."; return }
        guard let selected = microphones.first(where: { $0.id == selectedMicrophone }) else {
            refreshDevices()
            message = "Выберите доступный микрофон и повторите запуск."
            return
        }
        isPreparing = true
        defer { isPreparing = false; persist() }
        let allowed = await AVCaptureDevice.requestAccess(for: .audio)
        guard allowed else {
            message = "Нет доступа к микрофону. Разрешите Voxtant в Системные настройки → Конфиденциальность и безопасность → Микрофон."
            return
        }
        // Permission prompts and device changes can invalidate the cached object ID.
        microphones = Microphone.available()
        guard let current = Microphone.resolve(selected, from: microphones) else {
            selectedMicrophone = 0
            message = "Выбранный микрофон отключён. Выберите другой микрофон и повторите запуск."
            return
        }
        selectedMicrophone = current.id
        do {
            try newSession(source: "microphone")
            let recorder = AudioCapture()
            let session = createdAt
            recorder.onChunk = { [weak self] chunk, url, capturedAt in
                DispatchQueue.main.async {
                    guard let self, self.createdAt == session else { return }
                    self.enqueue(chunk, file: url, capturedAt: capturedAt)
                }
            }
            recorder.onLevel = { [weak self] rms, duration in
                DispatchQueue.main.async {
                    guard let self, self.createdAt == session, self.isRecording || self.isStopping else { return }
                    self.level = self.isRecording ? rms : 0
                    self.duration = duration
                }
            }
            recorder.onFailure = { [weak self] error in
                Task { @MainActor in
                    guard let self, self.createdAt == session, !self.processingStopped else { return }
                    self.message = error
                    await self.stop()
                }
            }
            capture = recorder
            try recorder.start(device: current, folder: folder!,
                               threshold: Float(pow(10, thresholdDB / 20)))
            isRecording = true
        } catch {
            if let capture { await capture.stop() }
            capture = nil
            message = error.localizedDescription
        }
    }

    func stop() async {
        guard !isStopping, isRecording || pending > 0 || activeWorkers > 0 else { return }
        isStopping = true
        isRecording = false
        cancelProcessing()
        // Only flush local audio already captured; never wait for an API response.
        await capture?.stop()
        capture = nil
        level = 0
        isStopping = false
        persist()
    }

    private func cancelProcessing() {
        suspendScheduling = true
        processingStopped = true
        // Retire ownership before cancellation callbacks can resume on MainActor.
        processingGeneration = UUID()
        asrTasks.values.forEach { $0.cancel() }
        translationTasks.values.forEach { $0.cancel() }
        asrTasks.removeAll()
        translationTasks.removeAll()
        activeWorkers = 0
        deferredASR.removeAll()
        recoveringASR.removeAll()
        partialTranslations.removeAll()
        partialUpdatedAt.removeAll()
        for i in segments.indices where ![.complete, .failed].contains(segments[i].status) {
            segments[i].status = .complete
            segments[i].translationMode = "cancelled-by-user"
            segments[i].error = nil
        }
    }

    func cancelPending() {
        guard !isRecording, !isStopping, !isImporting else { return }
        cancelProcessing()
        persist()
    }

    func retryFailed() {
        guard !busy else { return }
        processingGeneration = UUID()
        processingStopped = false
        suspendScheduling = false
        for i in segments.indices where segments[i].status == .failed {
            segments[i].error = nil
            segments[i].status = segments[i].transcript.isEmpty ? .queued : .ready
        }
        message = nil
        persist()
        schedule()
    }

    func importAudio() async {
        guard !busy, keyReady else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Выберите короткий фрагмент лекции для пакетного теста. Он не измеряет live-задержку."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        isImporting = true
        defer { isImporting = false; persist() }
        do {
            try newSession(source: "file")
            let destination = folder!.appendingPathComponent("source." + url.pathExtension)
            try FileManager.default.copyItem(at: url, to: destination)
            recordingName = destination.lastPathComponent
            let folder = folder!
            let threshold = Float(pow(10, thresholdDB / 20))
            let model = self
            try await Task.detached(priority: .userInitiated) {
                let file = try AVAudioFile(forReading: destination)
                let format = file.processingFormat
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192), format.sampleRate > 0 else {
                    throw LectureError.message("Не удалось прочитать аудиоформат.")
                }
                var segmenter = AudioSegmenter(sampleRate: format.sampleRate, threshold: threshold)
                var index = 0
                func store(_ chunk: AudioChunk) async throws {
                    let chunkFile = folder.appendingPathComponent(String(format: "chunks/%05d.wav", index))
                    index += 1
                    try WAVEncoder.encode(samples: chunk.samples, sampleRate: format.sampleRate, normalize: true).write(to: chunkFile, options: .atomic)
                    await model.enqueue(chunk, file: chunkFile, capturedAt: Date())
                }
                while file.framePosition < file.length {
                    try Task.checkCancellation()
                    try file.read(into: buffer)
                    guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { break }
                    var mono = [Float](repeating: 0, count: Int(buffer.frameLength))
                    for c in 0..<Int(format.channelCount) {
                        for f in mono.indices { mono[f] += channels[c][f] / Float(format.channelCount) }
                    }
                    for chunk in segmenter.append(mono) { try await store(chunk) }
                    let elapsed = Double(file.framePosition) / format.sampleRate
                    await MainActor.run { model.duration = elapsed }
                }
                if let chunk = segmenter.flush() { try await store(chunk) }
            }.value
        } catch { message = error.localizedDescription }
    }

    func export() {
        guard !busy, let folder else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Сохранить сюда"
        panel.message = "Сохранить сессию: аудио, фрагменты, оригинал, перевод и замеры."
        guard panel.runModal() == .OK, let parent = panel.url else { return }
        persist()
        do {
            let destination = parent.appendingPathComponent(folder.lastPathComponent)
            try FileManager.default.copyItem(at: folder, to: destination)
            NSWorkspace.shared.activateFileViewerSelecting([destination])
        } catch { message = "Не удалось экспортировать: \(error.localizedDescription)" }
    }

    func revealSession() {
        if let folder { NSWorkspace.shared.open(folder) }
    }

    func newSession(source: String) throws {
        try translationSettings.validate()
        guard !asrModel.trimmingCharacters(in: .whitespaces).isEmpty,
              !translationModel.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw LectureError.message("Укажите обе модели.")
        }
        let startedAt = Date()
        let folder = try RecordingLibrary.createSession(root: recordingsRoot, date: startedAt)
        self.folder = folder
        self.source = source
        createdAt = startedAt
        sessionExchangeRate = exchangeRate
        frozenMicrophoneName = source == "microphone" ? microphones.first { $0.id == selectedMicrophone }?.name : nil
        frozenSettings = translationSettings
        frozenThresholdDB = thresholdDB
        frozenASRLanguageHint = asrLanguageHint
        processingGeneration = UUID()
        processingStopped = false
        suspendScheduling = false
        speechGateNotes.removeAll()
        frozenASR = asrModel.trimmingCharacters(in: .whitespaces)
        frozenTranslation = translationModel.trimmingCharacters(in: .whitespaces)
        recordingName = "recording.caf"
        segments = []
        deferredASR.removeAll()
        recoveringASR.removeAll()
        partialTranslations.removeAll()
        partialUpdatedAt.removeAll()
        duration = 0
        message = nil
        persist()
    }

    private func enqueue(_ chunk: AudioChunk, file: URL, capturedAt: Date) {
        var segment = Segment(id: segments.count, start: chunk.start, end: chunk.end,
            file: "chunks/" + file.lastPathComponent, capturedAt: capturedAt,
            asrModel: frozenASR, translationModel: frozenTranslation)
        segment.queuedAt = Date()
        if processingStopped {
            segment.status = .complete
            segment.translationMode = "cancelled-by-user"
        }
        segments.append(segment)
        persist()
        if !processingStopped { schedule() }
    }

    private func schedule() {
        guard !suspendScheduling, let folder else { return }
        let settings = frozenSettings
        let languageHint = frozenASRLanguageHint
        let generation = processingGeneration
        let microphoneSession = source == "microphone"
        let live = microphoneSession && (isRecording || isStopping)
        while asrTasks.count < 2,
              let index = LiveASRPolicy.nextIndex(statuses: segments.map(\.status), deferred: deferredASR, live: live, activeWorkers: asrTasks.count, recovering: !recoveringASR.isEmpty) {
            let retryingDeferred = deferredASR.remove(index) != nil
            if retryingDeferred { recoveringASR.insert(index) }
            segments[index].status = .transcribing
            if !retryingDeferred {
                segments[index].asrStartedAt = Date()
                segments[index].asrSeconds = nil
            }
            let segment = segments[index]
            let context = segments.prefix(index).filter { !$0.transcript.isEmpty }.suffix(3)
                .map(\.transcript).joined(separator: "\n")
            let policy = LiveASRPolicy.retryPolicy(microphoneSession: microphoneSession, deferred: retryingDeferred)
            let client = clientFactory?(policy) ?? OpenRouterClient(key: apiKey, retryPolicy: policy)
            activeWorkers += 1
            asrTasks[index] = Task { [weak self] in
                do {
                    let result = try await client.transcribe(file: folder.appendingPathComponent(segment.file), model: segment.asrModel, context: context, settings: settings, filterNonSpeech: true, languageHint: languageHint)
                    try Task.checkCancellation()
                    guard let self, self.processingGeneration == generation else { return }
                    if let gate = result.speechGate {
                        self.speechGateNotes[index] = "Segment \(segment.id): " + gate.note
                        if gate.skipASR { self.segments[index].translationMode = "local-nonspeech-v1"; self.segments[index].translationCost = 0 }
                    }
                    self.segments[index].transcript = result.text
                    let earlierServiceSeconds = retryingDeferred ? (self.segments[index].attempts ?? []).filter { $0.stage == "asr" }.reduce(0) { $0 + $1.seconds } : 0
                    self.segments[index].asrSeconds = earlierServiceSeconds + result.seconds
                    self.segments[index].asrCost = result.cost
                    self.segments[index].attempts = (self.segments[index].attempts ?? []) + result.attempts
                    self.segments[index].transcriptReadyAt = Date()
                    self.segments[index].status = result.text.isEmpty ? .complete : .ready
                } catch {
                    guard let self, self.processingGeneration == generation else { return }
                    if microphoneSession && !retryingDeferred, let failure = error as? APIRequestFailure, LiveASRPolicy.canDefer(failure) {
                        self.segments[index].attempts = (self.segments[index].attempts ?? []) + failure.attempts
                        self.segments[index].status = .queued
                        self.deferredASR.insert(index)
                    } else { self.fail(index, error: error) }
                }
                guard let self, self.processingGeneration == generation else { return }
                self.recoveringASR.remove(index)
                self.asrTasks[index] = nil
                self.activeWorkers -= 1
                self.persist()
                self.schedule()
            }
        }
        // Cells/export remain in audio order; a retry on one cell must not block later translations.
        while translationTasks.count < 2,
              let index = segments.firstIndex(where: { $0.status == .ready }) {
            segments[index].status = .translating
            segments[index].translationStartedAt = Date()
            let segment = segments[index]
            let context = segments.prefix(index).filter { !$0.transcript.isEmpty }.suffix(3)
                .map(\.transcript).joined(separator: "\n")
            let client = clientFactory?(RetryPolicy()) ?? OpenRouterClient(key: apiKey)
            activeWorkers += 1
            let session = createdAt
            translationTasks[index] = Task { [weak self] in
                do {
                    let result = try await client.translate(segment.transcript, context: context, model: segment.translationModel,
                        settings: settings, latencyRouting: true, onPartial: { [weak self] text in
                            Task { @MainActor in
                                guard let self, self.createdAt == session, self.processingGeneration == generation, self.segments.indices.contains(index),
                                      self.segments[index].status == .translating else { return }
                                let now = Date()
                                if text.isEmpty || self.partialUpdatedAt[index] == nil || now.timeIntervalSince(self.partialUpdatedAt[index]!) >= 0.08 {
                                    self.partialTranslations[index] = text
                                    self.partialUpdatedAt[index] = now
                                }
                            }
                        })
                    try Task.checkCancellation()
                    guard let self, self.processingGeneration == generation else { return }
                    self.segments[index].translation = result.text
                    self.segments[index].translationSeconds = result.seconds
                    self.segments[index].translationCost = result.cost
                    self.segments[index].attempts = (self.segments[index].attempts ?? []) + result.attempts
                    self.segments[index].translationMode = result.attempts.isEmpty ? "local-chinese-preserve" : "configured-" + settings.mode.rawValue
                    self.segments[index].displayedAt = Date()
                    self.segments[index].latencySeconds = Date().timeIntervalSince(segment.capturedAt)
                    self.segments[index].status = .complete
                } catch {
                    guard let self, self.processingGeneration == generation else { return }
                    self.fail(index, error: error)
                }
                guard let self, self.processingGeneration == generation else { return }
                self.partialTranslations[index] = nil
                self.partialUpdatedAt[index] = nil
                self.translationTasks[index] = nil
                self.activeWorkers -= 1
                self.persist()
                self.schedule()
            }
        }
    }

    private func fail(_ index: Int, error: Error) {
        segments[index].status = .failed
        if let failure = error as? APIRequestFailure {
            segments[index].attempts = (segments[index].attempts ?? []) + failure.attempts
        }
        if error is CancellationError || (error as? URLError)?.code == .cancelled {
            segments[index].error = "Обработка отменена; аудио сохранено."
        } else { segments[index].error = error.localizedDescription }
    }

    private func persist() {
        guard let folder else { return }
        do {
            var report = SessionReport(createdAt: createdAt, source: source, duration: duration,
                                       recording: recordingName, segments: segments)
            report.translationSettings = frozenSettings
            report.notes.append("ASR language hint: " + (frozenSettings.asrLanguage ?? frozenASRLanguageHint?.rawValue ?? "auto"))
            report.notes += speechGateNotes.keys.sorted().compactMap { speechGateNotes[$0] }
            if processingStopped { report.notes.append("Stop cancels queued and in-flight processing. Cancelled cells retain saved audio and use translationMode=cancelled-by-user; late results are ignored.") }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .custom { date, encoder in
                var container = encoder.singleValueContainer()
                try container.encode(date.ISO8601Format(Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
            }
            try encoder.encode(report).write(to: folder.appendingPathComponent("session.json"), options: .atomic)
            let status = isRecording ? "recording" : isPreparing ? "starting" : processingStopped ? "stopped" : busy ? "processing" : failures > 0 || message != nil ? "failed" : "completed"
            let metadata = RecordingMetadata(folder: folder, createdAt: createdAt, source: source, status: status,
                duration: duration, recording: recordingName, asrModel: frozenASR, translationModel: frozenTranslation,
                settings: frozenSettings, hint: frozenSettings.asrLanguage ?? frozenASRLanguageHint?.rawValue,
                microphone: frozenMicrophoneName, cost: sessionCost, speechThresholdDB: frozenThresholdDB)
            try encoder.encode(metadata).write(to: folder.appendingPathComponent("metadata.json"), options: .atomic)
            try segments.map(\.transcript).filter { !$0.isEmpty }.joined(separator: "\n\n")
                .write(to: folder.appendingPathComponent("transcript.txt"), atomically: true, encoding: .utf8)
            try segments.map(\.translation).filter { !$0.isEmpty }.joined(separator: "\n\n")
                .write(to: folder.appendingPathComponent("translation.txt"), atomically: true, encoding: .utf8)
        } catch { message = "Не удалось сохранить метаданные сессии: \(error.localizedDescription)" }
    }

    private func percentile(_ fraction: Double) -> Double? {
        guard source == "microphone" else { return nil }
        let values = segments.compactMap(\.latencySeconds).sorted()
        guard !values.isEmpty else { return nil }
        return values[max(0, Int(ceil(Double(values.count) * fraction)) - 1)]
    }
}
