# voice-input 実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 右 Option キーで録音し、Soniox のリアルタイム認識で文字起こしして、フィラーの除去と用語集の置き換えをしたうえで、どのアプリのカーソル位置にも文字を入れる macOS メニューバーアプリを作る。

**Architecture:** 画面に依存しないロジックはすべて SwiftPM パッケージ `VoiceInputCore` に入れ、`swift test` で速くテストする。対象はキーの判定、テキスト処理、Soniox とのやり取り、セッションの制御、保存処理。マイク、全体のキー入力の監視、録音中の表示、各画面は `App/` に置き、XcodeGen で生成する Xcode プロジェクトからビルドする。`SessionController` は、音声の入力、Soniox との接続、文字の入力、最前面アプリの取得をプロトコル越しに受け取る。そのため、全体の流れを偽物の部品でテストできる。

**Tech Stack:** Swift 6 / Swift Testing / SwiftUI + AppKit / AVAudioEngine / URLSessionWebSocketTask / CGEventTap / Security(Keychain) / ServiceManagement / XcodeGen / Xcode 27.1

**Spec:** `docs/superpowers/specs/2026-10-24-voice-input-design.md`

## Global Constraints

- 対象は macOS 14 以降の Apple Silicon。`MACOSX_DEPLOYMENT_TARGET = 14.0`、`ARCHS = arm64`。
- App Sandbox は使わない。Hardened Runtime はオンにし、`com.apple.security.device.audio-input` を付ける。
- Bundle ID は `dev.ykazama.VoiceInput`、Keychain の service 名も `dev.ykazama.VoiceInput`。
- `LSUIElement = YES`（Dock に出さない）。`NSMicrophoneUsageDescription` = 「音声入力のためにマイクを使用します。」
- 署名は Automatic、Apple Development（Personal Team）。チーム ID は `Local.xcconfig`（git 管理外）の `DEVELOPMENT_TEAM` に書く。
- Soniox: `wss://stt-rt.soniox.com/transcribe-websocket`、`Authorization: Bearer <key>`、`model: "stt-rt-v5"`、`audio_format: "pcm_s16le"`、`sample_rate: 16000`、`num_channels: 1`、`language_hints: ["ja","en"]`、`enable_endpoint_detection: false`、`context.general = [{"key":"domain","value":"ソフトウェア開発"}]`。
- 録音のたびに接続し、終わったらすぐ閉じる。接続してよいのは、録音だと確定した後だけ。
- 確定の指示 `{"type":"finalize"}` は、録音を止めてから 200ms 後に送る。`<fin>` が届いたら空のテキストフレーム `""` を送る。`<fin>` を待つ時間の上限は 5 秒。
- 短く押したか押し続けたかの境目は 300ms。無音による自動停止は 60 秒。履歴の保存件数は 200 件。用語ヒントに使う文字数の上限は 9,000 文字。
- 初期のフィラー一覧: `えー, えーと, えっと, あー, あのー, うーん, んー, um, uh, uhm, er, erm, hmm`。「あの」「まあ」「その」は含めない。
- 保存先: `~/Library/Application Support/VoiceInput/`（`settings.json`、`glossary.json`、`history.json`）。API キーはキーチェーンにだけ保存する。
- 音声そのものは保存しない。ユーザーのクリップボードの中身は必ず元に戻す。録音中の表示はフォーカスを奪わない。
- ブランチ運用: `main` へ直接 push しない。作業は `feature/app-implementation` ブランチで行う。

## Review Focus

1. **接続が終わる前に話し終えた短い発話**: 押してすぐ離すような短い発話でも、ためておいた音声は確定の指示より前にすべて送られ、全文が入ること。→ Task 9 `shortUtteranceBeforeConnectFlushesBufferFirst`
2. **右 Option を使う普通の操作**（Option+矢印、Option+文字）: 接続も表示も文字の入力も起きないこと。→ Task 6 `chordCancelsBeforeConfirm` と Task 9 `cancelNeverOpensSession`
3. **クリップボードに画像やファイルなど文字以外が入っている場合**: 貼り付けた後、元の中身がそのまま戻ること。→ Task 10 `restoresNonTextPasteboardItems`
4. **`<fin>` が届く前に接続が切れた、またはエラーが返った場合**: 動きが止まったままにならず、それまでに確定した文字が履歴に残り、エラーが表示されること。→ Task 9 `socketClosesBeforeFinKeepsFinalsInHistory`
5. **フィラーしか話さなかった、または無音だった場合**: 何も入れず、履歴にも残さず、そのまま待機状態に戻ること。→ Task 9 `fillerOnlyUtteranceInsertsNothing`

---

## ファイル構成

```
Package.swift                         VoiceInputCore ライブラリ、voice-eval 実行ファイル、テスト
project.yml                           XcodeGen の定義（VoiceInput.app）
Local.xcconfig.example                DEVELOPMENT_TEAM のひな形（実物の Local.xcconfig は .gitignore）
scripts/build.sh                      xcodegen と xcodebuild でビルドし、~/Applications に配置
scripts/make-eval-audio.sh            say で評価用の仮音声を作る
Sources/VoiceInputCore/
  Text/FillerRemover.swift
  Text/Glossary.swift                 Term, Replacement, Glossary
  Text/TextPipeline.swift
  Text/RealtimeChunker.swift
  Text/CharacterAccuracy.swift
  Soniox/SonioxMessages.swift         SonioxConfig, SonioxContext, SonioxToken, SonioxResponse
  Soniox/TranscriptAssembler.swift
  Soniox/SonioxSession.swift          TranscriptionSession プロトコル、SonioxWebSocketSession, SonioxError
  Input/KeyStateMachine.swift         KeyID, KeyEvent, KeyAction, RecordingMode
  Input/PasteboardInserter.swift      TextInserter, PasteboardSnapshot, InsertionError
  Session/SessionController.swift     AudioSource, FrontmostAppProvider, SessionState
  Session/SilenceDetector.swift
  Storage/AppSettings.swift
  Storage/History.swift
  Storage/JSONStore.swift
  Storage/KeychainStore.swift
Sources/voice-eval/main.swift
Tests/VoiceInputCoreTests/...         ファイルごとのテスト（*Tests.swift）、Fixtures/
App/
  VoiceInputApp.swift                 @main、MenuBarExtra
  AppCoordinator.swift                部品を組み合わせる
  AudioCapture.swift                  AudioSource の実装
  GlobalKeyMonitor.swift              CGEventTap
  FrontmostApp.swift                  FrontmostAppProvider の実装
  Overlay/OverlayPanel.swift
  Overlay/OverlayView.swift
  Windows/SettingsView.swift
  Windows/GlossaryView.swift
  Windows/HistoryView.swift
  Windows/PermissionsView.swift
  VoiceInput.entitlements
Eval/cases.json
```

---

