#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
BOLD='\033[1m'
RESET='\033[0m'

fail=0

# ── iOS unit tests ──────────────────────────────────────────────────

echo -e "\n${BOLD}Running iOS unit tests…${RESET}\n"

if xcodebuild test \
  -project "$ROOT/Linkstr.xcodeproj" \
  -scheme Linkstr \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -resultBundlePath "$ROOT/.build/TestResults.xcresult" \
  -quiet; then
  echo -e "\n${GREEN}✔ iOS tests passed${RESET}"
else
  echo -e "\n${RED}✖ iOS tests failed${RESET}"
  fail=1
fi

# ── Go tests (push-service) ────────────────────────────────────────

echo -e "\n${BOLD}Running push-service Go tests…${RESET}\n"

if (cd "$ROOT/push-service" && go test -v -count=1 ./...); then
  echo -e "\n${GREEN}✔ Go tests passed${RESET}"
else
  echo -e "\n${RED}✖ Go tests failed${RESET}"
  fail=1
fi

# ── Summary ─────────────────────────────────────────────────────────

echo ""
if [ "$fail" -ne 0 ]; then
  echo -e "${RED}${BOLD}Some tests failed.${RESET}"
  exit 1
else
  echo -e "${GREEN}${BOLD}All tests passed.${RESET}"
fi
