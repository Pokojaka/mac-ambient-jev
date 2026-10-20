#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

bash "$ROOT/scripts/verify_v1_tests.sh"
bash "$ROOT/scripts/verify_v1_app.sh"

echo "V1 verification passed"
