# 直した単語を用語集に登録する機能 実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 直した部分を選んで ⌃⌥D を押すと、直前の音声入力と見比べて、誤認識の直しを用語集に登録する（3 秒以内に同じキーで取り消せる）。

**Architecture:** 判定はすべて VoiceInputCore の純粋な型に置く。対象は、ショートカットの型、選択と履歴の比較（差分）、登録の規則と取り消し、⌘C による選択の読み取り。AI の判断は `CorrectionJudge` プロトコルの後ろに置き、Foundation Models の実装は `#if canImport(FoundationModels)` と `@available(macOS 26, *)` の中に置く。App 側は、キー監視へのショートカットの追加、AppCoordinator での流れの組み立て、設定画面の 3 点だけを担当する。

**Tech Stack:** Swift 6 / Swift Testing / FoundationModels（macOS 26 以降のみ） / ApplicationServices（AX） / AppKit（NSPasteboard） / CGEventTap

**Spec:** `docs/superpowers/specs/2026-10-24-correction-hotkey-design.md`（本体: `docs/superpowers/specs/2026-10-24-voice-input-design.md`）

## Global Constraints

- 動作環境は macOS 14 以降のまま変えない。Foundation Models は `#if canImport(FoundationModels)` と `if #available(macOS 26, *)` で、使える Mac でだけ使う。
- AI は Apple の端末内AI（Foundation Models）だけを使う。外部の API は使わない。答えは `@Generable` の構造化出力で受け取る。
- 登録キーの初期値は ⌃⌥D（keyCode 2）。修飾キーを 1 つ以上含み、録音キーと同じ keyCode は使えない。
- 比べる履歴: 新しい順に最大 5 件、10 分以内、`text` を使う（`rawText` は使わない）。`inserted == false` の履歴も含める。単語だけを選んだ場合は、10 分以内でいちばん新しい 1 件だけと比べる。
- 「似ている」の基準: 共通の文字数が、選ばれた文字の長さの 50% 以上。差分は 1〜3 か所で、それぞれ 1〜30 文字。
- 捨てる組み合わせ: 置き換え元と正しい語が同じ、置き換え元が空、正しい語が空白や句読点だけ、両方が 1 文字だけ。
- 選ばれた文字が 200 文字を超えたら「選んだ範囲が長すぎます」。
- ⌘C の待ち時間は最大 0.3 秒。⌘C には `PasteboardInserter.syntheticEventTag` を付け、修飾キーは ⌘ だけを明示する。クリップボードは必ず元に戻す。
- AI の待ち時間は最大 1.5 秒。時間切れやエラーは「AI を使えない」と同じ扱い。
- 表示の文言（そのまま使う）: 「{to} を登録しました」「{from} → {to} を登録しました」「{先頭の語} ほか {n} 件を登録しました」「登録を取り消しました」「登録できる直しが見つかりませんでした」「文字を選んでからキーを押してください」「選んだ範囲が長すぎます」「パスワード入力中は使えません」「処理中です」。表示は 3 秒間（既存の `showOverlayMessage`）。
- 取り消しは直前の 1 回の登録だけ、3 秒以内、メモリにだけ持つ。取り消しの判定は「処理中」の判定より先に行う。
- 作業ブランチは `feature/correction-hotkey`。`main` には push しない。コミットの末尾には、ハーネスの指示どおりに Co-Authored-By の行を付ける。

## Review Focus

1. **前後を含めて選んだが、直した語が選択の端にある場合**（例: 選択「Dockerコンテナを再起動」、履歴「どうかコンテナを再起動して…」）: 直した語（Docker）が登録されること。→ Task 2 `editAtSelectionEdgeBecomesUnresolved`、Task 3 `unresolvedPieceUsesJudgeLocatedSource`
2. **何も直さずに選んだ、または関係ない文字を選んだ場合**: 何も登録されず、「登録できる直しが見つかりませんでした」が出ること。→ Task 2 `unchangedSelectionReturnsNil`、`unrelatedSelectionReturnsNil`
3. **AI が、履歴の文にない置き換え元を答えた場合**: その答えは使わず、認識のヒントだけを登録すること。→ Task 3 `judgeSourceNotInSentenceFallsBackToHintOnly`
4. **ターミナルなどで何も選ばずにキーを押した場合**（⌘C でクリップボードが変わらない）: クリップボードはそのままで、「文字を選んでからキーを押してください」が出ること。→ Task 4 `unchangedClipboardReturnsNilAndRestores`
5. **取り消しの前に、ユーザーが用語集の画面で同じ項目を消していた場合**: 落ちずに、残っている分だけを消すこと。もともとあった用語は、登録の報告にも取り消しの対象にも含めないこと。→ Task 3 `undoRemovesOnlyWhatRemains`、`existingTermIsNotReportedOrUndone`

