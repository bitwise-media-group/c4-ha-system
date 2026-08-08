#!/usr/bin/env sh
# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

# Runs every test suite, each in its own interpreter (driver files define
# globals, so suites must not share a Lua state).
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

lua=${LUA:-}
if [ -z "$lua" ]; then
    for candidate in luajit lua5.1 lua; do
        if command -v "$candidate" >/dev/null 2>&1; then
            lua=$candidate
            break
        fi
    done
fi
if [ -z "$lua" ]; then
    echo "no Lua interpreter found (need luajit or lua5.1)" >&2
    exit 1
fi

status=0
for suite in tests/test_*.lua; do
    if ! "$lua" "$suite"; then
        status=1
    fi
done
exit $status
