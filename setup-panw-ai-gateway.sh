#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Prisma AIRS AI Gateway - Docker Setup (No Kubernetes/Helm)
# =============================================================================
#
# Usage:
#   ./setup-panw-ai-gateway.sh [OPTIONS]
#
# Quick Start:
#   1. In Strata Cloud Manager: AI Gateway > Gateway Registration >
#      Register New Gateway > Download values.yaml
#   2. ./setup-panw-ai-gateway.sh --from-values values.yaml
#
# Prerequisites:
#   - Docker (20.10+) with Docker Compose
#   - curl
#   - Outbound HTTPS to registry.portkey.ai, aigw.portkey.ai,
#     mp.us.prod.airs-gw.portkey.ai
#
# Scope: gateway + Redis, which is the upstream Helm chart's own default
# topology. Dataservice, MinIO and Milvus are out of scope -- deploy with Helm
# if you need them. See docs/reference.md.
# =============================================================================

# --- Constants ---

SCRIPT_VERSION="0.1.0"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
RUNTIME_ENV_FILE="${SCRIPT_DIR}/.env.runtime"
COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.yml"
DEPLOY_LOG="${SCRIPT_DIR}/deploy.log"
DIGEST_FILE="${SCRIPT_DIR}/.image-digest"

GATEWAY_SERVICE="airs-gw-gateway"
REDIS_SERVICE="airs-gw-redis"

# Upstream chart defaults. Sources, in Portkey-AI/airs-gw-helm:
#   charts/airs-gw/values.yaml        -> images.*, environment.data.*
#   charts/airs-gw/templates/_helpers.tpl
#     "airsgateway.builtinDefaults"   -> ALBUS_BASEPATH, CONTROL_PLANE_BASEPATH,
#                                        LOG_STORE, ANALYTICS_STORE
#     "airsgateway.redisEnv"          -> REDIS_* / CACHE_STORE from the chart secret
# These are NOT present in the values.yaml downloaded from SCM. Omitting them
# leaves the gateway unable to reach its control plane, so they are reproduced
# here and applied underneath whatever the customer file supplies.
DEFAULT_GATEWAY_IMAGE_REPO="registry.portkey.ai/airsgw/gateway_enterprise"
DEFAULT_GATEWAY_IMAGE_TAG="2.15.0"
DEFAULT_REDIS_IMAGE="docker.io/redis:7.2-alpine"
MIN_GATEWAY_VERSION="2.15.0"

CHART_ENV_DEFAULTS=(
  "SERVICE_NAME=airsgateway"
  "PORT=8787"
  "MCP_PORT=8788"
  "SERVER_MODE=all"
  "LOG_STORE_FILE_PATH_FORMAT=v2"
  "ALBUS_BASEPATH=https://mp.us.prod.airs-gw.portkey.ai/api"
  "CONTROL_PLANE_BASEPATH=https://aigw.portkey.ai/v1"
  "LOG_STORE=control_plane"
  "ANALYTICS_STORE=control_plane"
)

# Cache-store keys the gateway understands (chart helper "cacheStore.commonEnv").
# Passed through to the container verbatim when present in .env.
CACHE_STORE_KEYS=(
  CACHE_STORE REDIS_URL REDIS_HOST REDIS_PORT REDIS_TLS_ENABLED REDIS_MODE
  REDIS_TLS_CERTS REDIS_USERNAME REDIS_PASSWORD REDIS_SCALE_READS
  REDIS_CLUSTER_ENDPOINTS REDIS_CLUSTER_DISCOVERY_URL REDIS_CLUSTER_DISCOVERY_AUTH
  AZURE_REDIS_AUTH_MODE AZURE_REDIS_ENTRA_CLIENT_ID AZURE_REDIS_ENTRA_CLIENT_SECRET
  AZURE_REDIS_ENTRA_TENANT_ID AZURE_REDIS_MANAGED_CLIENT_ID
  AWS_REDIS_AUTH_MODE AWS_REDIS_CLUSTER_NAME AWS_REDIS_REGION
  AWS_REDIS_ASSUME_ROLE_ARN AWS_REDIS_ROLE_EXTERNAL_ID
  GCP_REDIS_AUTH_MODE
)

# Log/analytics store keys ("logStore.commonEnv" / "analyticStore.commonEnv").
LOG_STORE_KEYS=(
  LOG_STORE LOG_STORE_ACCESS_KEY LOG_STORE_SECRET_KEY LOG_STORE_REGION
  LOG_STORE_GENERATIONS_BUCKET LOG_STORE_BASEPATH LOG_STORE_AWS_ROLE_ARN
  LOG_STORE_AWS_EXTERNAL_ID LOG_STORE_FILE_PATH_FORMAT
  AZURE_AUTH_MODE AZURE_STORAGE_ACCOUNT AZURE_STORAGE_KEY AZURE_STORAGE_CONTAINER
  AZURE_MANAGED_CLIENT_ID AZURE_ENTRA_CLIENT_ID AZURE_ENTRA_CLIENT_SECRET
  AZURE_ENTRA_TENANT_ID
  ANALYTICS_STORE ANALYTICS_STORE_ENDPOINT ANALYTICS_STORE_USER
  ANALYTICS_STORE_PASSWORD ANALYTICS_LOG_TABLE ANALYTICS_FEEDBACK_TABLE
)

# Core gateway keys always written to the runtime env.
CORE_ENV_KEYS=(
  SERVICE_NAME PORT MCP_PORT SERVER_MODE
  PORTKEY_CLIENT_AUTH ORGANISATIONS_TO_SYNC
  ALBUS_BASEPATH CONTROL_PLANE_BASEPATH MCP_GATEWAY_BASE_URL
)

# Keys whose values must never be printed or logged.
SECRET_KEYS=(
  PORTKEY_CLIENT_AUTH REGISTRY_PASSWORD REDIS_PASSWORD
  LOG_STORE_ACCESS_KEY LOG_STORE_SECRET_KEY ANALYTICS_STORE_PASSWORD
  AZURE_STORAGE_KEY AZURE_ENTRA_CLIENT_SECRET AZURE_REDIS_ENTRA_CLIENT_SECRET
  REDIS_CLUSTER_DISCOVERY_AUTH
)