---

## ファイル構成

```
Sources/VoiceInputCore/Input/Shortcut.swift              Shortcut, ShortcutModifiers
Sources/VoiceInputCore/Storage/AppSettings.swift         glossaryShortcut を追加
Sources/VoiceInputCore/Correction/CorrectionMatcher.swift CorrectionPair, CorrectionCandidates, CorrectionMatcher
Sources/VoiceInputCore/Correction/CorrectionRegistrar.swift CorrectionJudge, Registration, CorrectionRegistrar
Sources/VoiceInputCore/Correction/FoundationModelsJudge.swift  Foundation Models の実装（macOS 26 以降）
Sources/VoiceInputCore/Input/SelectionCopier.swift       ⌘C で選択を読み、クリップボードを戻す
App/GlobalKeyMonitor.swift                               登録キーの検出
App/SelectedText.swift                                   AX で選択を読み、だめなら SelectionCopier
App/AppCoordinator.swift                                 登録の流れ
App/Windows/SettingsView.swift                           登録キーの設定と、AI の状態の表示
Tests/VoiceInputCoreTests/{ShortcutTests,CorrectionMatcherTests,CorrectionRegistrarTests,SelectionCopierTests,FoundationModelsJudgeLiveTests}.swift
docs/manual-checks.md                                    手での確認項目を追加
```

---

### Task 1: Shortcut 型と設定項目

**Files:**
- Create: `Sources/VoiceInputCore/Input/Shortcut.swift`
- Modify: `Sources/VoiceInputCore/Storage/AppSettings.swift`
- Test: `Tests/VoiceInputCoreTests/ShortcutTests.swift`

**Interfaces:**
- Produces:
  - `public struct ShortcutModifiers: OptionSet, Codable, Hashable, Sendable { control, option, command, shift }`
    - `public init(cgFlags: UInt64)`: デバイスに依存しないフラグから作る。control 0x40000、option 0x80000、command 0x100000、shift 0x20000。
    - `public var symbols: String`: 「⌃⌥⇧⌘」の順に並べた記号。
  - `public struct Shortcut: Codable, Hashable, Sendable { public var modifiers: ShortcutModifiers; public var keyCode: UInt16; public var keyLabel: String }`
    - `public static let glossaryDefault`: modifiers [.control, .option]、keyCode 2、keyLabel "D"。
    - `public func matches(keyCode: UInt16, cgFlags: UInt64) -> Bool`: keyCode が同じで、修飾キーがちょうど一致する（余分な修飾キーがあれば false）。
    - `public static func isAllowed(_ s: Shortcut, recordKeys: [KeyID]) -> Bool`: 修飾キーが 1 つ以上ある。keyCode が修飾キーではない（`ModifierKeys.isModifier`）。keyCode が録音キーのどれとも違う。
    - `public var displayName: String`: `symbols + keyLabel`（例 "⌃⌥D"）。
  - `AppSettings.glossaryShortcut: Shortcut`。初期値は `.glossaryDefault`。古い JSON にこの項目がなければ初期値を入れる。

- [ ] **Step 1: 失敗するテストを書く**
  - `defaultIsControlOptionD`: `Shortcut.glossaryDefault.displayName == "⌃⌥D"`、`keyCode == 2`。
  - `matchesExactModifiersOnly`: `matches(keyCode: 2, cgFlags: 0x40000 | 0x80000)` は true。0x40000 だけなら false。0x40000 | 0x80000 | 0x100000 でも false。keyCode 3 なら false。
  - `modifierFlagsIgnoreDeviceBits`: `ShortcutModifiers(cgFlags: 0x80000 | 0x40)` が `[.option]` になる。
  - `disallowsNoModifierModifierKeyAndRecordKeyCollision`: 修飾キーなしは false。keyCode 61（右 Option）は false。keyCode が録音キー（F13 = 105）と同じなら false。初期値は true。
  - `settingsWithoutShortcutDecodeToDefault`: `{"insertionMode":"batch"}` を読み込むと、`glossaryShortcut == .glossaryDefault` になる。
