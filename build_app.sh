#!/bin/bash
set -e

# Resolve script directory dynamically
CDIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$CDIR"

echo "[Build] Compiling OpenCodexBar in release mode..."
swift build -c release

echo "[Build] Packaging OpenCodexBar.app..."
rm -rf OpenCodexBar.app
mkdir -p OpenCodexBar.app/Contents/MacOS
mkdir -p OpenCodexBar.app/Contents/Resources

cp .build/release/OpenCodexBar OpenCodexBar.app/Contents/MacOS/OpenCodexBar

# Generate Info.plist
cat << 'EOF' > OpenCodexBar.app/Contents/Info.plist
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>OpenCodexBar</string>
    <key>CFBundleIdentifier</key>
    <string>com.opencodex.OpenCodexBar</string>
    <key>CFBundleName</key>
    <string>OpenCodexBar</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.1.1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>OpenCodexBar requires microphone access for voice command input and transcription.</string>
</dict>
</plist>
EOF

chmod +x OpenCodexBar.app/Contents/MacOS/OpenCodexBar
echo "[Build] Codesigning OpenCodexBar.app with local certificate (E45810C2)..."
codesign --force --deep --sign "E45810C2C87A8196C56B58D6D62E7D1832CD6017" -r='designated => identifier "com.opencodex.OpenCodexBar"' OpenCodexBar.app
echo "[Build] OpenCodexBar.app packaged and signed successfully!"
