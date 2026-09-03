#!/bin/sh
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_dir"

export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/private/tmp/perch-clang-cache}"
export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-/private/tmp/perch-swiftpm-cache}"

if [ "${PERCH_SHOW_SETTINGS:-0}" = "1" ]; then
  swift build -c release -Xswiftc -warnings-as-errors -Xswiftc -DPERCH_UI_TEST
else
  swift build -c release -Xswiftc -warnings-as-errors
fi
binary_dir=$(swift build -c release --show-bin-path)
output_dir="$project_dir/.build/perch-app"
app_dir="$output_dir/Sleepwing.app"

if [ -d "$app_dir" ]; then
  rm -rf "$app_dir"
fi

mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$binary_dir/Perch" "$app_dir/Contents/MacOS/Perch"
cp "$binary_dir/PerchRelay" "$app_dir/Contents/MacOS/PerchRelay"
cp "$project_dir/Packaging/Info.plist" "$app_dir/Contents/Info.plist"
cp "$project_dir/Packaging/Perch.icns" "$app_dir/Contents/Resources/Perch.icns"
cp -R "$project_dir/Sources/Perch/Resources/." "$app_dir/Contents/Resources/"

if [ "${PERCH_SHOW_SETTINGS:-0}" = "1" ]; then
  /usr/libexec/PlistBuddy -c "Set :PerchShowSettingsOnLaunch true" "$app_dir/Contents/Info.plist"
fi

/usr/bin/codesign --force --deep --sign - "$app_dir"
"$project_dir/Scripts/verify-app-bundle.sh" "$app_dir"
echo "$app_dir"
