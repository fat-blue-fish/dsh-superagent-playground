#!/bin/sh
# Read-only preflight checks for a self-hosted dsh-superagent deployment.
#
# POSIX sh (dash-compatible). The script never writes to the system, never
# starts or stops the service, and never prints the value of a credential.
#
# Exit status: 0 = all checks passed or only warnings, 1 = at least one failure,
# 2 = invalid arguments.

set -u

PROFILE=${DSH_SUPERAGENT_PROFILE:-superagent}
BASE_URL=${DSH_SUPERAGENT_URL:-http://127.0.0.1:3082}
BASE_URL=${BASE_URL%/}
API_URL=$BASE_URL/orchestrator/api
TAB=$(printf '\t')

RESULTS=
PASSES=0
WARNS=0
FAILS=0

usage() {
  cat <<'EOF'
Usage: sh bin/preflight.sh [--json | --help]

Check a local dsh-superagent deployment without changing it. Each check runs
independently; one failure does not stop the later checks.

Options:
  --help    show this help and exit 0
  --json    print a JSON array instead of the human-readable table

Environment:
  DSH_HOME                 DeepSeek Harness home (default: $HOME/.dsh)
  DSH_SUPERAGENT_PROFILE   profile name (default: superagent)
  DSH_SUPERAGENT_URL       panel base URL (default: http://127.0.0.1:3082)
  DEEPSEEK_API_KEY         checked for presence only; the value is never printed

Checks:
  required-commands  node, pnpm, dsh, tmux, git and curl are on PATH
  dsh-home           DSH_HOME exists and is writable
  profile-config     <DSH_HOME>/profiles/<profile>/cordis.patch.yml is readable
  state-dir          the configured stateDir exists and is writable
  tmux-session       the tmux session dsh-<profile> exists
  panel-http         the panel answers HTTP 200 or 401
  management-api     GET state with x-orchestrator-request: 1 returns 200 JSON
  state-health       every state.health component is ready
  api-key            DEEPSEEK_API_KEY is non-empty in this shell
  disk-space         the stateDir filesystem has more than 1 GiB free

Exit status:
  0  every check passed, or only warnings
  1  at least one check failed
  2  invalid arguments
EOF
}

while [ $# -gt 0 ]; do
  case $1 in
    --help)
      usage
      exit 0
      ;;
    --json)
      JSON=1
      shift
      ;;
    *)
      printf 'preflight: unknown argument: %s\n' "$1" >&2
      printf 'Try: sh bin/preflight.sh --help\n' >&2
      exit 2
      ;;
  esac
done

# Add one result. Details and hints are flattened to one line so both the table
# and the JSON encoder stay simple.
add_result() {
  id=$1
  status=$2
  detail=$3
  hint=${4:-}
  detail=$(printf '%s' "$detail" | tr '\n\r\t' '   ')
  hint=$(printf '%s' "$hint" | tr '\n\r\t' '   ')
  # A healthy check takes no extra space.
  if [ "$status" = PASS ]; then
    hint=
  fi
  case $status in
    PASS) PASSES=$((PASSES + 1)) ;;
    WARN) WARNS=$((WARNS + 1)) ;;
    FAIL) FAILS=$((FAILS + 1)) ;;
  esac
  row="$id$TAB$status$TAB$detail$TAB$hint"
  if [ -z "$RESULTS" ]; then
    RESULTS=$row
  else
    RESULTS="$RESULTS
$row"
  fi
}

