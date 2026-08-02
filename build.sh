#!/bin/zsh
set -euo pipefail

root="${0:A:h}"
cd "$root"
version=$(tr -d '[:space:]' < VERSION)

if [[ ! "$version" =~ '^[0-9]+(\.[0-9]+){1,2}$' ]]; then
  print -u2 'VERSION must contain a version such as 1.0.0.'
  exit 1
fi

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
CLANG_MODULE_CACHE_PATH=/private/tmp/sonoslastfm-clang-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/sonoslastfm-swift-cache \
swift build -c release

app="build/SonosLastFM.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp .build/release/SonosLastFM "$app/Contents/MacOS/SonosLastFM"
cp Assets/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
cp Info.plist "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $version" "$app/Contents/Info.plist"

print "Built SonosLastFM $version at $app"
