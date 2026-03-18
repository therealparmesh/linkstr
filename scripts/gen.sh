#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v xcodegen &>/dev/null; then
  echo "error: xcodegen not found — install with 'brew install xcodegen'" >&2
  exit 1
fi

echo "▸ Generating Xcode project from project.yml…"
xcodegen generate

echo "✔ Linkstr.xcodeproj generated"