### Task 1: ひな形（パッケージ、Xcode プロジェクト、メニューバーだけのアプリ）

**Files:**
- Create: `Package.swift`, `Sources/VoiceInputCore/VoiceInputCore.swift`, `Tests/VoiceInputCoreTests/SmokeTests.swift`, `project.yml`, `Local.xcconfig.example`, `.gitignore`, `scripts/build.sh`, `App/VoiceInputApp.swift`, `App/VoiceInput.entitlements`

**Interfaces:**
- Produces: `VoiceInputCore` ライブラリ（`public let voiceInputCoreVersion = "0.1.0"`）。アプリのターゲット `VoiceInput` は、このパッケージにローカル依存する。

- [ ] **Step 1: `git checkout main && git merge --ff-only feature/design-spec && git checkout -b feature/app-implementation`**（ローカルのみ。リモートはまだない）
- [ ] **Step 2: XcodeGen を入れる** `brew install xcodegen`。期待結果: `xcodegen --version` でバージョンが表示される。
- [ ] **Step 3: `Package.swift` を書く。** `swift-tools-version: 6.0`、`platforms: [.macOS(.v14)]`。products は library `VoiceInputCore` と executable `voice-eval`。testTarget は `VoiceInputCoreTests` で、`resources: [.copy("Fixtures")]` を付ける。`Tests/VoiceInputCoreTests/Fixtures/.gitkeep` も作る。
- [ ] **Step 4: 失敗するテストを書く** `SmokeTests.swift`: `@Test func versionIsSet() { #expect(voiceInputCoreVersion == "0.1.0") }`
- [ ] **Step 5: `swift test` を実行する。** 期待結果: `voiceInputCoreVersion` が未定義でコンパイルエラーになる。
- [ ] **Step 6: `VoiceInputCore.swift` に定数を足し、`swift test` を実行する。** 期待結果: PASS。
- [ ] **Step 7: `project.yml` を書く。** 内容: Global Constraints の値、ターゲット `VoiceInput`（application, macOS）、sources は `App`、packages は `VoiceInputCore: {path: .}`、`configFiles: {Debug: Local.xcconfig, Release: Local.xcconfig}`、`CODE_SIGN_STYLE: Automatic`、`ENABLE_HARDENED_RUNTIME: YES`、`CODE_SIGN_ENTITLEMENTS: App/VoiceInput.entitlements`、Info.plist の `LSUIElement` と `NSMicrophoneUsageDescription`。
- [ ] **Step 8: `App/VoiceInputApp.swift` を書く。** `MenuBarExtra("VoiceInput", systemImage: "mic")` に「終了」だけを置く。
- [ ] **Step 9: チーム ID を調べて `Local.xcconfig` を作る。** `defaults read com.apple.dt.Xcode IDEProvisioningTeamByIdentifier` などで Personal Team の ID を調べ、`DEVELOPMENT_TEAM = <ID>` と書く。`.gitignore` に `Local.xcconfig`、`VoiceInput.xcodeproj/`、`build/`、`.build/` を足す。
- [ ] **Step 10: `scripts/build.sh` を書く。** 内容: `xcodegen generate && xcodebuild -project VoiceInput.xcodeproj -scheme VoiceInput -configuration Debug -derivedDataPath build -allowProvisioningUpdates build`。その後、`build/Build/Products/Debug/VoiceInput.app` を `~/Applications/` にコピーする（上書き）。
- [ ] **Step 11: `scripts/build.sh` を実行する。** 期待結果: `** BUILD SUCCEEDED **`。そのうえで `codesign -dv ~/Applications/VoiceInput.app 2>&1 | grep Authority` に `Apple Development` が含まれること。証明書がなければ、このとき自動で作られる。
- [ ] **Step 12: `open ~/Applications/VoiceInput.app` を実行する。** 期待結果: メニューバーにマイクのアイコンが出て、Dock には出ない。
- [ ] **Step 13: コミットする** `git add -A && git commit -m "chore: パッケージと Xcode プロジェクトのひな形を追加"`

---

### Task 2: FillerRemover

**Files:**
- Create: `Sources/VoiceInputCore/Text/FillerRemover.swift`
- Test: `Tests/VoiceInputCoreTests/FillerRemoverTests.swift`

**Interfaces:**
- Produces: `public struct FillerRemover: Sendable { public static let defaultFillers: [String]; public init(fillers: [String]); public func clean(_ text: String) -> String }`

- [ ] **Step 1: 失敗するテストを書く。** `FillerRemover(fillers: FillerRemover.defaultFillers)` を使い、表駆動の `@Test(arguments:)` で次を確かめる。

| 入力 | 期待する出力 |
|---|---|
| `えー、これはテストです。` | `これはテストです。` |
| `これはえーと、テストです。` | `これはテストです。` |
| `えーーと、はい` | `はい` |
| `あーー、そうですね` | `そうですね` |
| `うーん。難しい` | `難しい` |
| `あの件ですが` | `あの件ですが` |
| `Um, I think so.` | `I think so.` |
| `I uh think so` | `I think so` |
| `This is a hummer` | `This is a hummer` |
| `この PR を merge して` | `この PR を merge して` |
| `えー` | `` |
| `えー、うーん。` | `` |

  あわせて `defaultFillers` が Global Constraints の 13 語と一致することを確かめる。
- [ ] **Step 2: `swift test --filter FillerRemoverTests` を実行する。** 期待結果: FAIL（型がない）。
- [ ] **Step 3: `clean` を実装する。** 処理は次のとおり。
  - フィラーを文字数の長い順に並べて処理する。
  - ASCII のフィラーは `(?i)\b<語>\b[,.]?\s*` で消す。
  - ASCII 以外のフィラーは、語の中の `ー` を `ー+` に置き換えたパターンに `[、,。]?\s*` を続けて消す。
  - 最後に整える。連続する空白は 1 つにまとめる。文の先頭に残った `、`、`,`、`。` は消す。句読点の直前の空白は消す。前後の空白は取り除く。
- [ ] **Step 4: `swift test --filter FillerRemoverTests` を実行する。** 期待結果: PASS。
- [ ] **Step 5: コミットする** `git commit -m "feat: フィラー除去を追加"`

---

### Task 3: 用語集と TextPipeline

**Files:**
- Create: `Sources/VoiceInputCore/Text/Glossary.swift`, `Sources/VoiceInputCore/Text/TextPipeline.swift`
- Test: `Tests/VoiceInputCoreTests/GlossaryTests.swift`, `Tests/VoiceInputCoreTests/TextPipelineTests.swift`

