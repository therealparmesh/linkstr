#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v swiftlint &>/dev/null; then
  echo "error: swiftlint not found — install with 'brew install swiftlint'" >&2
  exit 1
fi

echo "▸ Linting Swift sources…"
swiftlint

echo "✔ No lint violations"
