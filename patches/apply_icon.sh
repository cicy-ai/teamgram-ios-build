#!/bin/sh
# Replace the app icon with the Cat icon (run from teamgram-ios repo root, macOS: uses sips).
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
D=Telegram/Telegram-iOS

# primary icon (Icon Composer bundle)
rm -rf "$D/Telegram.icon"
mkdir -p "$D/Telegram.icon/Assets"
cp "$HERE/icon/icon.json" "$D/Telegram.icon/icon.json"
cp "$HERE/icon/Assets/icon.png" "$D/Telegram.icon/Assets/icon.png"

# alternate icons, legacy IconDefault-* and DefaultAppIcon: same file names, Cat artwork at the same pixel size
find "$D" \( -path "$D/*.alticon/*.png" -o -name 'IconDefault*.png' -o -path "$D/DefaultAppIcon.xcassets/*.png" -o -path "$D/AppIcons.xcassets/*.png" \) -type f | while read -r f; do
  w=$(sips -g pixelWidth "$f" | awk '/pixelWidth/{print $2}')
  h=$(sips -g pixelHeight "$f" | awk '/pixelHeight/{print $2}')
  case "$f" in *Notification*) continue;; esac
  sips -s format png -z "$h" "$w" "$HERE/icon/cat-1024.png" --out "$f" >/dev/null
done
echo "icons replaced: $(find "$D" -name '*.png' -newer "$HERE/apply_icon.sh" | wc -l) png"