**Interfaces:**
- Consumes: `FillerRemover`（Task 2）
- Produces:
  - `public struct Term: Codable, Equatable, Hashable, Sendable { public var text: String; public var lastUsed: Date? }`
  - `public struct Replacement: Codable, Equatable, Identifiable, Sendable { public var id: UUID; public var from: String; public var to: String; public var lastUsed: Date? }`
  - `public struct Glossary: Codable, Equatable, Sendable { public var terms: [Term]; public var replacements: [Replacement]; public static let empty`
    - `public mutating func addTerm(_ text: String)`: 重複は無視する。
    - `public mutating func addCorrection(from: String, to: String)`: 置き換えを足し、`to` を用語にも足す。同じ `from` がすでにあれば `to` を上書きする。
    - `public mutating func markUsed(_ texts: Set<String>, at: Date)`
    - `public func contextTerms(budgetChars: Int = 9000) -> (terms: [String], truncated: Bool)` `}`
  - `public struct ProcessedText: Equatable, Sendable { public var text: String; public var usedTerms: Set<String> }`
  - `public struct TextPipeline: Sendable { public init(fillers: FillerRemover, glossary: Glossary); public func process(_ raw: String) -> ProcessedText }`

- [ ] **Step 1: 失敗するテストを書く。**
  - `addCorrectionAddsReplacementAndTerm`: `addCorrection(from:"ぎっとはぶ", to:"GitHub")` の後、`replacements.count == 1` かつ `terms.map(\.text) == ["GitHub"]`。
  - `addCorrectionOverwritesSameFrom`: 同じ `from` で 2 回登録すると、`replacements.count == 1` で `to` が新しい値になる。
  - `contextTermsDedupesAndPrefersRecent`: `lastUsed` が新しい順に並び、`lastUsed` が nil の語は最後に来る。重複はない。
  - `contextTermsRespectsBudget`: 1 語 100 文字の語を 100 個入れ、`budgetChars: 1000` で呼ぶ。期待結果: 返る語の文字数の合計が 1000 以下で、`truncated == true`。
  - `pipelineRemovesFillersThenReplaces`: 置き換え `ぎっとはぶ→GitHub` を登録し、入力 `えー、ぎっとはぶに push して` を処理する。期待結果: `text == "GitHubに push して"`、`usedTerms == ["GitHub"]`。
  - `pipelineReportsPlainTermUsage`: 用語 `Kubernetes` を登録し、入力 `Kubernetes を使う` を処理する。期待結果: `usedTerms == ["Kubernetes"]`。
  - `glossaryRoundTripsJSON`: JSON にエンコードしてデコードすると、元と等しい。
- [ ] **Step 2: `swift test --filter "GlossaryTests|TextPipelineTests"` を実行する。** 期待結果: FAIL。
- [ ] **Step 3: 実装する。** `process` の処理順は、`FillerRemover.clean` → 置き換え（`from` の長い順に、文字列をそのまま置換）→ 出力に含まれる用語を `usedTerms` に集める。`contextTerms` は `terms` と `replacements.to` を合わせ、重複を除き、`lastUsed` の新しい順に並べ、文字数の合計が予算以内に収まるところまで先頭から取る。
- [ ] **Step 4: 同じテストを実行する。** 期待結果: PASS。
- [ ] **Step 5: コミットする** `git commit -m "feat: 用語集とテキスト処理を追加"`

---

### Task 4: Soniox のメッセージと結果の組み立て

**Files:**
- Create: `Sources/VoiceInputCore/Soniox/SonioxMessages.swift`, `Sources/VoiceInputCore/Soniox/TranscriptAssembler.swift`
- Test: `Tests/VoiceInputCoreTests/SonioxMessagesTests.swift`, `Tests/VoiceInputCoreTests/TranscriptAssemblerTests.swift`

**Interfaces:**
- Produces:
  - `public struct SonioxConfig: Encodable, Equatable, Sendable { public init(languageHints: [String], terms: [String]) }`: 残りの項目は Global Constraints の固定値にする。キーは snake_case（`audio_format` など）。
  - `public struct SonioxToken: Decodable, Equatable, Sendable { public let text: String; public let isFinal: Bool }`
  - `public struct SonioxResponse: Decodable, Equatable, Sendable { public let tokens: [SonioxToken]; public let finished: Bool; public let errorCode: String?; public let errorMessage: String? }`
    - `tokens` がなければ空、`finished` がなければ false として扱う。
    - `error_code` は数値でも文字列でも受け取り、文字列にして持つ。
  - `public struct AssemblerUpdate: Equatable, Sendable { public var newFinalText: String; public var partialText: String; public var reachedFin: Bool }`
  - `public struct TranscriptAssembler: Sendable { public init(); public private(set) var finalText: String; public mutating func ingest(_ r: SonioxResponse) -> AssemblerUpdate }`

- [ ] **Step 1: 失敗するテストを書く。**
  - `configEncodesExpectedJSON`: `SonioxConfig(languageHints:["ja","en"], terms:["GitHub"])` をエンコードし、`JSONSerialization` で読み戻す。期待結果: Global Constraints のキーと値がすべてあり、`context.terms == ["GitHub"]`。
  - `decodesTokensAndFinished`: `{"tokens":[{"text":"こん","is_final":true},{"text":"にちは","is_final":false}],"final_audio_proc_ms":100,"total_audio_proc_ms":200}` を読み込める。`finished == false`。
  - `decodesNumericErrorCode`: `{"error_code":401,"error_message":"bad key"}` を読み込むと、`errorCode == "401"`。
  - `assemblerAppendsFinalsReplacesPartials`: 1 回目に final「こん」と仮「にち」、2 回目に final「にちは」と仮「。」を渡す。期待結果: `finalText == "こんにちは"`、2 回目の更新の `newFinalText == "にちは"`、`partialText == "。"`。
  - `assemblerStripsFinMarker`: final「<fin>」を渡す。期待結果: `reachedFin == true` で、`finalText` に `<fin>` が入らない。`<end>` も同じく取り除く。
- [ ] **Step 2: `swift test --filter "SonioxMessagesTests|TranscriptAssemblerTests"` を実行する。** 期待結果: FAIL。
- [ ] **Step 3: 実装する。** トークンの `text` は、空白も含めてそのままつなぐ（英語のトークンは先頭に空白を含んで届くため）。
- [ ] **Step 4: 同じテストを実行する。** 期待結果: PASS。
- [ ] **Step 5: コミットする** `git commit -m "feat: Soniox のメッセージ型と結果の組み立てを追加"`

---

### Task 5: Soniox の WebSocket 接続

**Files:**
- Create: `Sources/VoiceInputCore/Soniox/SonioxSession.swift`, `scripts/make-eval-audio.sh`
- Test: `Tests/VoiceInputCoreTests/SonioxLiveTests.swift`, `Tests/VoiceInputCoreTests/Fixtures/hello-ja.pcm`

