#!/bin/bash
# 설치 마법사(.pkg) 만들기: 최적화 빌드 → /Applications/Hanlabong.app 으로 설치하는 pkg.
#   scripts/make-pkg.sh            → build/Hanlabong-<버전>.pkg
# "Developer ID Installer" 인증서가 있으면 그걸로 서명하고(INSTALLER_IDENTITY로 지정 가능), 없으면 서명 없이 만든다.
# 서명·공증이 없는 pkg는 처음 열 때 macOS가 경고하고, 시스템 설정 › 개인정보 보호 및 보안에서 "그래도 열기"를 눌러야 한다.
set -euo pipefail
cd "$(dirname "$0")/.."
# 나눠줄 앱은 임시 서명(ad-hoc)으로: 개인 개발자 인증서로 서명하면 인증서 이름(애플 계정 이메일 등)이 앱에 박힌다.
# 공증용 Developer ID 인증서가 생기면 DIST_SIGN_IDENTITY="Developer ID Application: …"으로 지정한다.
SIGN_IDENTITY="${DIST_SIGN_IDENTITY:--}" ./scripts/build-app.sh release

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
IDENTIFIER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' Resources/Info.plist)"
WORK="build/pkg"
rm -rf "$WORK" && mkdir -p "$WORK/root/Applications" "$WORK/resources"
cp -R build/Hanlabong.app "$WORK/root/Applications/"
cp Installer/welcome.html Installer/conclusion.html "$WORK/resources/"
cp LICENSE "$WORK/resources/LICENSE.txt"

# 앱 하나짜리 구성요소 pkg (다른 위치로 옮겨 설치되지 않게 relocatable 끄기)
pkgbuild --analyze --root "$WORK/root" "$WORK/components.plist" >/dev/null
/usr/libexec/PlistBuddy -c "Set :0:BundleIsRelocatable false" "$WORK/components.plist"
# 설치 뒤: 예전 이름(DragEdit.app)으로 깔린 같은 앱은 휴지통으로. 식별자가 같아서 둘 다 있으면 맥이 헷갈린다.
mkdir -p "$WORK/scripts"
cat > "$WORK/scripts/postinstall" <<'SH'
#!/bin/bash
OLD="/Applications/DragEdit.app"
ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$OLD/Contents/Info.plist" 2>/dev/null)"
[ "$ID" = "app.dragedit.DragEdit" ] || exit 0
OWNER="$(stat -f%Su /dev/console)"
TRASH="/Users/$OWNER/.Trash"
[ -d "$TRASH" ] || exit 0
DEST="$TRASH/DragEdit.app"
[ -e "$DEST" ] && DEST="$TRASH/DragEdit $(date +%Y%m%d-%H%M%S).app"
mv "$OLD" "$DEST" && chown -R "$OWNER" "$DEST"
exit 0
SH
chmod +x "$WORK/scripts/postinstall"
pkgbuild --root "$WORK/root" --component-plist "$WORK/components.plist" --scripts "$WORK/scripts" \
  --identifier "$IDENTIFIER.pkg" --version "$VERSION" --install-location / "$WORK/Hanlabong-component.pkg"

# 설치 마법사 화면: 환영 → 라이선스 → 설치 → 완료
cat > "$WORK/distribution.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
  <title>한라봉 · Hanlabong</title>
  <welcome file="welcome.html" mime-type="text/html"/>
  <license file="LICENSE.txt"/>
  <conclusion file="conclusion.html" mime-type="text/html"/>
  <options customize="never" require-scripts="false" hostArchitectures="arm64"/>
  <domains enable_localSystem="true"/>
  <volume-check><allowed-os-versions><os-version min="26.0"/></allowed-os-versions></volume-check>
  <choices-outline><line choice="default"><line choice="app"/></line></choices-outline>
  <choice id="default"/>
  <choice id="app" visible="false"><pkg-ref id="$IDENTIFIER.pkg"/></choice>
  <pkg-ref id="$IDENTIFIER.pkg" version="$VERSION" onConclusion="none">Hanlabong-component.pkg</pkg-ref>
</installer-gui-script>
XML

OUT="build/Hanlabong-$VERSION.pkg"
if [ -z "${INSTALLER_IDENTITY:-}" ]; then
  INSTALLER_IDENTITY="$(security find-identity -v 2>/dev/null | awk -F'"' '/Developer ID Installer/ { print $2; exit }')"
fi
if [ -n "$INSTALLER_IDENTITY" ]; then
  productbuild --distribution "$WORK/distribution.xml" --resources "$WORK/resources" --package-path "$WORK" --sign "$INSTALLER_IDENTITY" "$OUT"
else
  echo "ℹ️  Developer ID Installer 인증서가 없어서 서명 없이 만들어요(받는 사람이 처음 열 때 경고가 떠요)."
  productbuild --distribution "$WORK/distribution.xml" --resources "$WORK/resources" --package-path "$WORK" "$OUT"
fi
rm -rf "$WORK"
echo "built $OUT"
