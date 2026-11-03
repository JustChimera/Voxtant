import AppKit
import AVFoundation
import LectureCore

/// Explicit two-cycle local hardware check. No model, Keychain or networking is involved.
@MainActor
enum AudioCaptureSmokeTest {
    static func run(folder: URL) async {
        var result: [String: Any] = ["passed": false,
            "note": "Local microphone only; two one-second captures. No API or credentials."]
        do {
            guard !FileManager.default.fileExists(atPath: folder.path) else {
                fputs("Audio smoke output directory must be new.\n", stderr)
                NSApp.terminate(nil)
                return
            }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
                throw LectureError.message("Existing microphone authorization is required; no permission prompt was opened.")
            }
            guard let selected = Microphone.available().first else { throw LectureError.message("No live microphone is available.") }
            var cycles: [[String: Any]] = []
            for cycle in 0..<2 {
                let output = folder.appendingPathComponent("cycle-\(cycle)", isDirectory: true)
                try FileManager.default.createDirectory(at: output.appendingPathComponent("chunks"), withIntermediateDirectories: true)
                let recorder = AudioCapture()
                do {
                    try recorder.start(device: selected, folder: output, threshold: Float(pow(10, -48.0 / 20)))
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                } catch {
                    await recorder.stop()
                    throw error
                }
                await recorder.stop()
                let file = try AVAudioFile(forReading: output.appendingPathComponent("recording.caf"))
                guard file.length > 0 else { throw LectureError.message("The microphone delivered no audio frames.") }
                cycles.append(["frames": file.length, "sampleRate": file.processingFormat.sampleRate,
                    "channels": file.processingFormat.channelCount])
            }
            result["cycles"] = cycles
            result["passed"] = true
        } catch {
            result["error"] = error.localizedDescription
        }
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: folder.appendingPathComponent("result.json"), options: .atomic)
        }
        NSApp.terminate(nil)
    }
}