- [ ] **Step 2: `swift test --filter ShortcutTests` を実行する。** 期待結果: FAIL（型がない）。
- [ ] **Step 3: 実装する**（AppSettings の `init(from:)` は、ほかの項目と同じく `decodeIfPresent` と初期値で書く）。
- [ ] **Step 4: `swift test` を実行する。** 期待結果: すべて PASS。
- [ ] **Step 5: コミットする** `feat: 登録キーの型と設定項目を追加`

---

### Task 2: CorrectionMatcher（選択と履歴の比較）

**Files:**
- Create: `Sources/VoiceInputCore/Correction/CorrectionMatcher.swift`
- Test: `Tests/VoiceInputCoreTests/CorrectionMatcherTests.swift`

**Interfaces:**
- Consumes: `HistoryEntry`（`id`、`date`、`text`）
- Produces:
  - `public struct CorrectionPair: Equatable, Hashable, Sendable { public var from: String; public var to: String }`
  - `public struct CorrectionCandidates: Equatable, Sendable { public var entryID: UUID; public var sentence: String; public var pairs: [CorrectionPair]; public var unresolved: [String] }`
    - `sentence` は比べた履歴の `text`。
    - `pairs` は、プログラムで置き換え元まで決まった組み合わせ。
    - `unresolved` は、置き換え元をプログラムで決められなかった、選択側の語。AI か「ヒントだけ」の規則で扱う。
  - `public enum CorrectionMatcher { public static func match(selection: String, history: [HistoryEntry], now: Date, maxEntries: Int = 5, window: TimeInterval = 600) -> CorrectionCandidates? }`

**決められた動き（spec 7.2 章）:**
1. 選択の前後の空白を取り除く。空なら nil を返す。
2. 対象の履歴は、`now - date <= window` を満たす新しい順に最大 `maxEntries` 件。
3. いずれかの履歴の `text` に、選択がそのまま含まれていれば、直していないので nil を返す。
4. 各履歴について、選択との最長共通部分列（LCS、文字単位）を求める。`LCS の長さ / 選択の文字数 >= 0.5` の履歴のうち、割合がいちばん高いもの（同じなら新しいもの）を使う。
   - 使う履歴が決まったら、LCS の対応から差分を取り出す。履歴側で最初に一致した文字から最後に一致した文字までの間で、両側が一致に挟まれた差分を `pairs` に入れる（from は履歴側、to は選択側）。
   - 選択の先頭や末尾にある、一致していない部分（選択の端の直し）は、置き換え元を決められない。そのため `unresolved` に入れる。
   - `pairs` と `unresolved` が両方とも空なら nil を返す。両方を合わせて 3 か所を超えるか、いずれかの側が 30 文字を超えるものがあれば nil を返す。
5. 4 で使える履歴がなく、選択が 30 文字以下なら、単語だけが選ばれた場合として扱う。10 分以内でいちばん新しい 1 件を `sentence` にし、`pairs: []`、`unresolved: [選択]` を返す。対象の履歴が 1 件もなければ nil を返す。
6. それ以外は nil を返す。

- [ ] **Step 1: 失敗するテストを書く**（`now` は固定、履歴は手で作る）
  - `internalEditBecomesPair`: 履歴「main ブランチにマージする前に CI が通るか確認します。」、選択「マージする前に GitHub Actions が通るか」。期待結果: `pairs == [CorrectionPair(from: "CI", to: "GitHub Actions")]`、`unresolved == []`。
  - `editAtSelectionEdgeBecomesUnresolved`: 履歴「どうかコンテナを再起動してからAPIを確認します。」、選択「Dockerコンテナを再起動」。期待結果: `pairs == []`、`unresolved == ["Docker"]`、`sentence` はその履歴。
  - `wordOnlySelectionUsesNewestEntry`: 履歴 2 件（古い方: 1 分前、新しい方: 10 秒前）、選択「Kubernetes」。期待結果: `unresolved == ["Kubernetes"]`、`sentence` は新しい方の `text`。
  - `unchangedSelectionReturnsNil`: 選択が履歴の一部と同じ → nil。
  - `unrelatedSelectionReturnsNil`: 選択「今日の天気は晴れです。明日は雨が降るでしょう。週末は」（31 文字以上で、どの履歴とも似ていない）→ nil。
  - `ignoresEntriesOlderThanWindowAndBeyondFive`: 11 分前の履歴だけなら nil。6 件目にしか一致しない場合も nil。
  - `tooManyEditsReturnsNil`: 差分が 4 か所 → nil。
  - `mixedJapaneseEnglish`: 履歴「この PR を merge して」、選択「この PR を marge して」→ `pairs == [CorrectionPair(from: "e", to: "a")]`。この組み合わせは Task 3 の規則（両方が 1 文字だけ）で捨てられる。ここでは matcher の出力だけを確かめる。
