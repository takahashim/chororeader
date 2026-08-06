#!/bin/bash
# ChoroReader.app を組み立てる。SwiftPM の実行ファイルだけではメニューや書類種別が効かないため。
set -euo pipefail

cd "$(dirname "$0")"
CONFIG="${1:-debug}"

swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/ChoroReader"

APP="build/ChoroReader.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ChoroReader"

# SwiftPM は資源を .bundle にまとめる。app の中へ持っていかないと実行時に見つからない。
BUNDLE="$(swift build -c "$CONFIG" --show-bin-path)/ChoroReader_ChoroReader.bundle"
[ -d "$BUNDLE" ] && cp -R "$BUNDLE" "$APP/Contents/Resources/"

# アイコンは assets/icon/build.rb が焼いたものを使う。
cp ChoroReader.icns "$APP/Contents/Resources/ChoroReader.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>ChoroReader</string>
    <key>CFBundleDisplayName</key><string>ChoroReader</string>
    <key>CFBundleIdentifier</key><string>dev.chororeader.ChoroReader</string>
    <key>CFBundleExecutable</key><string>ChoroReader</string>
    <key>CFBundleIconFile</key><string>ChoroReader</string>
    <key>CFBundleIconName</key><string>ChoroReader</string>
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
