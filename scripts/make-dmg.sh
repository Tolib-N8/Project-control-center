#!/bin/zsh
# Builds Orbit's drag-to-install disk image.
#   scripts/make-dmg.sh path/to/Orbit.app out/Orbit-X.Y.Z.dmg
# dmgbuild lives in its own venv (~/.cache/orbit-release/venv): no global packages, no sudo.
set -euo pipefail

app=${1:?usage: scripts/make-dmg.sh Orbit.app out.dmg}
out=${2:?usage: scripts/make-dmg.sh Orbit.app out.dmg}
root=$(cd "$(dirname "$0")/.." && pwd)
venv="$HOME/.cache/orbit-release/venv"
version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$app/Contents/Info.plist")

if [[ ! -x "$venv/bin/dmgbuild" ]]; then
  python3 -m venv "$venv"
  "$venv/bin/pip" install -q --upgrade pip
  "$venv/bin/pip" install -q "dmgbuild==1.6.5"
fi

# Volume icon from the app icon set.
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
set_dir="$work/Orbit.iconset"
mkdir -p "$set_dir"
src="$root/Orbit/Resources/Assets.xcassets/AppIcon.appiconset"
for s in 16 32 128 256 512; do
  cp "$src/icon_$s.png" "$set_dir/icon_${s}x${s}.png"
  cp "$src/icon_$((s * 2)).png" "$set_dir/icon_${s}x${s}@2x.png" 2>/dev/null || sips -z $((s * 2)) $((s * 2)) "$src/icon_1024.png" --out "$set_dir/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$set_dir" -o "$work/Orbit.icns"

rm -f "$out"
mkdir -p "$(dirname "$out")"
"$venv/bin/dmgbuild" -s "$root/scripts/dmg/settings.py" -D app="$app" -D icon="$work/Orbit.icns" -D background="$root/scripts/dmg/background.tiff" "Orbit $version" "$out" >/dev/null
hdiutil verify -quiet "$out"
echo "$out"
