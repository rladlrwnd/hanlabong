#!/bin/bash
# 최적화된 배포용으로 빌드해서 /Applications/DragEdit.app 에 설치하고 켠다.
# (다른 위치에 설치하려면: INSTALL_DIR=~/Applications scripts/install.sh)
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/build-app.sh release

pkill -x DragEdit 2>/dev/null || true
pkill -x Prism 2>/dev/null || true  # 예전 이름
pkill -x TextPopup 2>/dev/null || true
sleep 0.5

DEST="${INSTALL_DIR:-/Applications}/DragEdit.app"
rm -rf "$DEST"
# 예전 이름(Prism.app)이 남아 있으면 같은 번들 ID가 두 개 떠서 단축키가 겹치니 치운다
rm -rf "${INSTALL_DIR:-/Applications}/Prism.app"
cp -R build/DragEdit.app "$DEST"
# 개발용 복사본은 지워서, 같은 앱이 두 개 떠 있지 않게 한다
rm -rf build/DragEdit.app
open "$DEST"
echo "installed $DEST"
