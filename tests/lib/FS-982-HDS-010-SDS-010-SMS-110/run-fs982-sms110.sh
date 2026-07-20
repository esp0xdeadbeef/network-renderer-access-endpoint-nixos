#!/usr/bin/env bash
# GAMP-ID: FS-982-HDS-010-SDS-010-SMS-110
set -euo pipefail

repo_root="${SMS_TEST_REPO_ROOT:-$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)}"

bash "${repo_root}/SMT/FS-982-HDS-010-SDS-010-SMS-110-module-artifact.sh"
bash "${repo_root}/SIT/FS-982-HDS-010-SDS-010-SMS-110-cpm-contract-artifact.sh"

echo "PASS fs982-sms110-access-endpoint-renderer-testing-infrastructure"