- [ ] **Step 2: `swift test --filter CorrectionMatcherTests` を実行する。** 期待結果: FAIL。
- [ ] **Step 3: 実装する。** LCS は `Array(Character)` の DP（O(n·m)、選択 200 文字 × 履歴の長さ）で求める。対応をたどり直して、一致の区間と差分の区間に分ける。
- [ ] **Step 4: 同じテストを実行し、続けて `swift test` を実行する。** 期待結果: PASS。
- [ ] **Step 5: コミットする** `feat: 選んだ文字と履歴を比べて直しを取り出す`

---

### Task 3: CorrectionRegistrar（AI の判断、登録の規則、取り消し）

**Files:**
- Create: `Sources/VoiceInputCore/Correction/CorrectionRegistrar.swift`
- Test: `Tests/VoiceInputCoreTests/CorrectionRegistrarTests.swift`

**Interfaces:**
- Consumes: `CorrectionCandidates`、`CorrectionPair`（Task 2）、`Glossary`（`terms`、`replacements`、`addTerm`、`addCorrection`）
- Produces:
  - `public protocol CorrectionJudge: Sendable {`
    - `func locateSource(of word: String, in sentence: String) async throws -> String?`: sentence の中で、word に直されたと考えられる部分をそのまま返す。
    - `func isCommonWord(_ word: String) async throws -> Bool` `}`
  - `public struct Registration: Equatable, Sendable { public var addedTerms: [String]; public var addedReplacementIDs: [UUID]; public var message: String }`
  - `public struct CorrectionRegistrar: Sendable {`
    - `public init(judge: CorrectionJudge?, timeout: Duration = .milliseconds(1500), sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) })`
    - `public func register(_ c: CorrectionCandidates, into glossary: inout Glossary) async -> Registration?`: 登録するものがなければ nil を返す。
    - `public static func undo(_ r: Registration, in glossary: inout Glossary)` `}`

**決められた動き（spec 7.3〜7.5 章）:**
1. `unresolved` の各語 w について、judge があれば `locateSource(of: w, in: sentence)` を timeout 付きで呼ぶ。答えが空でなく、sentence に含まれていれば、`(from: 答え, to: w)` を候補に加える。それ以外（judge が nil、時間切れ、エラー、答えが sentence にない）は、w を「ヒントだけ」の語にする。
2. 候補から、Global Constraints の「捨てる組み合わせ」を除く。
3. 残った各組み合わせについて、judge があれば `isCommonWord(from)` を timeout 付きで呼ぶ。false のときだけ置き換えを登録する（`addCorrection`）。true、judge が nil、時間切れ、エラーのときは、ヒント（to）だけを登録する（`addTerm`）。
4. 「ヒントだけ」の語も `addTerm` する。
5. `addedTerms` と `addedReplacementIDs` には、登録前の glossary になかったものだけを入れる。両方とも空なら nil を返す。
6. `message`:
   - 1 件だけで、置き換えを登録した場合: 「{from} → {to} を登録しました」
   - 1 件だけで、ヒントだけの場合: 「{to} を登録しました」
   - 2 件以上の場合: 「{最初の to} ほか {n-1} 件を登録しました」
7. `undo` は、`addedReplacementIDs` に一致する置き換えと、`addedTerms` に一致する用語のうち、まだ残っているものだけを消す。

