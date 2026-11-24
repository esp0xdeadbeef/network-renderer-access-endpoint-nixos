#!/usr/bin/env bash
# Shim for the two repositories that documented `bash tests/run.sh`. Same reason as
# `run-all-tests.sh`: one implementation in `tests/test.sh`, this file forwards.
set -euo pipefail
exec bash "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test.sh" "$@"