# Outbound endpoints the data plane needs (docs/OutboundAPIs.md upstream).
EGRESS_HOSTS=(
  "mp.us.prod.airs-gw.portkey.ai|Management plane (config sync)"
  "aigw.portkey.ai|Control plane (analytics push)"
  "registry.portkey.ai|Image registry (setup/update only)"
)

# --- Color output (respects NO_COLOR) ---

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[1;33m'
  BLUE='\033[0;34m'
  BOLD='\033[1m'
  NC='\033[0m'
else
  RED='' GREEN='' YELLOW='' BLUE='' BOLD='' NC=''
fi

# --- Mode flags (set by arg parsing below) ---

MODE="install"
QUIET=false
DRY_RUN=false
FORCE_PULL=false
VALUES_FILE=""
PIN_TAG=""

# Space-separated list of gateway env keys resolved from values.yaml.
# Bash 3.2 (macOS default) has no associative arrays, so the resolved map lives
# in the shell environment and this tracks which keys belong to it.
RESOLVED_KEYS=""

# --- Output helpers ---

info() { [ "$QUIET" = true ] || printf "${BLUE}[INFO]${NC} %s\n" "$1"; }
success() { [ "$QUIET" = true ] || printf "${GREEN}[OK]${NC}   %s\n" "$1"; }
warn() { printf "${YELLOW}[WARN]${NC} %s\n" "$1" >&2; }
error() { printf "${RED}[ERR]${NC}  %s\n" "$1" >&2; }
die() {
  error "$1"
  exit 1
}
# Debug output to stderr, gated on DEBUG. Never pass secrets as args — callers
# must redact tokens/passwords before calling.
debug() { [ "${DEBUG:-false}" = true ] && printf "${YELLOW}[DEBUG]${NC} %s\n" "$1" >&2 || true; }
step() { [ "$QUIET" = true ] || printf "\n${BOLD}--- Step %s: %s ---${NC}\n" "$1" "$2"; }

# Probe a URL, echo the HTTP status code (or "000" when unreachable).
# curl's -w already prints "000" on connection failure, so the fallback must
# stay OUTSIDE the command substitution to avoid a doubled "000000".
http_probe() {
  local code
  code=$(curl -so /dev/null --proto =https --max-time 5 -w "%{http_code}" "$1" 2>/dev/null) || code="000"
  printf '%s' "$code"
}

# --- Deployment audit log (never contains secrets) ---

log_deploy() {
  local ts
  ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  printf "[%s] user=%s action=%s %s\n" "$ts" "$(whoami)" "$1" "${2:-}" >>"$DEPLOY_LOG"
  chmod 600 "$DEPLOY_LOG" 2>/dev/null || true
}

is_secret_key() {
  local candidate="$1" k
  for k in "${SECRET_KEYS[@]}"; do
    [ "$k" = "$candidate" ] && return 0
  done
  return 1
}

# --- Usage ---

usage() {
  cat <<'USAGE'
Usage:
  ./setup-panw-ai-gateway.sh [OPTIONS]

Deploys the Prisma AIRS AI Gateway data plane (gateway + Redis) with Docker
Compose, from the values.yaml issued by Strata Cloud Manager.

Options:
  --from-values FILE   Ingest an SCM values.yaml, write .env, then install
  --dry-run            Show the resolved config and compose file, change nothing
  --status             Show deployment state
  --validate           Check gateway health and control-plane reachability
  --diagnose           Analyze container logs for common failures
  --force-pull         Re-pull the image even when already cached
  --version TAG        Pin a specific gateway image tag
  --quiet              Errors and warnings only (for CI)
  --script-version,-v  Print the script version and exit
  --help,-h            Show this message

Quick start:
  1. Strata Cloud Manager > AI Gateway > Gateway Registration
     > Register New Gateway > Download values.yaml
  2. ./setup-panw-ai-gateway.sh --from-values values.yaml

Re-running with no flags redeploys from the existing .env.

Out of scope (use the Helm chart instead): dataservice, MinIO, Milvus,
autoscaling, ingress, Vault injection, and cloud IAM auth modes that depend on
a Kubernetes ServiceAccount identity. See docs/reference.md.
USAGE
}

# --- Argument parsing ---

while [ $# -gt 0 ]; do
  case "$1" in
    --from-values)
      [ $# -ge 2 ] || die "--from-values requires a file path"
      VALUES_FILE="$2"
      shift 2
      ;;
    --from-values=*)
      VALUES_FILE="${1#*=}"
      shift
      ;;
    --version)
      [ $# -ge 2 ] || die "--version requires a tag (e.g. 2.15.0)"
      PIN_TAG="$2"
      shift 2
      ;;
    --version=*)
      PIN_TAG="${1#*=}"
      shift
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --status)
      MODE="status"
      shift
      ;;
    --validate)
      MODE="validate"
      shift
      ;;
    --diagnose)
      MODE="diagnose"
      shift
      ;;
    --force-pull)
      FORCE_PULL=true
      shift
      ;;
    --quiet)
      QUIET=true
      shift
      ;;
    --script-version | -v)
      printf '%s\n' "$SCRIPT_VERSION"
      exit 0
      ;;
    --help | -h)
      usage
      exit 0
      ;;
    *)
      error "Unknown option: $1"
      echo ""
      usage
      exit 1
      ;;
  esac
done

# --- Safe .env parser (no arbitrary code execution) ---

