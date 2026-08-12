# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- Bundled Redis failed to start under `cap_drop: ALL`: the image's entrypoint drops root via
  `setpriv`, which needs `CAP_SETUID`. The container now starts directly as the redis uid (detected
  from the image), so no capability is needed and the gateway's `depends_on` gate is satisfied.

## [0.1.0] - 2026-08-12

Initial release. Deploys the Prisma AIRS AI Gateway hybrid data plane (gateway + Redis) with Docker
Compose, from the `values.yaml` issued by Strata Cloud Manager.

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
- `deploy.log` records image digests and timestamps, never secrets.

[0.1.0]: https://github.com/PaloAltoNetworks/airs-ai-gateway-docker/releases/tag/v0.1.0
