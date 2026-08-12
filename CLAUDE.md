# Repository instructions for Claude Code

Read the shared project documentation:
- @docs/PRD.md
- @docs/ARCHITECTURE.md
- @docs/DECISIONS.md
- @docs/FEATURES.yaml
- @docs/reference.md

These are the source of truth. Point to them; don't restate their content here.

## Behavior

- **Think before coding.** State assumptions. If multiple interpretations exist, present them — don't pick silently. If a simpler approach exists, say so. If unclear, stop and ask.
- **Simplicity first.** Minimum code that solves the problem. No speculative features, abstractions, configurability, or error handling for impossible cases. No backwards-compat shims. If 200 lines could be 50, rewrite.
- **Surgical changes.** Every changed line traces to the request. Don't improve adjacent code or refactor what isn't broken; match existing style. Remove only the orphans your change created; leave pre-existing dead code (mention it, don't delete).
- **Goal-driven.** Define success criteria before coding. For a bug, write the repro first. For planned features, the `acceptance:` block in `docs/FEATURES.yaml` is the criterion.

## Working rules

- Implement one feature at a time (one `F-1xx` from `docs/FEATURES.yaml` for planned work). Do not silently expand scope.
- Use plan mode before any multi-file or architectural change.
- Before editing, identify affected functions, risks, and the validation commands you will run.
- When implementation reveals a trade-off, record a new ADR in `docs/DECISIONS.md`.
- **The upstream Helm chart is the spec.** When changing how env vars are resolved, re-read
  `charts/airs-gw/templates/_helpers.tpl` in `Portkey-AI/airs-gw-helm`. The chart injects defaults
  that are absent from the customer's downloaded `values.yaml` (`airsgateway.builtinDefaults`,
  `airsgateway.redisEnv`) — dropping one silently points the gateway at the wrong control plane.
  The full inherited set is tabulated in `docs/reference.md`.
- Honor the security model in `docs/ARCHITECTURE.md`: never write secrets to `deploy.log`, process
  listings, or committed files. Watch the `set -euo pipefail` grep-abort trap.
- Ask before adding a new runtime dependency. `yq` is an optional fast path, never required.
- Never commit generated files: `docker-compose.yml`, `.env*`, `deploy.log`, `values.yaml`.
  Test fixtures use redacted credentials only.
- All GitHub Actions MUST be SHA-pinned (org rule).

## Verification

For every completed change:
- run `shellcheck setup-panw-ai-gateway.sh` and `shfmt -d -i 2 -ci setup-panw-ai-gateway.sh`;
- preview with `./setup-panw-ai-gateway.sh --from-values tests/fixtures/values.yaml --dry-run`;
- review the diff for regressions and secret leakage;
- update `docs/FEATURES.yaml` status (and `CHANGELOG.md` if behavior changed) only after acceptance criteria pass;
- summarize changed functions and remaining risks.

## Conventions

- Commit messages: single line, no `Co-Authored-By` trailer.
- Multi-concern work: split into focused commits, one concern each.
- Release: bump `SCRIPT_VERSION` + `CHANGELOG.md` as the **last** PR before merging `develop` into `main`. Tags annotated + SSH-signed, message bare `vX.Y.Z`, never override `gpgsign`.