# Fetch GET <API_URL>/state and split the body from the HTTP status that curl
# appends. Sets FETCH_RC, FETCH_CODE and FETCH_BODY.
fetch_state() {
  FETCH_RAW=$(curl -sS --max-time 5 -w '
__PREFLIGHT_HTTP__%{http_code}' -H 'x-orchestrator-request: 1' "$API_URL/state" 2>&1)
  FETCH_RC=$?
  FETCH_CODE=${FETCH_RAW##*__PREFLIGHT_HTTP__}
  FETCH_BODY=${FETCH_RAW%__PREFLIGHT_HTTP__*}
}

# 1. Required commands.
missing=
for cmd in node pnpm dsh tmux git curl; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    missing="$missing $cmd"
  fi
done
if [ -z "$missing" ]; then
  add_result required-commands PASS "node pnpm dsh tmux git curl are on PATH" ""
else
  add_result required-commands FAIL "missing:$missing" \
    "install the prerequisites: Node.js 22.19+/24+, pnpm, @deepseek-ai/dsh, tmux, git 2.32+, curl"
fi

# 2. DSH_HOME.
home=${HOME:-}
dsh_home=
home_source=
if [ -n "${DSH_HOME:-}" ]; then
  dsh_home=$DSH_HOME
  home_source=DSH_HOME
elif [ -n "$home" ]; then
  dsh_home=$home/.dsh
  home_source='default ($HOME/.dsh)'
fi
if [ -z "$dsh_home" ]; then
  add_result dsh-home FAIL "neither DSH_HOME nor HOME is set" \
    "set DSH_HOME to the DeepSeek Harness home directory"
elif [ ! -d "$dsh_home" ]; then
  add_result dsh-home FAIL "$dsh_home does not exist (from $home_source)" \
    "create the DeepSeek Harness home or point DSH_HOME at it"
elif [ ! -w "$dsh_home" ]; then
  add_result dsh-home FAIL "$dsh_home is not writable (from $home_source)" \
    "fix ownership and permissions on the DeepSeek Harness home"
else
  add_result dsh-home PASS "$dsh_home exists and is writable (from $home_source)" ""
fi

# 3. Profile machine configuration.
profile_file=
if [ -n "$dsh_home" ]; then
  profile_file=$dsh_home/profiles/$PROFILE/cordis.patch.yml
fi
if [ -z "$profile_file" ]; then
  add_result profile-config FAIL "the profile path cannot be resolved without DSH_HOME" \
    "set DSH_HOME, then check the profile again"
elif [ ! -e "$profile_file" ]; then
  add_result profile-config WARN "$profile_file does not exist" \
    "create the profile from the Web template and install the dsh-superagent bundle"
elif [ ! -r "$profile_file" ]; then
  add_result profile-config FAIL "$profile_file is not readable" \
    "fix permissions on the profile directory"
else
  add_result profile-config PASS "$profile_file is readable" ""
fi

# 4. stateDir, read from the profile configuration when possible.
state_dir=
state_source=
if [ -n "$profile_file" ] && [ -r "$profile_file" ]; then
  state_dir=$(sed -n 's/^[[:space:]]*stateDir:[[:space:]]*//p' "$profile_file" | head -n 1)
  state_dir=$(printf '%s' "$state_dir" | sed -e 's/[[:space:]]#.*$//' \
    -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
    -e "s/^['\"]//" -e "s/['\"]$//")
  if [ -n "$state_dir" ]; then
    state_source=profile
  fi
fi
if [ -z "$state_dir" ] && [ -n "$dsh_home" ]; then
  state_dir=$dsh_home/state/$PROFILE
  state_source=default
fi
if [ -z "$state_dir" ]; then
  add_result state-dir FAIL "stateDir cannot be resolved" \
    "set stateDir in the profile's cordis.patch.yml"
elif [ ! -d "$state_dir" ]; then
  add_result state-dir FAIL "$state_dir does not exist (from $state_source)" \
    "start the service once so it creates the state directory"
elif [ ! -w "$state_dir" ]; then
  add_result state-dir FAIL "$state_dir is not writable (from $state_source)" \
    "fix ownership and permissions on the state directory"
else
  add_result state-dir PASS "$state_dir exists and is writable (from $state_source)" ""
fi

# 5. tmux session.
session=dsh-$PROFILE
if ! command -v tmux >/dev/null 2>&1; then
  add_result tmux-session FAIL "tmux is not installed" \
    "install tmux, then start the service"
elif tmux has-session -t "$session" >/dev/null 2>&1; then
  add_result tmux-session PASS "tmux session '$session' exists" ""
else
  add_result tmux-session FAIL "tmux session '$session' does not exist" \
    "start it with scripts/dsh-superagent start, or run 'dsh --profile $PROFILE --no-open' in tmux session '$session'"
fi

# 6. Panel HTTP endpoint. The panel requires a token and answers 401 without
# one; both 200 and 401 mean the listener works.
if ! command -v curl >/dev/null 2>&1; then
  add_result panel-http FAIL "curl is not installed" "install curl"
else
  code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 "$BASE_URL/" 2>/dev/null)
  rc=$?
  if [ "$rc" -ne 0 ]; then
    add_result panel-http FAIL "cannot reach $BASE_URL/ (curl exit $rc)" \
      "check the service with scripts/dsh-superagent status"
  elif [ "$code" = 200 ] || [ "$code" = 401 ]; then
    add_result panel-http PASS "HTTP $code from $BASE_URL/" ""
  else
    add_result panel-http FAIL "HTTP $code from $BASE_URL/ (expected 200 or 401)" \
      "check the panel port and that the service finished starting"
  fi
fi

# 7. Management API.
if ! command -v curl >/dev/null 2>&1; then
  add_result management-api FAIL "curl is not installed" "install curl"
elif ! command -v python3 >/dev/null 2>&1; then
  add_result management-api FAIL "python3 is not installed, so the JSON answer cannot be validated" \
    "install Python 3.8+ (also needed by the state-health check)"
else
  fetch_state
  if [ "$FETCH_RC" -ne 0 ]; then
    add_result management-api FAIL "cannot reach $API_URL/state (curl exit $FETCH_RC)" \
      "check that the service is running and the panel port is correct"
  elif [ "$FETCH_CODE" != 200 ]; then
    add_result management-api FAIL "HTTP $FETCH_CODE from GET $API_URL/state (expected 200)" \
      "check that DSH_SUPERAGENT_URL uses 127.0.0.1 or localhost and that the panel is up"
  elif printf '%s' "$FETCH_BODY" | python3 -c 'import json, sys; json.load(sys.stdin)' >/dev/null 2>&1; then
    add_result management-api PASS "HTTP 200 and a JSON body from GET $API_URL/state" ""
  else
    add_result management-api FAIL "HTTP 200 but the state answer is not JSON" \
      "read the newest .artifacts/dsh-superagent-*.log for the runtime error"
  fi
fi

# 8. state.health. All entries must be ready; error is a failure, any other
# non-ready state (starting, paused) is a warning.
if ! command -v curl >/dev/null 2>&1; then
  add_result state-health FAIL "curl is not installed" "install curl"
elif ! command -v python3 >/dev/null 2>&1; then
  add_result state-health FAIL "python3 is not installed, so state.health cannot be parsed" \
    "install Python 3.8+"
else
  fetch_state
  if [ "$FETCH_RC" -ne 0 ]; then
    add_result state-health FAIL "cannot reach $API_URL/state (curl exit $FETCH_RC)" \
      "check that the service is running and the panel port is correct"
  elif [ "$FETCH_CODE" != 200 ]; then
    add_result state-health FAIL "HTTP $FETCH_CODE from GET $API_URL/state (expected 200)" \
      "check that the service is running and that the management API is reachable"
  else
    line=$(printf '%s' "$FETCH_BODY" | python3 -c '
import json, sys

try:
    data = json.load(sys.stdin)
except Exception as exc:
    print("FAIL\tstate.health unreadable: %s" % exc)
    raise SystemExit(0)

health = data.get("health")
if not isinstance(health, dict) or not health:
    print("FAIL\tstate.health is missing or empty")
    raise SystemExit(0)

bad = []
has_error = False
for name in sorted(health):
    entry = health[name] if isinstance(health[name], dict) else {}
    state = str(entry.get("state", "unknown"))
    if state == "ready":
        continue
    if state == "error":
        has_error = True
    detail = str(entry.get("detail", "")).strip()
    bad.append("%s=%s%s" % (name, state, (": " + detail) if detail else ""))

if bad:
    print(("FAIL" if has_error else "WARN") + "\t" + ", ".join(bad))
else:
    print("PASS\tall %d components ready: %s" % (len(health), ", ".join(sorted(health))))
' 2>/dev/null)
    if [ -z "$line" ]; then
      add_result state-health FAIL "state.health could not be parsed" \
        "read the newest .artifacts/dsh-superagent-*.log for the runtime error"
    else
      health_status=$(printf '%s' "$line" | cut -f1)
      health_detail=$(printf '%s' "$line" | cut -f2-)
      case $health_status in
        PASS|WARN|FAIL) ;;
        *) health_status=FAIL ;;
      esac
      add_result state-health "$health_status" "$health_detail" \
        "open the panel's Overview and Source pages for the affected components"
    fi
  fi
