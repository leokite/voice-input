# VoiceInput セットアップ手順

Mac に VoiceInput を入れる手順です。VoiceInput は配布用のアプリではなく、手元でソースからビルドして使います。

所要時間の目安は 30〜60 分です。Xcode のダウンロードにかかる時間が大半を占めます。

## 0. 始める前に

Mac の管理ポリシーによっては、途中で手順が進められなくなることがあります。管理者がいる Mac では、次の点を先に確認してください。

- **音声を外部のサービスに送ってよいか**: VoiceInput は、録音した音声を Soniox（米国のクラウドサービス）に送って文字起こしします。機密情報を話す可能性がある場合は、送ってよいかを確認してください。送れない場合は、ローカル（オフライン）モードを使えば、音声も文字も Mac の外に出ません（モデルのダウンロードが 1 回だけ必要で、約 1.5GB です。macOS 14 以降の Apple Silicon で使えます）。手順は「6.5 ローカル（オフライン）モードを使う」を見てください。
- **アクセシビリティとマイクを許可できるか**: VoiceInput は、どのアプリでも使えるように、キー入力の監視（アクセシビリティ）とマイクを使います。MDM（端末管理）で、これらの許可が禁止されていることがあります。
- **Xcode と Homebrew を入れてよいか**: 開発ツールのインストールが制限されていることがあります。
- **Apple ID で Xcode にサインインしてよいか**: アプリの署名に Apple ID（無料で可）が必要です。その Mac で Apple ID を使ってよいかを確認してください。

## 1. 動作環境

- Apple Silicon の Mac（M1 以降）
- macOS 14 以降
- 空き容量: 40 GB 程度（Xcode が大半）
- Soniox のアカウントと API キー（料金はリアルタイム認識で 1 時間あたり 0.12 ドル）

Apple Silicon かどうかは、ターミナルで確かめられます。`arm64` と出れば OK です。

```bash
uname -m
```

## 2. 開発ツールを入れる

### 2.1 Xcode

1. App Store から **Xcode** をインストールします（Command Line Tools だけでは足りません）。
2. 一度 Xcode を起動して、ライセンスに同意し、追加コンポーネントのインストールを済ませます。
3. ターミナルで、使う開発ツールを Xcode に切り替えます。

```bash
sudo xcode-select -s /Applications/Xcode.app
xcodebuild -version   # Xcode のバージョンが表示されれば OK
```

### 2.2 Homebrew と XcodeGen

Homebrew が入っていなければ、https://brew.sh の手順で入れてから、XcodeGen を入れます。

```bash
brew install xcodegen
xcodegen --version
```

## 3. ソースを取得する

```bash
mkdir -p ~/dev/src && cd ~/dev/src
git clone https://github.com/leokite/voice-input.git
cd voice-input
```

## 4. 署名の準備

アプリを毎回同じ署名でビルドするための準備です。署名が毎回変わると、ビルドのたびにマイクとアクセシビリティの許可が外れてしまいます。

### 4.1 Xcode に Apple ID でサインインする

1. Xcode を開き、「Settings」の「Accounts」を開きます。
2. 左下の「＋」から Apple ID を追加します（無料の Apple ID で構いません）。

### 4.2 署名用の証明書を作る

1. 同じ画面でサインインした Apple ID を選び、「Manage Certificates…」を押します。
2. 左下の「＋」から「Apple Development」を選びます。
3. 証明書が一覧に追加されたら閉じます。

証明書が有効になっているかを確かめます。

```bash
security find-identity -v -p codesigning
```

`1 valid identities found` のように 1 件以上表示されれば OK です。`0 valid identities found` と出る場合は、「8. うまくいかないとき」の「証明書が無効と表示される」を見てください。

### 4.3 Team ID を調べて Local.xcconfig を作る

証明書から Team ID（英数字 10 文字）を取り出します。

```bash
security find-certificate -c "Apple Development" -p \
  | openssl x509 -noout -subject \
  | sed -n 's/.*OU=\([A-Z0-9]\{10\}\).*/\1/p'
```

表示された Team ID を使って、リポジトリの直下に `Local.xcconfig` を作ります。このファイルは git の管理対象外です。

```bash
cp Local.xcconfig.example Local.xcconfig
# Local.xcconfig を開き、XXXXXXXXXX を自分の Team ID に書き換える
```

書き換えた後の中身は、次の 1 行です。

```
DEVELOPMENT_TEAM = AB12CD34EF
```

## 5. ビルドして配置する

```bash
scripts/build.sh
```

最後に `** BUILD SUCCEEDED **` と出れば成功です。アプリは `~/Applications/VoiceInput.app` に配置されます。

正しく署名されているかを確かめます。

```bash
codesign -dv ~/Applications/VoiceInput.app 2>&1 | grep -E "Authority=Apple Development|TeamIdentifier"
```

`Authority=Apple Development: …` と、自分の Team ID が表示されれば OK です。

## 6. 初回の設定

### 6.1 起動する

```bash
open ~/Applications/VoiceInput.app
```

メニューバーにマイクのアイコンが出ます。Dock には出ません。初回は「権限」の画面が自動で開きます。

### 6.2 マイクとアクセシビリティを許可する

「権限」の画面のボタンから許可するか、システム設定から直接許可します。

- **マイク**: システム設定 > プライバシーとセキュリティ > マイク で VoiceInput をオンにする
- **アクセシビリティ**: システム設定 > プライバシーとセキュリティ > アクセシビリティ で VoiceInput をオンにする

許可した後に再起動する必要はありません（数秒で反映されます）。

### 6.3 Soniox の API キーを入れる

