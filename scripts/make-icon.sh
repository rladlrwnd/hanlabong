#!/bin/bash
# 앱 아이콘 만들기: Resources/Icon/make-svg.py → SVG → 크기별 PNG → Resources/*.icns (본체·애드온)
# 로고를 고친 뒤에만 다시 돌리면 된다(결과 .icns는 저장소에 같이 넣어 둔다).
set -euo pipefail
cd "$(dirname "$0")/.."
ICON=Resources/Icon
python3 "$ICON/make-svg.py" >/dev/null
# 본체 + 애드온 두 개: (원본 SVG, 결과 .icns)
for pair in "hanlabong-appicon:AppIcon" "developing-appicon:DevelopingIcon" "pdf-appicon:PDFIcon"; do
  svg="${pair%%:*}"; name="${pair##*:}"
  SET="$(mktemp -d)/$name.iconset"
  mkdir -p "$SET"
  for size in 16 32 128 256 512; do
    swift "$ICON/render-png.swift" "$ICON/$svg.svg" "$SET/icon_${size}x${size}.png" "$size"
    swift "$ICON/render-png.swift" "$ICON/$svg.svg" "$SET/icon_${size}x${size}@2x.png" "$((size * 2))"
  done
  iconutil -c icns "$SET" -o "Resources/$name.icns"
  rm -rf "$(dirname "$SET")"
done
echo "built Resources/AppIcon.icns, DevelopingIcon.icns, PDFIcon.icns"
