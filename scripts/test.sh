#!/bin/bash
# 자동 테스트 전체 실행(화면 없이). ffmpeg가 있으면 AVI·MKV·WebM 등 영상 테스트도 같이 돈다.
set -euo pipefail
cd "$(dirname "$0")/.."
swift test 2>&1 | grep -E "✘|error:|Test run with" || true
