import Foundation
import VoiceInputCore

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

let args = Array(CommandLine.arguments.dropFirst())
let noGlossary = args.contains("--no-glossary")
guard let dirArg = args.first(where: { !$0.hasPrefix("--") }) else {
    fail("usage: voice-eval <Eval dir> [--no-glossary]")
}
let evalDir = URL(fileURLWithPath: dirArg, isDirectory: true)

guard let apiKey = ProcessInfo.processInfo.environment["SONIOX_API_KEY"] ?? KeychainStore.loadAPIKey() else {
    fail("No API key: set SONIOX_API_KEY or store one in the keychain.")
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
let glossary = noGlossary
    ? Glossary.empty
    : JSONStore(
        url: AppPaths.supportDirectory.appendingPathComponent("glossary.json"),
        defaultValue: Glossary.empty
    ).load()
let pipeline = TextPipeline(fillers: FillerRemover(fillers: settings.fillers), glossary: glossary)
let config = SonioxConfig(languageHints: settings.languageHints, terms: glossary.contextTerms().terms)
let factory = SonioxSessionFactory(apiKey: apiKey)

func recognize(pcm: Data) async throws -> String {
    let session = factory.makeSession()
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

var scores: [Double] = []
for (index, c) in cases.enumerated() {
    let label = String(format: "%03d", index + 1)
    do {
        let pcm = try Data(contentsOf: evalDir.appendingPathComponent(c.audio))
        let raw = try await recognize(pcm: pcm)
        let actual = pipeline.process(raw).text
        let score = CharacterAccuracy.score(expected: c.expected, actual: actual)
        scores.append(score)
        print("\(label)  \(String(format: "%.3f", score))  \(c.expected) → \(actual)")
    } catch {
        scores.append(0)
        print("\(label)  0.000  \(c.expected) → ERROR: \(error)")
    }
}

let mean = scores.isEmpty ? 0 : scores.reduce(0, +) / Double(scores.count)
print("mean: \(String(format: "%.3f", mean))  target 0.95: \(mean >= 0.95 ? "PASS" : "FAIL")")
