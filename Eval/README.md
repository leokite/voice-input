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