load_env() {
  local file="$1"
  while IFS= read -r line || [ -n "$line" ]; do
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
    if [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
      local key="${BASH_REMATCH[1]}"
      local value="${BASH_REMATCH[2]}"
      if [[ "$value" =~ ^\"(.*)\"$ ]]; then
        value="${BASH_REMATCH[1]}"
      elif [[ "$value" =~ ^\'(.*)\'$ ]]; then
        value="${BASH_REMATCH[1]}"
        # Undo the '\'' escaping applied by env_quote. The pattern must be
        # quoted: an unquoted backslash would be read as a glob escape.
        local q="'" esc="'\\''"
        value="${value//"$esc"/$q}"
      fi
      export "$key=$value"
    fi
  done <"$file"
}

# Escape a value for safe single-quoted shell/env storage. Wrapping in single
# quotes and rewriting each embedded quote as '\'' means backticks, $(), and
# double quotes in a secret cannot be evaluated when the file is sourced.
env_quote() {
  local v="$1"
  local quote="'"
  local escaped="'\\''"
  printf "'%s'" "${v//$quote/$escaped}"
}

# Write KEY='value' to stdout, skipping empty values.
emit_env() {
  local key="$1" value="$2"
  [ -n "$value" ] || return 0
  printf '%s=%s\n' "$key" "$(env_quote "$value")"
}

# --- Detect docker compose command ---

detect_compose() {
  if docker compose version &>/dev/null; then
    echo "docker compose"
  elif command -v docker-compose &>/dev/null; then
    echo "docker-compose"
  else
    echo ""
  fi
}

require_basics() {
  local missing=()
  command -v curl &>/dev/null || missing+=("curl")
  if [ ${#missing[@]} -gt 0 ]; then
    error "Missing required dependencies: ${missing[*]}"
    error "Install them and re-run."
    exit 1
  fi
}

validate_uuid() {
  [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]
}

# Compare dotted versions: returns 0 when $1 >= $2.
version_ge() {
  local a="$1" b="$2"
  [ "$a" = "$b" ] && return 0
  local highest
  highest=$(printf '%s\n%s\n' "$a" "$b" | sort -V | tail -1)
  [ "$highest" = "$a" ]
}

# =============================================================================
# values.yaml ingestion
# =============================================================================
#
# The file is machine-generated by SCM with a stable, shallow shape, so a
# targeted reader is enough and avoids making yq a hard dependency (see
# docs/DECISIONS.md ADR-004). yq is used when available because it is exact.

# Read a scalar from the values file. Args: file, dotted path.
values_get() {
  local file="$1" path="$2"
  if command -v yq &>/dev/null; then
    local out
    out=$(yq -r "$path // \"\"" "$file" 2>/dev/null) || out=""
    [ "$out" = "null" ] && out=""
    printf '%s' "$out"
    return 0
  fi
  values_get_awk "$file" "$path"
}

# Fallback reader. Handles the two shapes SCM emits:
#   a) nested maps            environment.data.PORT
#   b) first element of a list  imageCredentials[0].registry
# Emits nothing when the key is absent; callers apply their own defaults.
values_get_awk() {
  local file="$1" path="$2"
  awk -v path="$path" '
    function strip(s) {
      gsub(/^[ \t]+|[ \t]+$/, "", s)
      gsub(/^"|"$/, "", s)
      gsub(/^'"'"'|'"'"'$/, "", s)
      return s
    }
    BEGIN {
      # ".a.b[0].c" -> want[1]="a" want[2]="b" want[3]="c"
      p = path
      sub(/^\./, "", p)
      gsub(/\[0\]/, "", p)
      n = split(p, want, ".")
    }
    # Track indentation-based context. A list item ("- key: value") opens a new
    # level; only the first item is ever consulted, which matches [0].
    {
      line = $0
      sub(/[ \t]*#.*$/, "", line)
      if (line ~ /^[ \t]*$/) next

      match(line, /^[ \t]*/)
      indent = RLENGTH
      body = substr(line, indent + 1)

      isitem = 0
      if (body ~ /^- /) { isitem = 1; body = substr(body, 3); indent += 2 }

      if (body !~ /^[A-Za-z_][A-Za-z0-9_]*[ \t]*:/) next

      key = body
      sub(/[ \t]*:.*$/, "", key)
      val = body
      sub(/^[^:]*:[ \t]*/, "", val)

      # A list item resets the sibling context at its own indent.
      if (isitem) { for (i = indent; i <= 200; i++) delete ctx[i] }

      while (depth > 0 && stack[depth] >= indent) { delete ctx[stack[depth]]; depth-- }

      ctx[indent] = key
      depth++
      stack[depth] = indent

      # Build the dotted path of the current line from the open contexts.
      cur = ""
      for (i = 1; i <= depth; i++) {
        cur = (cur == "" ? ctx[stack[i]] : cur "." ctx[stack[i]])
      }

      target = want[1]
      for (i = 2; i <= n; i++) target = target "." want[i]

      if (cur == target && val != "") { print strip(val); exit }
    }
  ' "$file"
}

# List the keys present under environment.data.
values_env_keys() {
  local file="$1"
  if command -v yq &>/dev/null; then
    yq -r '.environment.data // {} | keys | .[]' "$file" 2>/dev/null
    return 0
  fi
  awk '
    /^[ \t]*#/ { next }
    /^[ \t]*environment[ \t]*:/ { in_env = 1; env_indent = index($0, "e") - 1; next }
    in_env && /^[ \t]*data[ \t]*:/ { in_data = 1; data_indent = index($0, "d") - 1; next }
    in_data {
      if ($0 ~ /^[ \t]*$/) next
      match($0, /^[ \t]*/)
      if (RLENGTH <= data_indent) { in_data = 0; in_env = 0; next }
      line = $0
      sub(/^[ \t]*/, "", line)
      if (line ~ /^[A-Za-z_][A-Za-z0-9_]*[ \t]*:/) {
        key = line
        sub(/[ \t]*:.*$/, "", key)
        print key
      }
    }
  ' "$file"
}

# Translate an SCM values.yaml into .env.
# Chart defaults are laid down first, then overridden by the file, mirroring
# how Helm deep-merges environment.data over the chart's own values.
do_from_values() {
  local file="$1"
  [ -f "$file" ] || die "values file not found: $file"

  step "1" "Reading $file"

  local registry username password
  registry=$(values_get "$file" ".imageCredentials[0].registry")
  username=$(values_get "$file" ".imageCredentials[0].username")
  password=$(values_get "$file" ".imageCredentials[0].password")

  # The chart takes a URL here ("https://registry.portkey.ai"); docker login
  # takes a bare host.
  registry="${registry#https://}"
  registry="${registry#http://}"
  registry="${registry%/}"
  [ -n "$registry" ] || registry="registry.portkey.ai"

  [ -n "$username" ] || die "imageCredentials[0].username missing from $file"
  [ -n "$password" ] || die "imageCredentials[0].password missing from $file"

  # Resolve the gateway environment into the shell's own environment: chart
  # defaults first, then the customer file on top. This mirrors how Helm
  # deep-merges environment.data over the chart's values, and keeps us on
  # bash 3.2 (macOS) which has no associative arrays.
  # RESOLVED_KEYS records insertion order so the writer can emit them all.
  RESOLVED_KEYS=""
  local pair key value
  for pair in "${CHART_ENV_DEFAULTS[@]}"; do
    key="${pair%%=*}"
    export "$key=${pair#*=}"
    RESOLVED_KEYS="${RESOLVED_KEYS}${key} "
  done

  while IFS= read -r key; do
    [ -n "$key" ] || continue
    # Guard against a malformed file injecting something like PATH.
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || {
      warn "Ignoring invalid key in environment.data: $key"
      continue
    }
    value=$(values_get "$file" ".environment.data.${key}")
    [ -n "$value" ] || continue
    export "$key=$value"
    case " $RESOLVED_KEYS " in
      *" $key "*) ;;
      *) RESOLVED_KEYS="${RESOLVED_KEYS}${key} " ;;
    esac
  done < <(values_env_keys "$file")

  # Mirrors the chart's own airsgateway.validateRequiredEnv fail-fast.
  [ -n "${PORTKEY_CLIENT_AUTH:-}" ] ||
    die "PORTKEY_CLIENT_AUTH is empty in $file. Re-download it from SCM > AI Gateway > Gateway Registration."
  [ -n "${ORGANISATIONS_TO_SYNC:-}" ] ||
    die "ORGANISATIONS_TO_SYNC is empty in $file. Re-download it from SCM > AI Gateway > Gateway Registration."
  validate_uuid "$ORGANISATIONS_TO_SYNC" ||
    warn "ORGANISATIONS_TO_SYNC is not a UUID ('$ORGANISATIONS_TO_SYNC'). Continuing, but verify the downloaded file."

  # service.containerPort is authoritative for what the process listens on; the
  # chart falls back to environment.data.PORT, then to service.port.
  local container_port service_port
  container_port=$(values_get "$file" ".service.containerPort")
  service_port=$(values_get "$file" ".service.port")
  [ -n "$container_port" ] && export PORT="$container_port"

  # service.port is the Kubernetes Service port. Publishing it on the host is
  # only sensible for unprivileged ports; 80 (the LoadBalancer default) would
  # need root, so fall back to the container port.
  HOST_PORT="${PORT:-8787}"
  if [ -n "$service_port" ] && [ "$service_port" -ge 1024 ] 2>/dev/null; then
    HOST_PORT="$service_port"
  fi
  HOST_MCP_PORT="${MCP_PORT:-8788}"
  export HOST_PORT HOST_MCP_PORT

  success "Registry:   $registry (user $username)"
  success "Gateway:    port ${PORT:-8787}, mode ${SERVER_MODE:-all}"
  success "MCP:        port ${MCP_PORT:-8788}"
  success "Org to sync: $ORGANISATIONS_TO_SYNC"
  info "PORTKEY_CLIENT_AUTH: present (not shown)"

  REGISTRY_HOST="$registry"
  REGISTRY_USERNAME="$username"
  REGISTRY_PASSWORD="$password"
  GATEWAY_IMAGE_REPO="${GATEWAY_IMAGE_REPO:-$DEFAULT_GATEWAY_IMAGE_REPO}"
  GATEWAY_IMAGE_TAG="${GATEWAY_IMAGE_TAG:-$DEFAULT_GATEWAY_IMAGE_TAG}"
  REDIS_IMAGE="${REDIS_IMAGE:-$DEFAULT_REDIS_IMAGE}"
  export REGISTRY_HOST REGISTRY_USERNAME REGISTRY_PASSWORD
  export GATEWAY_IMAGE_REPO GATEWAY_IMAGE_TAG REDIS_IMAGE

  step "2" "Writing .env"

  if [ "$DRY_RUN" = true ]; then
    info "[DRY RUN] Would write $ENV_FILE with the above values."
    return 0
  fi

  [ -f "$ENV_FILE" ] && cp "$ENV_FILE" "${ENV_FILE}.bak" && chmod 600 "${ENV_FILE}.bak"

  (
    umask 077
    {
      printf '# Generated by setup-panw-ai-gateway.sh %s from %s\n' "$SCRIPT_VERSION" "$(basename "$file")"
      printf '# Regenerate with: ./setup-panw-ai-gateway.sh --from-values <file>\n\n'

      printf '# --- Registry ---\n'
      emit_env REGISTRY_HOST "$REGISTRY_HOST"
      emit_env REGISTRY_USERNAME "$REGISTRY_USERNAME"
      emit_env REGISTRY_PASSWORD "$REGISTRY_PASSWORD"

      printf '\n# --- Image ---\n'
      emit_env GATEWAY_IMAGE_REPO "$GATEWAY_IMAGE_REPO"
      emit_env GATEWAY_IMAGE_TAG "$GATEWAY_IMAGE_TAG"
      emit_env REDIS_IMAGE "$REDIS_IMAGE"

      printf '\n# --- Gateway environment (chart defaults + values.yaml overrides) ---\n'
      # Intentionally unquoted: RESOLVED_KEYS is a space-separated key list.
      # shellcheck disable=SC2086
      for key in $(printf '%s\n' $RESOLVED_KEYS | tr ' ' '\n' | sort -u); do
        emit_env "$key" "${!key:-}"
      done

      printf '\n# --- Host port mapping ---\n'
      emit_env HOST_PORT "$HOST_PORT"
      emit_env HOST_MCP_PORT "$HOST_MCP_PORT"
    } >"$ENV_FILE"
  )
  chmod 600 "$ENV_FILE"
  success ".env written (mode 600)."
  log_deploy "env_generated" "source=$(basename "$file") registry=$registry"
}

# =============================================================================
# Compose generation
# =============================================================================

# True when the operator pointed the gateway at a Redis we do not run.
uses_external_redis() {
  local store="${CACHE_STORE:-redis}"
  [ -n "${REDIS_URL:-}" ] && [ "$store" != "redis" ] && return 0
  [ "$store" != "redis" ] && return 0
  # An explicit REDIS_URL that is not our own service also counts.
  if [ -n "${REDIS_URL:-}" ] && [[ "${REDIS_URL}" != *"${REDIS_SERVICE}"* ]]; then
    return 0
  fi
  return 1
}

# Emit the runtime env file consumed by the gateway container.
write_runtime_env() {
  local external_redis="$1"
  local key

  [ -f "$RUNTIME_ENV_FILE" ] && cp "$RUNTIME_ENV_FILE" "${RUNTIME_ENV_FILE}.bak" &&
    chmod 600 "${RUNTIME_ENV_FILE}.bak"

  (
    umask 077
    {
      printf '# Runtime environment for the gateway container.\n'
      printf '# Generated by setup-panw-ai-gateway.sh %s. Do not commit.\n\n' "$SCRIPT_VERSION"

      for key in "${CORE_ENV_KEYS[@]}"; do
        emit_env "$key" "${!key:-}"
      done

      if [ "$external_redis" = true ]; then
        for key in "${CACHE_STORE_KEYS[@]}"; do
          emit_env "$key" "${!key:-}"
        done
      else
        # Reproduces the chart's redis secret for the bundled instance.
        emit_env CACHE_STORE "redis"
        emit_env REDIS_URL "redis://${REDIS_SERVICE}:6379"
        emit_env REDIS_TLS_ENABLED "false"
        emit_env REDIS_MODE "standalone"
      fi

      for key in "${LOG_STORE_KEYS[@]}"; do
        emit_env "$key" "${!key:-}"
      done

      for key in HTTP_PROXY HTTPS_PROXY NO_PROXY; do
        emit_env "$key" "${!key:-}"
      done
    } >"$RUNTIME_ENV_FILE"
  )
  chmod 600 "$RUNTIME_ENV_FILE"
}

# Decide whether the pulled image can run an in-container healthcheck.
# The chart probes /v1/health over HTTP, but the image may be distroless with no
# HTTP client. Probe once and degrade gracefully (docs/DECISIONS.md ADR-005).
detect_health_client() {
  local image="$1"
  if docker run --rm --entrypoint sh "$image" -c 'command -v curl' &>/dev/null; then
    printf 'curl'
  elif docker run --rm --entrypoint sh "$image" -c 'command -v wget' &>/dev/null; then
    printf 'wget'
  else
    printf ''
  fi
}

# Resolve the uid:gid the redis image expects to run as. Hardcoding it would
# break a custom or pinned image that numbers its user differently.
detect_redis_uid() {
  local image="$1" ids
  ids=$(docker run --rm --entrypoint sh "$image" -c 'id -u redis; id -g redis' 2>/dev/null |
    tr '\n' ':' | sed 's/:$//')
  if [[ "$ids" =~ ^[0-9]+:[0-9]+$ ]]; then
    printf '%s' "$ids"
  else
    printf '999:1000'
  fi
}

write_compose() {
  local image="$1" external_redis="$2" health_client="$3"

  [ -f "$COMPOSE_FILE" ] && cp "$COMPOSE_FILE" "${COMPOSE_FILE}.bak"

  local port="${PORT:-8787}"
  local mcp_port="${MCP_PORT:-8788}"
  local host_port="${HOST_PORT:-$port}"
  local host_mcp_port="${HOST_MCP_PORT:-$mcp_port}"
  local server_mode="${SERVER_MODE:-all}"
  local mem_limit="${GATEWAY_MEM_LIMIT:-2g}"
  local cpus="${GATEWAY_CPUS:-2.0}"

  local REDIS_UID=""
  [ "$external_redis" != true ] && REDIS_UID="$(detect_redis_uid "${REDIS_IMAGE:-$DEFAULT_REDIS_IMAGE}")"

  {
    printf 'services:\n'

    if [ "$external_redis" != true ]; then
      cat <<EOF
  ${REDIS_SERVICE}:
    image: "${REDIS_IMAGE:-$DEFAULT_REDIS_IMAGE}"
    restart: unless-stopped
    command: ["redis-server", "--save", "60", "1", "--appendonly", "no"]
    volumes:
      - airs-gw-redis-data:/data
    # The image's entrypoint drops root to the redis user with setpriv, which
    # needs CAP_SETUID -- incompatible with cap_drop: ALL. Starting as that uid
    # directly means no identity change is attempted, so no capability is needed.
    user: "${REDIS_UID}"
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    mem_limit: 1g
    pids_limit: 256
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 3s
      retries: 6
      start_period: 10s
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"

EOF
    fi

    cat <<EOF
  ${GATEWAY_SERVICE}:
    # tag for reference: ${GATEWAY_IMAGE_REPO}:${GATEWAY_IMAGE_TAG}
    image: "${image}"
    env_file:
      - .env.runtime
    restart: unless-stopped
    ports:
      - "${host_port}:${port}"
EOF

    # The MCP listener only exists in "all" and "mcp" modes (chart: mcp.enabled).
    if [ "$server_mode" = "all" ] || [ "$server_mode" = "mcp" ]; then
      printf '      - "%s:%s"\n' "$host_mcp_port" "$mcp_port"
    fi

    if [ "$external_redis" != true ]; then
      cat <<EOF
    depends_on:
      ${REDIS_SERVICE}:
        condition: service_healthy
EOF
    fi

    # Mirrors the chart's securityContext: non-root 1000, read-only rootfs with
    # an emptyDir at /tmp, no privilege escalation, all caps dropped.
    cat <<EOF
    user: "1000:1000"
    read_only: true
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    tmpfs:
      - /tmp
    mem_limit: ${mem_limit}
    cpus: ${cpus}
    pids_limit: 512
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
EOF

    local probe_port="$port"
    [ "$server_mode" = "mcp" ] && probe_port="$mcp_port"

    case "$health_client" in
      curl)
        cat <<EOF
    healthcheck:
      test: ["CMD", "curl", "-fsS", "http://127.0.0.1:${probe_port}/v1/health"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 30s
EOF
        ;;
      wget)
        cat <<EOF
    healthcheck:
      test: ["CMD", "wget", "-qO-", "http://127.0.0.1:${probe_port}/v1/health"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 30s
EOF
        ;;
    esac

    if [ "$external_redis" != true ]; then
      printf '\nvolumes:\n  airs-gw-redis-data:\n'
    fi
  } >"$COMPOSE_FILE"
}

# =============================================================================
# Preflight
# =============================================================================

preflight() {
  local label="$1"
  info "Running preflight checks..."
  info "Script version: $SCRIPT_VERSION"

  local failed=false

  local curl_ver
  curl_ver=$(curl --version 2>/dev/null | head -n1 | awk '{print $2}' || echo "unknown")
  success "curl $curl_ver"

  if command -v yq &>/dev/null; then
    success "yq present (exact YAML parsing)"
  else
    info "yq not found — using the built-in values.yaml reader"
  fi

  if ! command -v docker &>/dev/null; then
    error "docker is not installed."
    failed=true
  elif ! docker info &>/dev/null 2>&1; then
    error "Docker daemon is not running or not accessible."
    failed=true
  else
    local docker_ver docker_major
    docker_ver=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo "0.0.0")
    docker_major=$(echo "$docker_ver" | cut -d. -f1)
    if [ "$docker_major" -lt 20 ] 2>/dev/null; then
      warn "Docker $docker_ver detected. Version 20.10+ recommended for security features."
    else
      success "Docker $docker_ver"
    fi
  fi

  local compose
  compose="$(detect_compose)"
  if [ -z "$compose" ]; then
    error "Docker Compose not found."
    failed=true
  else
    local compose_ver
    compose_ver=$($compose version --short 2>/dev/null || echo "unknown")
    success "Docker Compose $compose_ver ($compose)"
  fi

  if [ "$label" = "install" ]; then
    local entry host desc code
    for entry in "${EGRESS_HOSTS[@]}"; do
      host="${entry%%|*}"
      desc="${entry#*|}"
      code=$(http_probe "https://${host}")
      if [ "$code" != "000" ]; then
        success "Egress: $host reachable (HTTP $code) — $desc"
      else
        warn "Cannot reach $host — $desc. Check network/firewall."
      fi
    done
  fi

  if [ "$failed" = true ]; then
    if [ "$DRY_RUN" = true ]; then
      warn "Some preflight checks failed. These must be resolved before running."
    else
      error "Preflight checks failed. Fix the above issues and retry."
      exit 1
    fi
  else
    success "All preflight checks passed."
  fi
  echo ""
}

# =============================================================================
# MODE: install
# =============================================================================

do_install() {
  if [ "$QUIET" != true ]; then
    echo ""
    printf "${BOLD}=================================================${NC}\n"
    printf "${BOLD} Prisma AIRS AI Gateway - Docker Installer${NC}\n"
    printf "${BOLD} v%s${NC}\n" "$SCRIPT_VERSION"
    printf "${BOLD}=================================================${NC}\n"
    echo ""
  fi

  if [ -n "$VALUES_FILE" ]; then
    do_from_values "$VALUES_FILE"
  elif [ -f "$ENV_FILE" ]; then
    load_env "$ENV_FILE"
  else
    error "No .env found and no --from-values given."
    echo ""
    info "Download values.yaml from Strata Cloud Manager:"
    info "  AI Gateway > Gateway Registration > Register New Gateway"
    info "Then run:"
    info "  ./setup-panw-ai-gateway.sh --from-values values.yaml"
    exit 1
  fi

  step "3" "Preflight checks"
  preflight "install"

  local var
  for var in REGISTRY_HOST REGISTRY_USERNAME REGISTRY_PASSWORD PORTKEY_CLIENT_AUTH ORGANISATIONS_TO_SYNC; do
    [ -n "${!var:-}" ] || die "$var is not set. Re-run with --from-values <file>."
  done

  # Chart defaults for anything .env did not carry (older .env, hand edits).
  local pair key
  for pair in "${CHART_ENV_DEFAULTS[@]}"; do
    key="${pair%%=*}"
    [ -n "${!key:-}" ] || export "$key=${pair#*=}"
  done

  GATEWAY_IMAGE_REPO="${GATEWAY_IMAGE_REPO:-$DEFAULT_GATEWAY_IMAGE_REPO}"
  GATEWAY_IMAGE_TAG="${PIN_TAG:-${GATEWAY_IMAGE_TAG:-$DEFAULT_GATEWAY_IMAGE_TAG}}"
  REDIS_IMAGE="${REDIS_IMAGE:-$DEFAULT_REDIS_IMAGE}"

  if ! version_ge "$GATEWAY_IMAGE_TAG" "$MIN_GATEWAY_VERSION"; then
    warn "Gateway tag $GATEWAY_IMAGE_TAG is below the minimum supported $MIN_GATEWAY_VERSION."
  fi

  local full_image="${GATEWAY_IMAGE_REPO}:${GATEWAY_IMAGE_TAG}"
  local external_redis=false
  uses_external_redis && external_redis=true

  info "Image:  $full_image"
  if [ "$external_redis" = true ]; then
    info "Cache:  external (${CACHE_STORE:-redis}) — bundled Redis omitted"
  else
    info "Cache:  bundled Redis (${REDIS_IMAGE})"
  fi

  if [ "$DRY_RUN" = true ]; then
    echo ""
    info "[DRY RUN] Would perform:"
    info "  1. docker login $REGISTRY_HOST as $REGISTRY_USERNAME"
    info "  2. docker pull $full_image"
    info "  3. Write .env.runtime and docker-compose.yml"
    info "  4. Start the stack"
    echo ""
    info "Resolved gateway environment:"
    for key in "${CORE_ENV_KEYS[@]}"; do
      [ -n "${!key:-}" ] || continue
      if is_secret_key "$key"; then
        printf '    %s=<redacted>\n' "$key"
      else
        printf '    %s=%s\n' "$key" "${!key}"
      fi
    done
    echo ""
    write_compose "$full_image" "$external_redis" ""
    info "Preview of docker-compose.yml:"
    sed 's/^/    /' "$COMPOSE_FILE"
    rm -f "$COMPOSE_FILE"
    [ -f "${COMPOSE_FILE}.bak" ] && mv "${COMPOSE_FILE}.bak" "$COMPOSE_FILE"
    echo ""
    info "No changes were made."
    exit 0
  fi

  step "4" "Registry login"
  { set +x; } 2>/dev/null
  printf '%s\n' "$REGISTRY_PASSWORD" |
    docker login "$REGISTRY_HOST" -u "$REGISTRY_USERNAME" --password-stdin >/dev/null 2>&1 ||
    die "Docker login to $REGISTRY_HOST failed. Re-download values.yaml from SCM — registry credentials rotate."
  success "Registry login successful."

  step "5" "Pulling gateway image"

  local compose_cmd image_cached=false
  compose_cmd="$(detect_compose)"
  docker image inspect "$full_image" &>/dev/null && image_cached=true

  if [ "$FORCE_PULL" = true ] && [ "$image_cached" = true ]; then
    info "Force-pull requested. Removing cached image."
    [ -n "$compose_cmd" ] && $compose_cmd down 2>&1 | sed 's/^/  /' || true
    docker rmi -f "$full_image" &>/dev/null ||
      warn "Could not remove cached image; pull will revalidate from the registry."
    image_cached=false
  fi

  if [ "$image_cached" = true ]; then
    info "Tag $GATEWAY_IMAGE_TAG already in the local Docker store. Skipping pull."
  elif [ "$QUIET" = true ]; then
    local pull_err
    pull_err=$(docker pull "$full_image" 2>&1 >/dev/null) ||
      die "Failed to pull image: $full_image${pull_err:+ — $pull_err}"
  else
    docker pull "$full_image" || die "Failed to pull image: $full_image"
  fi

  local image_digest
  image_digest=$(docker inspect --format='{{range .RepoDigests}}{{println .}}{{end}}' "$full_image" 2>/dev/null |
    grep "^${GATEWAY_IMAGE_REPO}@" | head -1 | cut -d@ -f2)
  [ -z "$image_digest" ] && image_digest="unknown"
  info "Image digest: $image_digest"
  log_deploy "image_pulled" "image=$full_image digest=$image_digest"

  # Nothing to do when the same digest is already serving.
  if [ "$FORCE_PULL" != true ] && [ "$image_digest" != "unknown" ] && [ -f "$DIGEST_FILE" ]; then
    local prev_digest
    prev_digest=$(cat "$DIGEST_FILE" 2>/dev/null || echo "")
    if [ "$prev_digest" = "$image_digest" ] && [ -n "$compose_cmd" ] &&
      $compose_cmd ps --format json 2>/dev/null | grep -q '"running"'; then
      info "Already running this digest. Nothing to do."
      info "If you changed .env, run: $compose_cmd up -d --force-recreate"
      exit 0
    fi
  fi

  step "6" "Writing configuration"

  write_runtime_env "$external_redis"
  success ".env.runtime written (mode 600)."

  local health_client
  health_client="$(detect_health_client "$full_image")"
  if [ -n "$health_client" ]; then
    success "Healthcheck enabled (/v1/health via $health_client)."
  else
    info "Image ships no HTTP client — container healthcheck omitted."
    info "Use --validate from the host instead; restart: unless-stopped covers crashes."
  fi

  local compose_image="$full_image"
  [ "$image_digest" != "unknown" ] && compose_image="${GATEWAY_IMAGE_REPO}@${image_digest}"
  write_compose "$compose_image" "$external_redis" "$health_client"
  success "docker-compose.yml written."

  step "7" "Starting the stack"
  [ -n "$compose_cmd" ] || die "Docker Compose not found."
  $compose_cmd up -d || die "Failed to start the stack. Check: $compose_cmd logs"

  printf '%s' "$image_digest" >"$DIGEST_FILE"
  chmod 600 "$DIGEST_FILE"
  log_deploy "deployed" "image=$full_image digest=$image_digest external_redis=$external_redis"

  echo ""
  success "AI Gateway is up."
  info "Gateway:  http://localhost:${HOST_PORT:-${PORT:-8787}}"
  if [ "${SERVER_MODE:-all}" = "all" ] || [ "${SERVER_MODE:-all}" = "mcp" ]; then
    info "MCP:      http://localhost:${HOST_MCP_PORT:-${MCP_PORT:-8788}}"
  fi
  info "Verify:   ./setup-panw-ai-gateway.sh --validate"
}

# =============================================================================
# MODE: status
# =============================================================================

do_status() {
  [ -f "$ENV_FILE" ] || die ".env not found. Run --from-values <file> first."
  load_env "$ENV_FILE"

  printf "${BOLD}AI Gateway deployment status${NC}\n\n"

  local compose_cmd
  compose_cmd="$(detect_compose)"
  [ -n "$compose_cmd" ] || die "Docker Compose not found."
  [ -f "$COMPOSE_FILE" ] || die "docker-compose.yml not found. Run the installer first."

  $compose_cmd ps || true

  echo ""
  if [ -f "$DIGEST_FILE" ]; then
    printf "Image digest: %s\n" "$(cat "$DIGEST_FILE")"
  fi
  printf "Image tag:    %s:%s\n" "${GATEWAY_IMAGE_REPO:-$DEFAULT_GATEWAY_IMAGE_REPO}" "${GATEWAY_IMAGE_TAG:-$DEFAULT_GATEWAY_IMAGE_TAG}"
  printf "Server mode:  %s\n" "${SERVER_MODE:-all}"
  printf "Gateway port: %s -> %s\n" "${HOST_PORT:-8787}" "${PORT:-8787}"
  if [ "${SERVER_MODE:-all}" = "all" ] || [ "${SERVER_MODE:-all}" = "mcp" ]; then
    printf "MCP port:     %s -> %s\n" "${HOST_MCP_PORT:-8788}" "${MCP_PORT:-8788}"
  fi
  if uses_external_redis; then
    printf "Cache store:  %s (external)\n" "${CACHE_STORE:-redis}"
  else
    printf "Cache store:  bundled Redis\n"
  fi
}

# =============================================================================
# MODE: validate
# =============================================================================

do_validate() {
  [ -f "$ENV_FILE" ] || die ".env not found. Run --from-values <file> first."
  load_env "$ENV_FILE"

  local port="${HOST_PORT:-${PORT:-8787}}"
  local url="http://localhost:${port}/v1/health"
  local failed=false

  info "Probing $url"
  local code
  code=$(curl -so /dev/null --max-time 10 -w "%{http_code}" "$url" 2>/dev/null) || code="000"

  case "$code" in
    2*)
      success "Gateway healthy (HTTP $code)."
      ;;
    000)
      error "No response on port $port. Is the container running? Try --status."
      failed=true
      ;;
    *)
      error "Gateway returned HTTP $code on /v1/health."
      failed=true
      ;;
  esac

  local entry host desc
  for entry in "${EGRESS_HOSTS[@]}"; do
    host="${entry%%|*}"
    desc="${entry#*|}"
    [ "$host" = "registry.portkey.ai" ] && continue
    code=$(http_probe "https://${host}")
    if [ "$code" != "000" ]; then
      success "Control plane: $host reachable (HTTP $code)"
    else
      error "Cannot reach $host — $desc. The gateway will run on cached config only."
      failed=true
    fi
  done

  echo ""
  if [ "$failed" = true ]; then
    error "Validation failed. Run --diagnose for log analysis."
    exit 1
  fi
  success "Validation passed."
  info "Confirm end to end by sending an inference request and checking that it"
  info "appears in the SCM AI Gateway log view."
}

# =============================================================================
# MODE: diagnose
# =============================================================================

do_diagnose() {
  [ -f "$ENV_FILE" ] || die ".env not found. Run --from-values <file> first."
  load_env "$ENV_FILE"

  local compose_cmd
  compose_cmd="$(detect_compose)"
  [ -n "$compose_cmd" ] || die "Docker Compose not found."

  printf "${BOLD}Diagnosing AI Gateway${NC}\n\n"

  local logs
  logs=$($compose_cmd logs --tail 500 "$GATEWAY_SERVICE" 2>&1) || logs=""

  if [ -z "$logs" ]; then
    error "No logs available. Is the container running? Try --status."
    exit 1
  fi

  local found=false

  # grep in a guarded substitution: a no-match must not abort under set -e.
  match_log() {
    local pattern="$1" title="$2" fix="$3" hits
    hits=$(printf '%s' "$logs" | grep -ci "$pattern" || true)
    if [ "${hits:-0}" -gt 0 ]; then
      error "$title ($hits occurrences)"
      info "  -> $fix"
      found=true
    fi
  }

  match_log "unauthorized\|401\|invalid.*client.*auth\|authentication failed" \
    "Authentication failure" \
    "PORTKEY_CLIENT_AUTH is wrong or revoked. Re-download values.yaml from SCM and re-run --from-values."

  match_log "econnrefused.*6379\|redis.*connection.*refused\|redis.*timeout" \
    "Redis unreachable" \
    "Check the redis container (--status), or verify REDIS_URL / REDIS_PASSWORD for an external cache."

  match_log "enotfound\|eai_again\|getaddrinfo\|dns" \
    "DNS resolution failure" \
    "The container cannot resolve the control plane. Check the host's DNS and any egress proxy."

  match_log "etimedout\|econnreset\|network.*unreachable" \
    "Network connectivity failure" \
    "Allow outbound HTTPS to mp.us.prod.airs-gw.portkey.ai and aigw.portkey.ai."

  match_log "self_signed_cert\|unable_to_verify_leaf\|cert_has_expired\|depth_zero_self_signed" \
    "TLS chain rejected — a TLS-inspecting proxy (corporate VPN, SSL decryption) is intercepting" \
    "The container does not trust the proxy CA even though the host does. See 'TLS-inspecting proxies' in docs/reference.md."

  match_log "certificate\|self.signed\|ssl.*error" \
    "TLS/certificate error" \
    "Check whether a proxy is re-signing traffic: docker compose exec $GATEWAY_SERVICE node -e 'fetch(\"https://mp.us.prod.airs-gw.portkey.ai/api\").catch(e=>console.log(e.cause?.code))'"

  # The gateway logs a bare "fetch failed" when it cannot reach the control
  # plane. Left unexplained this looks like a key problem, because every API key
  # is then rejected with Error Code 03 regardless of validity.
  match_log "fetch failed\|fetchorganisationidfromapikey" \
    "Control plane unreachable — the gateway cannot validate API keys or sync config" \
    "Every key will be rejected with 'Error Code: 03' until this is fixed. Check egress to mp.us.prod.airs-gw.portkey.ai, then TLS interception. Note --validate probes from the host and can pass while this is broken."

  match_log "eacces\|permission denied\|read-only file system" \
    "Permission error" \
    "The container runs as uid 1000 with a read-only rootfs. Only /tmp is writable."

  match_log "organisations_to_sync\|organisation.*not found\|org.*sync.*fail" \
    "Organisation sync failure" \
    "ORGANISATIONS_TO_SYNC does not match the registered org. Re-download values.yaml from SCM."

  echo ""
  if [ "$found" = false ]; then
    success "No known failure patterns in the last 500 log lines."
    info "Inspect manually: $compose_cmd logs -f $GATEWAY_SERVICE"
  fi
}

# =============================================================================
# Dispatch
# =============================================================================

require_basics

case "$MODE" in
  install) do_install ;;
  status) do_status ;;
  validate) do_validate ;;
  diagnose) do_diagnose ;;
  *) die "Unknown mode: $MODE" ;;
esac