- [ ] **Step 1: 失敗するテストを書く**（偽物の judge: 答えを設定できる、呼ばれたら待ち続ける、エラーを投げる、の 3 種類）
  - `nonCommonSourceRegistersReplacementAndTerm`: pairs [("キューバーニーツ","Kubernetes")]、isCommonWord → false。期待結果: 置き換え 1 件と用語 1 件。message は「キューバーニーツ → Kubernetes を登録しました」。
  - `commonSourceRegistersHintOnly`: pairs [("どうか","Docker")]、isCommonWord → true。期待結果: 置き換えなし、用語「Docker」だけ。message は「Docker を登録しました」。
  - `unresolvedPieceUsesJudgeLocatedSource`: unresolved ["Docker"]、sentence「どうかコンテナを再起動」、locateSource → "どうか"、isCommonWord → false。期待結果: 置き換え どうか → Docker。
  - `judgeSourceNotInSentenceFallsBackToHintOnly`: locateSource → "ドッカー"（sentence にない）。期待結果: 用語「Docker」だけ。
  - `noJudgeMeansHintOnly`: judge nil、pairs [("キューバーニーツ","Kubernetes")]。期待結果: 用語だけ。
  - `judgeTimeoutMeansHintOnly`: 待ち続ける judge と、すぐ返る sleep。期待結果: 用語だけで、register が返ってくる。
  - `discardsTrivialPairs`: ("e","a")、("の","へ")、("x","x")、("", "A")、("A","、") → すべて捨てられて nil。
  - `multiplePairsMessage`: 2 件の登録 → 「{最初の to} ほか 1 件を登録しました」。
  - `existingTermIsNotReportedOrUndone`: glossary に「Docker」がすでにある → 登録しても `addedTerms` に入らない。2 件目の新しい語だけが入る。undo しても「Docker」は残る。
  - `undoRemovesOnlyWhatRemains`: 登録後に、ユーザーが用語を手で消したことにする → undo しても落ちず、残っている置き換えだけが消える。
- [ ] **Step 2: `swift test --filter CorrectionRegistrarTests` を実行する。** 期待結果: FAIL。
- [ ] **Step 3: 実装する。** 時間切れは task group で、judge の呼び出しと `sleep(timeout)` を競わせ、先に終わった方を採る。
- [ ] **Step 4: 同じテストを実行し、続けて `swift test` を実行する。** 期待結果: PASS。
- [ ] **Step 5: コミットする** `feat: 直しを用語集に登録する規則と取り消しを追加`

---

### Task 4: SelectionCopier（⌘C で選択を読む）

**Files:**
- Create: `Sources/VoiceInputCore/Input/SelectionCopier.swift`
- Test: `Tests/VoiceInputCoreTests/SelectionCopierTests.swift`

**Interfaces:**
- Consumes: `PasteboardSnapshot`、`PasteboardInserter.syntheticEventTag`（Input/PasteboardInserter.swift）
- Produces:
  - `public final class SelectionCopier: @unchecked Sendable {`
    - `public init(pasteboard: NSPasteboard = .general, postCopy: @escaping @Sendable () -> Void = SelectionCopier.sendCommandC, wait: TimeInterval = 0.3, pollInterval: TimeInterval = 0.02)`
    - `public func copySelection() async -> String?`: 保存 → postCopy → changeCount が変わるまで最大 wait 秒待つ → 文字列を読む → 必ず元に戻す。変わらなければ nil を返す。
    - `public static func sendCommandC()`: keyCode 8 の keyDown と keyUp。`flags = .maskCommand` を明示し、`eventSourceUserData` に `PasteboardInserter.syntheticEventTag` を付けて、`.cghidEventTap` へ送る。 `}`

- [ ] **Step 1: 失敗するテストを書く**（名前付きの専用クリップボードを使い、最後に `releaseGlobally()`）
  - `returnsCopiedTextAndRestoresOriginal`: 元は「original」。postCopy の中で「Docker」を書き込む → 返り値は「Docker」で、その後クリップボードは「original」に戻っている。
  - `unchangedClipboardReturnsNilAndRestores`: postCopy で何もしない → nil が返り、クリップボードは「original」のまま。
  - `restoresNonTextItems`: 元が PNG データのとき、読んだ後も PNG のバイト列が同じ。
