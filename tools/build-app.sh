#!/bin/bash
set -euo pipefail

root=$(cd -- "$(dirname -- "$0")/.." && pwd)
build="$root/build"
app="$build/合盖保活.app"
resources="$app/Contents/Resources"
architecture=$(/usr/bin/uname -m)
mkdir -p "$app/Contents/MacOS" "$resources" "$build/module-cache" "$build/AppIcon.iconset"

swift=(/usr/bin/xcrun swiftc -swift-version 5 -module-cache-path "$build/module-cache")
"${swift[@]}" "$root/tools/MakeIcon.swift" -o "$build/make-icon"
"$build/make-icon" "$build/AppIcon.png"
for size in 16 32 128 256 512; do
    /usr/bin/sips -z "$size" "$size" "$build/AppIcon.png" --out "$build/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
    scale=$(( size * 2 ))
    /usr/bin/sips -z "$scale" "$scale" "$build/AppIcon.png" --out "$build/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
/usr/bin/iconutil -c icns "$build/AppIcon.iconset" -o "$resources/AppIcon.icns"
/bin/cp "$build/AppIcon.iconset/icon_128x128.png" "$resources/HeaderIcon.png"

/usr/bin/osacompile -o "$resources/authorize.scpt" "$root/app/authorize.applescript"
/bin/cp -p "$root/lid-hold.command" "$resources/lid-hold.command"
/bin/cp "$root/app/authorization.sh" "$resources/authorization.sh"
"${swift[@]}" -target "$architecture-apple-macosx14.0" -O "$root"/app/*.swift -o "$app/Contents/MacOS/LidHold"

cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
    <key>CFBundleDisplayName</key><string>合盖保活</string>
    <key>CFBundleName</key><string>合盖保活</string>
    <key>CFBundleIdentifier</key><string>local.mac-lid-keep-awake.quick-launch</string>
    <key>CFBundleExecutable</key><string>LidHold</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>AppIcon.icns</string>
    <key>CFBundleShortVersionString</key><string>1.2.0</string>
    <key>CFBundleVersion</key><string>3</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
/usr/bin/codesign --force --sign - "$app"
/usr/bin/codesign --verify --strict "$app"
printf '%s\n' "$app"
