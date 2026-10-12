#!/bin/sh
# Compares this package with the JavaScript reference implementation on generated documents: acceptance, canonical form, and the reason, position, and code frame of every error. Expects `soml-javascript` next to this repository, and Node.js 26 or later. The files go in `tool/differential/work`, which is ignored.
#
#	tool/differential/run.sh [count] [seed] [text|bytes]
set -eu

directory=$(cd "$(dirname "$0")" && pwd)
count=${1-100000}
seed=${2-1}
mode=${3-text}
work="$directory/work"
mkdir -p "$work"

cd "$directory/../.."
dart compile exe tool/differential/decode.dart -o "$work/decode" > /dev/null
node "$directory/generate.mjs" "$work/input.json" "$count" "$seed" "$mode"
node "$directory/reference.mjs" "$work/input.json" "$work/reference.json" "$mode"
"$work/decode" "$work/input.json" "$work/dart.json" "$mode"
node "$directory/compare.mjs" "$work/input.json" "$work/reference.json" "$work/dart.json"