- [ ] **Step 2: `swift test --filter SelectionCopierTests` を実行する。** 期待結果: FAIL。
- [ ] **Step 3: 実装する。**
- [ ] **Step 4: 同じテストを実行し、続けて `swift test` を実行する。** 期待結果: PASS。
- [ ] **Step 5: コミットする** `feat: ⌘C で選択中の文字を読み、クリップボードを戻す`

---

### Task 5: FoundationModelsJudge

**Files:**
- Create: `Sources/VoiceInputCore/Correction/FoundationModelsJudge.swift`
- Test: `Tests/VoiceInputCoreTests/FoundationModelsJudgeLiveTests.swift`

**Interfaces:**
- Consumes: `CorrectionJudge`（Task 3）
- Produces:
  - `public enum JudgeAvailability: Equatable, Sendable { case available; case unavailable(String) }`。`String` は設定画面に出す 1 行の文言。
  - `public enum OnDeviceJudge { public static func make() -> (judge: CorrectionJudge?, availability: JudgeAvailability) }`。文言は次のとおり。
    - macOS 26 未満、または FoundationModels を import できない: 「macOS 26 以降でないため、置き換えは登録されません」
    - `.deviceNotEligible`: 「この Mac では端末内AIを使えないため、置き換えは登録されません」
    - `.appleIntelligenceNotEnabled`: 「Apple Intelligence がオフのため、置き換えは登録されません」
    - `.modelNotReady`: 「端末内AIを準備中のため、置き換えは登録されません」
    - 日本語に対応していない（`supportedLanguages` に ja がない）: 「端末内AIが日本語に対応していないため、置き換えは登録されません」
  - `@available(macOS 26, *) struct FoundationModelsJudge: CorrectionJudge`。呼び出しごとに `LanguageModelSession` を新しく作る。
    - `locateSource` は `@Generable struct SourceSpan { @Guide(description: "sentence の中からそのまま抜き出した、word に直された部分。見つからなければ空文字") var span: String }` で受け取る。
    - `isCommonWord` は `@Generable struct WordKind { @Guide(description: "日常的に使われる普通の日本語・英語の言葉なら true。誤認識でしか出てこない言葉や、固有名詞・専門用語なら false") var isCommon: Bool }` で受け取る。

- [ ] **Step 1: ライブテストを書く。** `.enabled(if: ProcessInfo.processInfo.environment["VOICEINPUT_FM_TESTS"] == "1")` で、環境変数があるときだけ動かす。
  - `locatesDockerSource`: `locateSource(of: "Docker", in: "どうかコンテナを再起動してからAPIを確認します。")` が "どうか" を返す。
  - `classifiesCommonWords`: 「どうか」は true、「キューバーニーツ」は false。
- [ ] **Step 2: `VOICEINPUT_FM_TESTS=1 swift test --filter FoundationModelsJudgeLiveTests` を実行する。** 期待結果: 実装前なので FAIL（型がない）。
- [ ] **Step 3: 実装する。** 指示文（instructions）は短く、例を 2 つ含める。
- [ ] **Step 4: 同じコマンドを 3 回実行し、結果を記録する。** 期待結果: PASS。端末内AIの答えは毎回同じとは限らないので、1 回でも失敗したらその答えを報告に書き、指示文を直す。あわせて `swift test`（環境変数なし）が PASS し、ライブテストは skip になることを確かめる。
- [ ] **Step 5: コミットする** `feat: 端末内AIで直しの置き換え元と普通の言葉かどうかを判断する`

---

### Task 6: キー監視と登録の流れ（App）

**Files:**
- Modify: `App/GlobalKeyMonitor.swift`, `App/AppCoordinator.swift`
- Create: `App/SelectedText.swift`

**Interfaces:**
- Consumes: Task 1〜5 のすべて、既存の `showOverlayMessage(_:)`、`updateGlossary(_:)`、`history`、`sessionState`、`IsSecureEventInputEnabled()`
- Produces:
  - `GlobalKeyMonitor.init(watched:shortcut:onEvent:onShortcut:onDisabled:)`。`shortcut: @Sendable () -> Shortcut?` と `onShortcut: @Sendable () -> Void` を足す。
    - keyDown が `shortcut()?.matches(keyCode:cgFlags:)` に一致したら、`onShortcut()` を呼び、イベントを握りつぶす。`.otherKeyDown` は通知しない。
    - 対応する keyUp も握りつぶす（keyCode が同じ keyUp は、直前の keyDown を握りつぶしていたら握りつぶす）。
    - オートリピートの keyDown（`keyboardEventAutorepeat` が 1）は、握りつぶすだけで `onShortcut` は呼ばない。
  - `enum SelectedText { @MainActor static func read(copier: SelectionCopier) async -> String? }`。まず AX（システム全体の要素 → `kAXFocusedUIElementAttribute` → `kAXSelectedTextAttribute`）で読む。空なら `copier.copySelection()` を使う。
  - `AppCoordinator.handleGlossaryShortcut()`（MainActor）。

