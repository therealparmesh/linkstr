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

SIMULATOR_NAME="${SIMULATOR_NAME:-$(
  xcrun simctl list devices available | awk '
    /iPhone/ {
      name = $0
      sub(/^ +/, "", name)
      separator = index(name, " (")
      if (separator > 0) {
        name = substr(name, 1, separator - 1)
      }
      if (name == "") {
        next
      }
      if (index($0, "(Booted)") && booted == "") {
        booted = name
      }
      if (fallback == "") {
        fallback = name
      }
    }
    END {
      if (booted != "") {
        print booted
      } else {
        print fallback
      }
    }
  '
)}"

if [ -z "$SIMULATOR_NAME" ]; then
  echo -e "\n${RED}✖ No available iPhone simulator found${RESET}"
  fail=1
else
  echo "Using iOS simulator: $SIMULATOR_NAME"
  RESULT_BUNDLE_PATH="$ROOT/.build/TestResults.xcresult"
  rm -rf "$RESULT_BUNDLE_PATH"

  if xcodebuild test \
    -project "$ROOT/Linkstr.xcodeproj" \
    -scheme Linkstr \
    -destination "platform=iOS Simulator,name=$SIMULATOR_NAME" \
    -resultBundlePath "$RESULT_BUNDLE_PATH" \
    -quiet; then
    echo -e "\n${GREEN}✔ iOS tests passed${RESET}"
  else
    echo -e "\n${RED}✖ iOS tests failed${RESET}"
    fail=1
  fi
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
