#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
if [ -n "${ZIG:-}" ]; then
    zig=$ZIG
elif [ -x "$root/.tools/zig/zig" ]; then
    zig=$root/.tools/zig/zig
elif command -v zig >/dev/null 2>&1; then
    zig=zig
else
    echo 'Zig 0.15.2 is required. Install it, or set ZIG=/path/to/zig.' >&2
    exit 1
fi
if [ "$("$zig" version)" != 0.15.2 ]; then
    echo 'This project requires Zig 0.15.2; set ZIG=/path/to/zig-0.15.2.' >&2
    exit 1
fi
cd "$root"
exec "$zig" build -Doptimize=ReleaseSafe "$@"
