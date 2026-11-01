#!/bin/sh
# Run the offline fastzap test suite.
#
# Usage: tools/run-tests.sh
#
# Zap resolves intra-project module imports relative to the entry file's own
# directory (D-0081, zaplang-io/zap#283), so for each test driver this assembles
# a single flat build root holding the fastzap library modules (src/fastzap.zap +
# src/fastzap/) AND the vendored `validation` dependency (vendor/validation/src/)
# next to the driver, then runs it with `zap run` and diffs stdout against the
# driver's .expected golden. This is real multi-module, multi-package compilation
# (fastzap -> validation -> validation.pattern) — no source concatenation.
#
# Each driver asserts conditions and prints a stable `ok <label>` token per check
# (never a raw value), so the golden is independent of float/JSON formatting and
# a break is localized to one line. Exits non-zero on any mismatch.
#
# Set $ZAP to override the zap binary (default: `zap` on PATH, e.g. inside the
# ghcr.io/zaplang-io/zap toolchain image). See the README "Build & test" section.
set -eu

here=$(cd "$(dirname "$0")/.." && pwd)
zap="${ZAP:-zap}"

run_one() {
    name=$1
    build="$here/build/test-$name"
    rm -rf "$build"
    mkdir -p "$build"
    # fastzap library modules.
    cp "$here/src/fastzap.zap" "$build/"
    cp -r "$here/src/fastzap" "$build/"
    # Vendored `validation` dependency (resolved as a sibling package).
    cp "$here/vendor/validation/src/validation.zap" "$build/"
    cp -r "$here/vendor/validation/src/validation" "$build/"
    # Test driver.
    cp "$here/tests/$name.zap" "$build/"

    got="$here/build/$name.out"
    "$zap" run "$build/$name.zap" > "$got"

    if diff -u "$here/tests/$name.expected" "$got"; then
        echo "$name: PASS"
    else
        echo "$name: FAIL (actual output differs from tests/$name.expected)" >&2
        exit 1
    fi
}

run_one fastzap_test
run_one decorator_test
run_one di_test
run_one params_test
run_one openapi_test
run_one middleware_test
run_one keepalive_test
run_one shutdown_test

echo "fastzap offline suite: PASS"
