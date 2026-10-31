# オフラインモード Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 設定で「ローカル」を選ぶと、文字起こしを WhisperKit で Mac の中だけで行い、Soniox にも OpenAI にもつながない。

**Architecture:** ローカルの認識は、既存の `TranscriptionSession` を実装する `LocalTranscriptionSession`（`VoiceInputCore`、依存なし）として載せる。録音中は音声をためておき、`finalize()` で `LocalTranscriber`（プロトコル）に渡し、結果を Soniox と同じ「確定トークン + `<fin>`」の形で返す。そのため `SessionController` の変更は最小で済む。WhisperKit を使う実装（`WhisperKitTranscriber`、`LocalModelManager`）は別ターゲット `VoiceInputLocal` に置き、`VoiceInputCore` を依存なしのまま保つ。

**Tech Stack:** Swift 6、SwiftPM、XcodeGen、WhisperKit 1.1.1（モデル `large-v3-v20240930_turbo`）、Swift Testing。

**Spec:** `docs/superpowers/specs/2026-10-31-offline-mode-design.md`

**Branch:** `feature/offline-mode`（`feature/offline-mode-design` から切る。`main` への直接 push は禁止。PR 経由でマージし、マージ後にブランチを削除する）。コミットメッセージは日本語の `feat:` / `test:` / `docs:` 形式で、末尾に `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>` を付ける。

## Global Constraints

- `VoiceInputCore` に外部の依存を入れない（モデルなしでテストできること）。WhisperKit は `VoiceInputLocal` だけが使う。
- アプリの最低 macOS は 14 のまま（`project.yml`）。WhisperKit の最低は macOS 13 なので、ローカルモードを新しい macOS に限る必要はない。
- 既定の文字起こしは「Soniox」。`settings.json` に値がなければ Soniox として読む。Soniox を選んでいる人の動きを変えない。
- ローカルを選んでいる間、Soniox のセッションも OpenAI の部品（`locator`、`extractor`）も作らない。通信が起こるのは、設定画面の「ダウンロード」だけ。
- ローカルの文字の入れ方は常に「話し終えてからまとめて」。Soniox の API キーは要らない。
- モデルは `large-v3-v20240930_turbo` の 1 種類（約 1.5GB）。保存場所は `~/Library/Application Support/VoiceInput/Models/`。
- 音が一度も出なかった録音は認識に渡さない。しきい値は `SilenceDetector` の既定（0.01）と同じものを使う。
- 画面の文言は日本語。置き換えの判断は今と同じ端末内AI（Foundation Models）。

## Review Focus

仕様が暗に求めているが、どの Task のテストにも自然には出てこない、使う人が踏みやすい条件。各行のテストは、担当する Task の中に入れてある。

1. 一度も音が出なかった録音（無音のまま止めた）→ 何も入力されず、履歴にも残らず、エラーも出ない（Task 2）。
2. 認識が失敗した → 「文字起こしに失敗しました」を出し、何も入力せず、履歴にも残さない。「ネットワークに接続できません」は出さない（Task 2）。
3. モデルが途中までしかない（ダウンロードが途中で止まった、トークナイザーだけ無い）→ 「使える」と判定されず、読み込みのためのダウンロードも試みない（Task 4）。
4. Soniox の API キーがないままローカルを選んでいる → 録音できる。モデルが無いときだけ録音を断る（Task 3）。
5. 30 秒を超える長い発話 → 文字が途中で切れない（自動テストでは確かめられない。Task 7 の手順で確かめる）。

---

### Task 1: 文字起こしエンジンの設定

**Files:**
- Modify: `Sources/VoiceInputCore/Storage/AppSettings.swift`
- Test: `Tests/VoiceInputCoreTests/StorageTests.swift`

**Interfaces:**
- Produces: `public enum TranscriptionEngine: String, Codable, Sendable { case soniox, local }`、`AppSettings.engine: TranscriptionEngine`（既定 `.soniox`）、`AppSettings.allowsCloud: Bool`（`engine == .soniox`）。