**Interfaces:**
- Consumes: `SonioxConfig`, `SonioxResponse`（Task 4）
- Produces:
  - `public protocol TranscriptionSession: AnyObject, Sendable {`
    - `func start(config: SonioxConfig) async throws`
    - `func sendAudio(_ pcm: Data) async throws`
    - `func finalize() async throws`
    - `func finish() async`
    - `var responses: AsyncThrowingStream<SonioxResponse, Error> { get }` `}`
  - `public protocol TranscriptionSessionFactory: Sendable { func makeSession() -> TranscriptionSession }`
  - `public enum SonioxError: Error, Equatable { case unauthenticated, paymentRequired, connectionClosed, finTimeout, server(code: String, message: String) }`
  - `public final class SonioxWebSocketSession: TranscriptionSession { public init(apiKey: String, url: URL = URL(string: "wss://stt-rt.soniox.com/transcribe-websocket")!) }`
  - `public struct SonioxSessionFactory: TranscriptionSessionFactory { public init(apiKey: String) }`

- [ ] **Step 1: 評価用の仮音声を作るスクリプトを書く。** `scripts/make-eval-audio.sh <text> <out.pcm>` は、`say -v Kyoko -o tmp.aiff "<text>"` → `afconvert -f WAVE -d LEI16@16000 -c 1` → 44 バイトの WAV ヘッダーを除いて、生の PCM にする。これで `Fixtures/hello-ja.pcm`（「こんにちは、これはテストです」）を作る。
- [ ] **Step 2: 失敗するテストを書く。** `SonioxLiveTests.liveTranscribesFixture` は、`.enabled(if: ProcessInfo.processInfo.environment["SONIOX_API_KEY"] != nil)` で、API キーがあるときだけ動かす。
  - 処理: 接続 → 設定を送る → 音声を 3,200 バイトずつ送る → `finalize` → `<fin>` が届くまで受け取り、`TranscriptAssembler` に渡す。
  - 期待結果: `finalText` に「テスト」が含まれる。
  - あわせて `liveBadKeyThrowsUnauthenticated` を書く。キーを `"invalid"` にすると、`responses` が `SonioxError.unauthenticated` で終わること。
- [ ] **Step 3: `SONIOX_API_KEY=... swift test --filter SonioxLiveTests` を実行する。** 期待結果: FAIL（型がない）。
- [ ] **Step 4: `SonioxWebSocketSession` を実装する。**
  - 接続には `URLSessionWebSocketTask` を使い、`URLRequest` に Authorization ヘッダーを付ける。
  - 設定と finalize はテキストフレームで送る。音声はバイナリフレームで送る。`finish` は空のテキストフレーム `""` を送ってから閉じる。
  - 受信は `responses` に流す。`error_code` が 401 なら `.unauthenticated`、402 なら `.paymentRequired`、それ以外は `.server` として、エラーで終わらせる。
  - 相手が閉じたら、`finished` を受け取っていればそのまま終わる。受け取っていなければ `.connectionClosed` で終わらせる。
- [ ] **Step 5: 同じテストを実行する。** 期待結果: PASS（キーがない環境では skip と表示される）。
- [ ] **Step 6: コミットする** `git commit -m "feat: Soniox WebSocket セッションを追加"`

---

### Task 6: KeyStateMachine

**Files:**
- Create: `Sources/VoiceInputCore/Input/KeyStateMachine.swift`
- Test: `Tests/VoiceInputCoreTests/KeyStateMachineTests.swift`

**Interfaces:**
- Produces:
  - `public struct KeyID: Codable, Hashable, Sendable { public var keyCode: UInt16; public static let rightOption = KeyID(keyCode: 61) }`。ほかに `rightCommand` 54、`rightControl` 62、`rightShift` 60、`function` 63 も用意する。
  - `public enum KeyEvent: Equatable, Sendable { case down(KeyID), up(KeyID), otherKeyDown }`
  - `public enum RecordingMode: String, Codable, Sendable { case toggle, hold }`
  - `public enum KeyAction: Equatable, Sendable { case beginBuffering, confirm(RecordingMode), stop, cancel }`
  - `public struct KeyStateMachine: Sendable {`
    - `public init(toggleKey: KeyID, holdKey: KeyID, holdThreshold: TimeInterval = 0.3)`
    - `public mutating func handle(_ e: KeyEvent, at t: TimeInterval) -> [KeyAction]`
    - `public mutating func tick(at t: TimeInterval) -> [KeyAction]`: アプリは、キーを押した瞬間から `holdThreshold` 後にこれを呼ぶ。
    - `public mutating func reset()`: 自動停止やエラーの後に待機状態へ戻す。 `}`

- [ ] **Step 1: 失敗するテストを書く**（すべて `toggleKey == holdKey == .rightOption` の場合）。
  - `tapStartsToggle`: 0.0 秒に押す → `[.beginBuffering]`。0.1 秒に離す → `[.confirm(.toggle)]`。
  - `secondTapStopsToggle`: 上の続きで、1.0 秒に押す → `[]`。1.1 秒に離す → `[.stop]`。
  - `holdConfirmsAtThresholdAndStopsOnRelease`: 0.0 秒に押す → `[.beginBuffering]`。`tick(at: 0.3)` → `[.confirm(.hold)]`。2.0 秒に離す → `[.stop]`。
  - `tickBeforeThresholdDoesNothing`: `tick(at: 0.2)` → `[]`。
  - `chordCancelsBeforeConfirm`: 押す → `otherKeyDown` → `[.cancel]`。その後に離す → `[]`。`tick` → `[]`。
  - `chordDuringToggleTapDoesNotStop`: 切り替えモードで録音中に、押す → `otherKeyDown` → 離す。期待結果: `.stop` は出ず、録音が続く。
  - `otherKeysIgnoredWhileHoldRecording`: 押し続けて確定した後の `otherKeyDown` → `[]`。
  - `separateKeys`: `toggleKey: .rightOption, holdKey: .rightCommand` の場合。
    - Command を押す → `[.beginBuffering]`。`tick(0.3)` → `[.confirm(.hold)]`。
    - Command を 0.1 秒で離す（確定前）→ `[.cancel]`。
    - Option を短く押す → `.confirm(.toggle)`。Option を押し続けても `tick` → `[]`（Option は切り替え専用）。
  - `resetReturnsToIdle`: 切り替えモードで録音中に `reset()` を呼ぶ。次に押すと `[.beginBuffering]` から始まる。
- [ ] **Step 2: `swift test --filter KeyStateMachineTests` を実行する。** 期待結果: FAIL。
- [ ] **Step 3: 実装する。** 状態は `idle`、`pressed(key, at, chorded)`、`toggleRecording(pressedAgain: Bool, chorded: Bool)`、`holdRecording` の 4 つ。
- [ ] **Step 4: 同じテストを実行する。** 期待結果: PASS。
- [ ] **Step 5: コミットする** `git commit -m "feat: 録音キーの判定を追加"`

---

### Task 7: RealtimeChunker と SilenceDetector

