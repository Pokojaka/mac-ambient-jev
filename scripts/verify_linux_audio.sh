#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODE="${1:---smoke}"

case "$MODE" in
    --smoke|--full) ;;
    *)
        echo "usage: $0 [--smoke|--full] [--json PATH]" >&2
        exit 64
        ;;
esac

shift || true
export PYTHONPATH="$ROOT/tools/linux-audio${PYTHONPATH:+:$PYTHONPATH}"

python3 "$ROOT/tools/linux-audio/run_suite.py"     "$MODE"     "$@"