- [ ] **Step 1: 失敗するテストを書く**（`StorageTests.swift` の既存の書き方に合わせる）
  - `engineDefaultsToSoniox`: `AppSettings.default.engine == .soniox`
  - `settingsWithoutEngineDecodeAsSoniox`: `{}` をデコードすると `engine == .soniox`
  - `engineRoundTrips`: `.local` を保存して読み直すと `.local`
  - `localEngineDisallowsCloud`: `AppSettings(engine: .local).allowsCloud == false`、`.soniox` は `true`
- [ ] **Step 2: 実行して失敗を確かめる** — `swift test --filter StorageTests`、期待: コンパイルエラー（`engine` が無い）。
- [ ] **Step 3: 実装する** — `AppSettings` の既存の流儀どおり、`init` の引数（既定 `.soniox`）、`init(from:)` の `decodeIfPresent ?? d.engine`、`default` に追加する。
- [ ] **Step 4: 実行して通ることを確かめる** — `swift test` が全部通る。
- [ ] **Step 5: コミット** — `feat: 文字起こしエンジンの設定（Soniox / ローカル）を追加`

---

### Task 2: LocalTranscriptionSession と SessionController の変更

**Files:**
- Create: `Sources/VoiceInputCore/Local/LocalTranscriber.swift`（プロトコルとエラー）
- Create: `Sources/VoiceInputCore/Local/LocalTranscriptionSession.swift`
- Create: `Sources/VoiceInputCore/Local/EngineSessionFactory.swift`
- Modify: `Sources/VoiceInputCore/Soniox/SonioxSession.swift`（`finalizeTimeout` の追加）
- Modify: `Sources/VoiceInputCore/Session/SilenceDetector.swift`（`defaultThreshold` を公開）
- Modify: `Sources/VoiceInputCore/Session/SessionController.swift`
- Modify: `Tests/VoiceInputCoreTests/Fakes.swift`
- Create: `Tests/VoiceInputCoreTests/LocalTranscriptionSessionTests.swift`
- Modify: `Tests/VoiceInputCoreTests/SessionControllerTests.swift`

**Interfaces:**
- Produces:
  - `public protocol LocalTranscriber: Sendable { func transcribe(pcm: Data, languageHints: [String], terms: [String]) async throws -> String }`（`pcm` は 16kHz モノラル s16le）
  - `public struct LocalTranscriptionError: Error, Equatable { public let message: String; public init(message: String) }`
  - `public final class LocalTranscriptionSession: TranscriptionSession, @unchecked Sendable`、`public init(transcriber: LocalTranscriber)`、`var finalizeTimeout: Duration`（15 秒 + 録音の長さの 3 倍。値は私の判断で、`voice-eval` の実測で調整してよい）
  - `public struct EngineSessionFactory: TranscriptionSessionFactory`、`public init(settings: @escaping @Sendable () -> AppSettings, soniox: @escaping @Sendable () -> TranscriptionSession, local: @escaping @Sendable () -> TranscriptionSession)`。`makeSession()` は録音のたびに `settings().engine` を読み、`.soniox` なら `soniox()`、`.local` なら `local()` だけを呼ぶ（選ばれなかった側のクロージャは呼ばない）。
  - `TranscriptionSession` に `var finalizeTimeout: Duration { get }` を追加し、拡張で既定値 `.seconds(5)`（Soniox は今の挙動のまま）
  - `SilenceDetector.defaultThreshold: Float`（0.01。`init` の既定値もこれを使う）
  - `SessionError.transcription`（`message` は「文字起こしに失敗しました」）。`SessionError.init(_ error:)` は `LocalTranscriptionError` を `.transcription` にする。
- Consumes: Task 1 の `AppSettings.engine`。

