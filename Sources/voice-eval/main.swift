import Combine
import Foundation
import VoiceInputCore
import VoiceInputLocal

struct EvalCase: Decodable {
    let audio: String
    let expected: String
}

struct EvalFailure: Error, CustomStringConvertible {
    let description: String
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let usage = "usage: voice-eval <Eval dir> [--no-glossary] [--glossary <path>] [--engine soniox|local] [--install-local]"
let args = Array(CommandLine.arguments.dropFirst())
let noGlossary = args.contains("--no-glossary")
let installLocal = args.contains("--install-local")

func value(of option: String) -> String? {
    guard let i = args.firstIndex(of: option) else { return nil }
    guard i + 1 < args.count, !args[i + 1].hasPrefix("--") else { fail(usage) }
    return args[i + 1]
}

let engine = value(of: "--engine") ?? "soniox"
guard engine == "soniox" || engine == "local" else { fail(usage) }
let glossaryPath = value(of: "--glossary")
let optionValues = Set([glossaryPath, value(of: "--engine")].compactMap { $0 })
guard let dirArg = args.first(where: { !$0.hasPrefix("--") && !optionValues.contains($0) }) else {
    fail(usage)
}
let evalDir = URL(fileURLWithPath: dirArg, isDirectory: true)

// ローカルでは Soniox の API キーを読まない
let apiKey: String?
if engine == "soniox" {
    guard let key = ProcessInfo.processInfo.environment["SONIOX_API_KEY"] ?? KeychainStore.loadAPIKey() else {
        fail("No API key: set SONIOX_API_KEY or store one in the keychain.")
    }
    apiKey = key
} else {
    apiKey = nil
}

let cases: [EvalCase]
do {
    cases = try JSONDecoder().decode(
        [EvalCase].self, from: Data(contentsOf: evalDir.appendingPathComponent("cases.json")))
} catch {
    fail("Cannot read cases.json: \(error)")
}

let settings = JSONStore(
    url: AppPaths.supportDirectory.appendingPathComponent("settings.json"),
    defaultValue: AppSettings.default
).load()
let glossary: Glossary
if noGlossary {
    glossary = .empty
} else if let glossaryPath {
    // 指定のファイルは読むだけ（JSONStore は壊れたファイルを移すので使わない）
    do {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        glossary = try decoder.decode(Glossary.self, from: Data(contentsOf: URL(fileURLWithPath: glossaryPath)))
    } catch {
        fail("Cannot read glossary \(glossaryPath): \(error)")
    }
} else {
    glossary = JSONStore(
        url: AppPaths.supportDirectory.appendingPathComponent("glossary.json"),
        defaultValue: Glossary.empty
    ).load()
}
let pipeline = TextPipeline(fillers: FillerRemover(fillers: settings.fillers), glossary: glossary)
let config = SonioxConfig(languageHints: settings.languageHints, terms: glossary.contextTerms().terms)
let factory = apiKey.map { SonioxSessionFactory(apiKey: $0) }

func recognizeWithSoniox(pcm: Data) async throws -> String {
    let session = factory!.makeSession()
    do {
        try await session.start(config: config)
        let stream = session.responses
        var offset = 0
        while offset < pcm.count {
            let end = min(offset + 3200, pcm.count)
            try await session.sendAudio(pcm.subdata(in: offset..<end))
            offset = end
            try await Task.sleep(for: .milliseconds(20))
        }
        try await session.finalize()
        let text = try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                var assembler = TranscriptAssembler()
                for try await response in stream {
                    if assembler.ingest(response).reachedFin { break }
                }
                return assembler.finalText
            }
            group.addTask {
                try await Task.sleep(for: .seconds(10))
                throw SonioxError.finTimeout
            }
            defer { group.cancelAll() }
            return try await group.next() ?? ""
        }
        await session.finish()
        return text
    } catch {
        // 送信側の失敗は接続断としか分からないので、受信側が持つ本当のエラー (401 など) を優先する。
        var reported = error
        if (error as? SonioxError) == .connectionClosed {
            do { for try await _ in session.responses {} } catch { reported = error }
        }
        await session.finish()
        throw reported
    }
}

let base = LocalModelLayout.downloadBase(supportDirectory: AppPaths.supportDirectory)
let recognize: (Data) async throws -> String
if engine == "local" {
    if installLocal, !LocalModelLayout.isInstalled(base: base) {
        let manager = LocalModelManager(base: base)
        var lastShown = ""
        let watch = manager.$status.sink { status in
            let line: String
            switch status {
            case let .downloading(fraction): line = "downloading \(Int(fraction * 100))%"
            case .preparing: line = "preparing (first load compiles the models)"
            default: line = "\(status)"
            }
            if line != lastShown {
                lastShown = line
                print(line)
            }
        }
        await manager.download()
        watch.cancel()
        guard manager.status == .ready else { fail("Local model install failed: \(manager.status)") }
    }
    guard LocalModelLayout.isInstalled(base: base) else {
        fail("Local model is not installed in \(base.path). Run with --install-local.")
    }
    // 無音の判定はせず、認識部品を直接呼ぶ
    let transcriber = WhisperKitTranscriber(base: base)
    recognize = { pcm in
        try await transcriber.transcribe(pcm: pcm, languageHints: config.languageHints, terms: config.context.terms)
    }
} else {
    recognize = recognizeWithSoniox
}

var scores: [Double] = []
for (index, c) in cases.enumerated() {
    let label = String(format: "%03d", index + 1)
    let started = Date()
    do {
        let pcm = try Data(contentsOf: evalDir.appendingPathComponent(c.audio))
        let raw = try await recognize(pcm)
        let actual = pipeline.process(raw).text
        let score = CharacterAccuracy.score(expected: c.expected, actual: actual)
        scores.append(score)
        let time = engine == "local" ? String(format: "  (%.2fs)", Date().timeIntervalSince(started)) : ""
        print("\(label)  \(String(format: "%.3f", score))  \(c.expected) → \(actual)\(time)")
    } catch {
        scores.append(0)
        print("\(label)  0.000  \(c.expected) → ERROR: \(error)")
    }
}

// ローカルの目標は設計書 9 の全体 0.91
let target = engine == "local" ? 0.91 : 0.95
let mean = scores.isEmpty ? 0 : scores.reduce(0, +) / Double(scores.count)
print("mean: \(String(format: "%.3f", mean))  target \(String(format: "%.2f", target)): \(mean >= target ? "PASS" : "FAIL")")
