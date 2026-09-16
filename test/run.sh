#!/usr/bin/env bash
#
# Runs every suite in this directory and adds up the results.
#
#   test/run.sh            all suites
#   test/run.sh verify     one suite, by name
#
# Nothing here touches your Steam install, your Proton trees or your home
# directory: each suite builds its fixtures under a temp directory and points
# the script's globals at them.

set -uo pipefail
shopt -s nullglob

cd "${BASH_SOURCE[0]%/*}" || exit 1

suites=()
if (( $# )); then
	for name in "$@"; do
		[[ -f "$name.sh" ]] || { printf 'no such suite: %s\n' "$name" >&2; exit 1; }
		suites+=("$name.sh")
	done
else
	for f in *.sh; do
		[[ $f == run.sh || $f == lib.sh ]] && continue
		suites+=("$f")
	done
fi

total_pass=0
total_fail=0
failed_suites=()

for suite in "${suites[@]}"; do
	printf '\n=== %s\n' "$suite"
	out=$(bash "$suite" 2>&1)
	status=$?
	printf '%s\n' "$out"

	# The summary line each suite ends with: --- name: N passed, M failed ---
	counts=$(sed -n 's/^--- .*: \([0-9]*\) passed, \([0-9]*\) failed ---$/\1 \2/p' <<<"$out")
	if [[ -n $counts ]]; then
		read -r p f <<< "$counts"
		total_pass=$((total_pass + p))
		total_fail=$((total_fail + f))
	fi
	(( status == 0 )) || failed_suites+=("$suite")
done

printf '\n============================================================\n'
printf '%d passed, %d failed, across %d suite(s)\n' \
	"$total_pass" "$total_fail" "${#suites[@]}"
if (( ${#failed_suites[@]} )); then
	printf 'failing: %s\n' "${failed_suites[*]}"
	exit 1
fi
exit 0