動き（テストで決まらない部分）:
- `start(config:)` は何もせず戻る（`config.languageHints` と `config.context.terms` を覚える）。`sendAudio` は音声をためる。このとき各チャンクの RMS（`PCMChunker.rms`）を計算し、`SilenceDetector.defaultThreshold` 以上が一度でもあったかを覚える。
- `finalize()` は認識を別のタスクで始めてすぐ戻る。音が一度も出ていなければ認識せず、`<fin>` だけを返す。認識に成功したら、空でなければ確定トークン 1 つ、続けて `<fin>` トークンを `responses` に流す。失敗したら `LocalTranscriptionError` で `responses` を終える。
- `finish()` は `responses` を終える（何度呼んでもよい）。
- `SessionController`: `waitForFin` の待ち時間を `session.finalizeTimeout` にする。`r.realtime` は `settings.insertionMode == .realtime && settings.engine == .soniox`。

- [ ] **Step 1: テスト用の部品を足す** — `Fakes.swift` に `FakeLocalTranscriber`（`result: Result<String, Error>` を設定でき、呼ばれた引数を `calls` に残す）と、`FakeSession` に `var finalizeTimeout: Duration = .seconds(5)` を足す。`Harness` の初期化に `sessions: TranscriptionSessionFactory? = nil` を足す（渡せば `FakeFactory` の代わりに使う）。音声のヘルパー: `loudPCM()`（振幅 8000 の 1600 サンプル）と `silentPCM()`（0 の 1600 サンプル）。
- [ ] **Step 2: 失敗するテストを書く**（`LocalTranscriptionSessionTests.swift`）
  - `transcribesBufferedAudioAfterStop`: 大きい音のチャンクを 2 つ送って止めると、`inserter.inserted == ["こんにちは"]`、`transcriber.calls.count == 1`、`calls[0].pcm.count == 6400`、`calls[0].hints == settings.languageHints`、`history.count == 1`
  - `neverLoudRecordingIsNotTranscribed`: 無音のチャンクだけで止めると、`transcriber.calls.isEmpty`、`inserted.isEmpty`、`history.isEmpty`、`errors.isEmpty`、最後の状態は `.idle`（Review Focus 1）
  - `transcriberFailureShowsTranscriptionError`: 失敗させると、`errors == [.transcription]`、`inserted.isEmpty`、`history.isEmpty`、状態に `.error("文字起こしに失敗しました")` が現れる（Review Focus 2）
  - `localEngineInsertsInOneBatch`: `settings.insertionMode = .realtime`、`settings.engine = .local`、結果 `"一つ目。二つ目。"` で、`inserted == ["一つ目。二つ目。"]`（Step 3 の前にこのテストが失敗しないなら、リアルタイムとの違いが出る形に強める）
  - `localEngineNeverBuildsSonioxSession`: `EngineSessionFactory` で、`engine = .local` のとき `soniox` のクロージャが 0 回、`local` が 1 回呼ばれる。`.soniox` に変えて作り直すと、逆になる
  - `finalizeTimeoutGrowsWithAudio`: 音声なしで `finalizeTimeout >= .seconds(15)`、10 秒分（320000 バイト）を送ると `>= .seconds(45)`
  - `SessionControllerTests.swift` に `usesSessionFinalizeTimeout`: `FakeSession.finalizeTimeout = .seconds(60)` にし、止めてから 5.1 秒進めても `.processing` のまま。その後 `<fin>` を返すと、エラーなしで `.idle` になる
- [ ] **Step 3: 実行して失敗を確かめる** — `swift test --filter LocalTranscriptionSessionTests`、期待: コンパイルエラー。
- [ ] **Step 4: 実装する** — 上の「動き」のとおり。`SessionError` の `message` を足したら、`AppCoordinator.guide(for:)` の `switch` も網羅させる（`.transcription` は何もしない）。
- [ ] **Step 5: 実行して通ることを確かめる** — `swift test` が全部通る（既存の Soniox 向けテストを含む）。
- [ ] **Step 6: コミット** — `feat: ローカル認識用のセッションを追加し、認識待ちをセッションごとに変える`

---

### Task 3: 録音を始めてよいかの判断（モデルの有無）

