#!/usr/bin/env bash
# End-to-end --dry-run on the redacted fixture: the chart's hidden defaults must
# reach the resolved environment, secrets must stay redacted, and the compose
# preview must be the hardened one.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Same interpreter as this test, so CI can pin e.g. macOS /bin/bash 3.2.
out=$("$BASH" "$ROOT/setup-panw-ai-gateway.sh" --from-values "$ROOT/tests/fixtures/values.yaml" --dry-run 2>&1)
rc=$?

FAIL=0
fail() {
  printf '  FAIL  %s\n' "$1"
  FAIL=1
}

if [ "$rc" -eq 0 ]; then printf '  ok    exit 0\n'; else fail "exit $rc"; fi

for want in \
  "ALBUS_BASEPATH=https://mp.us.prod.airs-gw.portkey.ai/api" \
  "CONTROL_PLANE_BASEPATH=https://aigw.portkey.ai/v1" \
  "PORTKEY_CLIENT_AUTH=<redacted>" \
  "ORGANISATIONS_TO_SYNC=11111111-2222-3333-4444-555555555555" \
  '"8787:8787"' \
  "read_only: true" \
  "cap_drop:"; do
  if printf '%s\n' "$out" | grep -qF -- "$want"; then
    printf '  ok    %s\n' "$want"
  else
    fail "missing: $want"
  fi
done

for secret in client-auth-REDACTED 00000000-0000-0000-0000-000000000000; do
  if printf '%s\n' "$out" | grep -qF -- "$secret"; then
    fail "secret printed: $secret"
  else
    printf '  ok    not printed: %s\n' "$secret"
  fi
done

[ "$FAIL" -eq 0 ] || printf '%s\n' "$out"
exit "$FAIL"
