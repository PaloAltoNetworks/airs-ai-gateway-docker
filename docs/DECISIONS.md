# Architecture Decision Log

Record decisions here when implementation reveals a trade-off.

## ADR-001 — Docker Compose installer, not Kubernetes/Helm

**Status:** accepted

The AI Gateway data plane ships only as a Helm chart. Customers who want the hybrid model — LLM
traffic staying inside their network, MCP servers registered locally — but who run on plain VMs,
EC2 or bare metal have no cluster to deploy into, and standing one up for two containers is
disproportionate.

A single Bash + Docker Compose installer reaches those hosts. The Helm path stays available upstream
for cluster users, and `docs/reference.md` maps the config across so nothing is lost in either
direction.

## ADR-002 — `values.yaml` is the input, not a Client ID + Secret

**Status:** accepted

Bootstrapping from nothing but a service-account Client ID and Secret would be the better experience,
and other PANW products do exactly that where the SASE API exposes the necessary endpoints. The AI
Gateway has no published equivalent:

- No AI Gateway OpenAPI spec on pan.dev, and none planned.
- The admin API behind the SCM console (`api.apps.paloaltonetworks.com/ai_gw/admin/v2/`) is outside
  the published HTTP contract, and PANW engineering has said as much: anything not in `CONTRACT.md`
  is internal and may change without notice. `CONTRACT.md` covers only the inference runtime.
- The credential-bearing routes (`api-keys`, `configs`, `policies/*`) return
  `403 {"msg":"Access denied"}` from the SCM edge. This is an allowlist, not RBAC — a superuser
  service account with all 96 `airs_gw.*` permissions is refused identically. No role fixes it.
- A `deployments` route exists in the SCM front-end bundle but is undocumented and unprobed.

So the operator downloads `values.yaml` once from SCM and passes it to `--from-values`. Building the
happy path on an unsanctioned endpoint would mean shipping something that breaks silently on an
upstream deploy we do not control.

Revisit if PANW publishes a gateway-registration endpoint; the change is contained to
`do_from_values` and would reduce the CLI to two prompts.

**Update 2026-08-12 — `POST /deployments` issues the credentials.** The premise above was wrong on
one point: registration *is* reachable over the API.

```
POST /ai_gw/admin/v2/deployments
{"name":"...","type":"production","organisation_id":"<tsg>",
 "auth_settings":{"allow_all_workspaces":true}}

-> {"id":"...","client_auth":"client-auth-...",
    "credentials":{"username":"<tsg>","password":"..."},
    "organisation_id":"<org-uuid>","object":"deployment"}
```

That is every field the installer needs. `GET /deployments?organisation_id=<tsg>` also returns 200
and lists deployments with `connection_status` and `last_synced_at`, but carries no credentials —
the secrets exist only in the POST response, which is why the SCM console says "Save these values
now. They won't be available later."

Verified with the lab service account (client_credentials, `scope=tsg_id:<TSG>`), so this is not a
console-session-only route.

Comparing two deployments in the same tenant shows what is scoped where:

| Field | Scope |
|---|---|
| `credentials.username` (= TSG ID) | Organisation — identical across deployments |
| `credentials.password` | Organisation — identical across deployments |
| `organisation_id` | Organisation |
| `client_auth` | **Per deployment** — newly minted on each POST, never retrievable again |

**The decision stands, but for a different reason.** `values.yaml` remains the default input:

- The route is still outside the supported HTTP contract. Building the only path on it means the
  installer breaks on an upstream deploy nobody warns us about.
- `POST` is not idempotent. It mints a new deployment and a new `client_auth` on every call. An
  installer that registers implicitly — on a re-run, a retry, a CI job — litters the tenant with
  phantom deployments whose tokens are lost the moment the response scrolls past.

So registration becomes an explicit opt-in verb (`--register`, tracked as F-108) that a human runs
once, deliberately, and never a fallback the install path reaches on its own. `--from-values` stays
the documented default.

## ADR-003 — Scope is gateway + Redis

**Status:** accepted

The chart can deploy six workloads (gateway, Redis, dataservice, MinIO, Milvus, etcd). Only the
first two are on by default: `dataservice.enabled`, `minio.enabled` and `milvus.enabled` are all
`false`, and `LOG_STORE`/`ANALYTICS_STORE` default to `control_plane`. A two-container Compose
deployment is therefore a faithful reproduction of the default install, not a degraded one.

The rest is deliberately out of scope. Milvus and etcd in particular are stateful, cluster-shaped
components whose value is in horizontal scale — reproducing them on a single Docker host would
invite a deployment nobody should run in production. The README says so plainly and points to Helm.

