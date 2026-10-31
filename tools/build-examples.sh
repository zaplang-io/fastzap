#!/bin/sh
# Compile-smoke the examples: assemble a flat build root holding the fastzap
# library modules + the vendored `validation` dependency next to each example,
# then `zap build` it (compile + link). Catches API/type drift in the examples.
# The examples are servers that block on accept(), so they are BUILT, not run.
#
# Usage: tools/build-examples.sh
# Set $ZAP to override the zap binary (default: `zap` on PATH).
set -eu

here=$(cd "$(dirname "$0")/.." && pwd)
zap="${ZAP:-zap}"

for ex in "$here"/examples/*.zap; do
    name=$(basename "$ex" .zap)
    build="$here/build/example-$name"
    rm -rf "$build"
    mkdir -p "$build"
    cp "$here/src/fastzap.zap" "$build/"
    cp -r "$here/src/fastzap" "$build/"
    cp "$here/vendor/validation/src/validation.zap" "$build/"
    cp -r "$here/vendor/validation/src/validation" "$build/"
    cp "$ex" "$build/"
    echo "building example: $name"
    "$zap" build "$build/$(basename "$ex")" -o "$build/$name"
    test -x "$build/$name"
    echo "  ok"
done
echo "examples: BUILD OK"
