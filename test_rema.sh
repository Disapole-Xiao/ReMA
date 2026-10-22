#!/usr/bin/env bash
# Tests always use an isolated copy of this checkout, never the installed CLI.
set -euo pipefail
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$script_dir/tests/test_rema.py" "${1:-$script_dir/rema}" "${@:2}"