**Files:**
- Create: `Sources/VoiceInputCore/Text/RealtimeChunker.swift`, `Sources/VoiceInputCore/Session/SilenceDetector.swift`
- Test: `Tests/VoiceInputCoreTests/RealtimeChunkerTests.swift`, `Tests/VoiceInputCoreTests/SilenceDetectorTests.swift`

**Interfaces:**
- Produces:
  - `public struct RealtimeChunker: Sendable {`
    - `public init(gap: TimeInterval = 0.5)`
    - `public mutating func append(_ finalText: String, at t: TimeInterval) -> String?`: ためた文が句読点（`。、！？.,!?`）で終わったら、その分を返す。
    - `public mutating func tick(at t: TimeInterval) -> String?`: 最後に足してから `gap` 以上たっていたら、ためた分を返す。
    - `public mutating func flush() -> String?` `}`
  - `public struct SilenceDetector: Sendable {`
    - `public init(timeout: TimeInterval = 60, threshold: Float = 0.01)`
    - `public mutating func feed(rms: Float, at t: TimeInterval) -> Bool`: 無音が `timeout` 以上続いたら true を返す。 `}`

- [ ] **Step 1: 失敗するテストを書く。**
  - `emitsOnPunctuation`: `append("これは", 0)` → nil。`append("テスト。", 0.1)` → `"これはテスト。"`。
  - `emitsAfterGap`: `append("hello", 0)` → nil。`tick(0.4)` → nil。`tick(0.5)` → `"hello"`。
  - `flushReturnsRemainderOnce`: `flush()` → 残り。もう一度 `flush()` → nil。
  - `silenceFiresAfterTimeout`: 0 秒から 59 秒まで 0.001 を渡す → false。60 秒で true。
  - `soundResetsSilence`: 30 秒に 0.2 を渡すと、89 秒までは false、90 秒で true。
- [ ] **Step 2: `swift test --filter "RealtimeChunkerTests|SilenceDetectorTests"` を実行する。** 期待結果: FAIL。
- [ ] **Step 3: 実装する。**
- [ ] **Step 4: 同じテストを実行する。** 期待結果: PASS。
- [ ] **Step 5: コミットする** `git commit -m "feat: リアルタイム入力の区切りと無音検出を追加"`

---

### Task 8: 設定、履歴、保存処理、キーチェーン

**Files:**
- Create: `Sources/VoiceInputCore/Storage/AppSettings.swift`, `History.swift`, `JSONStore.swift`, `KeychainStore.swift`
- Test: `Tests/VoiceInputCoreTests/StorageTests.swift`

**Interfaces:**
- Consumes: `KeyID`, `RecordingMode`（Task 6）、`FillerRemover.defaultFillers`（Task 2）、`Glossary`（Task 3）
- Produces:
  - `public enum InsertionMode: String, Codable, Sendable { case batch, realtime }`
  - `public struct AppSettings: Codable, Equatable, Sendable`。フィールドと初期値は次のとおり。
    - `toggleKey = .rightOption`、`holdKey = .rightOption`、`holdThreshold = 0.3`
    - `insertionMode = .batch`、`languageHints = ["ja","en"]`
    - `fillers = FillerRemover.defaultFillers`
    - `silenceTimeout: TimeInterval = 60`、`historyLimit = 200`、`launchAtLogin = false`
    - `public static let `default``
    - 足りないキーがある JSON を読み込んでも失敗せず、足りない項目には初期値を入れる。
  - `public struct HistoryEntry: Codable, Equatable, Identifiable, Sendable { id: UUID; date: Date; text: String; rawText: String; duration: TimeInterval; inserted: Bool }`
  - `public struct History: Codable, Equatable, Sendable { public var entries: [HistoryEntry]; public mutating func add(_ e: HistoryEntry, limit: Int) }`: 新しい順に並べ、`limit` を超えた古い分を捨てる。
  - `public final class JSONStore<T: Codable & Sendable>: @unchecked Sendable { public init(url: URL, defaultValue: T); public func load() -> T; public func save(_ v: T) throws }`
    - ファイルがない、または壊れていれば `defaultValue` を返す。
    - 書き込みは原子的に行う。親フォルダがなければ作る。
  - `public enum AppPaths { public static var supportDirectory: URL }`: `~/Library/Application Support/VoiceInput/` を返す。
  - `public enum KeychainStore { public static func saveAPIKey(_ key: String, service: String = "dev.ykazama.VoiceInput") throws; public static func loadAPIKey(service: String = "dev.ykazama.VoiceInput") -> String?; public static func deleteAPIKey(service: String = "dev.ykazama.VoiceInput") }`

- [ ] **Step 1: 失敗するテストを書く。**
  - `defaultsMatchSpec`: すべての初期値が上の値と一致する。
  - `settingsDecodeMissingKeysUsesDefaults`: `{"insertionMode":"realtime"}` を読み込むと、`insertionMode == .realtime` で、ほかの項目は初期値になる。
  - `historyCapsAtLimitNewestFirst`: 201 件足して `limit: 200` にする。期待結果: 200 件で、先頭がいちばん新しい。
  - `jsonStoreRoundTripAndCorruptFallback`: 一時フォルダに保存して読み戻すと等しい。ゴミを書き込んだ後に読むと `defaultValue` になる。
  - `keychainRoundTrip`: テスト用の service 名 `dev.ykazama.VoiceInput.tests` で、保存 → 読み込み → 削除 → 読み込みで nil。
- [ ] **Step 2: `swift test --filter StorageTests` を実行する。** 期待結果: FAIL。
- [ ] **Step 3: 実装する。** `AppSettings` の `init(from:)` は `decodeIfPresent` と初期値で書く。キーチェーンは `kSecClassGenericPassword` を使う。
- [ ] **Step 4: 同じテストを実行する。** 期待結果: PASS。
- [ ] **Step 5: コミットする** `git commit -m "feat: 設定、履歴、保存処理を追加"`

---

### Task 9: SessionController（全体の流れ）

**Files:**
- Create: `Sources/VoiceInputCore/Session/SessionController.swift`
- Test: `Tests/VoiceInputCoreTests/SessionControllerTests.swift`, `Tests/VoiceInputCoreTests/Fakes.swift`