**決められた流れ（spec 5〜7 章）:**
1. 直前の登録があり、その表示から 3 秒以内なら、`CorrectionRegistrar.undo` → `updateGlossary` → 「登録を取り消しました」と表示して終わる。
2. `sessionState != .idle` なら「処理中です」と表示して終わる。
3. Secure Event Input がオンなら「パスワード入力中は使えません」と表示して終わる。
4. `SelectedText.read` で読む。nil なら「文字を選んでからキーを押してください」、200 文字を超えたら「選んだ範囲が長すぎます」と表示して終わる。
5. `CorrectionMatcher.match(selection:history:now:)` を呼ぶ。nil なら「登録できる直しが見つかりませんでした」と表示して終わる。
6. `CorrectionRegistrar(judge: OnDeviceJudge.make().judge)` で register する。judge は起動時に 1 回作ってとっておく。nil なら 5 と同じ表示。そうでなければ `updateGlossary` して `message` を表示し、取り消し用に Registration と時刻を覚える。
7. 2 回目以降のキーが、処理の途中（4〜6 の await 中）で押された場合は無視する。

- [ ] **Step 1: 上の内容を実装する。** 判断の部分は Core にあるので、ここはつなぐだけにする。
- [ ] **Step 2: `scripts/build.sh` と `swift test` を実行する。** 期待結果: `** BUILD SUCCEEDED **`（App/ の新しい警告なし）、テストはすべて PASS。
- [ ] **Step 3: 起動を確かめる。** アプリを起動して 5 秒以上動き続け、`log show` に落ちた記録がないことを確かめてから終了する。
- [ ] **Step 4: コミットする** `feat: 登録キーで直しを用語集に登録する`

---

### Task 7: 設定画面と手での確認項目

**Files:**
- Modify: `App/Windows/SettingsView.swift`, `App/AppCoordinator.swift`, `docs/manual-checks.md`

**Interfaces:**
- Consumes: `Shortcut`、`Shortcut.isAllowed`（Task 1）、`JudgeAvailability`（Task 5）
- Produces: `AppCoordinator` に `@Published private(set) var judgeAvailability: JudgeAvailability` を足す。

- [ ] **Step 1: 設定画面に「用語集に登録するキー」の行を足す。** 既存の録音キーの行と同じ見た目にする。
  - 「押して設定」を押すと、次の keyDown を取り込む（修飾キー + keyCode。keyLabel は `charactersIgnoringModifiers` を大文字にしたもの）。
  - `Shortcut.isAllowed` が false なら「このキーは使えません」と出して取り込みを続ける。Esc で取り消せる。
  - 取り込みの間は、既存の録音キーの取り込みと同じく、キー監視を止める。アプリが手前でなくなったり、ウィンドウが閉じたり、10 秒たったりしたら、取り込みを終える。
- [ ] **Step 2: AI の状態を 1 行出す。** `judgeAvailability` が `.unavailable(文言)` ならその文言を、`.available` なら「端末内AIで置き換えを判断します」を出す。
- [ ] **Step 3: `docs/manual-checks.md` に「直した単語の登録」の節を足す。** spec 9 章の「手で確かめること」の各項目と、Review Focus の 1・4 を、チェックボックスで書く。
- [ ] **Step 4: `scripts/build.sh` と `swift test`、起動の確認をする。** 期待結果: Task 6 と同じ。
- [ ] **Step 5: コミットする** `feat: 用語集に登録するキーの設定と端末内AIの状態を表示する`

---

## 完了時

- `swift test` がすべて PASS し、`scripts/build.sh` が成功すること。
- `VOICEINPUT_FM_TESTS=1` のライブテストの結果（3 回分）が記録されていること。
- superpowers:finishing-a-development-branch に従い、PR 経由でマージすること。
