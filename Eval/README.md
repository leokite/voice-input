# Eval

精度評価用のケース集。`cases.json` は `[{"audio":"001.pcm","expected":"...","group":"ja"}]` の形式で、
`audio` は `Eval/` からの相対パス。`group` は省略できる（1〜5 が `ja`、6〜10 が `en`、11〜20 が `mixed`）。音声は 16 kHz モノラル s16le のヘッダなし PCM。

## 実行

```
SONIOX_API_KEY=... swift run voice-eval Eval [--no-glossary]
```

`SONIOX_API_KEY` がなければキーチェーンのキーを使う。用語集は `~/Library/Application Support/VoiceInput/glossary.json`、
フィラーは同じ場所の `settings.json` から読む。

ローカル（WhisperKit）で測るときは API キーは要らない。モデルは `~/Library/Application Support/VoiceInput/Models` から読む。
`--install-local` を付けると、未導入なら先にダウンロードする（約 1.5GB。通信はこのときだけ）。

```
swift run voice-eval Eval --engine local [--install-local] [--glossary Eval/glossary.json]
```

`Eval/glossary.json` は試作で使った 18 語の用語集。`--glossary <path>` で用語集のファイルを指定する（読むだけ）。
`--engine` は `soniox`（既定）か `local`。

`group` が付いたケースがあると、最後にグループごとの平均も出る。ローカルでは次の合格基準（設計書 9）で PASS / FAIL を出す。
`Eval/glossary.json` を付けて測る。

| グループ | 基準 |
|---|---|
| ja（日本語のみ） | 0.97 以上 |
| en（英語のみ） | 0.97 以上 |
| mixed（混在） | 0.85 以上 |
| 全体 | 0.91 以上 |

## 仮音声の再生成

`say` による合成音声（日本語は Kyoko、英語は Samantha）。

```
scripts/make-eval-audio.sh "<text>" Eval/001.pcm [voice]
```

## 自分の声に差し替える

1. 16 kHz モノラルで文を録音する（例: QuickTime で録音して `afconvert -f WAVE -d LEI16@16000 -c 1 in.m4a out.wav`）。
2. WAV のヘッダを除いた生 PCM にする（`scripts/make-eval-audio.sh` 内の perl と同じ要領で `data` チャンクだけを取り出す）。
3. `Eval/NNN.pcm` を置き換える。`expected` を変えるなら `cases.json` も直す。

## 「普通の言葉か」の判定精度（judge-eval）

用語集への登録で使う、端末内AI（Foundation Models）の判定を測る。`judge-cases.json` は
`[{"word":"どうか","common":true,"category":"common-ja"}]` の形式で、`common` が正解（普通の言葉なら true）。
正解ラベルとカテゴリは作者の判断なので、自分の使う語に合わせて足したり直したりする。

```
swift run judge-eval [--cases Eval/judge-cases.json] [--runs 3]
```

Apple Intelligence がオンの macOS 26 以降の Mac でだけ動く。語ごとに `--runs` 回聞き、全体とカテゴリ別の正解率、
間違いの向き、答えがぶれた語、応答時間を出す。普通の言葉を「普通でない」と答える間違いは、置き換えが誤って登録されるので、
特に見る。

指示文を調整するときは、調整用の `judge-cases.json` と、調整に使わない確認用の `judge-holdout.json` の両方で測る
（調整用だけで測ると、その語だけに合う指示文になる）。差は 1〜2 点ほどぶれるので、`--runs 5` 以上で比べる。
2026-11-03 の測定（この Mac、`--runs 5`）: 調整用 90.5%、確認用 80.6%。技術名のカタカナ（リアクト、パイソンなど）を
「普通」と答えやすい。例を足して基準を書いた指示文も試したが、差は誤差の範囲で、普通の言葉を誤って「普通でない」と答える回数は
増えたので採用しなかった。確認用の「ビュー」「ラスト」「スウィフト」は、普通の言葉としても使われるので、正解ラベルが微妙。

## 置き換え元探しの方式（source-eval）

オフラインで、OpenAI の代わりに端末内AIで置き換え元を探せるかを測る。`source-cases.json` は
`[{"sentence":"…","word":"Docker","source":"どうか","set":"tuning"}]` の形式（`source` が null なら直しではない文、
`set` は `tuning`（調整用）か `holdout`（確認用））。

```
swift run source-eval [--runs 3] [--set tuning|holdout] [--strategy free|choose|snapped|phonetic|hybrid|openai] [--verbose]
```

OpenAI と比べるときは `OPENAI_API_KEY` と `OPENAI_MODEL` を入れて `--strategy openai` を付ける。

2026-11-03 の測定（この Mac、`--runs 3`、置き換え元がある文のうち、確認用 holdout のみ抜粋）:

| 方式 | 内容 | 結果 |
|---|---|---|
| free | AI が文から自由に抜き出す | 断片や文全体を答えることが多く、正解率は 4 割台 |
| choose | 読みの近い候補 6 個から AI が選ぶ | 候補に正解は 36/36 入るが、AI が選び損ねる（4〜5 割） |
| snapped | free の答えを候補の区切りに直す | 5〜6 割。free より誤答が半分に |
| phonetic | AI なし。読みがいちばん近い候補を答える | 確認用で誤答 0、見逃し 18/48（英語の読み: SQL、API、AWS など） |
| hybrid | phonetic で見つからなければ snapped | 確認用で正解 69%、誤答 12/48（直しではない文 3 を含む）。調整用は 86% |

候補は、ひらがな・カタカナ・英数字・漢字の切れ目で区切り、端の助詞と語尾（です・ます）を外したもの。
AI に聞く前にこの候補と読みの近さで探す形が、いちばん安全で効く。
