#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/../.." && pwd)"
sdk_path="$(xcrun --sdk macosx --show-sdk-path)"

case "$sdk_path" in
  /nix/store/*)
    printf 'nix-sdk-check: xcrun selected a Nix SDK: %s\n' "$sdk_path" >&2
    exit 1
    ;;
esac

[[ -d "$sdk_path" ]] || {
  printf 'nix-sdk-check: selected SDK does not exist: %s\n' "$sdk_path" >&2
  exit 1
}

for tool in just shellcheck swift; do
  command -v "$tool" >/dev/null || {
    printf 'nix-sdk-check: missing tool: %s\n' "$tool" >&2
    exit 1
  }
done

swift package --package-path "$project_root" dump-package >/dev/null
printf 'nix-sdk-check: Apple SDK and SwiftPM manifest passed\n'
