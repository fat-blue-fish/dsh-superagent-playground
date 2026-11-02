#!/bin/sh
# Tests for bin/preflight.sh.
#
# The tests need no network access: preflight only contacts localhost, and a
# missing panel must not crash it. Temporary output goes to a mktemp directory
# that is removed on exit.

set -u

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
preflight=$root/bin/preflight.sh

if [ ! -f "$preflight" ]; then
  printf 'test_preflight: missing %s\n' "$preflight" >&2
  exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
  printf 'test_preflight: python3 is required\n' >&2
  exit 1
fi

tmp=$(mktemp -d "${TMPDIR:-/tmp}/dsh-preflight-test.XXXXXX") || {
  printf 'test_preflight: cannot create a temporary directory\n' >&2
  exit 1
}
trap 'rm -rf "$tmp"' 0 1 2 3 15

tests=0
failures=0

ok() {
  tests=$((tests + 1))
  printf 'ok %d - %s\n' "$tests" "$1"
}

not_ok() {
  tests=$((tests + 1))
  failures=$((failures + 1))
  printf 'not ok %d - %s\n' "$tests" "$1"
}

# 1. The script is valid POSIX sh.
if sh -n "$preflight" >"$tmp/syntax.out" 2>"$tmp/syntax.err"; then
  ok "sh -n accepts bin/preflight.sh"
else
  not_ok "sh -n rejects bin/preflight.sh: $(cat "$tmp/syntax.err")"
fi

# 2. --help exits 0 and prints usage.
sh "$preflight" --help >"$tmp/help.out" 2>"$tmp/help.err"
rc=$?
if [ "$rc" -eq 0 ] && grep -q '^Usage: sh bin/preflight.sh' "$tmp/help.out"; then
  ok "--help exits 0 and prints usage"
else
  not_ok "--help exits 0 and prints usage (exit $rc)"
fi

# 3. --json always prints one parseable JSON array with every check exactly once,
# even when some checks fail.
sh "$preflight" --json >"$tmp/preflight.json" 2>"$tmp/json.err"
rc=$?
if [ "$rc" -ne 0 ] && [ "$rc" -ne 1 ]; then
  not_ok "--json exits 0 or 1, not $rc"
elif python3 - "$tmp/preflight.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    checks = json.load(stream)

expected = [
    "required-commands", "dsh-home", "profile-config", "state-dir",
    "tmux-session", "panel-http", "management-api", "state-health",
    "api-key", "disk-space",
]
ids = [item.get("id") for item in checks]
assert isinstance(checks, list), "the output is not a JSON array"
assert ids == expected, "unexpected checks: %r" % (ids,)
for item in checks:
    assert item.get("status") in ("PASS", "WARN", "FAIL"), item
    assert isinstance(item.get("detail"), str), item
    assert isinstance(item.get("hint"), str), item
PY
then
  ok "--json is a parseable array with the ten checks"
else
  not_ok "--json is a parseable array with the ten checks"
fi

# 4. Unknown arguments exit non-zero.
sh "$preflight" --definitely-unknown >"$tmp/unknown.out" 2>"$tmp/unknown.err"
rc=$?
if [ "$rc" -ne 0 ]; then
  ok "an unknown argument exits non-zero (exit $rc)"
else
  not_ok "an unknown argument exited 0"
fi

# 5. A real run against this machine finishes without a crash. A FAIL is a
# valid result: the report says whether the deployment is ready.
sh "$preflight" >"$tmp/run.out" 2>"$tmp/run.err"
rc=$?
if [ "$rc" -eq 0 ] || [ "$rc" -eq 1 ]; then
  ok "the real run exits 0 or 1 (exit $rc)"
else
  not_ok "the real run exits 0 or 1 (exit $rc)"
fi
if grep -q 'Summary: [0-9][0-9]* PASS, [0-9][0-9]* WARN, [0-9][0-9]* FAIL' "$tmp/run.out"; then
  ok "the real run prints a summary"
else
  not_ok "the real run prints a summary"
fi
if grep -q '^dsh-superagent preflight$' "$tmp/run.out"; then
  ok "the real run prints the human-readable header"
else
  not_ok "the real run prints the human-readable header"
fi
if grep -qi 'syntax error' "$tmp/run.err"; then
  not_ok "the real run reported a syntax error: $(cat "$tmp/run.err")"
else
  ok "the real run reported no syntax error"
fi

printf '\n%d tests, %d failed\n' "$tests" "$failures"
if [ "$failures" -ne 0 ]; then
  exit 1
fi
exit 0
