#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$(bash "$ROOT/scripts/build_app.sh")"

open "$APP"
