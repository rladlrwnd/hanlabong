#!/bin/bash
# DragEdit.app 만들기: 빌드 → 앱으로 묶기 → 서명.
#   scripts/build-app.sh            최적화된 배포용(release)
#   scripts/build-app.sh debug      개발용(빌드가 빠름)
#
# 번들 식별자는 app.dragedit.DragEdit. 같은 인증서로 서명하면 다시 빌드해도 손쉬운 사용 권한이 유지된다.
set -euo pipefail
cd "$(dirname "$0")/.."

case "${1:-release}" in
  debug) CONFIG=Debug ;;
  release) CONFIG=Release ;;
  *) echo "사용법: $0 [debug|release]"; exit 1 ;;
esac

# --- 빌드 방식 고르기 ---
# Xcode가 있으면 xcodebuild(셰이더까지 직접 컴파일), 없으면 Command Line Tools의 swift build +
# 저장소에 같이 넣어둔 컴파일된 셰이더(Prebuilt/)를 쓴다. NO_XCODE=1 이면 Xcode가 있어도 후자로 간다.
USE_XCODE=0
if [ "${NO_XCODE:-0}" != "1" ]; then
  if [ -z "${DEVELOPER_DIR:-}" ]; then
    DEVELOPER_DIR="$(xcode-select -p 2>/dev/null || true)"
    if [[ "$DEVELOPER_DIR" != *.app/Contents/Developer ]]; then
      XCODE_APP="$(mdfind "kMDItemCFBundleIdentifier == 'com.apple.dt.Xcode'" 2>/dev/null | head -1)"
      DEVELOPER_DIR="${XCODE_APP:-/Applications/Xcode.app}/Contents/Developer"
    fi
  fi
  if [ -x "$DEVELOPER_DIR/usr/bin/xcodebuild" ]; then
    USE_XCODE=1
    export DEVELOPER_DIR
    if ! xcrun metal --version >/dev/null 2>&1; then
      echo "Metal Toolchain을 받는 중(처음 한 번만)…"
      xcodebuild -downloadComponent MetalToolchain
    fi
  fi
fi
if [ "$USE_XCODE" = "0" ]; then
  unset DEVELOPER_DIR
  if ! command -v swift >/dev/null 2>&1 || ! xcrun --show-sdk-path >/dev/null 2>&1; then
    echo "❌ 개발자 도구가 필요해요. 터미널에서 'xcode-select --install'을 실행한 뒤 다시 해줘. (Xcode는 없어도 돼요)"
    exit 1
  fi
  echo "Xcode 없이 빌드해요 (Command Line Tools + 미리 컴파일된 셰이더)"
fi

# --- 서명 인증서: 있으면 그걸로(다시 빌드해도 권한 유지), 없으면 임시 서명 ---
if [ -z "${SIGN_IDENTITY:-}" ]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/Apple Development|Developer ID Application/ { print $2; exit }')"
fi
if [ -z "$SIGN_IDENTITY" ]; then
  SIGN_IDENTITY="-"
  echo "⚠️  개발자 인증서가 없어서 임시로 서명해요. 다시 빌드하면 손쉬운 사용 권한을 다시 켜야 할 수 있어요."
fi

APP="build/DragEdit.app"

if [ "$USE_XCODE" = "1" ]; then
  DERIVED="build/DerivedData"
  PRODUCTS="$DERIVED/Build/Products/$CONFIG"
  xcodebuild \
    -scheme DragEdit \
    -destination "platform=macOS,arch=$(uname -m)" \
    -configuration "$CONFIG" \
    -derivedDataPath "$DERIVED" \
    CODE_SIGNING_ALLOWED=NO \
    -quiet \
    build
  BINARY="$PRODUCTS/DragEdit"
  # 셰이더를 직접 컴파일했으니, Xcode 없는 사람을 위해 저장소의 미리 컴파일된 셰이더도 최신으로 맞춘다
  mkdir -p Prebuilt && rm -rf Prebuilt/BorderBeamKit_BorderBeamKit.bundle
  cp -R "$PRODUCTS/BorderBeamKit_BorderBeamKit.bundle" Prebuilt/
  RESOURCE_BUNDLES=("$PRODUCTS"/*.bundle)
else
  swift build -c "$(echo "$CONFIG" | tr '[:upper:]' '[:lower:]')" 2>&1 | grep -E "error|Build complete" || true
  PRODUCTS=".build/$(echo "$CONFIG" | tr '[:upper:]' '[:lower:]')"
  BINARY="$PRODUCTS/DragEdit"
  [ -x "$BINARY" ] || { echo "❌ 빌드에 실패했어요"; exit 1; }
  # SwiftPM은 .metal을 컴파일하지 않으므로, 컴파일된 셰이더 번들로 갈아끼운다
  RESOURCE_BUNDLES=(Prebuilt/BorderBeamKit_BorderBeamKit.bundle)
  for bundle in "$PRODUCTS"/*.bundle; do
    [ "$(basename "$bundle")" = "BorderBeamKit_BorderBeamKit.bundle" ] || RESOURCE_BUNDLES+=("$bundle")
  done
fi

rm -rf "$APP" build/Prism.app build/TextPopup.app  # 예전 이름으로 만든 앱도 정리
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/DragEdit"
cp Resources/Info.plist "$APP/Contents/Info.plist"
for bundle in "${RESOURCE_BUNDLES[@]}"; do
  [ -e "$bundle" ] && cp -R "$bundle" "$APP/Contents/Resources/"
done

codesign --force --sign "$SIGN_IDENTITY" --identifier app.dragedit.DragEdit "$APP"
codesign --verify "$APP"
echo "built $APP ($CONFIG)"
# 선택: AVI·MKV·WebM·WMV·GIF 영상 변환은 ffmpeg가 있어야 한다
command -v ffmpeg >/dev/null 2>&1 || [ -x /opt/homebrew/bin/ffmpeg ] || echo "ℹ️  ffmpeg가 없어요. MP4·MOV 말고 다른 영상 형식도 쓰려면: brew install ffmpeg"
