#!/bin/zsh
# Builds Touchintosh and the installer, stages the shareable folder in dist/Touchintosh-Installer
# and zips it to dist/Touchintosh-Installer.zip.
# Needs the Xcode Command Line Tools (xcode-select --install). Intel Macs only.
#   zsh Source/build.sh
set -e
SRC=${0:A:h}
ROOT=${SRC:h}
DIST=$ROOT/dist
OUT=$(mktemp -d)
TARGET=x86_64-apple-macos13.0
VERSION=3.0

echo "Building Touchintosh…"
P=$OUT/Touchintosh.app
mkdir -p $P/Contents/MacOS $P/Contents/Resources
( cd $SRC/Touchintosh && swiftc -O -target $TARGET main.swift Touch.swift Settings.swift MenuBar.swift ButtonTest.swift Buttons.swift \
    Glide.swift KeyboardLayout.swift Keyboard.swift KeyboardView.swift KeyboardInput.swift -o $P/Contents/MacOS/Touchintosh )
# Builds the keyboard's word lists from the spell checker on the user's Mac (see Glide.swift).
swiftc -O -target $TARGET $SRC/Touchintosh/lexgen/lexgen.swift -o $P/Contents/MacOS/lexgen
cp $SRC/Touchintosh/Info.plist $P/Contents/Info.plist
/usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion 13.0" -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion ${VERSION//./}" $P/Contents/Info.plist
cp $SRC/Touchintosh/icon/AppIcon.icns $P/Contents/Resources/AppIcon.icns
codesign -f -s - $P/Contents/MacOS/lexgen
codesign -f -s - $P

echo "Building the installer…"
I="$OUT/Touchintosh Installer.app"
mkdir -p "$I/Contents/MacOS" "$I/Contents/Resources/Driver"
swiftc -O -target $TARGET $SRC/Installer/Installer.swift -o "$I/Contents/MacOS/Touchintosh Installer"
cat > "$I/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Touchintosh Installer</string>
<key>CFBundleIdentifier</key><string>com.oscacace.Touchintosh.Installer</string>
<key>CFBundleName</key><string>Touchintosh Installer</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>${VERSION//./}</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSAppleEventsUsageDescription</key><string>Runs the driver tool with your administrator password and can restart the Mac when you ask.</string>
</dict></plist>
EOF
cp $SRC/Touchintosh/icon/AppIcon.icns "$I/Contents/Resources/AppIcon.icns"
cp $ROOT/Driver/pentool.sh $ROOT/Driver/patches.conf "$I/Contents/Resources/Driver/"
ditto $P "$I/Contents/Resources/Touchintosh.app"
codesign -f -s - --deep "$I"

echo "Staging dist/Touchintosh-Installer…"
STAGE=$DIST/Touchintosh-Installer
rm -rf $STAGE $DIST/Touchintosh-Installer.zip
mkdir -p $STAGE
ditto "$I" "$STAGE/Touchintosh Installer.app"
ditto $ROOT/Driver $STAGE/Driver
ditto $ROOT/Source $STAGE/Source
cp $ROOT/README.md $ROOT/CLAUDE.md $ROOT/LICENSE $STAGE/
rm -rf $OUT
( cd $DIST && ditto -c -k --keepParent Touchintosh-Installer Touchintosh-Installer.zip )
echo "Done: $STAGE"
echo "      $DIST/Touchintosh-Installer.zip"
