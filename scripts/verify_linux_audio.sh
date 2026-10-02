#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if [ "$#" -lt 1 ]; then
    echo "usage: $0 --smoke|--full [run_suite.py options...]" >&2
    exit 64
fi
MODE="$1"
shift

case "$MODE" in
    --smoke|--full) ;;
    *)
        echo "usage: $0 --smoke|--full [run_suite.py options...]" >&2
        exit 64
        ;;
esac

export PYTHONPATH="$ROOT/tools/linux-audio${PYTHONPATH:+:$PYTHONPATH}"

python3 "$ROOT/tools/linux-audio/run_suite.py" "$MODE" "$@"