fi

# 9. Model key. Presence only: never print, quote or log the value.
if [ -n "${DEEPSEEK_API_KEY:-}" ]; then
  add_result api-key PASS "DEEPSEEK_API_KEY is set in this shell (value not shown)" ""
else
  add_result api-key FAIL "DEEPSEEK_API_KEY is empty or unset in this shell" \
    "export it before starting the service; Executor shells strip key-like variables, so run preflight from the operator shell"
fi

# 10. Free space on the stateDir filesystem.
if ! command -v df >/dev/null 2>&1; then
  add_result disk-space FAIL "df is not installed" "install coreutils"
elif [ -z "$state_dir" ] || [ ! -d "$state_dir" ]; then
  add_result disk-space FAIL "the stateDir is unavailable, so free space cannot be checked" \
    "fix the state-dir check first"
else
  available=$(df -Pk "$state_dir" 2>/dev/null | awk 'NR == 2 { print $4 }')
  case $available in
    ''|*[!0-9]*)
      add_result disk-space FAIL "cannot read free space for $state_dir" \
        "run 'df -Pk $state_dir' by hand"
      ;;
    *)
      if [ "$available" -gt 1048576 ]; then
        add_result disk-space PASS "$((available / 1024)) MiB available on the stateDir filesystem (> 1 GiB)" ""
      else
        add_result disk-space FAIL "$((available / 1024)) MiB available on the stateDir filesystem (<= 1 GiB)" \
          "free space under $state_dir, or move stateDir to a larger filesystem"
      fi
      ;;
  esac
