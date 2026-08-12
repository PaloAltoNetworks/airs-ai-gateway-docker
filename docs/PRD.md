# PRD — Prisma AIRS AI Gateway (Docker)

## 1. Overview

A single-file Bash installer that deploys the Prisma AIRS AI Gateway hybrid data plane via Docker
Compose — no Kubernetes, no Helm. It turns a portal download plus a Helm install into one command on
any host with Docker.

The AI Gateway hybrid model keeps LLM traffic inside the customer's network and registers MCP servers
locally, while configuration and analytics sync outbound to the SaaS control plane.

## 2. Problem

The data plane ships only as a Helm chart. Customers running AI workloads on plain VMs, EC2 or bare
metal have no cluster, and standing one up for two containers is disproportionate.

Beyond the missing cluster, the manual Docker path is genuinely error-prone: the chart injects eight
environment variables that never appear in the customer's downloaded `values.yaml`. Miss
`ALBUS_BASEPATH` or `CONTROL_PLANE_BASEPATH` and the gateway starts, serves traffic, and silently
never syncs with its control plane. That failure is invisible until someone notices the SCM log view
is empty.

## 3. Goals

- One command from a downloaded `values.yaml` to a running gateway.
- Faithfully reproduce what `helm template` renders, including the defaults the chart hides.
- Ship a hardened-by-default stack matching the chart's own security context.
- Be safe to re-run: idempotent, exits early when the digest is unchanged.
- Leave a credential-free audit trail for SOC 2 / ISO 27001.
- Be explicit about what is out of scope, and point to Helm for it.

## 4. Non-Goals

- Not a Kubernetes deployment tool (the Helm chart already exists upstream).
- Does not deploy dataservice, MinIO, or Milvus — see ADR-003.
- Does not support Kubernetes-native cloud IAM auth (IRSA, Workload Identity) — no Docker equivalent.
- Does not register the gateway in SCM; that stays a portal action (see §6).
- Does not manage fleets — one data plane per host.
- No telemetry / phone-home.

### Rejected alternatives

| Alternative | Why not |
|---|---|
| Auto-fetch credentials from a Client ID + Secret | No published API. The admin routes behind SCM are outside the supported HTTP contract and edge-blocked. ADR-002. |
| Reproduce all six chart workloads | Milvus and etcd are cluster-shaped; a single-host copy invites a deployment nobody should run in production. ADR-003. |
| Ship a `docker run` snippet in docs | Pushes the eight-variable merge onto the user by hand — exactly the failure this removes. |
| Rewrite the installer in Go/Rust | Heavier toolchain and release pipeline for a thin orchestration layer. |
| Require `yq` | Breaks the portability promise on hosts where installing it needs a change ticket. ADR-004. |

## 5. Users

| Persona | Need |
|---|---|
| Security engineer | Stand up the data plane fast on existing infra, without a cluster |
| Platform / SRE | Reproducible, auditable, hardened deploy that fits change management |
| SE / field | Working hybrid gateway in a demo or POC in minutes |

Primary segment is teams running AI workloads on non-Kubernetes infra. The deployment model does not
change the product's security posture versus K8s: same outbound-only sync, same credentials, same
image; only the orchestration layer differs.

## 6. Use case — primary journey

1. In SCM: **AI Gateway → Gateway Registration → Register New Gateway → Download values.yaml**.
2. Download the script from the latest release, `chmod +x`.
3. `./setup-panw-ai-gateway.sh --from-values values.yaml` — parses the file, merges chart defaults,
   logs into the registry, pulls and digest-pins the image, writes `.env` / `.env.runtime` /
   `docker-compose.yml`, starts gateway + Redis.
4. `--validate` → `/v1/health` green and control plane reachable.
5. Send an inference request; confirm it lands in the SCM AI Gateway log view.

Step 5 is the real acceptance test. Health alone proves the process is up, not that it is syncing.

Failure recovery: prior `.env` and compose are backed up to `*.bak`; `--diagnose` pattern-matches
logs; re-running `--from-values` refreshes rotated credentials. No partial state blocks a retry.

## 7. Requirements

### 7.1 Functional

Priority key: **P0** core install path; **P1** important; **P2** convenience.

- **FR1 — Values ingestion (P0).** `--from-values FILE` extracts registry credentials, gateway env
  and ports; merges chart defaults underneath; validates the two required keys; writes `.env`.
- **FR2 — Install (P0).** Registry login, digest-pinned pull, generate `.env.runtime` and a hardened
  `docker-compose.yml`, start the stack.
- **FR3 — Redis topology (P0).** Bundled Redis by default; omitted entirely when the operator points
  `CACHE_STORE`/`REDIS_URL` at a managed cache.
