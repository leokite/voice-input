@preconcurrency import AVFoundation
import VoiceInputCore

/// マイクの入力を 16kHz、モノラル、s16le に変換し、約 100ms ごとに RMS と一緒に渡す。
final class AudioCapture: AudioSource {
    enum CaptureError: Error {
        case permissionDenied, formatUnavailable
    }

    private var engine: AVAudioEngine?

    func start(onChunk: @escaping @Sendable (Data, Float) -> Void) throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            // 許可のダイアログを出す。今回の録音は失敗として扱い、許可後の次の録音から使える。
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
            throw CaptureError.permissionDenied
        default:
            throw CaptureError.permissionDenied
        }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
              let outputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000,
                                               channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        else { throw CaptureError.formatUnavailable }

        let pipeline = ConversionPipeline(converter: converter, outputFormat: outputFormat, onChunk: onChunk)
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
            pipeline.process(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        self.engine = engine
    }

    func stop() {
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
    }
}

/// オーディオスレッドだけから使う変換処理。
private final class ConversionPipeline: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat
    private let onChunk: @Sendable (Data, Float) -> Void
    private var chunker = PCMChunker()

    init(converter: AVAudioConverter, outputFormat: AVAudioFormat,
         onChunk: @escaping @Sendable (Data, Float) -> Void) {
        self.converter = converter
        self.outputFormat = outputFormat
        self.onChunk = onChunk
    }

    func process(_ buffer: AVAudioPCMBuffer) {
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, let samples = output.int16ChannelData, output.frameLength > 0 else { return }
        let frames = Array(UnsafeBufferPointer(start: samples[0], count: Int(output.frameLength)))
        for chunk in chunker.append(frames) {
            onChunk(chunk.data, chunk.rms)
        }
    }
}
