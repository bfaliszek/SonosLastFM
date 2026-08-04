#!/bin/zsh
set -euo pipefail

root="${0:A:h}"
cd "$root"
version=$(tr -d '[:space:]' < VERSION)
app="build/SonosLastFM.app"
archive="build/SonosLastFM-${version}.zip"
profile="SonosLastFM-notary"

"$root/build.sh"

# Use an explicit identity if DEVELOPER_ID_IDENTITY is set; otherwise use the
# first Developer ID Application identity installed in the login keychain.
identity="${DEVELOPER_ID_IDENTITY:-}"
if [[ -z "$identity" ]]; then
  identity=$(/usr/bin/security find-identity -v -p codesigning | /usr/bin/sed -n 's/.*"\(Developer ID Application:.*\)"/\1/p' | /usr/bin/head -n 1)
fi

if [[ -z "$identity" ]]; then
  print -u2 "No Developer ID Application certificate was found in the login keychain."
  exit 1
fi

/usr/bin/codesign --force --options runtime --timestamp --sign "$identity" "$app"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$app"

/usr/bin/ditto -c -k --keepParent "$app" "$archive"
/usr/bin/xcrun notarytool submit "$archive" --keychain-profile "$profile" --wait
/usr/bin/xcrun stapler staple "$app"
/usr/bin/xcrun stapler validate "$app"

# Recreate the archive so the stapled app is the file uploaded to GitHub.
/usr/bin/ditto -c -k --keepParent "$app" "$archive"
/usr/sbin/spctl --assess --type execute --verbose=4 "$app"

print "Signed and notarized SonosLastFM $version"
print "GitHub release archive: $archive"