- **FR4 — Idempotent re-run (P1).** Unchanged digest with a running container exits early.
- **FR5 — Status / validate / diagnose.** `--status` (P1); `--validate` probes `/v1/health` plus
  control-plane reachability (P0 — how success is confirmed); `--diagnose` pattern-matches logs (P2).
- **FR6 — Update (P1).** `--version TAG` pins; `--force-pull` re-pulls a repushed tag.
- **FR7 — Dry run (P1).** `--dry-run` prints resolved env (secrets redacted) and the compose file.
- **FR8 — Quiet mode (P2).** `--quiet` for CI.
- **FR9 — Self-version (P2).** `--script-version` / `-v`.

### 7.2 Non-functional

- **Security.** Registry password via `--password-stdin`; secret files `chmod 600` under `umask 077`;
  single-quoted `.env` values safe against `$()` / backticks; image digest-pinned; keys from
  `values.yaml` validated before export.
- **Fidelity.** The generated environment must match `helm template` for the default topology. The
  eight inherited defaults are the specific regression risk (ADR-006).
- **Portability.** Linux (x86_64, aarch64) and macOS; bash 3.2 compatible; `curl` the only hard
  dependency; `yq` optional.
- **Robustness.** `set -euo pipefail`; guarded command substitutions so a no-match `grep` cannot
  abort a run; `die()` for fatal errors.
- **Auditability.** Every install and pull appended to `deploy.log` with timestamp and digest, no
  secrets.
- **Maintainability.** Single script, ShellCheck-clean, shfmt-formatted (2-space), CI lint on push
  and PR.

## 8. Configuration surface

- **Input:** `values.yaml` from SCM.
- **Files:** `.env` (source of truth), `.env.runtime` (container only), `docker-compose.yml`,
  `deploy.log`, `.image-digest` — all generated, all gitignored.
- **Tunables:** `SERVER_MODE`, `PORT` / `MCP_PORT`, `HOST_PORT` / `HOST_MCP_PORT`,
  `GATEWAY_MEM_LIMIT`, `GATEWAY_CPUS`, the `CACHE_STORE` / `REDIS_*` family, proxy variables.
- **Pinned to the chart:** `CHART_ENV_DEFAULTS`, `CACHE_STORE_KEYS`, `LOG_STORE_KEYS` mirror
  `_helpers.tpl` and must be re-diffed when the supported chart version moves.

## 9. Dependencies

- **External:** `registry.portkey.ai` (image pull); `mp.us.prod.airs-gw.portkey.ai` (config sync);
  `aigw.portkey.ai` (analytics); Docker.
- **Upstream contract:** the `Portkey-AI/airs-gw-helm` chart is the spec. A change to
  `airsgateway.builtinDefaults` or `airsgateway.redisEnv` silently breaks fidelity — chart bumps
  require re-reading `_helpers.tpl`.
- **Manual step:** gateway registration in SCM. Automating it needs an API that is not public
  (ADR-002).

## 10. Distribution

- Released as the standalone `setup-panw-ai-gateway.sh` with a Sigstore build-provenance attestation
  generated by the release workflow on tag push.
- Release body is changelog-only.
- Semantic Versioning; CHANGELOG follows Keep a Changelog.

## 11. Success metrics

No telemetry ships, so these are measured out-of-band:

- **Time from download to a gateway visible in SCM** — target one command, under 5 minutes on a
  prepared host.
- **Config fidelity** — the resolved environment matches `helm template` for the default topology.
  Verifiable locally, and the one thing worth a CI check.
- **Idempotent re-run** — unchanged digest exits early without restarting the container.
- **Zero secret leakage** — nothing in `deploy.log`, `ps`, or committed files.

## 12. Risks and open items

### Technical
- **Chart drift.** Hardcoded defaults go stale when upstream changes them, and the failure is silent.
  Mitigation: ADR-006, the `CLAUDE.md` standing instruction, and pinning a known-good chart version
  in the docs.
- **Healthcheck presence is unverified.** Whether the gateway image ships an HTTP client is detected
  at install time rather than known (ADR-005).
- **YAML fallback is shape-specific.** It handles what SCM emits and returns empty otherwise. A
  restructured `values.yaml` would fall back to defaults rather than erroring loudly on every field.

### Operational
- **Registry credentials rotate.** Login failures need a fresh download; surfaced in `--diagnose`
  and the troubleshooting table.
- **Single-host scaling ceiling.** No HPA. Scale by running more hosts behind a load balancer, or
  move to Helm.
- **Support surface.** A one-command installer invites hands-off use on hosts the team never sees;
  `--diagnose` is the first-line self-service mitigation.
