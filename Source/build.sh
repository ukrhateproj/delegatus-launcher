#!/bin/bash
set -euo pipefail
launcher_source=$(cd "$(dirname "$0")" && pwd)
launcher_output=${1:-"$launcher_source/../package/Mac"}
mkdir -p "$launcher_output"
launcher_output=$(cd "$launcher_output" && pwd)
launcher_app="$launcher_output/Delegatus.app"
if [ -e "$launcher_app" ]; then printf '%s\n' 'Output app already exists; choose an empty output folder.' >&2; exit 2; fi
launcher_build=$(mktemp -d "${TMPDIR:-/tmp}/delegatus-build.XXXXXXXX")
trap 'rm -rf -- "$launcher_build"' EXIT
for launcher_arch in arm64 x86_64; do
    /usr/bin/swiftc "$launcher_source/Core.swift" "$launcher_source/Launcher.swift" -target "$launcher_arch-apple-macos13.0" -O -framework AppKit -framework WebKit -o "$launcher_build/$launcher_arch"
done
mkdir -p "$launcher_app/Contents/MacOS" "$launcher_app/Contents/Resources"
/usr/bin/lipo -create "$launcher_build/arm64" "$launcher_build/x86_64" -output "$launcher_app/Contents/MacOS/Delegatus"
cp "$launcher_source/Delegatus.icns" "$launcher_app/Contents/Resources/Delegatus.icns"
cp "$launcher_source/setup-runtime.sh" "$launcher_app/Contents/Resources/setup-runtime.sh"
cp "$launcher_source/Delegatus-LICENSE.txt" "$launcher_app/Contents/Resources/Delegatus-LICENSE.txt"
cat > "$launcher_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleDevelopmentRegion</key><string>uk</string>
<key>CFBundleDisplayName</key><string>Delegatus</string>
<key>CFBundleExecutable</key><string>Delegatus</string>
<key>CFBundleIconFile</key><string>Delegatus.icns</string>
<key>CFBundleIdentifier</key><string>org.delegatus.community-launcher</string>
<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
<key>CFBundleName</key><string>Delegatus</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>2.0.1</string>
<key>CFBundleVersion</key><string>4</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSHumanReadableCopyright</key><string>Community launcher, MIT. Delegatus logo: Latand/delegatus, MIT.</string>
</dict></plist>
PLIST
printf 'APPL????' > "$launcher_app/Contents/PkgInfo"
/usr/bin/codesign --force --sign "${SIGNING_IDENTITY:--}" "$launcher_app"
/usr/bin/codesign --verify --deep --strict "$launcher_app"
/usr/bin/plutil -lint "$launcher_app/Contents/Info.plist"
/usr/bin/lipo -info "$launcher_app/Contents/MacOS/Delegatus"
printf '%s\n' "$launcher_app"
