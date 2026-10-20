#!/bin/bash
# 개발용: 빠른 debug 빌드로 build/DragEdit.app을 만들고 다시 켠다.
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/build-app.sh debug
pkill -x DragEdit 2>/dev/null || true
pkill -x Prism 2>/dev/null || true  # 예전 이름
pkill -x TextPopup 2>/dev/null || true
sleep 0.3
open build/DragEdit.app
