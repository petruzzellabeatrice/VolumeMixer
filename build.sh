#!/bin/zsh
# Compila VolumeMixer.
#   ./build.sh            compila e installa in ~/Applications
#   ./build.sh --release  compila per Apple Silicon e Intel e crea dist/VolumeMixer-<versione>.zip
#
# Si compila in una cartella temporanea: le cartelle sincronizzate con iCloud
# aggiungono attributi che impediscono la firma del codice.
set -e
cd "$(dirname "$0")"

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)
BUILD=$(mktemp -d)
trap 'rm -rf "$BUILD"' EXIT
APP="$BUILD/VolumeMixer.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp AppIcon.icns "$APP/Contents/Resources/"
cp Info.plist "$APP/Contents/"

compile() {
    swiftc -O -swift-version 5 -parse-as-library \
        -target "$1-apple-macos14.4" \
        -framework SwiftUI -framework AppKit -framework CoreAudio -framework AudioToolbox \
        -framework ServiceManagement \
        Sources/*.swift -o "$2"
}

if [[ "$1" == "--release" ]]; then
    compile arm64 "$BUILD/VolumeMixer-arm64"
    compile x86_64 "$BUILD/VolumeMixer-x86_64"
    lipo -create "$BUILD/VolumeMixer-arm64" "$BUILD/VolumeMixer-x86_64" \
        -output "$APP/Contents/MacOS/VolumeMixer"
else
    compile arm64 "$APP/Contents/MacOS/VolumeMixer"
fi

xattr -cr "$APP"
codesign --force --sign - "$APP"

if [[ "$1" == "--release" ]]; then
    mkdir -p dist
    ZIP="dist/VolumeMixer-$VERSION.zip"
    rm -f "$ZIP"
    ditto -c -k --norsrc --noextattr --keepParent "$APP" "$ZIP"
    echo "Creato $(pwd)/$ZIP"
else
    DEST="$HOME/Applications/VolumeMixer.app"
    mkdir -p "$HOME/Applications"
    pkill -x VolumeMixer 2>/dev/null || true
    rm -rf "$DEST"
    ditto "$APP" "$DEST"
    echo "Installata in $DEST"
fi
