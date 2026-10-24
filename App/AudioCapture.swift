@preconcurrency import AVFoundation
import VoiceInputCore

/// マイクの入力を 16kHz、モノラル、s16le に変換し、約 100ms ごとに RMS と一緒に渡す。
final class AudioCapture: AudioSource {
    enum CaptureError: Error {
        case permissionDenied, formatUnavailable
    }

    private var engine: AVAudioEngine?
    private var pipeline: ConversionPipeline?

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
        // 小さめのバッファにして、止めたときに取りこぼす末尾を短くする。
        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { buffer, _ in
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
        self.pipeline = pipeline
    }

    /// マイクを止め、変換器と PCMChunker に残った末尾の音声を onChunk で渡してから戻る。
    func stop() {
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        pipeline?.finish()
        self.engine = nil
        self.pipeline = nil
    }
}

/// オーディオスレッドの process と、止めるときの finish の両方から使うので、lock で守る。
private final class ConversionPipeline: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat
    private let onChunk: @Sendable (Data, Float) -> Void
    private let lock = NSLock()
    private var chunker = PCMChunker()
    private var finished = false

    init(converter: AVAudioConverter, outputFormat: AVAudioFormat,
         onChunk: @escaping @Sendable (Data, Float) -> Void) {
        self.converter = converter
        self.outputFormat = outputFormat
        self.onChunk = onChunk
    }

    func process(_ buffer: AVAudioPCMBuffer) {
        lock.withLock {
            guard !finished else { return }
            let ratio = outputFormat.sampleRate / buffer.format.sampleRate
            let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
            var supplied = false
            deliver(convert(capacity: capacity) { inputStatus in
                if supplied {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                supplied = true
                inputStatus.pointee = .haveData
                return buffer
            })
        }
    }

    /// 変換器の中に残ったサンプルを吐き出させ、PCMChunker の端数も渡す。
    func finish() {
        lock.withLock {
            guard !finished else { return }
            finished = true
            deliver(convert(capacity: 1024) { inputStatus in
                inputStatus.pointee = .endOfStream
                return nil
            })
            if let rest = chunker.flush() { onChunk(rest.data, rest.rms) }
        }
    }

    private func convert(capacity: AVAudioFrameCount,
                         input: @escaping (UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer?) -> [Int16] {
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return [] }
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in input(inputStatus) }
        guard status != .error, let samples = output.int16ChannelData, output.frameLength > 0 else { return [] }
        return Array(UnsafeBufferPointer(start: samples[0], count: Int(output.frameLength)))
    }

    private func deliver(_ samples: [Int16]) {
        guard !samples.isEmpty else { return }
        for chunk in chunker.append(samples) {
            onChunk(chunk.data, chunk.rms)
        }
    }
}