**Interfaces:**
- Consumes: Task 3 から 8 の型すべて、`TextInserter` と `InsertionError`（以下の定義は Task 9 で作り、Task 10 で実装する）
- Produces:
  - `public protocol AudioSource: AnyObject { func start(onChunk: @escaping @Sendable (Data, Float) -> Void) throws; func stop() }`: `Data` は 16kHz、モノラル、s16le の音声。`Float` はその区切りの音の大きさ（RMS）。
  - `public protocol TextInserter { func insert(_ text: String) throws }`
  - `public enum InsertionError: Error, Equatable { case secureInput, failed }`
  - `public protocol FrontmostAppProvider { func frontmostBundleID() -> String? }`
  - `public enum SessionState: Equatable, Sendable { case idle, recording(level: Float, preview: String), processing, error(String), notice(String) }`
  - `@MainActor public final class SessionController {`
    - `public init(audio: AudioSource, sessions: TranscriptionSessionFactory, inserter: TextInserter, frontmost: FrontmostAppProvider, settings: @escaping () -> AppSettings, glossary: @escaping () -> Glossary, onHistory: @escaping (HistoryEntry) -> Void, onTermsUsed: @escaping (Set<String>) -> Void, now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }, sleep: @escaping (Duration) async -> Void = { try? await Task.sleep(for: $0) })`
    - `public var onStateChange: ((SessionState) -> Void)?`
    - `public var onAutoStop: (() -> Void)?`: 無音で自動停止したときに呼ぶ。呼ばれた側は KeyStateMachine の `reset()` を呼ぶ。
    - `public func handle(_ action: KeyAction)`
    - `public func waitUntilIdle() async`: テスト用。 `}`
  - 失敗やお知らせの文言: `"ネットワークに接続できません"`、`"API キーが正しくありません"`、`"Soniox の残高または予算が不足しています"`、`"パスワード欄には入力できません"`、`"アプリが切り替わったため履歴に保存しました"`。`error` と `notice` は 3 秒表示してから `idle` に戻す。

**決められた動き（spec 6.2〜6.5、7 章）:**
1. `.beginBuffering`: マイクを開始し、音声を手元の配列にためる。表示は変えない（`idle` のまま）。
2. `.cancel`: マイクを止め、ためた音声を捨てる。接続は作らない。
3. `.confirm(mode)`: 最前面アプリの bundle ID を覚え、状態を `recording` にする。`makeSession()` → `start(config:)` を呼ぶ。config の terms には `glossary().contextTerms().terms` を使う。接続できたら、ためた音声を順に送り、その後は届く音声をそのまま送る。
4. 録音中は、届く音声の RMS を `SilenceDetector` に渡す。true が返ったら `.stop` と同じ処理をして、`onAutoStop` を呼ぶ。
5. `.stop`: さらに 200ms 音声を取り込んで送り（`sleep(.milliseconds(200))`）、マイクを止める。状態を `processing` にし、`finalize()` を送る。`<fin>` を最大 5 秒待ち、その後 `finish()` を呼ぶ。
6. まとめて入れる場合: `<fin>` の後、`finalText` を `TextPipeline` で処理する。結果が空なら、何もせず `idle` に戻す。空でなければ次のとおり。
   - 最前面アプリが録音開始時と同じなら `insert` する。違えば入れずに `notice` を出す。
   - どちらの場合も `onHistory` を呼ぶ（`inserted` に結果を入れる）。`onTermsUsed` も呼ぶ。
7. リアルタイムで入れる場合: 新しく確定した文字を `RealtimeChunker` に渡し、区切りの単位ごとに `TextPipeline` で処理する。最前面アプリが同じなら `insert` する。違ったら、それ以降は入れずに `notice` を出す。仮の結果は、`recording(preview:)` で表示側に渡す。
   - `RealtimeChunker.tick` は、100ms ごとに `now()` を使って呼ぶ。
   - `<fin>` の後、`flush()` の残りを同じように処理する。履歴には全文を 1 件として残す。
8. エラー（接続できない、`responses` がエラーで終わった、5 秒待っても `<fin>` が来ない）: それまでの `finalText` を処理する。空でなければ履歴に残す（`inserted: false`）。録音開始時と同じアプリが最前面なら入れる。状態は `error(文言)` にし、マイクと接続を閉じる。
9. 入力で `InsertionError.secureInput` が出た場合: `notice("パスワード欄には入力できません")` を出し、履歴には `inserted: false` で残す。

- [ ] **Step 1: 偽物の部品を `Fakes.swift` に書く。**
  - `FakeAudio`: `emit(_ data: Data, rms: Float)` で音声を流せる。`started` と `stopped` を記録する。
  - `FakeSession`: 送られた音声、finalize、finish の順番を `log: [String]` に記録する。`push(_ SonioxResponse)` と `fail(_ Error)` で受信を流せる。`startDelay` を設定できる。
  - `FakeFactory`: `sessions` を記録する。
  - `FakeInserter`: `inserted: [String]` を記録する。`error` を設定できる。
  - `FakeFrontmost`: `bundleID` を変えられる。
  - 時計と `sleep` は、手動で進める `TestClock` に差し替える。
- [ ] **Step 2: 失敗するテストを書く**（名前と確かめる内容）。
  - `cancelNeverOpensSession`: `.beginBuffering` → `.cancel` の後、`factory.sessions.isEmpty` で、`audio.stopped` が true。
  - `shortUtteranceBeforeConnectFlushesBufferFirst`: `startDelay` を 1 秒にする。音声 A と B を流し、`.confirm(.toggle)` → `.stop`。期待結果: `log` が `["audio:A","audio:B",…,"finalize","finish"]` の順になり、`finalize` が最後の音声の後に来る。
  - `batchInsertsProcessedTextWhenSameApp`: final「えー、ぎっとはぶです」と `<fin>` を流す。置き換え `ぎっとはぶ→GitHub` を登録しておく。期待結果: `inserted == ["GitHubです"]`、履歴 1 件で `inserted == true`、`onTermsUsed` に `["GitHub"]` が渡る。
  - `appSwitchSavesToHistoryOnly`: `.confirm` の後に `FakeFrontmost.bundleID` を変える。期待結果: `inserted.isEmpty`、履歴 1 件で `inserted == false`、`notice("アプリが切り替わったため履歴に保存しました")`。
  - `fillerOnlyUtteranceInsertsNothing`: final「えー、うーん」と `<fin>` を流す。期待結果: 入力なし、履歴なし、最後の状態が `idle`。
  - `socketClosesBeforeFinKeepsFinalsInHistory`: final「途中まで」の後に `fail(SonioxError.connectionClosed)` を流す。期待結果: 履歴に「途中まで」が残り、状態が `error("ネットワークに接続できません")`、`audio.stopped`。
  - `unauthenticatedShowsKeyError`: `fail(.unauthenticated)` を流す → `error("API キーが正しくありません")`。
  - `finTimeoutAfterFiveSeconds`: `<fin>` を流さずに時計を 5 秒進める。期待結果: `finish` が呼ばれ、状態が `error` になる。
  - `silenceAutoStops`: `.confirm(.toggle)` の後、RMS 0.001 の音声を 60 秒分流す。期待結果: `finalize` が送られ、`onAutoStop` が 1 回呼ばれる。
  - `realtimeInsertsPerChunk`: `insertionMode = .realtime` にする。final「これは」→「テスト。」→「次も」→（0.5 秒たつ）→ `<fin>` の順に流す。期待結果: `inserted == ["これはテスト。","次も"]`、履歴は全文の 1 件。
  - `secureInputShowsNotice`: `FakeInserter.error = .secureInput` にする。期待結果: `notice("パスワード欄には入力できません")`、履歴は `inserted == false`。
