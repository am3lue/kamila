#!/bin/bash
# Kamila test runner wrapper.
#
# Usage:
#   ./scripts/test.sh                 # run the full suite
#   ./scripts/test.sh tools           # run one target (tools|agent|memory|tasks|security|bridge)
#   ./scripts/test.sh tools agent     # run several targets
#   ./scripts/test.sh --ci            # strict mode (fail fast)
#   ./scripts/test.sh --coverage      # run with --code-coverage and print per-file coverage
#   ./scripts/test.sh --network       # include network-backed tests

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if ! command -v julia &> /dev/null; then
    echo "Julia is not installed or not in PATH."
    exit 1
fi

COVERAGE=false
RUN_ARGS=()

for arg in "$@"; do
    case "$arg" in
        --coverage)
            COVERAGE=true
            ;;
        *)
            RUN_ARGS+=("$arg")
            ;;
    esac
done

if [ "$COVERAGE" = true ]; then
    # Remove stale coverage files so totals reflect this run only.
    find src test -name '*.cov' -delete 2>/dev/null || true
    julia --project=. --code-coverage=user test/run.jl "${RUN_ARGS[@]}"
    julia test/coverage.jl --min=40
else
    julia --project=. test/run.jl "${RUN_ARGS[@]}"
fi
