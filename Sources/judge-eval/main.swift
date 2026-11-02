import Foundation
import VoiceInputCore

struct JudgeCase: Decodable {
    let word: String
    /// 普通の言葉なら true（正解ラベル）。
    let common: Bool
    let category: String
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let usage = "usage: judge-eval [--cases <path>] [--runs <n>]"
let args = Array(CommandLine.arguments.dropFirst())

func value(of option: String) -> String? {
    guard let i = args.firstIndex(of: option) else { return nil }
    guard i + 1 < args.count, !args[i + 1].hasPrefix("--") else { fail(usage) }
    return args[i + 1]
}

let casesPath = value(of: "--cases") ?? "Eval/judge-cases.json"
let runs = value(of: "--runs").flatMap(Int.init) ?? 3
guard runs >= 1 else { fail(usage) }

let cases: [JudgeCase]
do {
    cases = try JSONDecoder().decode([JudgeCase].self, from: Data(contentsOf: URL(fileURLWithPath: casesPath)))
} catch {
    fail("Cannot read \(casesPath): \(error)")
}

let made = OnDeviceJudge.make()
guard let judge = made.judge else {
    if case .unavailable(let reason) = made.availability { fail("端末内AIを使えません: \(reason)") }
    fail("端末内AIを使えません")
}

struct Result {
    let item: JudgeCase
    var answers: [Bool] = []
    var errors = 0
    var latencies: [Double] = []
    var correct: Int { answers.filter { $0 == item.common }.count }
}

func seconds(_ d: Duration) -> Double {
    Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
}

let clock = ContinuousClock()
var results = cases.map { Result(item: $0) }
for i in results.indices {
    for _ in 0..<runs {
        let start = clock.now
        do {
            let answer = try await judge.isCommonWord(results[i].item.word)
            results[i].answers.append(answer)
            results[i].latencies.append(seconds(clock.now - start))
        } catch {
            results[i].errors += 1
        }
    }
    let r = results[i]
    let mark = r.correct == r.answers.count && r.errors == 0 ? "ok " : "NG "
    print("\(mark)\(r.item.word)\t期待: \(r.item.common ? "普通" : "普通でない")\t正解 \(r.correct)/\(runs)")
}

func percent(_ n: Int, _ d: Int) -> String {
    d == 0 ? "-" : String(format: "%.1f%% (%d/%d)", Double(n) / Double(d) * 100, n, d)
}

print("\n== 全体（1 回ずつの答えを数える。語 \(cases.count) × \(runs) 回）==")
let totalAnswers = results.reduce(0) { $0 + $1.answers.count }
print("正解率: \(percent(results.reduce(0) { $0 + $1.correct }, totalAnswers))")
let totalErrors = results.reduce(0) { $0 + $1.errors }
if totalErrors > 0 { print("エラー: \(totalErrors) 回（正解率には含めない）") }

print("\n== カテゴリ別 ==")
for category in Dictionary(grouping: results, by: { $0.item.category }).keys.sorted() {
    let group = results.filter { $0.item.category == category }
    print("\(category)\t\(percent(group.reduce(0) { $0 + $1.correct }, group.reduce(0) { $0 + $1.answers.count }))")
}

// 普通の言葉を「普通でない」と答えると、置き換えが登録されて別の場面で書き換わる。こちらのほうが困る。
let harmful = results.reduce(0) { $0 + ($1.item.common ? $1.answers.filter { !$0 }.count : 0) }
let benign = results.reduce(0) { $0 + ($1.item.common ? 0 : $1.answers.filter { $0 }.count) }
print("\n== 間違いの向き ==")
print("普通の言葉を「普通でない」と答えた（置き換えが誤って登録される）: \(harmful) 回")
print("普通でない言葉を「普通」と答えた（ヒントだけの登録になる）: \(benign) 回")

let unstable = results.filter { Set($0.answers).count > 1 }
print("\n== 答えがぶれた語（\(unstable.count) 語）==")
for r in unstable { print("\(r.item.word)\t普通 \(r.answers.filter { $0 }.count)/\(r.answers.count)") }

let latencies = results.flatMap(\.latencies).sorted()
if !latencies.isEmpty {
    func p(_ q: Double) -> Double { latencies[min(latencies.count - 1, Int(Double(latencies.count) * q))] }
    let slow = latencies.filter { $0 > 1.5 }.count
    print("\n== 応答時間（秒）==")
    print(String(format: "中央値 %.2f / 95%% %.2f / 最大 %.2f", p(0.5), p(0.95), latencies.last!))
    print("1.5 秒を超えた: \(slow) / \(latencies.count)（アプリでは時間切れで「普通の言葉」扱いになる）")
}
