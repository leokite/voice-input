# Eval

精度評価用のケース集。`cases.json` は `[{"audio":"001.pcm","expected":"..."}]` の形式で、
`audio` は `Eval/` からの相対パス。音声は 16 kHz モノラル s16le のヘッダなし PCM。

## 実行

```
SONIOX_API_KEY=... swift run voice-eval Eval [--no-glossary]
```

`SONIOX_API_KEY` がなければキーチェーンのキーを使う。用語集は `~/Library/Application Support/VoiceInput/glossary.json`、
フィラーは同じ場所の `settings.json` から読む。

## 仮音声の再生成

`say` による合成音声（日本語は Kyoko、英語は Samantha）。

```
scripts/make-eval-audio.sh "<text>" Eval/001.pcm [voice]
```

## 自分の声に差し替える

1. 16 kHz モノラルで文を録音する（例: QuickTime で録音して `afconvert -f WAVE -d LEI16@16000 -c 1 in.m4a out.wav`）。
2. WAV のヘッダを除いた生 PCM にする（`scripts/make-eval-audio.sh` 内の perl と同じ要領で `data` チャンクだけを取り出す）。
3. `Eval/NNN.pcm` を置き換える。`expected` を変えるなら `cases.json` も直す。
