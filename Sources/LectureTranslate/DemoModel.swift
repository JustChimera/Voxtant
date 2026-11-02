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
    @Published var asrModel = "qwen/qwen3-asr-1.7b"
    @Published var translationModel = "google/gemini-2.5-flash-lite"
    @Published var thresholdDB = -48.0
    @Published var isRecording = false
    @Published var isPreparing = false
    @Published var isStopping = false
    @Published var isImporting = false
    @Published private var activeWorkers = 0
    @Published var segments: [Segment] = []
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
    private var frozenASR = ""
    private var frozenTranslation = ""
    private var suspendScheduling = false

    var pending: Int { segments.filter { ![.complete, .failed].contains($0.status) }.count }
    var failures: Int { segments.filter { $0.status == .failed }.count }
    var busy: Bool { isRecording || isPreparing || isStopping || isImporting || pending > 0 || activeWorkers > 0 }
    var completeCount: Int { segments.filter { $0.status == .complete }.count }
    var state: String {
        if isPreparing { return "Подготовка" }
        if isRecording { return pending > 3 ? "Запись · обработка отстаёт" : "Запись" }
        if isStopping || isImporting || pending > 0 || activeWorkers > 0 { return "Обработка" }
        if failures > 0 { return "Есть ошибки" }
        return segments.isEmpty ? "Готов к записи" : "Завершено"
    }
    var knownCost: Double {
        segments.reduce(0) { sum, segment in
            if let attempts = segment.attempts {
                return sum + attempts.compactMap(\.cost).reduce(0, +)
            }
            return sum + (segment.asrCost ?? 0) + (segment.translationCost ?? 0)
        }
    }
    var allCostsKnown: Bool {
        !segments.isEmpty && segments.allSatisfy {
            $0.status == .complete && $0.asrCost != nil && $0.translationCost != nil &&
                ($0.attempts?.allSatisfy { $0.cost != nil } ?? true)
        }
    }
    var medianLatency: Double? { percentile(0.5) }
    var p95Latency: Double? { percentile(0.95) }

    init() {
        if let key = KeychainStore.read(), !key.isEmpty { apiKey = key; keyReady = true }
        refreshDevices()
    }

    func refreshDevices() {
        microphones = Microphone.available()
        if !microphones.contains(where: { $0.id == selectedMicrophone }) {
            selectedMicrophone = microphones.first?.id ?? 0
        }
    }

    func saveKey() {
        let key = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
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
        guard selectedMicrophone != 0 else { message = "Микрофон не найден. Подключите его и обновите список."; return }
        isPreparing = true
        defer { isPreparing = false }
        let allowed = await AVCaptureDevice.requestAccess(for: .audio)
        guard allowed else {
            message = "Нет доступа к микрофону. Разрешите Voxtant в Системные настройки → Конфиденциальность и безопасность → Микрофон."
            return
        }
        do {
            try newSession(source: "microphone")
            let recorder = AudioCapture()
            recorder.onChunk = { [weak self] chunk, url, capturedAt in
                DispatchQueue.main.async { self?.enqueue(chunk, file: url, capturedAt: capturedAt) }
            }
            recorder.onLevel = { [weak self] rms, duration in
                DispatchQueue.main.async { self?.level = rms; self?.duration = duration }
            }
            recorder.onFailure = { [weak self] error in
                Task { @MainActor in
                    guard let self else { return }
                    self.message = error
                    await self.stop()
                }
            }
            capture = recorder
            try recorder.start(device: selectedMicrophone, folder: folder!,
                               threshold: Float(pow(10, thresholdDB / 20)))
            isRecording = true
        } catch {
            if let capture { await capture.stop() }
            capture = nil
            message = error.localizedDescription
        }
    }

    func stop() async {
        guard isRecording, !isStopping else { return }
        isStopping = true
        isRecording = false
        await capture?.stop()
        capture = nil
        level = 0
        isStopping = false
        persist()
    }

    func cancelPending() {
        guard !isRecording, !isStopping, !isImporting else { return }
        suspendScheduling = true
        asrTasks.values.forEach { $0.cancel() }
        translationTasks.values.forEach { $0.cancel() }
        // Keep worker slots occupied until cancellation has actually unwound.
        for i in segments.indices where ![.complete, .failed].contains(segments[i].status) {
            segments[i].status = .failed
            segments[i].error = "Обработка отменена. Аудио сохранено; можно повторить."
        }
        persist()
        suspendScheduling = false
    }

    func retryFailed() {
        guard asrTasks.isEmpty, translationTasks.isEmpty else { return }
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

    private func newSession(source: String) throws {
        guard !asrModel.trimmingCharacters(in: .whitespaces).isEmpty,
              !translationModel.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw LectureError.message("Укажите обе модели.")
        }
        let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                              appropriateFor: nil, create: true)
            .appendingPathComponent("LectureTranslateDemo/Sessions", isDirectory: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let folder = root.appendingPathComponent("Lecture_" + formatter.string(from: Date()) + "_" + UUID().uuidString.prefix(6))
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("chunks"), withIntermediateDirectories: true)
        self.folder = folder
        self.source = source
        createdAt = Date()
        frozenASR = asrModel.trimmingCharacters(in: .whitespaces)
        frozenTranslation = translationModel.trimmingCharacters(in: .whitespaces)
        recordingName = "recording.caf"
        segments = []
        duration = 0
        message = nil
        persist()
    }

    private func enqueue(_ chunk: AudioChunk, file: URL, capturedAt: Date) {
        var segment = Segment(id: segments.count, start: chunk.start, end: chunk.end,
            file: "chunks/" + file.lastPathComponent, capturedAt: capturedAt,
            asrModel: frozenASR, translationModel: frozenTranslation)
        segment.queuedAt = Date()
        segments.append(segment)
        persist()
        schedule()
    }

    private func schedule() {
        guard !suspendScheduling, let folder else { return }
        while asrTasks.count < 2, let index = segments.firstIndex(where: { $0.status == .queued }) {
            segments[index].status = .transcribing
            segments[index].asrStartedAt = Date()
            let segment = segments[index]
            let context = segments.prefix(index).filter { !$0.transcript.isEmpty }.suffix(3)
                .map(\.transcript).joined(separator: "\n")
            let client = OpenRouterClient(key: apiKey)
            activeWorkers += 1
            asrTasks[index] = Task { [weak self] in
                do {
                    let result = try await client.transcribe(file: folder.appendingPathComponent(segment.file), model: segment.asrModel, context: context)
                    try Task.checkCancellation()
                    guard let self else { return }
                    self.segments[index].transcript = result.text
                    self.segments[index].asrSeconds = result.seconds
                    self.segments[index].asrCost = result.cost
                    self.segments[index].attempts = (self.segments[index].attempts ?? []) + result.attempts
                    self.segments[index].transcriptReadyAt = Date()
                    self.segments[index].status = result.text.isEmpty ? .complete : .ready
                } catch { self?.fail(index, error: error) }
                self?.asrTasks[index] = nil
                self?.activeWorkers -= 1
                self?.persist()
                self?.schedule()
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
            let client = OpenRouterClient(key: apiKey)
            activeWorkers += 1
            translationTasks[index] = Task { [weak self] in
                do {
                    let result = try await client.translate(segment.transcript, context: context, model: segment.translationModel)
                    try Task.checkCancellation()
                    guard let self else { return }
                    self.segments[index].translation = result.text
                    self.segments[index].translationSeconds = result.seconds
                    self.segments[index].translationCost = result.cost
                    self.segments[index].attempts = (self.segments[index].attempts ?? []) + result.attempts
                    self.segments[index].translationMode = result.attempts.isEmpty ? "local-chinese-preserve" : "masked-english-translation"
                    self.segments[index].displayedAt = Date()
                    self.segments[index].latencySeconds = Date().timeIntervalSince(segment.capturedAt)
                    self.segments[index].status = .complete
                } catch { self?.fail(index, error: error) }
                self?.translationTasks[index] = nil
                self?.activeWorkers -= 1
                self?.persist()
                self?.schedule()
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
            let report = SessionReport(createdAt: createdAt, source: source, duration: duration,
                                       recording: recordingName, segments: segments)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .custom { date, encoder in
                var container = encoder.singleValueContainer()
                try container.encode(date.ISO8601Format(Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
            }
            try encoder.encode(report).write(to: folder.appendingPathComponent("session.json"), options: .atomic)
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
