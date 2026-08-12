# Prisma AIRS AI Gateway — Docker

The [AI Gateway](https://docs.paloaltonetworks.com/ai-runtime-security/administration/configure-ai-gateway)
hybrid deployment runs the data plane inside your own network: LLM traffic never leaves it, and MCP
servers are registered locally instead of round-tripping through the SaaS. Upstream it ships only as
a Kubernetes Helm chart.

This is a one-command Docker Compose install of that data plane. No Kubernetes, no Helm. Runs on any
server with Docker (EC2, VM, bare metal).

## Install

1. In Strata Cloud Manager: **AI Gateway → Gateway Registration → Register New Gateway**, then
   **Download values.yaml**.
2. Run:

```bash
curl -fLO https://github.com/PaloAltoNetworks/airs-ai-gateway-docker/releases/latest/download/setup-panw-ai-gateway.sh
chmod +x setup-panw-ai-gateway.sh
./setup-panw-ai-gateway.sh --from-values values.yaml
```

Everything else — registry credentials, image, ports, control-plane endpoints, Redis — is derived
from that file and the chart's own defaults.

Verify: `./setup-panw-ai-gateway.sh --validate`

## What it deploys

Two containers: the gateway (`registry.portkey.ai/airsgw/gateway_enterprise`) and a Redis cache.
That is the upstream chart's own default topology — `dataservice`, `minio` and `milvus` are all
disabled by default there, and logs and analytics go to the control plane, so no local object store
is needed.

**Out of scope — use the Helm chart for these:** dataservice, MinIO, Milvus/etcd, autoscaling,
ingress, Vault injection, and any cloud IAM auth mode that derives identity from a Kubernetes
ServiceAccount (IRSA, EKS Pod Identity, Azure Workload Identity, GKE Workload Identity Federation).
Static-credential equivalents work fine. Details in the [Reference](docs/reference.md).

## Why values.yaml and not just a Client ID

An API does exist — `POST /ai_gw/admin/v2/deployments` returns the registration token and registry
credentials — but it sits outside the supported HTTP contract, and the call is not idempotent: every
POST mints a new deployment and a new token that is never retrievable again. An installer that
registered implicitly would litter your tenant on every retry.

So `--from-values` is the default, and API registration will land as an explicit `--register` verb
you run once on purpose (see `docs/DECISIONS.md` ADR-002).

## Docs

- **[Reference](docs/reference.md)** — configuration, external Redis, egress rules, operations, Helm migration
- **Troubleshooting** — run `./setup-panw-ai-gateway.sh --diagnose`

Releases ship with a Sigstore build-provenance attestation.
