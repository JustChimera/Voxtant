import AVFoundation
import CoreAudio
import Darwin
import LectureCore

struct Microphone: Identifiable, Hashable {
    let id: AudioDeviceID
    let name: String

    static func available() -> [Microphone] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices) == noErr else { return [] }
        return devices.compactMap { id in
            var input = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
            var inputSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &input, 0, nil, &inputSize) == noErr, inputSize > 0 else { return nil }
            var property = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var name: Unmanaged<CFString>?
            var nameSize = UInt32(MemoryLayout<CFString>.size)
            guard AudioObjectGetPropertyData(id, &property, 0, nil, &nameSize, &name) == noErr else { return nil }
            return Microphone(id: id, name: name?.takeUnretainedValue() as String? ?? "Microphone")
        }.sorted { $0.name < $1.name }
    }
}

/// One serial disk/DSP queue, independent of all networking. The tap only copies buffers.
final class AudioCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let queue = DispatchQueue(label: "lecture.audio.disk", qos: .userInitiated)
    private var recording: AVAudioFile?
    private var segmenter: AudioSegmenter?
    private var chunkIndex = 0
    private var folder: URL?
    private var tapInstalled = false
    private var failed = false
    private var lastBufferEndAt = Date()
    private var lastBufferAudioEnd = 0.0
    private var selectedDevice: AudioDeviceID = 0
    private var captureFormat: AVAudioFormat?
    private var notification: NSObjectProtocol?
    var onChunk: ((AudioChunk, URL, Date) -> Void)?
    var onLevel: ((Float, Double) -> Void)?
    var onFailure: ((String) -> Void)?

    func start(device: AudioDeviceID, folder: URL, threshold: Float) throws {
        self.folder = folder
        selectedDevice = device
        let input = engine.inputNode
        try input.auAudioUnit.setDeviceID(device)
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0, format.commonFormat == .pcmFormatFloat32 else {
            throw LectureError.message("Микрофон не предоставил Float32 аудиоформат.")
        }
        segmenter = AudioSegmenter(sampleRate: format.sampleRate, threshold: threshold)
        captureFormat = format
        recording = try AVAudioFile(forWriting: folder.appendingPathComponent("recording.caf"), settings: format.settings)
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, timestamp in
            guard let self, let copy = Self.copy(buffer) else { return }
            let now = Date()
            let endAt: Date
            if timestamp.isHostTimeValid {
                let endHost = AVAudioTime.seconds(forHostTime: timestamp.hostTime) + Double(buffer.frameLength) / format.sampleRate
                let currentHost = AVAudioTime.seconds(forHostTime: mach_absolute_time())
                endAt = now.addingTimeInterval(endHost - currentHost)
            } else { endAt = now }
            self.queue.async { self.consume(copy, endAt: endAt) }
        }
        tapInstalled = true
        engine.prepare()
        do { try engine.start() }
        catch {
            input.removeTap(onBus: 0)
            tapInstalled = false
            recording = nil
            throw error
        }
        // Preparing/starting the graph can itself emit configuration notifications.
        // Register after startup and inspect the device instead of treating every event as a disconnect.
        notification = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
            object: engine, queue: .main) { [weak self] _ in
                self?.handleConfigurationChange()
            }
    }

    private func handleConfigurationChange() {
        guard tapInstalled else { return }
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var alive: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(selectedDevice, &address, 0, nil, &size, &alive)
        guard status == noErr, alive != 0 else {
            onFailure?("Выбранный микрофон отключён. Запись остановлена; уже записанное сохранено.")
            return
        }
        guard !engine.isRunning else { return }
        let format = engine.inputNode.outputFormat(forBus: 0)
        guard let captureFormat, format.sampleRate == captureFormat.sampleRate,
              format.channelCount == captureFormat.channelCount else {
            onFailure?("Формат микрофона изменился. Запись сохранена; нажмите Start для новой сессии.")
            return
        }
        do { try engine.start() }
        catch { onFailure?("Не удалось возобновить микрофон: \(error.localizedDescription)") }
    }

    func stop() async {
        if let notification { NotificationCenter.default.removeObserver(notification); self.notification = nil }
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        engine.stop()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                if let chunk = self.segmenter?.flush() { self.emit(chunk) }
                self.recording = nil
                // Deliver all chunk callbacks on the main queue before Stop completes.
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }

    private func consume(_ buffer: AVAudioPCMBuffer, endAt: Date) {
        guard !failed else { return }
        do {
            try recording?.write(from: buffer)
            guard let channels = buffer.floatChannelData else { return }
            let frames = Int(buffer.frameLength)
            let count = Int(buffer.format.channelCount)
            var mono = [Float](repeating: 0, count: frames)
            for channel in 0..<count {
                for frame in 0..<frames { mono[frame] += channels[channel][frame] / Float(count) }
            }
            let rms = sqrt(mono.reduce(Float(0)) { $0 + $1 * $1 } / Float(max(1, frames)))
            let elapsed = Double(recording?.length ?? 0) / buffer.format.sampleRate
            lastBufferEndAt = endAt
            lastBufferAudioEnd = elapsed
            onLevel?(rms, elapsed)
            for chunk in segmenter?.append(mono) ?? [] { emit(chunk) }
        } catch {
            failed = true
            onFailure?("Ошибка записи на диск: \(error.localizedDescription)")
        }
    }

    private func emit(_ chunk: AudioChunk) {
        guard let folder, let sampleRate = segmenter?.sampleRate else { return }
        let url = folder.appendingPathComponent(String(format: "chunks/%05d.wav", chunkIndex))
        chunkIndex += 1
        do {
            try WAVEncoder.encode(samples: chunk.samples, sampleRate: sampleRate, normalize: true).write(to: url, options: .atomic)
            onChunk?(chunk, url, lastBufferEndAt.addingTimeInterval(chunk.end - lastBufferAudioEnd))
        } catch {
            onFailure?("Не удалось сохранить аудиофрагмент: \(error.localizedDescription)")
        }
    }

    private static func copy(_ input: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: input.format, frameCapacity: input.frameLength),
              let source = input.floatChannelData, let destination = copy.floatChannelData else { return nil }
        copy.frameLength = input.frameLength
        for channel in 0..<Int(input.format.channelCount) {
            destination[channel].update(from: source[channel], count: Int(input.frameLength))
        }
        return copy
    }
}
