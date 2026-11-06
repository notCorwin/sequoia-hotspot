#!/bin/sh
set -eu
hotspot_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$hotspot_root"
swift build -c release --product SequoiaHotspot
hotspot_bin=$(swift build -c release --show-bin-path)
hotspot_app="/Applications/Sequoia Hotspot.app"
mkdir -p "$hotspot_app/Contents/MacOS"
cp "$hotspot_bin/SequoiaHotspot" "$hotspot_app/Contents/MacOS/SequoiaHotspot"
cp Support/Info.plist "$hotspot_app/Contents/Info.plist"
/usr/bin/codesign --force --sign - --identifier local.sequoia-hotspot.app "$hotspot_app"
/usr/bin/codesign --verify --strict "$hotspot_app"
/usr/bin/plutil -lint "$hotspot_app/Contents/Info.plist"
echo "$hotspot_app"