fi

if [ "${JSON:-0}" -eq 1 ]; then
  printf '%s\n' "$RESULTS" | awk -F '\t' '
    function esc(s,   r) {
      r = s
      gsub(/\\/, "\\\\", r)
      gsub(/"/, "\\\"", r)
      gsub(/\r/, "", r)
      return r
    }
    BEGIN { printf "[" }
    {
      if (NR > 1) printf ","
      printf "{\"id\":\"%s\",\"status\":\"%s\",\"detail\":\"%s\",\"hint\":\"%s\"}", esc($1), esc($2), esc($3), esc($4)
    }
    END { printf "]\n" }
  '
else
  printf 'dsh-superagent preflight\n'
  printf 'profile: %s   panel: %s   stateDir: %s\n\n' \
    "$PROFILE" "$BASE_URL" "${state_dir:-unknown}"
  printf '%s\n' "$RESULTS" | awk -F '\t' '
    BEGIN {
      printf "%-7s %-20s %s\n", "STATUS", "CHECK", "DETAIL"
    }
    {
      printf "%-7s %-20s %s\n", $2, $1, $3
      if ($4 != "") printf "%-7s %-20s hint: %s\n", "", "", $4
    }
    END { printf "\n" }
  '
  printf 'Summary: %d PASS, %d WARN, %d FAIL\n' "$PASSES" "$WARNS" "$FAILS"
  if [ "$FAILS" -gt 0 ]; then
    printf 'Result: FAIL (exit 1)\n'
  else
    printf 'Result: OK (exit 0)\n'
  fi
fi

if [ "$FAILS" -gt 0 ]; then
  exit 1
fi
exit 0
