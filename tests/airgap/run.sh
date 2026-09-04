#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
failed=0
for t in test_*.sh; do
  echo "▶ $t"
  bash "$t" || { echo "  ✗ $t FAILED"; failed=1; }
done
exit "$failed"