Kubernetes-native cloud auth (IRSA, EKS Pod Identity, Azure Workload Identity, GKE Workload Identity
Federation) is out for a harder reason: the pod's ServiceAccount token *is* the credential. There is
no Docker equivalent to port. Static-credential modes (`REDIS_PASSWORD`, access keys, Entra client
secret) are supported and cover the same backends.

## ADR-004 — Parse YAML with `yq` when present, `awk` otherwise

**Status:** accepted

`values.yaml` is machine-generated by SCM with a stable, shallow shape: one `imageCredentials` entry,
a flat `environment.data` map, and a small `service` block. Making `yq` a hard dependency would break
the portability promise (`curl` is the only required tool) on hosts where installing it needs a
change ticket.

So `values_get` uses `yq` when it is on PATH and falls back to a targeted `awk` reader otherwise.
`tests/test-values-parser.sh` asserts the two agree field-for-field on the fixture, which is what
keeps the fallback honest.

The fallback is deliberately not a general YAML parser. It handles the shapes SCM emits and returns
empty for anything else, so callers apply their own defaults rather than silently reading a wrong
value.

## ADR-005 — Healthcheck gated on what the image ships

**Status:** accepted

The chart probes `GET /v1/health`, which Kubernetes performs from the kubelet — no in-container HTTP
client needed. Docker healthchecks run *inside* the container, so they need `curl` or `wget` to be
present, and the gateway image may well be distroless.

The installer probes the pulled image once and emits a healthcheck only when a client exists,
otherwise omitting it. `restart: unless-stopped` covers crash recovery either way.

Verified on gateway `2.15.0`: the image ships **`wget`, not `curl`** (also `nc` and `node`), so the
wget variant is what actually runs. Detection is still worth keeping — the base image is upstream's
to change, and a switch to a distroless base would silently remove the client.

**Caveat, learned the hard way:** `--validate` probes `/v1/health` from the host, which only proves
the process is listening. It says nothing about whether the *container* can reach the control plane.
On a host behind a TLS-inspecting proxy the host probe passes while the gateway is entirely unable
to sync — a green `--validate` on a broken deployment. F-106 fixes this by probing from inside the
container too.

## ADR-008 — Run Redis as its own uid instead of granting CAP_SETUID

**Status:** accepted

The `redis:7.2-alpine` entrypoint starts as root and drops to the `redis` user via `setpriv`, which
needs `CAP_SETUID`. Under `cap_drop: ALL` that call fails, the container loops on
`setpriv: setresuid failed: Operation not permitted`, and the gateway never starts because it waits
on a healthy Redis.

Two ways out: add back `CAP_SETUID`, or start the container as the target uid so no identity change
is attempted. The second keeps every capability dropped, so that is what `write_compose` does.

The uid is detected from the image (`detect_redis_uid`) rather than hardcoded, since a pinned or
custom Redis image may number its user differently — the stock image is 999:1000. Falls back to
999:1000 when detection fails.

Found by deploying for real; the chart never hits this because Kubernetes applies `runAsUser`
directly and the chart leaves Redis's own `securityContext` empty.

## ADR-006 — Reproduce the chart's hidden defaults explicitly

**Status:** accepted

`airsgateway.builtinDefaults` and `airsgateway.redisEnv` in `_helpers.tpl` inject four control-plane
variables and four Redis variables that never appear in the customer's downloaded `values.yaml`.
Helm deep-merges them underneath `environment.data`.

`CHART_ENV_DEFAULTS` in the installer mirrors that merge: defaults are laid down first, then the
customer file overrides them. Getting this wrong is the highest-consequence failure mode in the port
— a gateway missing `ALBUS_BASEPATH` or `CONTROL_PLANE_BASEPATH` starts cleanly, serves traffic, and
silently never syncs with its control plane.

These values are pinned to a chart version. When bumping the supported chart, re-read `_helpers.tpl`
and diff the defaults. `CLAUDE.md` carries this as a standing instruction.

## ADR-007 — Single-quoted `.env` values with explicit unescaping

**Status:** accepted

Registry passwords and `PORTKEY_CLIENT_AUTH` tokens are opaque strings that may contain any shell
metacharacter. Double-quoted `.env` values would let `` ` `` and `$()` execute when the file is
sourced — a code-execution path from a value we do not control.

`env_quote` wraps every value in single quotes and rewrites embedded quotes as `'\''`; `load_env`
reverses it. The regression test in `tests/test-values-parser.sh` round-trips a credential
containing backticks, `$()`, and both quote types, and asserts nothing executes — both through
`load_env` and through a plain `source`, since operators do that.

This is the fix for the escaping gap left open in the sibling project (its F-101).
