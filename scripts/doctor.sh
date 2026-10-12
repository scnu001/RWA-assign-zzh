#!/usr/bin/env bash
#
# Pre-class self-check. Tells you in 30 seconds whether this machine can run the lab.
#
#   bash scripts/doctor.sh
#
# Every failure prints the exact command that fixes it. Do not come asking the TA first.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

pass=0
fail=0
ok() {
	printf '  \033[32m✓\033[0m %s\n' "$1"
	pass=$((pass + 1))
}
bad() {
	printf '  \033[31m✗\033[0m %s\n' "$1"
	fail=$((fail + 1))
}
hint() { printf '      -> %s\n' "$1"; }

echo "RWA tokenization lab · environment self-check"
echo

# ---------- 1. Toolchain ----------
for b in forge cast anvil; do
	if command -v "$b" >/dev/null 2>&1; then
		ok "$b  $(command -v "$b")"
	else
		bad "$b is not installed"
		hint "bash scripts/install-foundry-cn.sh"
	fi
done

echo

# ---------- 2. Are the dependencies vendored with the repo (no network needed) ----------
for d in lib/forge-std lib/openzeppelin-contracts; do
	if [ -n "$(ls -A "$d" 2>/dev/null)" ]; then
		ok "$d is in place"
	else
		bad "$d is empty"
		hint "git checkout -- lib   (it ships with the repo); only if that fails, make setup"
	fi
done

echo

# ---------- 3. Compile + core tests ----------
if command -v forge >/dev/null 2>&1; then
	echo "  compiling and running the core tests, about 30 seconds ..."
	if out="$(forge test --no-match-path 'test/{challenges,exercises}/*' 2>&1)"; then
		n="$(printf '%s' "$out" | grep -oE '[0-9]+ tests passed' | head -1)"
		if [ -n "$n" ]; then
			ok "make test passed (${n})"
		else
			ok "make test passed"
		fi
	else
		bad "make test did not pass"
		printf '%s\n' "$out" | tail -15
		hint "see the Common problems section of the README; if that does not help, paste the block above to the TA"
	fi
fi

echo
echo "----------------------------------------"
printf '%d passed, %d failed\n' "$pass" "$fail"
if [ "$fail" -eq 0 ]; then
	echo "ready for class."
else
	echo "fix everything marked ✗ above first. If you are stuck, bring this output to the TA."
fi

[ "$fail" -eq 0 ] || exit 1
