#!/bin/zsh
# Builds PenBridge and the installer, stages the shareable folder in dist/PenBridge-Installer
# and zips it to dist/PenBridge-Installer.zip.
# Needs the Xcode Command Line Tools (xcode-select --install). Intel Macs only.
#   zsh Source/build.sh
set -e
SRC=${0:A:h}
ROOT=${SRC:h}
DIST=$ROOT/dist
OUT=$(mktemp -d)
TARGET=x86_64-apple-macos13.0
VERSION=2.1

echo "Building PenBridge…"
P=$OUT/PenBridge.app
mkdir -p $P/Contents/MacOS $P/Contents/Resources
( cd $SRC/PenBridge && swiftc -O -target $TARGET main.swift Touch.swift Settings.swift MenuBar.swift ButtonTest.swift Buttons.swift -o $P/Contents/MacOS/PenBridge )
cp $SRC/PenBridge/Info.plist $P/Contents/Info.plist
/usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion 13.0" -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion ${VERSION//./}" $P/Contents/Info.plist
cp $SRC/PenBridge/icon/AppIcon.icns $P/Contents/Resources/AppIcon.icns
codesign -f -s - $P

echo "Building the installer…"
I="$OUT/PenBridge Installer.app"
mkdir -p "$I/Contents/MacOS" "$I/Contents/Resources/Driver"
swiftc -O -target $TARGET $SRC/Installer/Installer.swift -o "$I/Contents/MacOS/PenBridge Installer"
cat > "$I/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>PenBridge Installer</string>
<key>CFBundleIdentifier</key><string>com.oscacace.PenBridge.Installer</string>
<key>CFBundleName</key><string>PenBridge Installer</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>${VERSION//./}</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSAppleEventsUsageDescription</key><string>Runs the driver tool with your administrator password and can restart the Mac when you ask.</string>
</dict></plist>
EOF
cp $SRC/PenBridge/icon/AppIcon.icns "$I/Contents/Resources/AppIcon.icns"
cp $ROOT/Driver/pentool.sh $ROOT/Driver/patches.conf "$I/Contents/Resources/Driver/"
ditto $P "$I/Contents/Resources/PenBridge.app"
codesign -f -s - --deep "$I"

echo "Staging dist/PenBridge-Installer…"
STAGE=$DIST/PenBridge-Installer
rm -rf $STAGE $DIST/PenBridge-Installer.zip
mkdir -p $STAGE
ditto "$I" "$STAGE/PenBridge Installer.app"
ditto $ROOT/Driver $STAGE/Driver
ditto $ROOT/Source $STAGE/Source
cp $ROOT/README.md $ROOT/CLAUDE.md $ROOT/LICENSE $STAGE/
rm -rf $OUT
( cd $DIST && ditto -c -k --keepParent PenBridge-Installer PenBridge-Installer.zip )
echo "Done: $STAGE"
echo "      $DIST/PenBridge-Installer.zip"