**Files:**
- Modify: `Sources/VoiceInputCore/Session/RecordingGate.swift`
- Test: `Tests/VoiceInputCoreTests/RecordingGateTests.swift`

**Interfaces:**
- Produces: `RecordingGate.Rejection.localModelNotReady`、`decide(_:hasAPIKey:secureInput:localModelReady: Bool = true)`（既存の呼び出しは変わらない）。

動き: `.beginBuffering` で、`hasAPIKey` が false なら今までどおり。そうでなく `localModelReady` が false なら、`.missingAPIKey` と同じ道（押下を覚えて、`.confirm` で `.localModelNotReady` として断る。`.cancel` なら断らずに静かに戻る）。

- [ ] **Step 1: 失敗するテストを書く**
  - `modelNotReadyRejectsOnConfirm`: `hasAPIKey: true, localModelReady: false` で `.beginBuffering` は `forward == nil`。続く `.confirm(.toggle)` は `rejection == .localModelNotReady`、`forward == nil`
  - `modelNotReadyCancelIsQuiet`: `.beginBuffering` の後に `.cancel` で `rejection == nil`、`isQuiet == true`
  - `recordsWithoutAPIKeyWhenCallerPassesTrue`: `hasAPIKey: true, localModelReady: true` で `.beginBuffering` は `forward == .beginBuffering`（呼び出し側がローカルのときに `hasAPIKey: true` を渡す前提の確認。Review Focus 4）
- [ ] **Step 2: 実行して失敗を確かめる** — `swift test --filter RecordingGateTests`、期待: コンパイルエラー。
- [ ] **Step 3: 実装する** — 上の「動き」のとおり。
- [ ] **Step 4: 実行して通ることを確かめる** — `swift test --filter RecordingGateTests` が通る。
- [ ] **Step 5: コミット** — `feat: ローカルのモデルが使えないときは録音を始めない`

---

### Task 4: ローカルの部品（保存場所、用語集のプロンプト、言語の選び方）

**Files:**
- Create: `Sources/VoiceInputCore/Local/LocalModelLayout.swift`
- Create: `Sources/VoiceInputCore/Local/PromptTerms.swift`
- Create: `Sources/VoiceInputCore/Local/LanguageChoice.swift`
- Test: `Tests/VoiceInputCoreTests/LocalModelLayoutTests.swift`、`PromptTermsTests.swift`、`LanguageChoiceTests.swift`

**Interfaces:**
- Produces:
  - `public enum LocalModelStatus: Equatable, Sendable { case notInstalled, downloading(fraction: Double), preparing, ready, failed(String) }`
  - `public enum LocalModelLayout`: `static let variant = "large-v3-v20240930_turbo"`、`static func downloadBase(supportDirectory: URL) -> URL`（`<support>/Models`）、`static func modelFolder(base: URL) -> URL`（`<base>/models/argmaxinc/whisperkit-coreml/openai_whisper-large-v3-v20240930_turbo`）、`static func tokenizerFolder(base: URL) -> URL`（`<base>/models/openai/whisper-large-v3`）、`static func isInstalled(base: URL) -> Bool`
  - `public enum PromptTerms { public static func build(from terms: [String], maxChars: Int = 120) -> String }`（上限 120 文字は私の判断で、`voice-eval` の実測で調整してよい）
  - `public enum LanguageChoice { public static func pick(hints: [String], probabilities: [String: Float]) -> String? }`

動き:
- `isInstalled` は、モデルのフォルダに `AudioEncoder.mlmodelc`、`TextDecoder.mlmodelc`、`MelSpectrogram.mlmodelc`、`config.json` があり、かつトークナイザーのフォルダに `tokenizer.json` があるときだけ true（試作で観察した配置。Task 5 で実際の配置と突き合わせる）。
- `PromptTerms.build` は用語を渡された順（最近使った順）に `, ` でつなぎ、`maxChars` を超える手前で止める（飛ばして後ろを拾わない）。空なら空文字。
- `LanguageChoice.pick`: ヒントが 0 個なら nil、1 個ならそれ、複数なら `probabilities` の値が最も大きいヒント。値が無いヒントは比べず、すべて無ければ先頭のヒント。