- [ ] **Step 3: `swift test --filter SessionControllerTests` を実行する。** 期待結果: FAIL。
- [ ] **Step 4: 上の「決められた動き」のとおりに実装する。** 受信は 1 つの `Task` で `for try await` し、`TranscriptAssembler` に渡す。`<fin>` の待ち合わせは `CheckedContinuation` と時計によるタイムアウトで行う。
- [ ] **Step 5: 同じテストを実行し、続けて `swift test` 全体も実行する。** 期待結果: PASS。
- [ ] **Step 6: コミットする** `git commit -m "feat: 録音セッションの制御を追加"`

---

### Task 10: PasteboardInserter

**Files:**
- Create: `Sources/VoiceInputCore/Input/PasteboardInserter.swift`
- Test: `Tests/VoiceInputCoreTests/PasteboardInserterTests.swift`

**Interfaces:**
- Consumes: `TextInserter`, `InsertionError`（Task 9）
- Produces:
  - `public struct PasteboardSnapshot { public static func capture(_ pb: NSPasteboard) -> PasteboardSnapshot; public func restore(to pb: NSPasteboard) }`: すべての item と、すべての type のデータを保存する。
  - `public final class PasteboardInserter: TextInserter {`
    - `public init(pasteboard: NSPasteboard = .general, isSecureInput: @escaping () -> Bool = { IsSecureEventInputEnabled() }, postPaste: @escaping () -> Void = PasteboardInserter.sendCommandV, restoreDelay: TimeInterval = 0.25)`
    - `public static func sendCommandV()`
    - `insert(_:)` の処理順: 保存 → 文字列を置く → `postPaste` → `restoreDelay` 後に元に戻す（`changeCount` が自分の書き込みのままのときだけ）。 `}`

- [ ] **Step 1: 失敗するテストを書く。** テストでは `NSPasteboard(name: .init("vi-test-\(UUID())"))` を使う。
  - `pastesTextAndRestoresString`: 元が「original」の状態で `insert("hello")` を呼ぶ。期待結果: `postPaste` の中で読むと「hello」。`restoreDelay: 0` で戻した後は「original」。
  - `restoresNonTextPasteboardItems`: 元が PNG データ（`.png`）と `.fileURL` の 2 種類の状態で insert し、戻した後に両方のデータがバイト単位で一致する。
  - `secureInputThrows`: `isSecureInput: { true }` → `InsertionError.secureInput` が投げられ、`postPaste` は呼ばれない。
  - `doesNotClobberNewerClipboard`: `postPaste` の中で、ほかのアプリが「new」を書き込んだことにする。期待結果: 戻した後も「new」のまま。
- [ ] **Step 2: `swift test --filter PasteboardInserterTests` を実行する。** 期待結果: FAIL。
- [ ] **Step 3: 実装する。** `sendCommandV` は `CGEvent(keyboardEventSource:virtualKey:0x09,keyDown:)` を使い、`flags = .maskCommand` を明示する（押されたままの Option を混ぜないため）。`.cghidEventTap` へ送る。
- [ ] **Step 4: 同じテストを実行する。** 期待結果: PASS。
- [ ] **Step 5: コミットする** `git commit -m "feat: クリップボード経由の文字入力を追加"`

---

### Task 11: アプリの組み立て（マイク、キーの監視、録音中の表示）

**Files:**
- Create: `App/AudioCapture.swift`, `App/GlobalKeyMonitor.swift`, `App/FrontmostApp.swift`, `App/Overlay/OverlayPanel.swift`, `App/Overlay/OverlayView.swift`, `App/AppCoordinator.swift`
- Modify: `App/VoiceInputApp.swift`

**Interfaces:**
- Consumes: `SessionController`, `KeyStateMachine`, `PasteboardInserter`, `SonioxSessionFactory`, `JSONStore`, `AppPaths`, `KeychainStore`
- Produces:
  - `final class AudioCapture: AudioSource`: AVAudioEngine の入力を、`AVAudioConverter` で 16kHz、モノラル、Int16 に変換する。約 100ms ごとに渡し、RMS も計算して渡す。
  - `final class GlobalKeyMonitor { init(watched: @escaping () -> Set<KeyID>, onEvent: @escaping (KeyEvent) -> Void); func start() -> Bool }`
    - `CGEvent.tapCreate(.cgSessionEventTap, .headInsertEventTap, ...)` で `flagsChanged`、`keyDown`、`keyUp` を見る。
    - 監視しているキーが修飾キーなら、`flagsChanged` の keyCode と flag の増減から down と up を判断する。
    - 監視しているキーが修飾キーでなければ、そのイベントは握りつぶす（アプリに届けない）。
    - 監視していないキーの `keyDown` は `.otherKeyDown` として通知し、イベントはそのまま通す。
    - tap が無効にされたら（`tapDisabledByTimeout`）、再度有効にする。
  - `struct FrontmostApp: FrontmostAppProvider`: `NSWorkspace.shared.frontmostApplication?.bundleIdentifier` を返す。
  - `final class OverlayPanel: NSPanel`: `styleMask [.nonactivatingPanel, .borderless]`、`level = .statusBar`、`ignoresMouseEvents = true`、`collectionBehavior [.canJoinAllSpaces, .fullScreenAuxiliary]`。表示はマウスがある画面の `visibleFrame` の下部中央（下端から 24pt）。`SessionState` が `idle` のときは隠す。
  - `OverlayView`: `recording` なら赤い点、音量バー、プレビューの文字。`processing` なら回転するインジケーター。`error` と `notice` なら文言を出す。
  - `@MainActor final class AppCoordinator: ObservableObject`: 保存処理、`SessionController`、`KeyStateMachine`、`GlobalKeyMonitor`、`OverlayPanel` を組み合わせる。キーイベントを `KeyStateMachine` に渡し、出てきた `KeyAction` を `SessionController` に渡す。`.beginBuffering` のときは、`holdThreshold` 後に `tick` を呼ぶ。API キーは `KeychainStore` から読む。

