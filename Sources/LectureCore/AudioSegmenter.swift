import Foundation

public struct AudioChunk: Sendable {
    public let samples: [Float]
    public let start: Double
    public let end: Double
}

/// Non-overlapping segments: no text deduplication that could erase repeated Chinese examples.
public struct AudioSegmenter {
    public let sampleRate: Double
    public var targetSeconds: Double
    public var maximumSeconds: Double
    public var silenceSeconds: Double
    public var threshold: Float
    private var samples: [Float] = []
    private var offset = 0
    private var silenceFrames = 0
    private var hasSpeech = false

    public init(sampleRate: Double, targetSeconds: Double = 1.2,
                maximumSeconds: Double = 2.8, silenceSeconds: Double = 0.25,
                threshold: Float = 0.004) {
        precondition(sampleRate > 0)
        self.sampleRate = sampleRate
        self.targetSeconds = targetSeconds
        self.maximumSeconds = maximumSeconds
        self.silenceSeconds = silenceSeconds
        self.threshold = threshold
    }

    public mutating func append(_ input: [Float]) -> [AudioChunk] {
        // Evaluate short windows even when importing a file with large read buffers.
        let window = max(1, Int(sampleRate * 0.02))
        var chunks: [AudioChunk] = []
        for start in stride(from: 0, to: input.count, by: window) {
            let slice = input[start..<min(input.count, start + window)]
            let rms = sqrt(slice.reduce(Float(0)) { $0 + $1 * $1 } / Float(slice.count))
            samples.append(contentsOf: slice)
            if rms >= threshold {
                hasSpeech = true
                silenceFrames = 0
            } else {
                silenceFrames += slice.count
            }
            if !hasSpeech {
                // Keep 120 ms before speech, rather than sending seconds of leading silence.
                let removed = max(0, samples.count - Int(sampleRate * 0.12))
                if removed > 0 { samples.removeFirst(removed); offset += removed }
                continue
            }
            let duration = Double(samples.count) / sampleRate
            if duration >= maximumSeconds ||
                (duration >= targetSeconds && Double(silenceFrames) / sampleRate >= silenceSeconds) {
                if let chunk = flush() { chunks.append(chunk) }
            }
        }
        return chunks
    }

    public mutating func flush() -> AudioChunk? {
        guard !samples.isEmpty else { return nil }
        let start = Double(offset) / sampleRate
        offset += samples.count
        let chunk = hasSpeech ? AudioChunk(samples: samples, start: start,
                                          end: Double(offset) / sampleRate) : nil
        samples.removeAll(keepingCapacity: true)
        silenceFrames = 0
        hasSpeech = false
        return chunk
    }
}

public enum WAVEncoder {
    /// Resample short speech chunks to mono 16 kHz PCM16. The original stays untouched on disk.
    public static func encode(samples: [Float], sampleRate: Double, normalize: Bool = false) -> Data {
        let rate = 16_000
        let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
        let gain: Float = normalize && peak > 0 ? min(8, 0.8 / peak) : 1
        let count = Int(Double(samples.count) * Double(rate) / sampleRate)
        var pcm = Data(capacity: count * 2)
        for i in 0..<count {
            let position = Double(i) * sampleRate / Double(rate)
            let left = min(Int(position), max(0, samples.count - 1))
            let right = min(left + 1, max(0, samples.count - 1))
            let fraction = Float(position - Double(left))
            let value = (samples[left] * (1 - fraction) + samples[right] * fraction) * gain
            pcm.appendLE(Int16(max(-1, min(1, value)) * 32767))
        }
        var data = Data("RIFF".utf8)
        data.appendLE(UInt32(36 + pcm.count))
        data.append(Data("WAVEfmt ".utf8))
        data.appendLE(UInt32(16))
        data.appendLE(UInt16(1))
        data.appendLE(UInt16(1))
        data.appendLE(UInt32(rate))
        data.appendLE(UInt32(rate * 2))
        data.appendLE(UInt16(2))
        data.appendLE(UInt16(16))
        data.append(Data("data".utf8))
        data.appendLE(UInt32(pcm.count))
        data.append(pcm)
        return data
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}
