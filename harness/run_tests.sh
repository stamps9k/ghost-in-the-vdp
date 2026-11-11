#!/bin/sh
# =============================================================================
# run_tests.sh — run every tests/*.test script against the ROM
#
# Usage: run_tests.sh <mdharness> <core.so> <rom.bin> <tests-dir> <out-dir>
#
# Each script's captures land in <out-dir>/<test-name>/. A Markdown summary
# of every shot (CRC, pass/fail) is written to <out-dir>/summary.md so CI can
# publish it. Exits non-zero if any test fails.
# =============================================================================
set -u

harness=$1 core=$2 rom=$3 tests=$4 out=$5
status=0

mkdir -p "$out"
summary="$out/summary.md"
printf '| Test | Shot | Frame | Size | CRC | Result |\n|---|---|---|---|---|---|\n' > "$summary"

for script in "$tests"/*.test; do
	name=$(basename "$script" .test)
	mkdir -p "$out/$name"
	echo "== $name"
	"$harness" "$core" "$rom" "$script" "$out/$name" > "$out/$name/log.txt"
	rc=$?
	cat "$out/$name/log.txt"
	if [ "$rc" -ne 0 ]; then
		echo "   FAILED (exit $rc)"
		status=1
	fi
	# shot NAME frame N WxH crc=XXXXXXXX ok|MISMATCH|(no expectation) ...
	awk -v t="$name" '$1 == "shot" {
		crc = $6; sub(/^crc=/, "", crc)
		res = ($7 == "(no") ? "no expectation" : $7
		printf "| %s | %s | %s | %s | `%s` | %s |\n", t, $2, $4, $5, crc, res
	}' "$out/$name/log.txt" >> "$summary"
	if [ "$rc" -gt 1 ]; then
		printf '| %s | — | — | — | — | harness error (exit %s) |\n' "$name" "$rc" >> "$summary"
	fi
done

exit $status
