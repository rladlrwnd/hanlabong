#!/bin/bash
# 자동 테스트 전체 실행(화면 없이). ffmpeg가 있으면 AVI·MKV·WebM 등 영상 테스트도 같이 돈다.
set -euo pipefail
cd "$(dirname "$0")/.."
# 실패하면 종료 코드도 실패로(전에는 "|| true" 때문에 테스트가 깨져도 늘 성공으로 끝났다)
LOG="$(mktemp -t hanlabong-test)"
trap 'rm -f "$LOG"' EXIT
STATUS=0
swift test >"$LOG" 2>&1 || STATUS=$?
grep -E "✘|error:|Test run with" "$LOG" || tail -40 "$LOG"
if [ "$STATUS" -ne 0 ]; then echo "❌ 테스트 실패 (종료 코드 $STATUS)"; fi
exit "$STATUS"
