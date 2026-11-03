import Foundation
import VoiceInputCore

struct SourceCase: Decodable {
    let sentence: String
    let word: String
    /// 正解の置き換え元。直しではない（見つからないのが正しい）ケースは null。
    let source: String?
    let set: String
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let usage = "usage: source-eval [--cases <path>] [--runs <n>] [--set tuning|holdout] [--strategy free|choose|openai ...] [--verbose]"
let args = Array(CommandLine.arguments.dropFirst())

func values(of option: String) -> [String] {
    var result: [String] = []
    for (i, a) in args.enumerated() where a == option {
        guard i + 1 < args.count, !args[i + 1].hasPrefix("--") else { fail(usage) }
        result.append(args[i + 1])
    }
    return result
}

let casesPath = values(of: "--cases").first ?? "Eval/source-cases.json"
let runs = values(of: "--runs").first.flatMap(Int.init) ?? 3
let onlySet = values(of: "--set").first
let verbose = args.contains("--verbose")
guard runs >= 1 else { fail(usage) }

let all: [SourceCase]
do {
    all = try JSONDecoder().decode([SourceCase].self, from: Data(contentsOf: URL(fileURLWithPath: casesPath)))
} catch {
    fail("Cannot read \(casesPath): \(error)")
}
let cases = all.filter { onlySet == nil || $0.set == onlySet }

// 測る方式。OpenAI は OPENAI_API_KEY と OPENAI_MODEL があるときだけ。
let requested = values(of: "--strategy")
var locators: [(name: String, locator: SourceLocator)] = []
for strategy in OnDeviceSourceLocator.Strategy.allCases where requested.isEmpty || requested.contains(strategy.rawValue) {
    guard let locator = OnDeviceSourceLocator.make(strategy: strategy) else {
        fail("端末内AIを使えません")
    }
    locators.append((strategy.rawValue, locator))
}
if requested.contains("openai") {
    let env = ProcessInfo.processInfo.environment
    guard let locator = OpenAISourceLocator.make(apiKey: env["OPENAI_API_KEY"] ?? "", model: env["OPENAI_MODEL"] ?? "") else {
        fail("openai は OPENAI_API_KEY と OPENAI_MODEL が要ります")
    }
    locators.append(("openai", locator))
}
guard !locators.isEmpty else { fail(usage) }

func seconds(_ d: Duration) -> Double {
    Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
}

/// アプリ（CorrectionRegistrar）と同じ確認。答えが文にあり、正しい語と違うときだけ使う。
func usable(_ answer: String?, _ c: SourceCase) -> String? {
    guard let answer, !answer.isEmpty, answer != c.word, c.sentence.contains(answer) else { return nil }
    return answer
}

print("ケース \(cases.count) 件 × \(runs) 回（set: \(onlySet ?? "すべて")）")
let clock = ContinuousClock()
for (name, locator) in locators {
    var correct = 0, wrong = 0, missed = 0, falseHit = 0, trueNone = 0, errors = 0
    var latencies: [Double] = []
    var lines: [String] = []
    for c in cases {
        var got: [String] = []
        for _ in 0..<runs {
            let start = clock.now
            do {
                let answer = usable(try await locator.locate(word: c.word, in: c.sentence), c)
                latencies.append(seconds(clock.now - start))
                got.append(answer ?? "(なし)")
                switch (c.source, answer) {
                case (let e?, let a?) where e == a: correct += 1
                case (_?, _?): wrong += 1
                case (_?, nil): missed += 1
                case (nil, _?): falseHit += 1
                case (nil, nil): trueNone += 1
                }
            } catch {
                errors += 1
            }
        }
        let expected = c.source ?? "(なし)"
        let ok = got.allSatisfy { $0 == expected }
        if verbose || !ok {
            lines.append("\(ok ? "ok " : "NG ")[\(c.set)] \(c.word)\t期待: \(expected)\t答え: \(got.joined(separator: " / "))")
        }
    }
    let total = correct + wrong + missed + falseHit + trueNone
    func pct(_ n: Int) -> String { total == 0 ? "-" : String(format: "%.1f%% (%d/%d)", Double(n) / Double(total) * 100, n, total) }
    print("\n==== \(name) ====")
    lines.forEach { print($0) }
    print("正解（置き換え元が合う／なしが合う）: \(pct(correct + trueNone))")
    print("  置き換え元を当てた: \(correct)  直しではないのに「なし」と答えた: \(trueNone)")
    print("間違った置き換え元を答えた（誤って置き換えが登録される）: \(wrong + falseHit) 回（うち直しではない文: \(falseHit)）")
    print("見つけられなかった（ヒントだけの登録になる）: \(missed) 回")
    if errors > 0 { print("エラー: \(errors) 回") }
    let sorted = latencies.sorted()
    if let last = sorted.last {
        print(String(format: "応答時間（秒）: 中央値 %.2f / 最大 %.2f", sorted[sorted.count / 2], last))
    }
}

// choose 方式の上限。候補に正解が入っていなければ、選びようがない。
let expectedCases = cases.filter { $0.source != nil }
let recalled = expectedCases.filter { OnDeviceSourceLocator.candidates(word: $0.word, in: $0.sentence).contains($0.source!) }
print("\n候補に正解が入っている割合（choose の上限）: \(recalled.count)/\(expectedCases.count)")
for c in expectedCases where !recalled.contains(where: { $0.sentence == c.sentence }) {
    print("  入っていない: \(c.source!) ← 候補 \(OnDeviceSourceLocator.candidates(word: c.word, in: c.sentence))")
}