- [ ] **Step 1: 失敗するテストを書く**
  - Layout（一時ディレクトリを使う）: `emptyDirectoryIsNotInstalled`、`modelWithoutTokenizerIsNotInstalled`（Review Focus 3）、`modelMissingEncoderIsNotInstalled`、`completeLayoutIsInstalled`
  - PromptTerms: `joinsInGivenOrder`（`["A","B"]` → `"A, B"`）、`stopsBeforeExceedingBudget`（`maxChars: 5`、`["abc","de","f"]` → `"abc"`）、`emptyTermsGiveEmptyPrompt`
  - LanguageChoice: `noHintsReturnsNil`、`singleHintIsUsed`、`multipleHintsPickMostLikely`（`["ja","en"]`、`["en": -0.1, "ja": -2.0]` → `"en"`）、`hintMissingFromProbabilitiesIsSkipped`、`noProbabilitiesFallsBackToFirstHint`
- [ ] **Step 2: 実行して失敗を確かめる** — `swift test --filter "LocalModelLayoutTests|PromptTermsTests|LanguageChoiceTests"`、期待: コンパイルエラー。
- [ ] **Step 3: 実装する** — 上の「動き」のとおり。
- [ ] **Step 4: 実行して通ることを確かめる** — 同じコマンドが通る。
- [ ] **Step 5: コミット** — `feat: ローカルモデルの保存場所、用語集のプロンプト、言語の選び方を追加`

---

### Task 5: VoiceInputLocal ターゲット（WhisperKit の実装）

**Files:**
- Modify: `Package.swift`
- Modify: `project.yml`
- Create: `Sources/VoiceInputLocal/WhisperKitTranscriber.swift`
- Create: `Sources/VoiceInputLocal/LocalModelManager.swift`
- Create: `Eval/glossary.json`
- Modify: `Sources/voice-eval/main.swift`

**Interfaces:**
- Consumes: Task 2 の `LocalTranscriber`、`LocalTranscriptionError`、Task 4 の `LocalModelLayout`、`LocalModelStatus`、`PromptTerms`、`LanguageChoice`。
- Produces:
  - `public final class WhisperKitTranscriber: LocalTranscriber`、`public init(base: URL)`。保存場所のファイルだけから読み込む（`WhisperKitConfig(modelFolder:, tokenizerFolder:, download: false)`）。初回の `transcribe` で読み込み、読み込み済みなら再利用する。
  - `@MainActor public final class LocalModelManager: ObservableObject`、`public init(base: URL)`、`@Published public private(set) var status: LocalModelStatus`、`public func refresh()`（ファイルを見て `notInstalled` か `ready` にする）、`public func download() async`、`public func delete() throws`、`public var transcriber: WhisperKitTranscriber`
- Package: `VoiceInputLocal`（ライブラリ。`VoiceInputCore` と WhisperKit に依存）、`voice-eval` が `VoiceInputLocal` に依存する。Swift 6 の並行性チェックで WhisperKit の型がエラーになる場合は、このターゲットだけ `.swiftLanguageMode(.v5)` にしてよい。`project.yml` では、アプリが `VoiceInputCore` パッケージの `VoiceInputLocal` プロダクトにも依存する。

