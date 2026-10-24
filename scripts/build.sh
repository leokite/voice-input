#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# 署名のチームがないと ad-hoc 署名になり、ビルドのたびにマイクとアクセシビリティの許可が外れ、
# キーチェーンの確認も出るようになる。
if [ ! -f Local.xcconfig ]; then
  echo "error: Local.xcconfig がありません。次の 1 行を書いた Local.xcconfig をリポジトリの直下に作ってください:" >&2
  echo "  DEVELOPMENT_TEAM = <あなたの Team ID>" >&2
  exit 1
fi
xcodegen generate
xcodebuild -project VoiceInput.xcodeproj -scheme VoiceInput -configuration Debug \
  -derivedDataPath build -allowProvisioningUpdates build
mkdir -p ~/Applications
rm -rf ~/Applications/VoiceInput.app
cp -R build/Build/Products/Debug/VoiceInput.app ~/Applications/
