#!/usr/bin/env bash
# Shim. `./run-all-tests.sh` is the documented spelling in AGENTS.md and README,
# `bash tests/test.sh` in older notes, `bash tests/run.sh` in two repositories.
# Every one of them must mean the same run, so the implementation lives in
# `tests/test.sh` and this file only forwards to it with the caller's arguments.
set -euo pipefail
exec bash "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/tests/test.sh" "$@"