動き:
- `transcribe`: 言語は、ヒントが複数なら WhisperKit の言語判定（音声配列を受け取る `detectLangauge(audioArray:)`。綴りが `detectLangauge` なのに注意）の確率から `LanguageChoice.pick` で選び、ヒントが 1 つならそれを使う。`DecodingOptions(task: .transcribe, language:, temperature: 0)`。用語は `PromptTerms.build` の結果をトークナイズし（先頭に空白を足し、特殊トークンを除く）、`promptTokens` と `usePrefillPrompt = true` に入れる。入力の PCM は Float に直す（`Int16` を 32768 で割る）。結果の各区間の文字列をつなぐ。失敗は `LocalTranscriptionError` に包む。
- `download()`: `WhisperKit.download(variant:downloadBase:progressCallback:)` でモデルを取り、進み具合を `.downloading(fraction:)` に反映する。続けて、トークナイザーの取得とコンパイルのため、一度 WhisperKit を読み込んで短い無音を認識する（`.preparing`）。成功したら `isInstalled` を確かめて `.ready`。失敗は `.failed(理由)`。途中で止めても、次の `refresh()` で `isInstalled` が false なら `.notInstalled` に戻る。
- `delete()`: `downloadBase` の下のモデルとトークナイザーを消し、`.notInstalled` にする。
- `Eval/glossary.json`: 試作で使った 18 語（`GitHub`、`Slack`、`meeting`、`bug`、`release`、`Google Calendar`、`Swift`、`async await`、`Docker`、`API`、`TypeScript`、`Kubernetes`、`main`、`CI`、`ブランチ`、`コミット`、`プルリクエスト`、`デプロイ`）を `terms` に持つ `Glossary` の JSON（`replacements` は空）。
- `voice-eval`: `--engine local|soniox`（既定 soniox）。local のときは Soniox の API キーを要求せず、`WhisperKitTranscriber` を直接使う（無音の判定はしない）。`--install-local` を付けると、未導入のとき `LocalModelManager.download()` を先に実行して進み具合を表示する。`--glossary <path>` で用語集のファイルを指定できる（未指定なら今のとおり Application Support の `glossary.json`）。

- [ ] **Step 1: パッケージの定義を直す** — `Package.swift` に WhisperKit（`from: "1.1.1"`）、`VoiceInputLocal` ターゲットとプロダクト、`voice-eval` の依存を足す。`project.yml` を直す。`swift build` が通る。
- [ ] **Step 2: 実装する** — 上の「動き」のとおり。
- [ ] **Step 3: 保存場所の配置を確かめる** — `swift run voice-eval Eval --engine local --install-local --glossary Eval/glossary.json` を実行する。終わったら `find ~/Library/Application\ Support/VoiceInput/Models -maxdepth 5 -type d` で、`LocalModelLayout.modelFolder` と `tokenizerFolder` の場所にファイルがあることを確かめる。違っていたら `LocalModelLayout` を実際の配置に直し、Task 4 のテストの期待も合わせる。
- [ ] **Step 4: 認識の結果を確かめる** — 同じコマンドをもう一度実行する（2 回目はダウンロードなし）。20 本すべてが `ERROR` でなく文字を返し、最初の読み込みが 2 回目以降は数秒で終わる。
- [ ] **Step 5: コミット** — `feat: WhisperKit によるローカル文字起こしとモデルの管理を追加`

---

### Task 6: アプリへの組み込み

**Files:**
- Modify: `App/AppCoordinator.swift`
- Modify: `App/Windows/SettingsView.swift`

**Interfaces:**
- Consumes: Task 1〜5 のすべて。

動き（`AppCoordinator`）:
- `LocalModelManager`（`base` は `LocalModelLayout.downloadBase(supportDirectory: AppPaths.supportDirectory)`）を持ち、`@Published` で設定画面に見せる。起動時に `refresh()` する。ローカルを選んでいて `.ready` なら、起動時に裏で 1 回短い無音を認識させてモデルを読み込んでおく（私の判断。1.5GB が常駐してよいという前提）。
- `KeychainSessionFactory` を `EngineSessionFactory` に替える。`soniox` は今の `KeychainSessionFactory` の中身（キーチェーンから読んだキーで Soniox のセッションを作る）、`local` は `LocalTranscriptionSession(transcriber: models.transcriber)`。
- `dispatch` の `gate.decide` に、`hasAPIKey: settings.engine == .local ? true : hasAPIKey` と `localModelReady: settings.engine == .soniox || models.status == .ready` を渡す。`reject` に `.localModelNotReady` を足し、「ローカルのモデルが使えません」のエラーを出して設定画面を開く。
- `makeLocator` は `settings.allowsCloud` が false なら nil を返す（`extractor` も同じ `makeLocator` の結果を使っている）。