1. Soniox Console（https://console.soniox.com）で、この Mac 用の API キーを新しく作ります。Mac ごとに別のキーにしておくと、特定の Mac だけを止めたいときに、そのキーだけを無効にできます。
2. Billing 画面で、クレジットが入っていることと、月の予算の上限が 0 になっていないことを確認します。
3. VoiceInput のメニューから「設定」を開き、「API キー」にキーを貼り付けて「保存」を押します。「保存済み」と表示されれば OK です。

注意:

- **API キーは必ず設定画面から入れてください。** ターミナルの `security add-generic-password … -w` で入れると、入力が 128 文字で切り捨てられます。Soniox のキーはそれより長いので、認証に失敗します（401）。
- API キーは macOS のキーチェーンにだけ保存されます。ファイルには書き出されません。

### 6.4 必要ならログイン時に自動で起動する

「設定」の「ログイン時に起動」をオンにします。

### 6.5 ローカル（オフライン）モードを使う（任意）

音声を Soniox に送らず、Mac の中だけで文字起こしします。ネットワークがなくても動きます。

1. VoiceInput のメニューから「設定」を開きます。
2. 「文字起こし」を「ローカル」にします。
3. 「ダウンロード」を押します。ダウンロードの前にモデルの大きさ（約 1.5GB）が表示されます。
4. 表示が「準備中」から「使える」に変われば終わりです。ダウンロードは 1 回だけで、通信するのはこのときだけです。

注意:

- ローカルのときは、Soniox の API キーは要りません。
- 「準備中」は、最初の 1 回だけモデルの準備に数分かかります。
- ローカルでは、OpenAI を使う項目と「文の区切りごと」は使えません。
- Soniox に戻すときは、「文字起こし」を「Soniox」にします。

## 7. 動作確認

1. テキストエディットを開き、新しい書類にカーソルを置きます。
2. **右 Option を短く押して離す** → 画面の下部中央に録音中の表示が出る → 話す → **もう一度右 Option を短く押す** → 文字が入る。
3. **右 Option を押し続けたまま話し、離す** → 文字が入る。
4. Option+← など、普段の Option 操作では、録音が始まらない（マイクの使用表示も出ない）。

うまく入らないときは、メニューの「履歴」に認識結果が残っていないかを確認してください。

### ほかの Mac の用語集を持ってくる（任意）

用語集、設定、履歴は次の場所に JSON で保存されています。用語集だけをコピーすれば、ほかの Mac で育てた用語集をこの Mac でも使えます。

```
~/Library/Application Support/VoiceInput/glossary.json
~/Library/Application Support/VoiceInput/settings.json
~/Library/Application Support/VoiceInput/history.json
```

コピーする前に、VoiceInput を終了しておいてください。

## 8. うまくいかないとき

| 症状 | 原因と対処 |
|---|---|
| `security find-identity` が `0 valid identities found` を返す | Apple の中間証明書（WWDR G3）が入っていない可能性があります。`curl -fsSL -o /tmp/AppleWWDRCAG3.cer https://www.apple.com/certificateauthority/AppleWWDRCAG3.cer && security add-certificates -k ~/Library/Keychains/login.keychain-db /tmp/AppleWWDRCAG3.cer` を実行してから、もう一度確かめてください。 |
| `scripts/build.sh` が `Local.xcconfig がありません` で止まる | 手順 4.3 の `Local.xcconfig` を作ってください。 |
| ビルド時に `No Account for Team` や `No signing certificate` と出る | Xcode の Accounts で Apple ID にサインインしているか、`Local.xcconfig` の Team ID が証明書の Team ID と一致しているかを確認してください。 |
| ビルド時に `App ID … is not available` と出る | Bundle ID `dev.ykazama.VoiceInput` が、別のチームですでに使われています。自分の Apple ID ではない Apple ID でビルドしようとしていないかを確認してください。別の Apple ID でビルドする場合は、`project.yml` の `bundleIdPrefix` と `PRODUCT_BUNDLE_IDENTIFIER` を自分のものに変えてください。 |
| 右 Option を押しても何も起きない | アクセシビリティが許可されていない可能性があります。メニューに「アクセシビリティの許可が必要です」が出ていないかを確認してください。JIS 配列の MacBook には右 Option がないので、「設定」で別のキー（右 Command など）に変えてください。 |
| 「API キーが正しくありません」と出る | キーが間違っているか、128 文字で切り捨てられています。設定画面から入れ直してください。 |
| 「Soniox の残高または予算が不足しています」と出る | Soniox Console の Billing で、クレジットと月の予算を確認してください。 |
| 「マイクを使用できません」と出る | マイクが許可されていないか、マイクが接続されていません。手順 6.2 を確認してください。 |
| ビルドし直したら許可が外れた | 署名が変わった可能性があります。手順 5 の `codesign` で、Team ID が前回と同じかを確認してください。 |

## 9. アップデート

```bash
cd ~/dev/src/voice-input
git pull
scripts/build.sh
```

VoiceInput が起動中の場合は、終了してからもう一度起動してください。署名が同じなので、許可や API キーはそのまま引き継がれます。

## 10. アンインストール

1. メニューから VoiceInput を終了します。
2. 「設定」で「ログイン時に起動」をオンにしていた場合は、先にオフにしておきます。
3. 次のコマンドで、アプリ、データ、API キー、許可を削除します。

```bash
rm -rf ~/Applications/VoiceInput.app
rm -rf ~/Library/Application\ Support/VoiceInput
security delete-generic-password -s dev.ykazama.VoiceInput -a apiKey
tccutil reset Microphone dev.ykazama.VoiceInput
tccutil reset Accessibility dev.ykazama.VoiceInput
```

4. 使わなくなった Soniox の API キーは、Soniox Console で無効にします。
