# Reference

Full configuration, operations, and migration guide for the Prisma AIRS AI Gateway Docker installer.

---

## CLI modes

| Command | Description |
|---|---|
| `./setup-panw-ai-gateway.sh --from-values FILE` | Ingest an SCM `values.yaml`, write `.env`, install |
| `./setup-panw-ai-gateway.sh` | Redeploy from the existing `.env` |
| `./setup-panw-ai-gateway.sh --dry-run` | Show the resolved config and compose file, change nothing |
| `./setup-panw-ai-gateway.sh --status` | Deployment state, image digest, port mapping |
| `./setup-panw-ai-gateway.sh --validate` | Probe `/v1/health` and control-plane reachability |
| `./setup-panw-ai-gateway.sh --diagnose` | Pattern-match container logs against known failures |
| `./setup-panw-ai-gateway.sh --force-pull` | Re-pull even when the image is cached |
| `./setup-panw-ai-gateway.sh --version TAG` | Pin a gateway image tag |
| `./setup-panw-ai-gateway.sh --quiet` | Errors and warnings only, for CI |
| `./setup-panw-ai-gateway.sh --script-version` | Print the script version (`-v`) |

## Prerequisites

| Requirement | Details |
|---|---|
| **Docker** | 20.10+, with Docker Compose (v1 or v2) |
| **OS** | Linux (x86_64, aarch64) or macOS (Intel, Apple Silicon) |
| **Tools** | `curl` required; `yq` optional (used for exact YAML parsing when present) |
| **Network** | Outbound HTTPS — see [Egress](#egress-requirements) |
| **Input** | `values.yaml` from SCM → AI Gateway → Gateway Registration |

---

## Getting values.yaml

1. Strata Cloud Manager → **AI Gateway** → **Gateway Registration**
2. **Register New Gateway** — give it a name and a type (Production / Non-Production)
3. **Download values.yaml**

The file carries your registry credentials, the gateway's `PORTKEY_CLIENT_AUTH` token, and the org
UUID to sync. Treat it as a secret: it is gitignored here, and the registry password rotates, so
re-download rather than hand-editing when login starts failing.

---

## Configuration

### What comes from where

The installer merges three layers, in this order. Later layers win.

1. **Chart defaults** — hardcoded in the installer, mirroring the Helm chart's own
   `environment.data` and `airsgateway.builtinDefaults`.
2. **Your `values.yaml`** — whatever `environment.data` keys SCM put in it.
3. **Your `.env`** — anything you add or edit by hand after generation.

This matters because the downloaded `values.yaml` is short. It typically contains only
`PORTKEY_CLIENT_AUTH`, `ORGANISATIONS_TO_SYNC` and `PORT` — everything else in the table below is
inherited, exactly as Helm would.

### Inherited chart defaults

| Variable | Default | Purpose |
|---|---|---|
| `SERVICE_NAME` | `airsgateway` | Service identifier in logs and analytics |
| `PORT` | `8787` | Gateway HTTP listener |
| `MCP_PORT` | `8788` | MCP listener (active in `all` / `mcp` mode) |
| `SERVER_MODE` | `all` | `all` = gateway + MCP, `gateway` = inference only, `mcp` = MCP only |
| `LOG_STORE_FILE_PATH_FORMAT` | `v2` | Log path layout |
| `ALBUS_BASEPATH` | `https://mp.us.prod.airs-gw.portkey.ai/api` | Management plane — config sync |
| `CONTROL_PLANE_BASEPATH` | `https://aigw.portkey.ai/v1` | Control plane — analytics push |
| `LOG_STORE` | `control_plane` | Where request/response logs go |
| `ANALYTICS_STORE` | `control_plane` | Where analytics go |

Do not override the two basepaths unless PANW tells you to. A gateway pointed at the wrong
management plane starts cleanly and serves traffic — it just never syncs, which is easy to miss.

### Required

| Variable | Source | Notes |
|---|---|---|
| `PORTKEY_CLIENT_AUTH` | `values.yaml` | Gateway identity token. Install fails if empty. |
| `ORGANISATIONS_TO_SYNC` | `values.yaml` | Org UUID. Warns if not UUID-shaped. |
| `REGISTRY_USERNAME` | `values.yaml` | Your TSG ID. |
| `REGISTRY_PASSWORD` | `values.yaml` | Rotates — re-download when `docker login` starts failing. |

### Ports

`service.containerPort` from `values.yaml` sets what the process listens on. `service.port` is the
Kubernetes Service port; the installer publishes it on the host only when it is ≥ 1024, since the
`LoadBalancer` default of 80 would need root. Override with `HOST_PORT` / `HOST_MCP_PORT` in `.env`.

### Resource limits

| Variable | Default |
|---|---|
| `GATEWAY_MEM_LIMIT` | `2g` |
| `GATEWAY_CPUS` | `2.0` |

The chart ships `resources: {}` (unbounded, cluster's problem). A single Docker host needs a ceiling,
so these are the installer's own defaults — raise them for production throughput.

---

## External Redis

The bundled Redis is fine for a single-host deployment. For production, point the gateway at a
managed cache: set `CACHE_STORE` to anything other than `redis` and the bundled container is omitted
from the generated compose file.

Add to `.env` and re-run the installer.

### AWS ElastiCache

```env
CACHE_STORE="aws-elastic-cache"
REDIS_URL="redis://my-cache.abc123.ng.0001.euw1.cache.amazonaws.com:6379"
REDIS_TLS_ENABLED="true"
REDIS_PASSWORD="<auth-token>"
# REDIS_MODE="cluster"     # only when cluster mode is enabled
```

### Azure Managed Redis

```env
CACHE_STORE="azure-redis"
REDIS_URL="rediss://my-cache.redis.cache.windows.net:6380"
AZURE_REDIS_AUTH_MODE="password"
REDIS_TLS_ENABLED="true"
REDIS_PASSWORD="<access-key>"
```

Entra ID also works, since it is static-credential:

```env
AZURE_REDIS_AUTH_MODE="entra"
AZURE_REDIS_ENTRA_CLIENT_ID="..."
AZURE_REDIS_ENTRA_CLIENT_SECRET="..."
AZURE_REDIS_ENTRA_TENANT_ID="..."
```

### GCP Memorystore

```env
CACHE_STORE="gcp-memory-store"
REDIS_URL="redis://10.0.0.3:6379"
REDIS_TLS_ENABLED="false"
REDIS_PASSWORD="<auth-string>"
```

### Auth modes that do not work here

| Mode | Why |
|---|---|
| AWS IRSA / EKS Pod Identity (`AWS_REDIS_AUTH_MODE=iam`) | Identity comes from the pod's ServiceAccount token |
| Azure Workload Identity (`workload`) | Same — projected ServiceAccount token |
| Azure Managed Identity (`managed`) | Requires the Azure instance metadata endpoint and an AKS-assigned identity |
| GCP Workload Identity Federation (`workload`) | Identity comes from the GKE metadata server via the KSA |

These have no Docker equivalent: the Kubernetes ServiceAccount *is* the credential. Use a static
credential from the sections above, or deploy with Helm. The same applies to `LOG_STORE: s3_assume`
and the Azure/GCP identity modes for log storage.

---

## Egress requirements

Outbound HTTPS (TCP/443):

| Endpoint | When | Purpose |
|---|---|---|
| `mp.us.prod.airs-gw.portkey.ai` | Always | Management plane — config sync (every ~30s) |
| `aigw.portkey.ai` | Always | Control plane — analytics/metrics push |
| `registry.portkey.ai` | Setup / update | Image pull |

Plus outbound access to whichever LLM providers you route to. All connections are gateway-initiated;
nothing inbound is required.

`--validate` probes the first two. The gateway caches config for 7 days, so a management-plane
outage degrades rather than breaks inference.

### Proxy support

```env
HTTP_PROXY="http://proxy.example.com:8080"
HTTPS_PROXY="http://proxy.example.com:8080"
NO_PROXY="localhost,127.0.0.1"
```

### TLS-inspecting proxies (corporate VPN)

If your host re-signs TLS traffic — a corporate VPN, an SSL-decrypting firewall, Zscaler and
friends — the gateway will fail to reach its control plane even though the host reaches it fine.
The host trusts the proxy's CA; the container does not.

Symptoms:

```
error: fetchOrganisationIdFromAPIKey error: fetch failed
error: Job N failed in queue syncDataQueue fetch failed
```

and every API key rejected with `Portkey Error: Invalid API Key. Error Code: 03` — which means
"could not validate this key", not "this key is wrong".

Confirm it is TLS and not DNS or firewall:

```bash
docker compose exec airs-gw-gateway node -e \
  'fetch("https://mp.us.prod.airs-gw.portkey.ai/api").then(r=>console.log(r.status)).catch(e=>console.log(e.cause?.code))'
```

`SELF_SIGNED_CERT_IN_CHAIN` or `UNABLE_TO_VERIFY_LEAF_SIGNATURE` confirms interception. Identify the
issuer from the host:

```bash
echo | openssl s_client -connect mp.us.prod.airs-gw.portkey.ai:443 \
  -servername mp.us.prod.airs-gw.portkey.ai 2>/dev/null | openssl x509 -noout -issuer
```

An issuer that is not a public CA is your proxy.

#### Workaround — lab only

```env
INSECURE_SKIP_TLS_VERIFY="true"
```

Re-run the installer. This sets `NODE_TLS_REJECT_UNAUTHORIZED=0` in the container and prints a
warning on every run.

> **This disables TLS peer verification on every outbound connection**, not just the control plane.
> Traffic to your LLM providers included: prompts and responses travel over tunnels whose peer
> identity is no longer verified, and the gateway will accept any certificate presented to it.
> On a product whose job is securing AI traffic, that is a poor trade outside a lab.

For production behind an inspecting proxy, use one of these instead:

- **Exempt the control-plane FQDNs from decryption** — the three hosts in
  [Egress requirements](#egress-requirements). Usually a one-line firewall rule and the cleanest fix.
- **Run the gateway on a host outside the inspection path.**
- **Supply the proxy CA to the container** — mount it and set `NODE_EXTRA_CA_CERTS`, which keeps
  verification on and only adds your CA to the trust list. Currently a hand-edit of the generated
  compose file, overwritten on the next install run; first-class support is tracked as F-106 in
  `docs/FEATURES.yaml`.

---

## Out of scope

Deploy with the [Helm chart](https://github.com/Portkey-AI/airs-gw-helm) if you need:

| Feature | Note |
|---|---|
| **Dataservice** | Fine-tuning, custom batches, data exports. Needs S3 + ClickHouse. |
| **MinIO** | Self-hosted S3 for log storage. Use real S3/GCS/Blob, or `control_plane`. |
| **Milvus + etcd** | Vector store for semantic caching. Stateful, cluster-shaped. |
| **Autoscaling (HPA)** | Compose has no equivalent. Scale by running more hosts behind a load balancer. |
| **PodDisruptionBudget** | Kubernetes-only concept. |
| **Ingress** | Terminate TLS with your own reverse proxy in front of the published port. |
| **Vault injection** | Needs the Vault Agent sidecar injector. |
| **Cloud IAM auth** | See [above](#auth-modes-that-do-not-work-here). |

---

## Security

The generated compose file mirrors the chart's security context:

```yaml
user: "1000:1000"                      # non-root
read_only: true                        # immutable rootfs
tmpfs: [/tmp]                          # only writable path
security_opt: [no-new-privileges:true]
cap_drop: [ALL]
```

Plus limits the chart delegates to the cluster: `mem_limit`, `cpus`, `pids_limit`,
`restart: unless-stopped`, json-file log rotation.

Additional protections:

- Gateway image pinned by digest, so `compose up` cannot pick up a mutated tag.
- Registry password passed to `docker login` via `--password-stdin` — never visible in `ps`.
- `.env` and `.env.runtime` created mode `600` under `umask 077`.
- `.env` values single-quoted with `'\''` escaping — a credential containing backticks or `$()`
  cannot execute when sourced.
- Registry credentials stay out of the container's environment (`.env.runtime` excludes them).
- `--dry-run` redacts secrets before printing.
- `deploy.log` records image digests and timestamps, no secrets. Supports SOC 2 / ISO 27001.

### Rotating credentials

1. Re-register the gateway in SCM and download a fresh `values.yaml`.
2. `./setup-panw-ai-gateway.sh --from-values values.yaml`
3. `./setup-panw-ai-gateway.sh --validate`
4. Delete stale backups — they still hold the old secrets:
   ```bash
   shred -u .env.bak .env.runtime.bak 2>/dev/null || rm -f .env.bak .env.runtime.bak
   ```

Backups (`.env.bak`, `.env.runtime.bak`, `docker-compose.yml.bak`) are rewritten on every run and
never pruned automatically.

---

## Operations

```bash
./setup-panw-ai-gateway.sh --status         # deployment overview
./setup-panw-ai-gateway.sh --validate       # health + control plane
./setup-panw-ai-gateway.sh --diagnose       # log analysis

docker compose logs -f airs-gw-gateway      # follow logs
docker compose down                         # stop
docker compose up -d                        # start
docker compose restart                      # after editing .env.runtime
docker stats airs-gw-gateway                # resource usage
```

### Health

Where the image ships `curl` or `wget`, the installer emits a Docker healthcheck against
`/v1/health`. Gateway `2.15.0` ships `wget`, so the check is active. Distroless images would get
none, with `restart: unless-stopped` covering crashes.

```bash
curl -s localhost:8787/v1/health
```

**A green health check does not mean the gateway is working.** It proves the process is listening,
nothing more. In particular, `--validate` probes from the *host*, so on a machine behind a
TLS-inspecting proxy it reports success while the container cannot reach the control plane at all.

To tell the difference, look for sync failures in the logs:

```bash
docker compose logs airs-gw-gateway | grep -i "fetch failed\|fetchOrganisationIdFromAPIKey"
```

If those appear, the gateway is isolated — see
[TLS-inspecting proxies](#tls-inspecting-proxies-corporate-vpn). The only real end-to-end proof is
an inference request that shows up in the SCM AI Gateway log view.

### Updating

Re-run the installer. It pulls the configured tag, compares digests, and exits early when nothing
changed:

```bash
./setup-panw-ai-gateway.sh                     # current tag
./setup-panw-ai-gateway.sh --version 2.16.0    # move to a new tag
./setup-panw-ai-gateway.sh --force-pull        # same tag, repushed
```

Minimum supported gateway version is `2.15.0`; the installer warns below that.

### Uninstall

```bash
docker compose down -v
rm -f .env .env.runtime docker-compose.yml .image-digest
```

`-v` also removes the Redis volume. Omit it to keep the cache.

---

## Troubleshooting

Run `--diagnose` first — it pattern-matches the last 500 log lines.

| Problem | Likely cause | Fix |
|---|---|---|
| `Docker login failed` | Registry password rotated | Re-download `values.yaml`, re-run `--from-values` |
| `PORTKEY_CLIENT_AUTH is empty` | Incomplete `values.yaml` | Re-download from Gateway Registration |
| Container exits immediately | Bad `PORTKEY_CLIENT_AUTH` | `--diagnose`; re-register the gateway |
| Redis connection refused | Bundled Redis unhealthy, or bad `REDIS_URL` | `--status`; check `REDIS_PASSWORD` / TLS for external |
| Health check fails, logs look clean | Wrong `PORT` vs `service.containerPort` | Compare `.env` `PORT` and `HOST_PORT` |
| **Every** key rejected with `Error Code: 03` | Control plane unreachable — the key is probably fine | Check logs for `fetch failed`; see [TLS-inspecting proxies](#tls-inspecting-proxies-corporate-vpn) |
| `fetch failed` in the logs, `--validate` green | Container cannot egress, host can | [TLS-inspecting proxies](#tls-inspecting-proxies-corporate-vpn) |
| Gateway runs, nothing in SCM logs | Management plane unreachable | Allow egress to `mp.us.prod.airs-gw.portkey.ai` |
| `SELF_SIGNED_CERT_IN_CHAIN` | Corporate VPN / SSL decryption | [TLS-inspecting proxies](#tls-inspecting-proxies-corporate-vpn) |
| `read-only file system` | Something writing outside `/tmp` | Expected — the rootfs is immutable by design |
| `docker compose` not found | Compose plugin missing | `apt install docker-compose-plugin` |

---

## Migrating to Kubernetes

Config carries over directly — the variable names are the chart's own.

| Docker Compose | Helm |
|---|---|
| `.env.runtime` keys | `environment.data` in `values.yaml` |
| `REGISTRY_*` | `imageCredentials[0]` |
| `GATEWAY_IMAGE_REPO` / `_TAG` | `images.gatewayImage.repository` / `.tag` |
| `HOST_PORT` mapping | `service.port` / `ingress` |
| `user` / `read_only` / `cap_drop` | `securityContext` (already the chart's defaults) |
| `mem_limit` / `cpus` | `resources.limits` |
| Bundled Redis service | `redis.external.enabled: false` |
| External `REDIS_URL` | `redis.external.enabled: true` + `connectionUrl` |

Then:

```bash
helm repo add airs-gw https://portkey-ai.github.io/airs-gw-helm
helm upgrade --install airs-gw airs-gw/airs-gw -f values.yaml -n airs-gw --create-namespace
```

The original `values.yaml` from SCM works as-is — that is the supported path, and the one to use for
anything in [Out of scope](#out-of-scope).