- [ ] **Step 1: 上の部品を実装し、`VoiceInputApp` から `AppCoordinator` を起動する。** メニューには「履歴」「用語集」「設定」「終了」を置く（中身は Task 12 で作る）。
- [ ] **Step 2: `scripts/build.sh` を実行する。** 期待結果: `** BUILD SUCCEEDED **`。
- [ ] **Step 3: 手で確かめる**（テストで代わりにできない部分）。システム設定でマイクとアクセシビリティを許可し、`security add-generic-password -s dev.ykazama.VoiceInput -a apiKey -w <key>` で API キーを入れたうえで、次を確かめる。
  - テキストエディットで右 Option を短く押す → 話す → もう一度短く押す。文字が入ること。
  - 右 Option を押し続けて話し、離す。文字が入ること。
  - Option+← を押して、表示が出ないこと。
  - クリップボードの中身が変わらないこと。
  - 日本語入力をオンにした状態でも、正しく文字が入ること。
  - 表示を出してもフォーカスが外れないこと。
  - 話し終えてから文字が入るまでの時間を体感で記録する（目標は 1 秒以内）。
  - Slack、VS Code、ターミナル、Safari、Chrome、メモでも同じように動くかを確かめ、アプリごとの結果を `docs/manual-checks.md` に書く。
- [ ] **Step 4: コミットする** `git commit -m "feat: マイク、キー監視、録音中の表示をアプリに組み込む"`

---

### Task 12: 設定、用語集、履歴の画面、初回の案内、ログイン時の起動

**Files:**
- Create: `App/Windows/SettingsView.swift`, `GlossaryView.swift`, `HistoryView.swift`, `PermissionsView.swift`
- Modify: `App/AppCoordinator.swift`, `App/VoiceInputApp.swift`

**Interfaces:**
- Consumes: `AppSettings`, `Glossary`（`addTerm`, `addCorrection`）, `History`, `KeychainStore`, `JSONStore`
- Produces: `AppCoordinator` に `@Published var settings: AppSettings`、`@Published var glossary: Glossary`、`@Published var history: History` を持たせる。変更したら、そのたびに保存する。

- [ ] **Step 1: SettingsView を作る。** spec 6.9 の項目をすべて置く。
  - API キー: SecureField。保存先はキーチェーン。
  - 2 つのキーそれぞれ: 「押して設定」ボタン。押すと、次に押されたキーの keyCode を記録する。修飾キーにも対応する。
  - 短く押したか押し続けたかの境目: 0.15〜1.0 秒。
  - 文字の入れ方: Picker。
  - 言語のヒント: 文字列で入力する。
  - フィラーの一覧: 一覧の編集。
  - 無音による自動停止: 10〜600 秒。
  - ログイン時の起動: Toggle。`SMAppService.mainApp.register()` と `unregister()` を使う。
  - あわせて、用語ヒントが上限で削られているときは警告を出す（`contextTerms().truncated`）。
- [ ] **Step 2: GlossaryView を作る。** 用語と置き換えを 2 つの表で見せ、足す、直す、消すができるようにする。
- [ ] **Step 3: HistoryView を作る。** 新しい順に一覧を見せる。各行で「コピー」ができる。文字列の一部を選んで「用語集に登録」を押すと、シートが開く。シートの置き換え元には選んだ文字列が入り、置き換え先を入れて `addCorrection` を呼ぶ。
- [ ] **Step 4: PermissionsView を作る。** マイク（`AVCaptureDevice.authorizationStatus`）とアクセシビリティ（`AXIsProcessTrusted`）の状態を見せる。許可がなければ、許可を求めるボタンと、システム設定の該当画面を開くボタンを出す。起動時に、どちらかの許可がないか API キーが未設定なら、この画面を開く。
- [ ] **Step 5: `scripts/build.sh` を実行する。** 期待結果: `** BUILD SUCCEEDED **`。
- [ ] **Step 6: 手で確かめる。**
  - 「ぎっとはぶ」と誤認識された履歴から GitHub を登録すると、次に「ぎっとはぶ」と話したときに GitHub と入る。
  - キーを右 Command に変えると、右 Option では反応しなくなる。
  - 文字の入れ方をリアルタイムに変えると、文の区切りごとに入る。
  - ログイン時の起動をオンにし、ログアウトしてログインすると起動している。
- [ ] **Step 7: コミットする** `git commit -m "feat: 設定、用語集、履歴の画面と初回の案内を追加"`

---

### Task 13: 精度の評価ツール

**Files:**
- Create: `Sources/VoiceInputCore/Text/CharacterAccuracy.swift`, `Sources/voice-eval/main.swift`, `Eval/cases.json`
- Test: `Tests/VoiceInputCoreTests/CharacterAccuracyTests.swift`

**Interfaces:**
- Consumes: `SonioxSessionFactory`, `TranscriptAssembler`, `TextPipeline`, `JSONStore`, `AppPaths`
- Produces: `public enum CharacterAccuracy { public static func normalize(_ s: String) -> String; public static func score(expected: String, actual: String) -> Double }`
  - `normalize`: 空白と句読点（`。、，．！？,.!?`）を消し、英字を小文字にする。
  - `score`: 1 − (文字単位の編集距離 ÷ 期待する文の文字数) を 0〜1 に収める。

- [ ] **Step 1: 失敗するテストを書く。**
  - `identicalIsOne`: `score("GitHub に push", "github に push。") == 1.0`
  - `oneCharWrongOutOfTen`: 10 文字中 1 文字だけ違う → `0.9`
  - `clampsAtZero`: 期待する文が「あ」で、実際の文が長い → `0.0`
- [ ] **Step 2: `swift test --filter CharacterAccuracyTests` を実行する。** 期待結果: FAIL。
- [ ] **Step 3: 実装する。** 編集距離は Levenshtein（`Array(Character)` 上の DP）で計算する。
- [ ] **Step 4: 同じテストを実行する。** 期待結果: PASS。
- [ ] **Step 5: `Eval/cases.json` を作る。** 形式は `[{"audio":"001.pcm","expected":"..."}]`。日本語 5 文、英語 5 文、混在 5 文、ソフトウェア用語の多い文 5 文の、計 20 文。`scripts/make-eval-audio.sh` で仮音声を作る（英語は `say -v Samantha`）。ユーザーが自分の声で録音した音声に差し替えられるよう、手順を `Eval/README.md` に書く。
- [ ] **Step 6: `voice-eval` を実装する。** `swift run voice-eval Eval [--no-glossary]` で動かす。
  - 処理: 各ケースを Task 5 の手順で認識し、`TextPipeline` で処理する（用語集は `AppPaths` の `glossary.json`。`--no-glossary` なら空）。
  - 出力: 各文の score、全体の平均、95% に届いたかどうか。
  - API キーは環境変数 `SONIOX_API_KEY`、なければキーチェーンから読む。
- [ ] **Step 7: `SONIOX_API_KEY=... swift run voice-eval Eval` を実行する。** 期待結果: 20 行と平均が出力される。値は記録するだけで、合否には使わない。
- [ ] **Step 8: コミットする** `git commit -m "feat: 精度の評価ツールを追加"`

---

## 完了時

- `swift test` がすべて PASS し、`scripts/build.sh` が成功すること。
- Task 11 と 12 の手での確認結果が、`docs/manual-checks.md` に書かれていること。
- superpowers:finishing-a-development-branch に従って統合する。`main` へ直接 push せず、PR 経由でマージする。
