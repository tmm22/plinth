#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
APP_DIR="$PROJECT_DIR/dist/Slant Studio.app"
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_DIR/SlantStudio" "$APP_DIR/Contents/MacOS/SlantStudio"
cp "$PROJECT_DIR/Sources/SlantStudio/Resources/Euclid-LICENSE.txt" "$APP_DIR/Contents/Resources/Euclid-LICENSE.txt"
# Keep the OpenAPI document inside Contents/Resources. A SwiftPM resource
# bundle at the .app root is unsigned content and codesign rejects it.
# Newer SwiftPM build systems nest bundle resources under Contents/Resources.
OPENAPI_SRC="$BIN_DIR/SlantStudio_SlantStudio.bundle/openapi.json"
[ -f "$OPENAPI_SRC" ] || OPENAPI_SRC="$BIN_DIR/SlantStudio_SlantStudio.bundle/Contents/Resources/openapi.json"
cp "$OPENAPI_SRC" "$APP_DIR/Contents/Resources/openapi.json"
# Document types: Launch Services ignores CFBundleTypeExtensions in an entry that also has LSItemContentTypes, so the
# extension claim (for files another app has typed with a different 3MF/OBJ/STL UTI) is a separate entry. All are
# Viewer/Alternate, so Slant Studio is offered in Open With without becoming any type's default.
cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>SlantStudio</string>
<key>CFBundleIdentifier</key><string>app.slantstudio.mac</string>
<key>CFBundleName</key><string>Slant Studio</string>
<key>CFBundleDisplayName</key><string>Slant Studio</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSLocationUsageDescription</key><string>Use your current location to suggest a delivery address when you choose Use Current Location. You review the address before using it.</string>
<key>NSLocationWhenInUseUsageDescription</key><string>Use your current location to suggest a delivery address when you choose Use Current Location. You review the address before using it.</string>
<key>NSHumanReadableCopyright</key><string>Independent client. Not affiliated with Slant 3D.</string>
<key>CFBundleDocumentTypes</key><array>
<dict><key>CFBundleTypeName</key><string>STL Model</string><key>CFBundleTypeRole</key><string>Viewer</string><key>LSHandlerRank</key><string>Alternate</string><key>LSItemContentTypes</key><array><string>public.standard-tesselated-geometry-format</string></array></dict>
<dict><key>CFBundleTypeName</key><string>OBJ Model</string><key>CFBundleTypeRole</key><string>Viewer</string><key>LSHandlerRank</key><string>Alternate</string><key>LSItemContentTypes</key><array><string>public.geometry-definition-format</string></array></dict>
<dict><key>CFBundleTypeName</key><string>3MF Model</string><key>CFBundleTypeRole</key><string>Viewer</string><key>LSHandlerRank</key><string>Alternate</string><key>LSItemContentTypes</key><array><string>io.3mf.3mf</string></array></dict>
<dict><key>CFBundleTypeName</key><string>3D Model File</string><key>CFBundleTypeRole</key><string>Viewer</string><key>LSHandlerRank</key><string>Alternate</string><key>CFBundleTypeExtensions</key><array><string>stl</string><string>obj</string><string>3mf</string></array></dict>
</array>
<key>UTImportedTypeDeclarations</key><array>
<dict><key>UTTypeIdentifier</key><string>io.3mf.3mf</string><key>UTTypeDescription</key><string>3D Manufacturing Format</string><key>UTTypeConformsTo</key><array><string>public.data</string><string>public.3d-content</string></array><key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key><array><string>3mf</string></array><key>public.mime-type</key><array><string>model/3mf</string></array></dict></dict>
</array>
</dict></plist>
PLIST

ICON_TEMP="$(mktemp -d "${TMPDIR:-/tmp}/slantstudio-icon.XXXXXX")"
trap 'rm -rf "$ICON_TEMP"' EXIT
mkdir -p "$ICON_TEMP/AppIcon.iconset"
cat > "$ICON_TEMP/draw.swift" <<'SWIFT'
import AppKit
let destination = CommandLine.arguments[1]
func polygon(_ points: [NSPoint], color: NSColor) {
    let shape = NSBezierPath()
    shape.move(to: points[0])
    for point in points.dropFirst() { shape.line(to: point) }
    shape.close()
    color.setFill()
    shape.fill()
}
let image = NSImage(size: NSSize(width: 1024, height: 1024))
image.lockFocus()
NSColor(calibratedRed: 0.08, green: 0.11, blue: 0.16, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: 20, y: 20, width: 984, height: 984), xRadius: 210, yRadius: 210).fill()
polygon([.init(x: 512,y: 800),.init(x: 790,y: 650),.init(x: 512,y: 490),.init(x: 234,y: 650)], color: NSColor(calibratedRed: 0.55,green: 0.94,blue: 0.81,alpha: 1))
polygon([.init(x: 234,y: 650),.init(x: 512,y: 490),.init(x: 512,y: 188),.init(x: 234,y: 350)], color: NSColor(calibratedRed: 0.18,green: 0.68,blue: 0.55,alpha: 1))
polygon([.init(x: 512,y: 490),.init(x: 790,y: 650),.init(x: 790,y: 350),.init(x: 512,y: 188)], color: NSColor(calibratedRed: 0.12,green: 0.47,blue: 0.40,alpha: 1))
image.unlockFocus()
let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: destination))
SWIFT
# Compile rather than JIT-run: some toolchains' immediate mode doesn't link AppKit.
swiftc -O -o "$ICON_TEMP/draw" "$ICON_TEMP/draw.swift"
"$ICON_TEMP/draw" "$ICON_TEMP/icon.png"
for SIZE in 16 32 128 256 512; do
    sips -z "$SIZE" "$SIZE" "$ICON_TEMP/icon.png" --out "$ICON_TEMP/AppIcon.iconset/icon_${SIZE}x${SIZE}.png" >/dev/null
    DOUBLE=$((SIZE * 2))
    sips -z "$DOUBLE" "$DOUBLE" "$ICON_TEMP/icon.png" --out "$ICON_TEMP/AppIcon.iconset/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
done
iconutil -c icns "$ICON_TEMP/AppIcon.iconset" -o "$APP_DIR/Contents/Resources/AppIcon.icns"
plutil -lint "$APP_DIR/Contents/Info.plist"
codesign --force --deep --sign - "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"
printf 'Built %s\nLaunch with: open "%s"\n' "$APP_DIR" "$APP_DIR"