動き（`SettingsView`）:
- 「文字起こし」のセクション（Soniox / ローカル）を、API キーのセクションの前に置く。ローカルのときは Soniox の API キーのセクションを「ローカルでは使いません」の表示に変える（消さない）。
- ローカルのセクション: 状態の表示、「ダウンロード」（押す前に約 1.5GB と書く）、「削除」、失敗の理由。
- 「文字の入れ方」は、ローカルのとき「文の区切りごと」を選べなくし、「ローカルでは、話し終えてからまとめて入力します」と書く（選択値は変えない）。
- 用語集のセクションの OpenAI の項目は、ローカルのとき「オフラインモードでは使えません」の表示に変える（消さない）。

- [ ] **Step 1: 実装する** — 上の「動き」のとおり。
- [ ] **Step 2: ビルドする** — `scripts/build.sh`（`Local.xcconfig` が必要）が通る。通らなければ、原因が `Local.xcconfig` 以外かを確かめる。
- [ ] **Step 3: 手で確かめる**（`docs/manual-checks.md` に Task 7 で項目を足す）
  - Soniox を選んだ状態で、今までどおり録音して文字が入る。
  - ローカルを選び、モデルが未導入のとき、録音を試すと断られて設定画面が開く。
  - 「ダウンロード」を押して `.ready` になり、録音して文字が入る。
  - Soniox の API キーを削除した状態でも、ローカルで録音できる。
- [ ] **Step 4: コミット** — `feat: 設定でローカルの文字起こしを選べるようにする`

---

### Task 7: 精度の確認とドキュメント

**Files:**
- Modify: `Eval/cases.json`（各ケースに `"group"` を足す）
- Modify: `Eval/README.md`
- Modify: `Sources/voice-eval/main.swift`（グループごとの平均を出す）
- Modify: `docs/manual-checks.md`
- Modify: `docs/setup.md`

**Interfaces:**
- Consumes: Task 5 の `voice-eval --engine local`。

動き:
- `cases.json`: 1〜5 を `"ja"`、6〜10 を `"en"`、11〜20 を `"mixed"`。`voice-eval` はこの `group` が付いたケースがあれば、グループごとの平均も出す（`group` は省略できる）。
- `docs/manual-checks.md`: ローカルの確認項目を足す。Wi-Fi と有線を切って動くこと。通信の監視で、ローカルを選んでいる間は何も送っていないこと（ダウンロード時を除く）。モデルの導入から最初の音声入力まで待たされすぎないこと。30 秒を超える発話で文字が切れないこと（Review Focus 5）。制限のあるネットワークでダウンロードが通るか。
- `docs/setup.md`: 「0. 始める前に」の「音声を外部に送ってよいか」に、ローカルモードを使えば送らずに済むことと、モデルのダウンロード（約 1.5GB、1 回だけ）を書く。

- [ ] **Step 1: 精度を測る** — `swift run voice-eval Eval --engine local --glossary Eval/glossary.json` を実行する。期待（仕様の合格基準）: 日本語のみと英語のみは各 0.97 以上、混在は 0.85 以上、全体は 0.91 以上。
- [ ] **Step 2: 届かなければ調整する** — 言語の選び方（`LanguageChoice` と判定）、`PromptTerms` の上限、`finalizeTimeout` の係数を見直す。調整は小さく、1 つずつ行い、結果を残す。基準に届かないまま進めない。
- [ ] **Step 3: ドキュメントを直す** — 上の「動き」のとおり。
- [ ] **Step 4: 全体のテストとビルドを確かめる** — `swift test` が全部通る。`scripts/build.sh` が通る。
- [ ] **Step 5: コミット** — `docs: ローカルモードの確認項目と手順を追加し、精度の基準を確かめる`
