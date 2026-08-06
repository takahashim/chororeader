#!/bin/bash
# TZReader.app を組み立てる。SwiftPM の実行ファイルだけではメニューや書類種別が効かないため。
set -euo pipefail

cd "$(dirname "$0")"
CONFIG="${1:-debug}"

swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/TZReader"

APP="build/TZReader.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/TZReader"

# SwiftPM は資源を .bundle にまとめる。app の中へ持っていかないと実行時に見つからない。
BUNDLE="$(swift build -c "$CONFIG" --show-bin-path)/TZReader_TZReader.bundle"
[ -d "$BUNDLE" ] && cp -R "$BUNDLE" "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>TZReader</string>
    <key>CFBundleDisplayName</key><string>TZReader</string>
    <key>CFBundleIdentifier</key><string>net.tzreader.TZReader</string>
    <key>CFBundleExecutable</key><string>TZReader</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSSupportsAutomaticTermination</key><false/>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>EPUB</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSHandlerRank</key><string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array><string>org.idpf.epub-container</string></array>
        </dict>
        <dict>
            <key>CFBundleTypeName</key><string>PDF</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSHandlerRank</key><string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array><string>com.adobe.pdf</string></array>
        </dict>
    </array>
</dict>
</plist>
PLIST

# 署名がないと WKWebView のプロセス起動が拒否されるため、アドホック署名を付ける。
codesign --force --sign - "$APP" 2>/dev/null || true

echo "built: $APP"
