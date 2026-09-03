#!/bin/sh
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
info_plist="$project_dir/Packaging/Info.plist"
require_distribution=${PERCH_REQUIRE_DISTRIBUTION:-0}
skip_tests=${PERCH_SKIP_TESTS:-0}
allow_dirty=${PERCH_ALLOW_DIRTY:-0}

export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/private/tmp/perch-clang-cache}"
export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-/private/tmp/perch-swiftpm-cache}"

fail() {
  echo "Release preflight failed: $*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"
}

for required_file in \
  "$project_dir/README.md" \
  "$project_dir/PRIVACY.md" \
  "$project_dir/SECURITY.md" \
  "$project_dir/CHANGELOG.md" \
  "$project_dir/docs/BETA_TEST.md" \
  "$project_dir/docs/RELEASE_CHECKLIST.md" \
  "$project_dir/docs/RELEASE_ACCEPTANCE_TEMPLATE.md" \
  "$project_dir/docs/STABLE_RELEASE_GATES.md" \
  "$project_dir/Scripts/verify-app-bundle.sh" \
  "$project_dir/Packaging/Perch.entitlements" \
  "$info_plist"
do
  [ -f "$required_file" ] || fail "missing $(basename "$required_file")"
done

require_command git
require_command swift
require_command plutil

/usr/bin/plutil -lint "$info_plist" "$project_dir/Packaging/Perch.entitlements" >/dev/null
/usr/bin/plutil -lint \
  "$project_dir/Sources/Perch/Resources/en.lproj/Localizable.strings" \
  "$project_dir/Sources/Perch/Resources/zh-Hans.lproj/Localizable.strings" >/dev/null

for script in "$project_dir"/Scripts/*.sh
do
  /bin/sh -n "$script" || fail "invalid shell syntax: $script"
done

pet_contract=$(/usr/bin/python3 \
  "$project_dir/Sources/Perch/Resources/Skills/perch-pet/scripts/package_perch_pet.py" \
  --print-contract)
printf '%s\n' "$pet_contract" | /usr/bin/grep -F '"width": 1536' >/dev/null \
  || fail "Perch Pet Skill contract width drifted"
printf '%s\n' "$pet_contract" | /usr/bin/grep -F '"height": 2288' >/dev/null \
  || fail "Perch Pet Skill contract height drifted"

bundle_id=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$info_plist")
version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$info_plist")
build=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$info_plist")
minimum_system=$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" "$info_plist")
show_settings=$(/usr/libexec/PlistBuddy -c "Print :PerchShowSettingsOnLaunch" "$info_plist")

[ "$bundle_id" = "app.sleepwing.Sleepwing" ] || fail "unexpected bundle identifier: $bundle_id"
printf '%s\n' "$version" | /usr/bin/grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' \
  || fail "CFBundleShortVersionString must use x.y.z"
printf '%s\n' "$build" | /usr/bin/grep -Eq '^[1-9][0-9]*$' \
  || fail "CFBundleVersion must be a positive integer"
[ "$minimum_system" = "14.0" ] || fail "unexpected minimum macOS version: $minimum_system"
[ "$show_settings" = "false" ] || fail "PerchShowSettingsOnLaunch must be false"

if [ "$allow_dirty" != "1" ] && [ -n "$(git -C "$project_dir" status --porcelain)" ]; then
  fail "git worktree is not clean; commit the intended release state or set PERCH_ALLOW_DIRTY=1 for a local source check"
fi

if [ "$skip_tests" != "1" ]; then
  (
    cd "$project_dir"
    swift test -Xswiftc -warnings-as-errors
    swift build -c release -Xswiftc -warnings-as-errors
  )
fi

if [ "$require_distribution" = "1" ]; then
  identity=${PERCH_SIGN_IDENTITY:-}
  notary_profile=${PERCH_NOTARY_PROFILE:-}

  [ "$(uname -m)" = "arm64" ] \
    || fail "the current public beta pipeline builds Apple Silicon artifacts and must run on arm64"
  [ "${PERCH_SHOW_SETTINGS:-0}" != "1" ] \
    || fail "PERCH_SHOW_SETTINGS=1 is reserved for local UI checks"
  [ -n "$identity" ] \
    || fail "set PERCH_SIGN_IDENTITY to a Developer ID Application certificate"
  [ -n "$notary_profile" ] \
    || fail "set PERCH_NOTARY_PROFILE to a notarytool keychain profile"

  identity_line=$(/usr/bin/security find-identity -v -p codesigning 2>/dev/null \
    | /usr/bin/grep -F "$identity" \
    | /usr/bin/head -n 1 || true)
  [ -n "$identity_line" ] || fail "the requested signing identity is not available in the keychain"
  printf '%s\n' "$identity_line" | /usr/bin/grep -F "Developer ID Application:" >/dev/null \
    || fail "the release identity must be a Developer ID Application certificate"

  /usr/bin/xcrun --find notarytool >/dev/null \
    || fail "notarytool is unavailable"
  /usr/bin/xcrun --find stapler >/dev/null \
    || fail "stapler is unavailable"
  /usr/bin/xcrun notarytool history --keychain-profile "$notary_profile" >/dev/null \
    || fail "the notarytool keychain profile could not be authenticated"
fi

echo "Release preflight passed: Perch $version ($build), macOS $minimum_system+."
