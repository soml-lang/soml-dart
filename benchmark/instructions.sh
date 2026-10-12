#!/bin/sh
# Counts the instructions that each operation takes per document, which, unlike the time, the load of the machine does not change. Needs macOS, whose `/usr/bin/time -l` reports the instructions retired. Compare a change by running it before and after.
#
#	./instructions.sh
set -eu

cd "$(dirname "$0")"
mkdir -p build
dart compile exe bin/operation.dart -o build/operation > /dev/null

# The instructions of a run that repeats the operation, minus those of a run that only prepares it, such as by reading the fixture, per repetition.
count_instructions() {
	if ! measurement=$(/usr/bin/time -l build/operation "$1" "$2" "$3" 2>&1 > /dev/null); then
		printf '%s\n' "$measurement" >&2
		exit 1
	fi

	count=$(printf '%s\n' "$measurement" | awk '/instructions retired/ {print $1}')

	if [ -z "$count" ]; then
		echo "Could not count the instructions of $1 on $2. Run build/operation $1 $2 $3 to see why" >&2
		exit 1
	fi

	echo "$count"
}

for fixture in service platform earthquakes; do
	case $fixture in
		service) repetitions=2000 ;;
		platform) repetitions=200 ;;
		earthquakes) repetitions=5 ;;
	esac

	for operation in read read-bytes write write-canonical format json-read json-read-bytes json-write toml-read toml-write; do
		base=$(count_instructions "$operation" "$fixture" 0)
		total=$(count_instructions "$operation" "$fixture" "$repetitions")
		echo "$fixture $operation: $(( (total - base) / repetitions / 1000 ))k instructions"
	done
done
