#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
xcodegen generate
xcodebuild -project VoiceInput.xcodeproj -scheme VoiceInput -configuration Debug \
  -derivedDataPath build -allowProvisioningUpdates build
mkdir -p ~/Applications
rm -rf ~/Applications/VoiceInput.app
cp -R build/Build/Products/Debug/VoiceInput.app ~/Applications/
