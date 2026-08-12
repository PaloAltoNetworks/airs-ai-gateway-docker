#!/usr/bin/env bash
# Exercises the values.yaml reader against the redacted fixture, on both the
# yq fast path and the built-in awk fallback, and asserts they agree.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURE="${SCRIPT_DIR}/tests/fixtures/values.yaml"
INSTALLER="${SCRIPT_DIR}/setup-panw-ai-gateway.sh"

# Pull just the functions under test out of the installer. Sourcing the whole
# file would run its argument parsing and dispatch.
extract_fn() {
  awk -v fn="$1" '
    $0 ~ "^" fn "\\(\\) \\{" { on = 1 }
    on { print }
    on && /^\}$/ { exit }
  ' "$INSTALLER"
}

eval "$(extract_fn values_get_awk)"
eval "$(extract_fn values_env_keys)"
eval "$(extract_fn env_quote)"
eval "$(extract_fn load_env)"

PASS=0
FAIL=0

check() {
  local label="$1" got="$2" want="$3"
  if [ "$got" = "$want" ]; then
    printf '  ok    %-42s = %s\n' "$label" "$got"
    PASS=$((PASS + 1))
  else
    printf '  FAIL  %-42s got [%s] want [%s]\n' "$label" "$got" "$want"
    FAIL=$((FAIL + 1))
  fi
}

echo "== awk fallback reader =="
check "imageCredentials[0].registry" "$(values_get_awk "$FIXTURE" '.imageCredentials[0].registry')" "https://registry.portkey.ai"
check "imageCredentials[0].username" "$(values_get_awk "$FIXTURE" '.imageCredentials[0].username')" "1234567890"
check "imageCredentials[0].password" "$(values_get_awk "$FIXTURE" '.imageCredentials[0].password')" "00000000-0000-0000-0000-000000000000"
check "environment.data.PORTKEY_CLIENT_AUTH" "$(values_get_awk "$FIXTURE" '.environment.data.PORTKEY_CLIENT_AUTH')" "client-auth-REDACTEDREDACTEDREDACTEDREDACTED"
check "environment.data.ORGANISATIONS_TO_SYNC" "$(values_get_awk "$FIXTURE" '.environment.data.ORGANISATIONS_TO_SYNC')" "11111111-2222-3333-4444-555555555555"
check "environment.data.PORT" "$(values_get_awk "$FIXTURE" '.environment.data.PORT')" "8787"
check "service.port" "$(values_get_awk "$FIXTURE" '.service.port')" "80"
check "service.containerPort" "$(values_get_awk "$FIXTURE" '.service.containerPort')" "8787"
check "service.type" "$(values_get_awk "$FIXTURE" '.service.type')" "LoadBalancer"
check "absent key returns empty" "$(values_get_awk "$FIXTURE" '.environment.data.NOPE')" ""

echo ""
echo "== awk env key listing =="
keys=$(values_env_keys "$FIXTURE" | sort | tr '\n' ',')
check "environment.data keys" "$keys" "ORGANISATIONS_TO_SYNC,PORT,PORTKEY_CLIENT_AUTH,"

if command -v yq &>/dev/null; then
  echo ""
  echo "== yq agrees with the fallback =="
  for path in \
    .imageCredentials[0].registry \
    .imageCredentials[0].username \
    .imageCredentials[0].password \
    .environment.data.PORTKEY_CLIENT_AUTH \
    .environment.data.ORGANISATIONS_TO_SYNC \
    .environment.data.PORT \
    .service.port \
    .service.containerPort; do
    yq_val=$(yq -r "$path // \"\"" "$FIXTURE" 2>/dev/null)
    [ "$yq_val" = "null" ] && yq_val=""
    awk_val=$(values_get_awk "$FIXTURE" "$path")
    check "$path" "$awk_val" "$yq_val"
  done
else
  echo ""
  echo "  (yq not installed — cross-check skipped)"
fi

echo ""
echo "== secret round-trip through env_quote + load_env =="
# A credential containing every shell metacharacter that could be evaluated on
# source must survive intact and must never execute.
# The metacharacters are literal on purpose — that is the whole point.
# shellcheck disable=SC2016
NASTY='p@ss`whoami`$(touch /tmp/aigw-test-pwned)'"'"'"x'
TMP_ENV=$(mktemp)
trap 'rm -f "$TMP_ENV" /tmp/aigw-test-pwned' EXIT
rm -f /tmp/aigw-test-pwned
printf 'SECRET_UNDER_TEST=%s\n' "$(env_quote "$NASTY")" >"$TMP_ENV"

load_env "$TMP_ENV"
check "value round-trips intact" "${SECRET_UNDER_TEST:-}" "$NASTY"

if [ -e /tmp/aigw-test-pwned ]; then
  printf '  FAIL  %-42s command substitution executed\n' "no code execution"
  FAIL=$((FAIL + 1))
else
  printf '  ok    %-42s = nothing executed\n' "no code execution"
  PASS=$((PASS + 1))
fi

# The same file must also be safe for a plain `source`, since operators do that.
# shellcheck disable=SC1090
(
  set -a
  . "$TMP_ENV"
) >/dev/null 2>&1
if [ -e /tmp/aigw-test-pwned ]; then
  printf '  FAIL  %-42s command substitution executed\n' "safe to source directly"
  FAIL=$((FAIL + 1))
else
  printf '  ok    %-42s = nothing executed\n' "safe to source directly"
  PASS=$((PASS + 1))
fi

echo ""
printf 'passed %d, failed %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
