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

AVAILABLE_DESTINATIONS="$(
  xcodebuild -showdestinations \
    -project "$ROOT/Linkstr.xcodeproj" \
    -scheme Linkstr 2>/dev/null || true
)"

derive_destination() {
  local requested_name="${SIMULATOR_NAME-}"
  local requested_os="${SIMULATOR_OS-}"

  awk -v requested_name="$requested_name" -v requested_os="$requested_os" '
    function trim(value) {
      gsub(/^ +| +$/, "", value)
      return value
    }

    function version_gt(lhs, rhs,    lhs_parts, rhs_parts, count, i, lhs_value, rhs_value) {
      split(lhs, lhs_parts, ".")
      split(rhs, rhs_parts, ".")
      count = length(lhs_parts)
      if (length(rhs_parts) > count) {
        count = length(rhs_parts)
      }

      for (i = 1; i <= count; i++) {
        lhs_value = lhs_parts[i] + 0
        rhs_value = rhs_parts[i] + 0
        if (lhs_value > rhs_value) {
          return 1
        }
        if (lhs_value < rhs_value) {
          return 0
        }
      }

      return 0
    }

    /\{ platform:iOS Simulator,/ {
      if (match($0, /OS:[^,}]+/) == 0) {
        next
      }
      os = trim(substr($0, RSTART + 3, RLENGTH - 3))

      if (match($0, /name:[^}]+/) == 0) {
        next
      }
      name = trim(substr($0, RSTART + 5, RLENGTH - 5))

      if (name !~ /^iPhone/) {
        next
      }
      if (requested_name != "" && name != requested_name) {
        next
      }
      if (requested_os != "" && os != requested_os) {
        next
      }

      if (best_name == "" || version_gt(os, best_os) || (os == best_os && name < best_name)) {
        best_name = name
        best_os = os
      }
    }

    END {
      if (best_name != "") {
        printf "platform=iOS Simulator,OS=%s,name=%s\n", best_os, best_name
      }
    }
  ' <<<"$AVAILABLE_DESTINATIONS"
}

SIMULATOR_DESTINATION="${SIMULATOR_DESTINATION-}"
if [ -z "$SIMULATOR_DESTINATION" ]; then
  SIMULATOR_DESTINATION="$(derive_destination)"
fi

if [ -z "$SIMULATOR_DESTINATION" ]; then
  echo -e "\n${RED}✖ No available iPhone simulator found${RESET}"
  fail=1
else
  echo "Using iOS simulator: $SIMULATOR_DESTINATION"
  RESULT_BUNDLE_PATH="$ROOT/.build/TestResults.xcresult"
  rm -rf "$RESULT_BUNDLE_PATH"

  if xcodebuild test \
    -project "$ROOT/Linkstr.xcodeproj" \
    -scheme Linkstr \
    -destination "$SIMULATOR_DESTINATION" \
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
