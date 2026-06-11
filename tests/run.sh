#!/usr/bin/env bash
# Test runner for network-renderer-access-endpoint-nixos
# Invokes all focused construction tests.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

echo "=== network-renderer-access-endpoint-nixos test runner ==="
echo ""

for test in test-*.sh; do
  if [ -x "$test" ] || [ -f "$test" ]; then
    echo "--- Running: $test ---"
    bash "$test" || {
      echo "FAILED: $test"
      exit 1
    }
    echo ""
  fi
done

echo "All tests passed."
