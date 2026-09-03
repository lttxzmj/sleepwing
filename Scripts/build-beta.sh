#!/bin/sh
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
app_dir="$project_dir/.build/perch-app/Sleepwing.app"
release_dir="$project_dir/.build/perch-beta"
version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$project_dir/Packaging/Info.plist")
build=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$project_dir/Packaging/Info.plist")
archive_path="$release_dir/Sleepwing-$version-$build-beta-macOS-arm64.zip"
notary_result="$release_dir/notary-result.json"
manifest_path="$release_dir/release-manifest.json"
entitlements_path="$release_dir/signed-entitlements.plist"
identity=${PERCH_SIGN_IDENTITY:-}
notary_profile=${PERCH_NOTARY_PROFILE:-}

archive_app() {
  /bin/rm -f "$archive_path"
  COPYFILE_DISABLE=1 /usr/bin/ditto -c -k --keepParent --norsrc --noextattr \
    "$app_dir" "$archive_path"
  /usr/bin/unzip -tq "$archive_path" >/dev/null
  if /usr/bin/unzip -Z1 "$archive_path" \
    | /usr/bin/grep -E '(^|/)\._|^__MACOSX/' >/dev/null; then
    echo "The release archive contains macOS metadata sidecars." >&2
    exit 1
  fi
}

PERCH_REQUIRE_DISTRIBUTION=1 "$project_dir/Scripts/release-preflight.sh"

"$project_dir/Scripts/build-app.sh"
if [ -d "$release_dir" ]; then
  rm -rf "$release_dir"
fi
mkdir -p "$release_dir"

/usr/bin/codesign --force --options runtime --timestamp \
  --sign "$identity" "$app_dir/Contents/MacOS/PerchRelay"
/usr/bin/codesign --force --options runtime --timestamp \
  --sign "$identity" "$app_dir/Contents/MacOS/Perch"
/usr/bin/codesign --force --options runtime --timestamp \
  --entitlements "$project_dir/Packaging/Perch.entitlements" \
  --sign "$identity" "$app_dir"

/usr/bin/codesign --verify --deep --strict --verbose=2 "$app_dir"
/usr/bin/codesign -d --entitlements :- "$app_dir" >"$entitlements_path" 2>/dev/null || true
if /usr/libexec/PlistBuddy -c "Print :com.apple.security.get-task-allow" "$entitlements_path" 2>/dev/null \
  | /usr/bin/grep -qi true; then
  echo "Release signing must not include com.apple.security.get-task-allow." >&2
  exit 1
fi

signing_info=$(/usr/bin/codesign -d --verbose=4 "$app_dir" 2>&1)
printf '%s\n' "$signing_info" | /usr/bin/grep -F "runtime" >/dev/null \
  || {
    echo "Hardened Runtime is missing from the signed app." >&2
    exit 1
  }
printf '%s\n' "$signing_info" | /usr/bin/grep -F "Timestamp=" >/dev/null \
  || {
    echo "A secure signing timestamp is missing." >&2
    exit 1
  }

main_archs=$(/usr/bin/lipo -archs "$app_dir/Contents/MacOS/Perch")
relay_archs=$(/usr/bin/lipo -archs "$app_dir/Contents/MacOS/PerchRelay")
[ "$main_archs" = "arm64" ] && [ "$relay_archs" = "arm64" ] \
  || {
    echo "The current public beta must contain arm64-only Perch and PerchRelay binaries." >&2
    exit 1
  }

archive_app

/usr/bin/xcrun notarytool submit "$archive_path" \
  --keychain-profile "$notary_profile" \
  --wait \
  --output-format json >"$notary_result"
notary_status=$(/usr/bin/plutil -extract status raw "$notary_result")
[ "$notary_status" = "Accepted" ] \
  || {
    echo "Apple notarization did not accept this archive. See $notary_result." >&2
    exit 1
  }

/usr/bin/xcrun stapler staple "$app_dir"
/usr/bin/xcrun stapler validate "$app_dir"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$app_dir"
archive_app
/usr/sbin/spctl --assess --type execute --verbose=4 "$app_dir"

sha256=$(/usr/bin/shasum -a 256 "$archive_path" | /usr/bin/awk '{print $1}')
commit=$(git -C "$project_dir" rev-parse HEAD)
generated_at=$(/bin/date -u +"%Y-%m-%dT%H:%M:%SZ")
notary_id=$(/usr/bin/plutil -extract id raw "$notary_result")

{
  printf '{\n'
  printf '  "product": "Sleepwing",\n'
  printf '  "version": "%s",\n' "$version"
  printf '  "build": "%s",\n' "$build"
  printf '  "bundleIdentifier": "app.sleepwing.Sleepwing",\n'
  printf '  "minimumMacOS": "14.0",\n'
  printf '  "architecture": "arm64",\n'
  printf '  "gitCommit": "%s",\n' "$commit"
  printf '  "notarizationId": "%s",\n' "$notary_id"
  printf '  "sha256": "%s",\n' "$sha256"
  printf '  "generatedAt": "%s",\n' "$generated_at"
  printf '  "archive": "%s"\n' "$(basename "$archive_path")"
  printf '}\n'
} >"$manifest_path"

echo "Notarized beta archive: $archive_path"
echo "Release manifest: $manifest_path"
