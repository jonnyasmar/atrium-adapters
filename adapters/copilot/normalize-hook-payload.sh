#!/usr/bin/env bash
set -euo pipefail
exec bash "${BASH_SOURCE[0]%/*}/run-python.sh" "${BASH_SOURCE[0]%/*}/hooks.py" normalize "${1:-}"
