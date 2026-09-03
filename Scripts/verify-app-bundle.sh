#!/bin/sh
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
app_dir=${1:-"$project_dir/.build/perch-app/Sleepwing.app"}
resources="$app_dir/Contents/Resources"

fail() {
  echo "App bundle verification failed: $*" >&2
  exit 1
}

[ -d "$app_dir" ] || fail "missing app: $app_dir"
[ -x "$app_dir/Contents/MacOS/Perch" ] || fail "missing Perch executable"
[ -x "$app_dir/Contents/MacOS/PerchRelay" ] || fail "missing PerchRelay executable"
[ -f "$resources/Perch.icns" ] || fail "missing app icon"
[ -f "$resources/perch-sleepwing-bird-v2.png" ] \
  || fail "missing Sleepwing Bird atlas"
[ -f "$resources/perch-crescent-cat-v2.png" ] \
  || fail "missing Moontail Cat atlas"
[ -f "$resources/BrandAssets/gemini-cli.png" ] || fail "missing Gemini brand asset"
[ -f "$resources/BrandAssets/opencode.png" ] || fail "missing OpenCode brand asset"
[ -f "$resources/BrandAssets/pi.svg" ] || fail "missing Pi brand asset"
[ -f "$resources/Skills/perch-pet/SKILL.md" ] || fail "missing Perch Pet Skill"
[ -x "$resources/Skills/perch-pet/scripts/package_perch_pet.py" ] \
  || fail "missing executable pet packager"
[ -f "$resources/en.lproj/Localizable.strings" ] || fail "missing English localization"
[ -f "$resources/zh-Hans.lproj/Localizable.strings" ] \
  || fail "missing Simplified Chinese localization"

if find "$app_dir" -type l -print | /usr/bin/grep -q .; then
  fail "shipping app contains a symbolic link"
fi

/usr/bin/plutil -lint \
  "$app_dir/Contents/Info.plist" \
  "$resources/en.lproj/Localizable.strings" \
  "$resources/zh-Hans.lproj/Localizable.strings" >/dev/null
/usr/bin/codesign --verify --deep --strict "$app_dir"

for executable in \
  "$app_dir/Contents/MacOS/Perch" \
  "$app_dir/Contents/MacOS/PerchRelay"
do
  if /usr/bin/strings "$executable" | /usr/bin/grep -F "$project_dir" >/dev/null; then
    fail "shipping executable contains the build machine's project path"
  fi
done

contract=$(/usr/bin/python3 \
  "$resources/Skills/perch-pet/scripts/package_perch_pet.py" \
  --print-contract)
printf '%s\n' "$contract" | /usr/bin/grep -F '"width": 1536' >/dev/null \
  || fail "bundled pet packager contract drifted"
printf '%s\n' "$contract" | /usr/bin/grep -F '"height": 2288' >/dev/null \
  || fail "bundled pet packager contract drifted"

echo "App bundle verification passed: $app_dir"
