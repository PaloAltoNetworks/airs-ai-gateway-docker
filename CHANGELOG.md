# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2026-08-12

Initial release. Deploys the Prisma AIRS AI Gateway hybrid data plane (gateway + Redis) with Docker
Compose, from the `values.yaml` issued by Strata Cloud Manager.

Verified end to end against a live gateway (`2.15.0`): registry login, digest-pinned pull, both
containers healthy, a real LLM completion routed through the local gateway, and the request pushed
to the control plane with the deployment reporting `healthy` in SCM.

### Added

- `--from-values FILE` — parse an SCM `values.yaml`, merge the Helm chart's own defaults underneath
  it, and write `.env`. Reproduces `airsgateway.builtinDefaults` and `airsgateway.redisEnv`, which
  are absent from the downloaded file but required for the gateway to reach its control plane.
- Install path: registry login via `--password-stdin`, digest-pinned image pull, generated
  `.env.runtime` and hardened `docker-compose.yml`, stack start.
- Bundled Redis by default; omitted entirely when `CACHE_STORE` / `REDIS_URL` point at a managed
  cache (ElastiCache, Azure Managed Redis, GCP Memorystore).
- `--dry-run`, `--status`, `--validate`, `--diagnose`, `--force-pull`, `--version TAG`, `--quiet`,
  `--script-version`.
- Container hardening mirroring the chart's security context: non-root uid/gid 1000, read-only
  rootfs with tmpfs `/tmp`, all capabilities dropped, no privilege escalation, plus Compose-side
  memory/CPU/pid limits and log rotation.
- `INSECURE_SKIP_TLS_VERIFY` — lab escape hatch for hosts behind a TLS-inspecting proxy, where the
  gateway (a Node process, so it ignores the host trust store) cannot reach its control plane and
  every API key fails with `Error Code: 03`. Emits `NODE_TLS_REJECT_UNAUTHORIZED=0` and warns on
  every run. Disables peer verification on all outbound connections, LLM providers included:
  lab and POC only.
- `--diagnose` patterns for control-plane unreachability (`fetch failed`,
  `fetchOrganisationIdFromAPIKey`) and TLS chain rejection, explaining that every key is rejected
  with `Error Code: 03` until egress is fixed.
- YAML reading via `yq` when present, with a built-in `awk` fallback so `curl` stays the only hard
  dependency.
- `tests/test-values-parser.sh` — asserts the two readers agree field-for-field, and that a
  credential containing backticks, `$()` and both quote types round-trips intact without executing.

### Security

- `.env` values are single-quoted with `'\''` escaping and unescaped on read, so a credential
  containing shell metacharacters cannot execute when the file is sourced.
- Registry credentials are kept out of the container's environment.
- Keys read from `values.yaml` are validated before export, so a malformed file cannot inject
  variables like `PATH`.
- Bundled Redis runs as its own uid rather than being granted `CAP_SETUID`, so every capability
  stays dropped.
- `deploy.log` records image digests and timestamps, never secrets.

### Known limitations

- `--validate` probes `/v1/health` from the host, so it can report green while the container itself
  cannot reach the control plane. Check the logs for `fetch failed` to tell the difference.
- Toggling a value in `.env` alone does not redeploy — the early-exit path compares image digests.
  Use `--force-pull` after editing config.
- Out of scope, use the Helm chart: dataservice, MinIO, Milvus, autoscaling, ingress, Vault
  injection, and cloud IAM auth modes that derive identity from a Kubernetes ServiceAccount.

[0.1.0]: https://github.com/PaloAltoNetworks/airs-ai-gateway-docker/releases/tag/v0.1.0
