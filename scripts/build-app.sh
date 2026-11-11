#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
# The SwiftPM product, which names the executable and its resource bundle.
PRODUCT="Plinth"
APP_DIR="$PROJECT_DIR/dist/Plinth.app"
# Plinth was called Slant Studio. A build of the old app is never removed here: it is the owner's way back, and it
# may be running. The script only mentions it once Plinth is built (see the end).
LEGACY_APP_DIR="$PROJECT_DIR/dist/Slant Studio.app"
# Optional: a code-signing identity on this Mac (its name as Keychain Access shows it, or its SHA-1 hash), such as a
# self-signed "Plinth Local" certificate (see README, "A stable signature for local builds"). Unset or empty signs ad
# hoc, as before: that signature changes with every build, so macOS asks again for Keychain access after each rebuild.
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
SIGN_HASH=""

# Prints the SHA-1 hash of the one valid code-signing identity whose name or hash is exactly $1. Returns 1 when there
# is none (missing, expired, revoked or not trusted for code signing) and 2 when more than one has that name.
find_signing_identity() {
    local wanted="$1" line hash name found="" count=0
    local pattern='^[[:space:]]*[0-9]+\)[[:space:]]+([0-9A-Fa-f]{40})[[:space:]]+"(.*)"$'
    local wanted_upper
    wanted_upper="$(printf '%s' "$wanted" | tr '[:lower:]' '[:upper:]')"
    while IFS= read -r line; do
        [[ $line =~ $pattern ]] || continue
        hash="${BASH_REMATCH[1]}"
        name="${BASH_REMATCH[2]}"
        if [ "$name" = "$wanted" ] || [ "$(printf '%s' "$hash" | tr '[:lower:]' '[:upper:]')" = "$wanted_upper" ]; then
            if [ "$hash" != "$found" ]; then
                count=$((count + 1))
                found="$hash"
            fi
        fi
    done < <(security find-identity -v -p codesigning 2>/dev/null)
    [ "$count" -eq 0 ] && return 1
    [ "$count" -gt 1 ] && return 2
    printf '%s\n' "$found"
}

# Checked before building, so a mistyped name stops at once rather than after the release build.
if [ -n "$SIGN_IDENTITY" ]; then
    FIND_STATUS=0
    SIGN_HASH="$(find_signing_identity "$SIGN_IDENTITY")" || FIND_STATUS=$?
    if [ "$FIND_STATUS" -eq 2 ]; then
        printf 'SIGN_IDENTITY="%s" matches more than one code-signing identity. Delete the extra certificate in Keychain Access, or set SIGN_IDENTITY to the SHA-1 hash shown by: security find-identity -v -p codesigning\n' "$SIGN_IDENTITY" >&2
        exit 1
    elif [ "$FIND_STATUS" -ne 0 ] || [ -z "$SIGN_HASH" ]; then
        printf 'SIGN_IDENTITY="%s" isn'"'"'t a valid code-signing identity on this Mac (missing, expired, or not trusted for code signing).\nList the valid ones with: security find-identity -v -p codesigning\nOr leave SIGN_IDENTITY unset to sign ad hoc.\n' "$SIGN_IDENTITY" >&2
        exit 1
    fi
fi

swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_DIR/$PRODUCT" "$APP_DIR/Contents/MacOS/$PRODUCT"
cp "$PROJECT_DIR/Sources/Plinth/Resources/Euclid-LICENSE.txt" "$APP_DIR/Contents/Resources/Euclid-LICENSE.txt"
# Keep the OpenAPI documents inside Contents/Resources. A SwiftPM resource
# bundle at the .app root is unsigned content and codesign rejects it.
# Newer SwiftPM build systems nest bundle resources under Contents/Resources.
# openapi.json is Plinth's patched spec; slant-openapi-upstream.json is Slant's
# unpatched spec as last reviewed, which the Slant API change check compares with.
RESOURCE_BUNDLE="$BIN_DIR/${PRODUCT}_${PRODUCT}.bundle"
for RESOURCE in openapi.json slant-openapi-upstream.json; do
    RESOURCE_SRC="$RESOURCE_BUNDLE/$RESOURCE"
    [ -f "$RESOURCE_SRC" ] || RESOURCE_SRC="$RESOURCE_BUNDLE/Contents/Resources/$RESOURCE"
    cp "$RESOURCE_SRC" "$APP_DIR/Contents/Resources/$RESOURCE"
done
# Document types: Launch Services ignores CFBundleTypeExtensions in an entry that also has LSItemContentTypes, so the
# extension claim (for files another app has typed with a different 3MF/OBJ/STL UTI) is a separate entry. All are
# Viewer/Alternate, so Plinth is offered in Open With without becoming any type's default.
# The heredoc is quoted, so nothing in it is expanded; sed fills in only the @PRODUCT@ placeholder.
sed "s/@PRODUCT@/$PRODUCT/" > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>@PRODUCT@</string>
<key>CFBundleIdentifier</key><string>io.github.tmm22.plinth</string>
<key>CFBundleName</key><string>Plinth</string>
<key>CFBundleDisplayName</key><string>Plinth</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSLocationUsageDescription</key><string>Use your current location to suggest a delivery address when you choose Use Current Location. You review the address before using it.</string>
<key>NSLocationWhenInUseUsageDescription</key><string>Use your current location to suggest a delivery address when you choose Use Current Location. You review the address before using it.</string>
<key>NSHumanReadableCopyright</key><string>Independent client for the Slant 3D API. Not affiliated with or endorsed by Slant 3D.</string>
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

ICON_TEMP="$(mktemp -d "${TMPDIR:-/tmp}/plinth-icon.XXXXXX")"
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
if [ -n "$SIGN_IDENTITY" ]; then
    # By hash, so a second certificate whose name contains this one can't make codesign's name match ambiguous.
    codesign --force --deep --sign "$SIGN_HASH" "$APP_DIR"
else
    codesign --force --deep --sign - "$APP_DIR"
fi
codesign --verify --deep --strict "$APP_DIR"
printf 'Built %s\nLaunch with: open "%s"\n' "$APP_DIR" "$APP_DIR"
if [ -n "$SIGN_IDENTITY" ]; then
    printf 'Signed with the code-signing identity "%s" (%s). Once you allow Keychain access for this build, later builds signed with it shouldn'"'"'t ask again.\n' "$SIGN_IDENTITY" "$SIGN_HASH"
else
    printf 'Signed ad hoc: macOS asks again for Keychain access after each rebuild. Set SIGN_IDENTITY to sign with a stable identity (see README).\n'
fi
if [ -d "$LEGACY_APP_DIR" ]; then
    printf 'Note: %s is still there and was left alone. Delete it once you no longer need it; until then Open With may list the app twice.\n' "$LEGACY_APP_DIR"
fi
