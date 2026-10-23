# CLAUDE.md

This file provides guidance to Claude Code when working with the homelab repository.

## Project Overview

IaC-driven homelab running Proxmox VE across 3 nodes, provisioning Kubernetes (k3s), PostgreSQL, and on-demand sandbox VMs with Terraform, Packer, and Ansible. Kubernetes workloads are deployed via ArgoCD GitOps.

## Repository Structure

```
homelab/
├── packer/ubuntu-2404/           # VM template (Packer + cloud-init autoinstall)
├── terraform/
│   ├── modules/proxmox-vm/       # Reusable VM module
│   └── stacks/
│       ├── k3s-cluster/          # k3s control plane + workers
│       ├── database/             # PostgreSQL VM
│       ├── ollama/               # Ollama inference server (GPU passthrough)
│       └── sandbox/              # On-demand test VMs
├── ansible/                      # Post-provisioning playbooks + roles
├── cloud-init/                   # Cloud-init configs (base, k8s, postgres)
├── scripts/                      # Proxmox host setup, API token generation
├── kubernetes/
│   ├── root-app.yml              # ArgoCD bootstrap (app-of-apps)
│   ├── projects/                 # ArgoCD AppProjects (NOT auto-synced)
│   │   ├── infrastructure.yml    # For infra services (traefik, cert-manager, etc.)
│   │   └── applications.yml      # For application workloads (external app repos)
│   ├── apps/                     # ArgoCD Applications (auto-synced by root-app)
│   │   ├── cert-manager/
│   │   ├── coredns/
│   │   ├── linkwarden/
│   │   ├── metallb/
│   │   ├── monitoring/
│   │   ├── speedtest-tracker/
│   │   ├── traefik/
│   │   ├── workout-tracker/
│   │   ├── arc/                  # GitHub Actions Runner Controller (ARC)
│   │   ├── litellm/             # LiteLLM API gateway
│   │   ├── mmo/                 # MMO game server (syncs deploy/k8s from azskylab/videogame)
│   │   ├── swgemu/              # SWGEmu Core3 (Star Wars Galaxies emulator) + MariaDB
│   │   ├── traefik-public/      # Second Traefik, internet-facing, game only (10.0.20.83)
│   │   └── wireguard/           # WireGuard VPN (wg-easy)
│   └── manifests/
│       ├── ingress/              # Traefik Ingress resources for infra services
│       ├── arc/                  # ARC runner CA certificate
│       ├── cert-manager-ca/     # Internal CA issuers + Let's Encrypt issuers (letsencrypt-issuers.yml)
│       ├── litellm/             # LiteLLM proxy (ConfigMap, Deployment, Service, Ingress)
│       ├── swgemu/              # Core3 Deployment + UDP LoadBalancer (10.0.20.84), MariaDB
│       └── wireguard/           # wg-easy + DuckDNS CronJob
├── images/swgemu-core3/          # Core3 server image (Dockerfile, entrypoint, console + add-account helpers, custom_scripts, dev/ test server)
├── workstation/ai-3d/            # Local AI 3D service on the workstation (ComfyUI, TRELLIS.2, SDXL)
└── docs/                         # Network design, Unifi setup, AD migration
```

## Cluster Topology

| Node | IP | Role |
|------|-----|------|
| k3s-server-01 | 10.0.20.10 | Control plane |
| k3s-agent-01 | 10.0.20.21 | Worker |
| k3s-agent-02 | 10.0.20.22 | Worker |
| k3s-agent-03 | 10.0.20.23 | Worker |
| postgres-01 | 10.0.30.10 | External PostgreSQL (VLAN 30) |
| ollama-01 | 10.0.20.30 | Ollama inference server (GPU passthrough, VLAN 20) |
| workstation | 10.0.10.40 | Workstation Ollama (RTX 5090, VLAN 10) |

### Key IPs

| Service | IP | DNS |
|---------|-----|-----|
| Traefik LB | 10.0.20.80 | `*.home.lab` ingress (internal only; never port-forward this) |
| Traefik public LB | 10.0.20.83 | `jankmmo.duckdns.org` (internet-facing, MMO game only) |
| CoreDNS LB | 10.0.20.53 | Internal DNS |
| PostgreSQL | 10.0.30.10 | `postgres.home.lab` |
| Ollama (VM) | 10.0.20.30 | `ollama.home.lab` |
| Ollama (Workstation) | 10.0.10.40 | `desktop.home.lab` |
| LiteLLM | 10.0.20.80 | `llm.home.lab` (via Traefik) |
| WireGuard | 10.0.20.21 (hostNetwork) | `vpn.home.lab` (web UI) |
| SWGEmu Core3 LB | 10.0.20.84 | — (UDP 44453 login, 44462 ping, 44463 zone; TCP 44455 status) |

### Kubeconfig

```bash
# From the k3s server
ssh ubuntu@10.0.20.10 sudo cat /etc/rancher/k3s/k3s.yaml
# Replace 127.0.0.1 with 10.0.20.10, save to ~/.kube/config
```

Or use the Ansible-generated kubeconfig:
```bash
export KUBECONFIG=ansible/kubeconfig
```

## ArgoCD GitOps Architecture

### App-of-Apps Pattern

ArgoCD is bootstrapped via Ansible which applies `kubernetes/root-app.yml`. This root Application watches `kubernetes/apps/` recursively and auto-discovers all Application YAMLs:

```
root-app.yml (applied by Ansible)
  └── watches kubernetes/apps/** (directory, recurse: true)
        ├── cert-manager/cert-manager.yml     → deploys cert-manager Helm chart
        ├── coredns/coredns.yml               → deploys CoreDNS Helm chart
        ├── traefik/traefik.yml               → deploys Traefik Helm chart
        ├── workout-tracker/workout-tracker.yml → syncs external repo k8s/ dir
        └── ...
```

### AppProjects

Two projects control permissions:

- **`infrastructure`** — For infra services deployed from Helm charts or this repo. Has `clusterResourceWhitelist: */*` and scoped namespace destinations.
- **`applications`** — For application workloads, potentially from external repos. Has `clusterResourceWhitelist` for Namespaces and `namespaceResourceWhitelist: */*` with wildcard namespace destinations.

**Important:** AppProjects live in `kubernetes/projects/` which is NOT watched by the root app. Changes to AppProjects must be applied manually:

```bash
kubectl apply -f kubernetes/projects/applications.yml
kubectl apply -f kubernetes/projects/infrastructure.yml
```

### Adding a New Application

1. **Create the Application YAML:**
   ```bash
   mkdir kubernetes/apps/<app-name>/
   ```
   Create `kubernetes/apps/<app-name>/<app-name>.yml`:
   ```yaml
   ---
   apiVersion: argoproj.io/v1alpha1
   kind: Application
   metadata:
     name: <app-name>
     namespace: argocd
     finalizers:
       - resources-finalizer.argocd.argoproj.io
   spec:
     project: applications  # or infrastructure
     source:
       repoURL: https://github.com/azskylab/<repo>.git
       targetRevision: main  # or master
       path: k8s/            # path to manifests in the source repo
     destination:
       server: https://kubernetes.default.svc
       namespace: <app-namespace>
     syncPolicy:
       automated:
         prune: true
         selfHeal: true
       syncOptions:
         - CreateNamespace=true
   ```

2. **If using an external repo,** add it to the AppProject's `sourceRepos`:
   Edit `kubernetes/projects/applications.yml`:
   ```yaml
   sourceRepos:
     - https://github.com/azskylab/<new-repo>.git
   ```
   Then apply manually: `kubectl apply -f kubernetes/projects/applications.yml`
   A **private** repo also needs an ArgoCD repository Secret (a read-only deploy key over SSH; see the MMO section),
   and the AppProject must list the SSH URL.

3. **Add DNS entry** in `kubernetes/apps/coredns/coredns.yml` under `zoneFiles[0].contents`:
   ```
   <subdomain>           IN  A    10.0.20.80
   ```
   All web apps route through Traefik at `10.0.20.80`.

4. **Commit and push.** The root app will auto-discover the new Application YAML.

5. **Run any post-deploy steps** (migrations, seeding, etc.) via `kubectl exec`.

### Ingress Pattern (Traefik + TLS)

All HTTPS ingresses follow this pattern using Traefik and cert-manager:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: <app-name>
  namespace: <app-namespace>
  annotations:
    cert-manager.io/cluster-issuer: home-lab-ca
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
spec:
  ingressClassName: traefik
  tls:
    - secretName: <app-name>-tls
      hosts:
        - <app-name>.home.lab
  rules:
    - host: <app-name>.home.lab
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: <service-name>
                port:
                  number: <port>
```

- `home-lab-ca` is a cert-manager ClusterIssuer (internal CA)
- `websecure` is the Traefik HTTPS entrypoint
- TLS certificates are auto-provisioned by cert-manager

### Infrastructure Services

| Service | Namespace | Type | Access |
|---------|-----------|------|--------|
| ArgoCD | argocd | Helm (argo-helm) | https://argocd.home.lab |
| Traefik | traefik | Helm | LB at 10.0.20.80 |
| Traefik (public) | traefik-public | Helm (same chart 42.1.2) | LB at 10.0.20.83; serves only Ingresses of class `traefik-public` |
| CoreDNS | coredns | Helm | LB at 10.0.20.53 |
| cert-manager | cert-manager | Helm | Internal CA (`home-lab-ca`); Let's Encrypt (`letsencrypt-staging`, `letsencrypt-prod`) for public hosts |
| MetalLB | metallb-system | Helm | IP pool: `k8s-vlan-pool` |
| Prometheus + Grafana | monitoring | Helm | https://grafana.home.lab |
| ARC Controller | arc-systems | Helm (gha-runner-scale-set-controller) | N/A (internal) |
| ARC Runner Set | arc-runners | Helm (gha-runner-scale-set) | GitHub Actions `homelab-runners` |

### Application Workloads

| App | Namespace | Source Repo | Access |
|-----|-----------|-------------|--------|
| Linkwarden | linkwarden | homelab (kubernetes/manifests/linkwarden/) | https://linkwarden.home.lab |
| Workout Tracker | workout-tracker | GitHub azskylab/workouttracker (k8s/) | https://workout.home.lab |
| CorpoCache | corpocache | GitHub azskylab/CorpoCache (helm/) | https://cache.home.lab |
| Speedtest Tracker | speedtest-tracker | homelab (kubernetes/manifests/speedtest-tracker/) | https://speedtest.home.lab |
| LiteLLM | litellm | homelab (kubernetes/manifests/litellm/) | https://llm.home.lab |
| Open WebUI | open-webui | homelab (kubernetes/manifests/open-webui/) | https://chat.home.lab |
| WireGuard | wireguard | homelab (kubernetes/manifests/wireguard/) | https://vpn.home.lab |
| MMO game server | mmo | GitHub azskylab/videogame, private (deploy/k8s/) | `wss://jankmmo.duckdns.org` (public) |
| SWGEmu Core3 | swgemu | homelab (kubernetes/manifests/swgemu/), image from images/swgemu-core3 | UDP `10.0.20.84:44453` |

## External PostgreSQL

PostgreSQL runs on a dedicated VM at `10.0.30.10` (VLAN 30, Database network), provisioned via Terraform and configured via Ansible.

### Creating a Database for a New App

```bash
# Connect as admin
PGPASSWORD='<admin-password>' psql -h 10.0.30.10 -U postgres

# Create database and user
CREATE DATABASE <appname>;
CREATE USER <appname> WITH ENCRYPTED PASSWORD '<password>';
GRANT ALL PRIVILEGES ON DATABASE <appname> TO <appname>;
\c <appname>
GRANT ALL ON SCHEMA public TO <appname>;
```

### Database Connection String Format

```
postgresql://<user>:<password>@10.0.30.10:5432/<database>
```

Store in a Kubernetes Secret in the app's namespace, referenced by the backend pods.

## Common Tasks

### Deploying Code Changes to an App

For apps using `imagePullPolicy: Always` with `latest` tag:

```bash
# 1. Push code to git (ArgoCD syncs k8s manifests automatically)
# 2. Build and push Docker images
docker build -t <registry>/<image>:latest -f <Dockerfile> .
docker push <registry>/<image>:latest
# 3. Restart deployments to pull new images
kubectl rollout restart deployment/<name> -n <namespace>
```

For proper GitOps, apps should have a GitHub Actions CI workflow that builds images on push and pushes to GHCR. See the GitHub Actions CI/CD section below.

### Checking ArgoCD Status

```bash
kubectl get applications -n argocd
kubectl get application <name> -n argocd -o jsonpath='{.status.sync.status} {.status.health.status}'
# Force refresh
kubectl annotate application <name> -n argocd argocd.argoproj.io/refresh=hard --overwrite
```

### Debugging a Failed Sync

```bash
kubectl get application <name> -n argocd -o jsonpath='{.status.operationState.syncResult.resources}' | python3 -m json.tool
```

Common issues:
- **"resource not permitted in project"** — Update the AppProject's `sourceRepos`, `destinations`, or resource whitelists, then `kubectl apply` the project file
- **Stuck retrying old revision** — Clear the operation: `kubectl patch application <name> -n argocd --type merge -p '{"operation": null}'`

## Secrets Management

All secrets are stored in `pass` (GPG-backed password store) under the `homelab/` prefix.

```bash
# List all secrets
pass homelab/

# Retrieve a secret
pass homelab/<app>/<key-name>

# Store a new secret
echo 'value' | pass insert -e homelab/<app>/<key-name>
```

### Secret Inventory

| pass path | K8s Secret | Namespace | Description |
|-----------|-----------|-----------|-------------|
| `homelab/glance/github-token` | glance-secrets | glance | GitHub API token for repo widget |
| `homelab/glance/jellyfin-api-key` | glance-secrets | glance | Jellyfin API key for media widgets |
| `homelab/glance/unifi-api-key` | glance-secrets | glance | Unifi controller API key |
| `homelab/glance/speedtest-tracker-api-token` | glance-secrets | glance | Speedtest Tracker API token |
| `homelab/linkwarden/*` | linkwarden-secrets | linkwarden | DB password, NextAuth, Meili key, API key |
| `homelab/proxmox/monitoring-*` | pve-exporter-credentials | monitoring | PVE API token (`prometheus@pve!monitoring`) |
| `homelab/unifi/unpoller-*` | unpoller-credentials | monitoring | UnPoller read-only user credentials |
| `homelab/speedtest-tracker/app-key` | speedtest-tracker-secrets | speedtest-tracker | Laravel APP_KEY |
| `homelab/pgadmin/*` | pgadmin-credentials | pgadmin | Default admin email and password |
| `homelab/corpocache/*` | corpocache-secret | corpocache | PostgreSQL connection details |
| `homelab/workout-tracker/*` | workout-tracker-secrets | workout-tracker | PostgreSQL URL, JWT secrets |
| `homelab/arc/github-app-id` | arc-github-app | arc-runners | GitHub App ID for ARC runner registration |
| `homelab/arc/github-app-installation-id` | arc-github-app | arc-runners | GitHub App Installation ID |
| `homelab/arc/github-app-private-key` | arc-github-app | arc-runners | GitHub App private key (PEM) |
| `homelab/litellm/master-key` | litellm-secrets | litellm | LiteLLM master key (API auth + UI login) |
| `homelab/litellm/db-password` | litellm-secrets | litellm | LiteLLM PostgreSQL password |
| `homelab/litellm/master-key` | litellm-api-key | open-webui | Same key, used by Open WebUI to call LiteLLM |
| `homelab/wireguard/password-hash` | wireguard-secrets | wireguard | Bcrypt hash for wg-easy web UI login |
| `homelab/wireguard/wg-host` | wireguard-secrets | wireguard | DuckDNS hostname (`malliefivpn.duckdns.org`) |
| `homelab/wireguard/duckdns-token` | duckdns-secrets | wireguard | DuckDNS API token |
| `homelab/wireguard/duckdns-subdomain` | duckdns-secrets | wireguard | DuckDNS subdomain (`malliefivpn`) |
| `homelab/mmo/db-password` | mmo-server (`DATABASE_URL`), mmo-backup (`PGPASSWORD`) | mmo | PostgreSQL password for the `mmo` database |
| `homelab/mmo/signup-code` | mmo-server (`MMO_SIGNUP_CODE`) | mmo | Invite code players type to create an account |
| `homelab/mmo/argocd-deploy-key` | videogame-repo | argocd | Read-only GitHub deploy key so ArgoCD can read the private videogame repo |
| — (copied from corpocache) | ghcr-pull-secret | mmo | GHCR pull secret, attached to the namespace's `default` ServiceAccount |
| `homelab/swgemu/db-password` | swgemu-secrets (`db-password`) | swgemu | MariaDB `swgemu` user, used by Core3 |
| `homelab/swgemu/db-root-password` | swgemu-secrets (`db-root-password`) | swgemu | MariaDB root |
| `homelab/swgemu/db-secret` | swgemu-secrets (`db-secret`) | swgemu | Core3 `DBSecret`, mixed into every account password hash (changing it breaks all logins) |
| `homelab/swgemu/admin-password` | — | — | Game account `cameren` (admin level 15) |
| `homelab/swgemu/litellm-key` | swgemu-secrets (`litellm-key`) | swgemu | LiteLLM virtual key for the talk bridge, limited to `vm/qwen3.8:27b` (optional: without it the NPCs give canned lines) |
| — (copied from corpocache) | ghcr-pull-secret | swgemu | GHCR pull secret, attached to the namespace's `default` ServiceAccount |

### Recreating a K8s Secret from pass

```bash
# Example: recreate linkwarden-secrets
kubectl create secret generic linkwarden-secrets -n linkwarden \
  --from-literal=NEXTAUTH_SECRET="$(pass homelab/linkwarden/nextauth-secret)" \
  --from-literal=NEXTAUTH_URL="https://linkwarden.home.lab/api/v1/auth" \
  --from-literal=DATABASE_URL="$(pass homelab/linkwarden/database-url)" \
  --from-literal=MEILI_MASTER_KEY="$(pass homelab/linkwarden/meili-master-key)"
```

## LiteLLM (Multi-GPU API Gateway)

LiteLLM runs as an OpenAI-compatible proxy in k8s, aggregating both Ollama backends behind a single endpoint at `https://llm.home.lab`.

### Backends

| Backend | GPU | IP | Prefix |
|---------|-----|-----|--------|
| Proxmox VM (ollama-01) | RTX 3090 (24GB) | 10.0.20.30:11434 | `vm/` |
| Workstation | RTX 5090 (32GB) | 10.0.10.40:11434 | `ws/` |

### Model Routing

- **`vm/<model>`** — routes to the Proxmox VM (RTX 3090)
- **`ws/<model>`** — routes to the workstation (RTX 5090)
- **`ollama/<model>`** — load-balanced across whichever backend has the model

Models are listed explicitly per backend in `kubernetes/manifests/litellm/configmap.yml`. When pulling a new model on either Ollama instance, add a corresponding entry to the ConfigMap (then `kubectl rollout restart deployment litellm -n litellm` — config is read at startup). Use `model: "ollama_chat/<model>"` in `litellm_params`: the `ollama/` prefix talks to `/api/generate` and fakes tool calls with JSON mode, which broke every tool-using client (omp, Open WebUI tools) until 2026-10-22.

Current headliners (2026-10): `qwen3.8:27b` on both (dense, vision, 18GB; also load-balanced as `ollama/qwen3.8:27b`),
and `ws/qwen3.6:35b-a3b` (MoE, 23GB, about 3x faster).

`qwen3.6-abliterated:27b` (both backends, since 2026-10-23) is huihui-ai's abliterated (refusals removed) Qwen3.6 27B,
not from the Ollama library, so `ollama pull` and the Ansible role can't fetch it. To rebuild it on a backend:
- Download `Huihui-Qwen3.6-27B-abliterated-ggml-model-Q4_K.gguf` (16.8 GB) and `mmproj-model-f16.gguf` from
  `huihui-ai/Huihui-Qwen3.6-27B-abliterated-MTP-GGUF` and check them against the repo's LFS sha256. `ollama pull
  hf.co/...:Q4_K` doesn't work: Hugging Face only accepts standard quant names like `Q4_K_M` as tags.
- `ollama create qwen3.6-abliterated:27b -f Modelfile`. The Modelfile is `ollama show --modelfile qwen3.6:35b-a3b`
  minus its `FROM`, plus two `FROM` lines (the model GGUF, then the mmproj), so it gets the same renderer, parser,
  sampling and MTP drafting.
- MTP (the `nextn` layer, `draft_num_predict 2`) roughly doubles speed: 66 → 115 tok/s on the 5090.

### Ollama context length (important)

Ollama defaults to a 4096 context, which silently truncates agentic prompts. Fixed via
systemd drop-in `zz-context.conf` on both backends (the `zz-` prefix matters — the stock
`override.conf` also sets `OLLAMA_CONTEXT_LENGTH` and drop-ins are applied in filename
order, last wins):

- Workstation: `OLLAMA_CONTEXT_LENGTH=65536` (since 2026-10-22; every model still fits on the 5090, 25-27.4 of 32.6 GB), `OLLAMA_NUM_PARALLEL=1` (parallel slots multiply KV memory)
- ollama-01 VM: `OLLAMA_CONTEXT_LENGTH=16384`, `OLLAMA_NUM_PARALLEL=1` (24GB card, tighter)

### OpenCode — local coding agent on the workstation

[OpenCode](https://github.com/anomalyco/opencode) 2.x (MIT) is installed from the Arch repo (`pacman -S opencode`, so
`-Syu` updates it) and wired to LiteLLM, so it codes against the local GPUs. It replaced oh-my-pi (omp) on 2026-10-22:
same bug-fix task on `ws/qwen3.8:27b`, both passed, but OpenCode's own prompt is about 8k tokens against omp's 18k,
so it also runs on the 3090's 16k context (omp could not).

- Config: `~/.config/opencode/opencode.jsonc`. Provider `homelab`, package `@opencode/ai/providers/openai-compatible`,
  `settings.baseURL: http://llm.home.lab/v1`, `settings.apiKey: {file:~/.config/opencode/litellm.key}` (the LiteLLM
  master key, mode 600). Model keys are LiteLLM model names; default `homelab/ws/qwen3.8:27b`.
- Each model's `limit.context` is its backend's `OLLAMA_CONTEXT_LENGTH` (ws 65536, vm 16384); `limit.output` 16384 / 4096.
  `capabilities.tools: true` must be set on custom models.
- `disabled_providers: [ollama, lmstudio, vllm, opencode]`: the first three would list the same models again with their
  native 262k context; `opencode` is OpenCode's hosted free-model service, which would send code off the LAN.
  `share: disabled`, `update: disable` (pacman updates it).
- A background server (127.0.0.1 only) runs the sessions; after editing the config run `opencode service restart`.
  `opencode models` should list exactly the four `homelab/...` models.
- Usage: `opencode` (TUI) in a project folder, or `opencode run --auto "prompt"` (one-shot, auto-approves tools);
  `-m homelab/ws/qwen3.6:35b-a3b` for the faster model, `-m homelab/vm/qwen3.8:27b` for the 3090.
- omp's leftover config and sessions are in `~/.omp` (796K); `rm -rf ~/.omp` once it is no longer wanted.

### Authentication

All API requests require `Authorization: Bearer <master-key>`. The master key is stored in:
- `pass homelab/litellm/master-key`
- K8s Secret `litellm-secrets` in namespace `litellm` (env var `LITELLM_MASTER_KEY`)

The LiteLLM admin UI is at `https://llm.home.lab/ui` (login with the master key).

### Open WebUI Integration

Open WebUI connects to LiteLLM via env vars in `kubernetes/manifests/open-webui/deployment.yml`:
- `OPENAI_API_BASE_URLS` → `http://litellm.litellm.svc.cluster.local:4000/v1`
- `OPENAI_API_KEYS` → from Secret `litellm-api-key` in `open-webui` namespace

### Network Requirements

- **USG firewall rule**: VLAN 20 (10.0.20.0/24) → 10.0.10.40:11434 (TCP) — allows k8s pods to reach workstation Ollama
- **Workstation UFW rule**: `ufw allow from 10.0.20.0/24 to any port 11434 proto tcp`
- Workstation Ollama binds `0.0.0.0` via systemd override at `/etc/systemd/system/ollama.service.d/override.conf`

## AI 3D Service (Workstation)

Local image and 3D generation on the workstation RTX 5090 for the game's art pipeline
(`~/github/videogame/tools/ai_assets/`). Files: `workstation/ai-3d/` (`setup.sh`, `ai3d.sh`, `models.md`, `README.md`).

- **What:** ComfyUI (pinned tag) with TRELLIS.2 (image to textured mesh) and SDXL + OpenPose/depth ControlNets.
  Every node, model and revision is pinned in `setup.sh`; `models.md` lists licences (read 2026-10-14).
- **Where:** heavy files in `~/ai-3d/` (venv, ComfyUI, weights) and `~/.ce/` (the TRELLIS2 node's pixi env); not in git.
- **Run:** `workstation/ai-3d/ai3d.sh start|stop|status|log`. Listens on **127.0.0.1:8188 only** (no UFW/USG rule;
  not behind LiteLLM). Starts with `HF_HUB_OFFLINE=1` so nothing downloads weights or remote code at run time.
- **VRAM:** TRELLIS.2 needs about 24 GB. Unload Ollama models first (`ollama ps`, `ollama stop <model>`);
  `ai3d.sh` warns when Ollama has models loaded.
- **Licence to-do:** DINOv3 (used inside TRELLIS.2) comes from a re-upload; accept Meta's licence on the official
  `facebook/dinov3-vitl16-pretrain-lvd1689m` page once.

## MMO Game Server (Public)

The game server from `azskylab/videogame` is the only thing in the lab that faces the internet over TCP. It has its own
door: a second Traefik on its own MetalLB address, so the router never forwards to the lab-wide Traefik.

### Architecture

```
Internet → USG port forward (TCP 80, 443) → traefik-public LB 10.0.20.83 → Ingress (class traefik-public) → mmo-server:7777
mmo-server pod → PostgreSQL VM 10.0.30.10 (database `mmo`)
Players: wss://jankmmo.duckdns.org (Let's Encrypt certificate, TLS ends at traefik-public, the pod speaks plain ws)
Downloads: https://jankmmo.duckdns.org/downloads/ → Ingress mmo-downloads → nginx (mmo-downloads pod) ← mirror sidecar ← GitHub Releases
```

### Key Details

| Setting | Value |
|---------|-------|
| Public name | `jankmmo.duckdns.org` (DuckDNS, A record → home public IP) |
| Public Traefik | `traefik-public` namespace, LB `10.0.20.83`, `--providers.kubernetesingress.ingressClass=traefik-public` |
| Certificate | `mmo-server-tls` in `mmo`, ClusterIssuer `letsencrypt-prod` (HTTP-01), renews automatically |
| Image | `ghcr.io/azskylab/mmo-server:latest` (private; built by the videogame repo's `image.yml` on ARC runners) |
| ArgoCD app | `mmo` (project `applications`), `git@github.com:AzSkyLab/videogame.git`, path `deploy/k8s` |
| Database | `mmo` on `10.0.30.10`, user `mmo` |
| Backups | CronJob `mmo-backup`, daily 03:30 America/New_York, PVC `mmo-backups` |
| Admin account | `cameren` (`MMO_ADMINS`); in-game `/who /kick /ban /unban /announce` |
| Dev commands | Off (`MMO_DEV_COMMANDS=0`) |
| Downloads | Deployment `mmo-downloads` (nginx-unprivileged + a curl mirror sidecar, images pinned by digest), PVC `mmo-downloads` 6 Gi; in the app's `include` list in `kubernetes/apps/mmo/mmo.yml` since 2026-10-17 |
| Mirror token | Secret `mmo-downloads-token` (key `token`), `pass homelab/mmo/downloads-token`: fine-grained, videogame repo only, Contents read-only, made 2026-10-17, **expires about 2027-10-17** |
| Update signing key | Private half in `pass mmo/update-signing-key` (top level, not under `homelab/`) and the repo secret `MMO_UPDATE_SIGNING_KEY`; public half committed as `tools/installer/update_key.pem` |

### USG Port Forwards

| Name | Protocol | WAN port | Forward IP | Forward port |
|------|----------|----------|------------|--------------|
| WireGuard VPN | UDP | 443 | `10.0.20.21` | 443 |
| MMO https | TCP | 443 | `10.0.20.83` | 443 |
| MMO http (Let's Encrypt) | TCP | 80 | `10.0.20.83` | 80 |

Never forward to `10.0.20.80` (lab-wide Traefik) or to a node address over TCP. TCP and UDP 443 go to different hosts.

### Important Design Decisions and Gotchas

- **Separate public Traefik.** It only serves Ingresses of class `traefik-public`, so `*.home.lab` hosts return 404 on
  the public door. Check after any change:
  `curl -sk -o /dev/null -w "%{http_code}\n" --resolve grafana.home.lab:443:10.0.20.83 https://grafana.home.lab/` → `404`.
  The lab-wide Traefik serves only class `traefik` (since 2026-10-22; before that both doors claimed the game's
  Ingresses and kept overwriting their status). Both doors strip aliasing headers (`aliasHeadersStrategy: delete`,
  CVE-2026-88879) and set `core.strictTLSOptions`; the public door also refuses encoded characters in paths.
- **HTTP-01 behind an https redirect.** The public Traefik redirects port 80 to https for everything, so the Let's
  Encrypt issuers give the solver Ingress `router.entrypoints: web,websecure` and `router.tls: "true"`
  (`letsencrypt-issuers.yml`, `ingressTemplate`). Let's Encrypt follows the redirect and does not check the
  certificate behind it.
- **Split DNS inside the cluster (manual, not in git).** From inside the LAN the public IP answers with the USG's own
  login page (no hairpin for that path), so cert-manager's self-check failed. The k3s CoreDNS override resolves the game
  name to the public Traefik inside the cluster. It lives in the `coredns-custom` ConfigMap in `kube-system`, key
  `jankmmo.server`:
  ```
  jankmmo.duckdns.org:53 {
    errors
    hosts {
      10.0.20.83 jankmmo.duckdns.org
    }
  }
  ```
  Recreate with `kubectl -n kube-system patch configmap coredns-custom --type merge -p '{"data":{"jankmmo.server":"..."}}'`
  then `kubectl -n kube-system rollout restart deploy/coredns`.
- **Split DNS for LAN clients (in git, since 2026-10-18).** The lab CoreDNS (`coredns-external`, 10.0.20.53) has a
  `jankmmo.duckdns.org` zone answering `10.0.20.83` (`kubernetes/apps/coredns/coredns.yml`), so home computers that use
  10.0.20.53 reach the game and its downloads page. A device on a network whose DHCP hands out another DNS server still
  gets the public IP and the USG login page (`nslookup jankmmo.duckdns.org` tells which).
- **Testing from the LAN is misleading.** `curl https://<public IP>/` from inside answers with the USG login page for any
  host name (HTTP 200). Test the doors by address (`--resolve host:443:10.0.20.83`) or from a phone on mobile data.
- **Private repo access.** ArgoCD reads the private videogame repo with a read-only deploy key (GitHub: repo settings ▸
  Deploy keys, "ArgoCD (read-only)"); the ArgoCD repository Secret is `videogame-repo` in `argocd`, and the AppProject
  `applications` lists the SSH URL `git@github.com:AzSkyLab/videogame.git`.
- **Downloads mirror.** Every 5 minutes the sidecar reads the newest GitHub Release with the token, checks every file
  against `SHA256SUMS` and switches `latest.json` last; a failed round keeps serving the old version. It gives up on a
  tag after 3 failed tries, remembered in `/data/downloads/.failed` on the volume (survives restarts), and a release seen
  before its assets finish uploading counts as a try. To make it try again:
  `kubectl -n mmo exec deploy/mmo-downloads -c mirror -- rm /data/downloads/.failed`. When the token lapses it logs
  "cannot read the latest release"; make a new one and replace the Secret.
- **Image pulls.** `ghcr-pull-secret` (copied from `corpocache`) is attached to the `mmo` namespace's `default`
  ServiceAccount, the same pattern as corpocache and workout-tracker.

### Common Tasks

```bash
# Logs
kubectl -n mmo logs deploy/mmo-server -f
# Update the server: push to videogame main (image.yml builds the image), then
kubectl -n mmo rollout restart deployment/mmo-server   # everyone is saved and disconnected; warn with /announce first
# Certificate state
kubectl -n mmo get certificate,challenge
# Downloads: what is served, and the mirror's log (a new v* tag on the videogame repo is served within ~5 minutes of its release)
curl -s --resolve jankmmo.duckdns.org:443:10.0.20.83 https://jankmmo.duckdns.org/downloads/latest.json | head -5
kubectl -n mmo logs deploy/mmo-downloads -c mirror --tail=20
# Register the admin before letting anyone in (only needed on a fresh database)
kubectl -n mmo port-forward svc/mmo-server 7777:7777   # then the client connects to ws://127.0.0.1:7777
```

### Recreating K8s Secrets

```bash
kubectl create namespace mmo
kubectl -n mmo create secret generic mmo-server \
  --from-literal=DATABASE_URL="postgres://mmo:$(pass homelab/mmo/db-password)@10.0.30.10:5432/mmo" \
  --from-literal=MMO_SIGNUP_CODE="$(pass homelab/mmo/signup-code)" \
  --from-literal=MMO_ADMINS=cameren
kubectl -n mmo create secret generic mmo-downloads-token --from-literal=token="$(pass homelab/mmo/downloads-token)"
kubectl -n mmo create secret generic mmo-backup \
  --from-literal=PGHOST=10.0.30.10 --from-literal=PGUSER=mmo --from-literal=PGDATABASE=mmo \
  --from-literal=PGPASSWORD="$(pass homelab/mmo/db-password)"
kubectl -n corpocache get secret ghcr-pull-secret -o json \
  | jq '{apiVersion,kind,type,data,metadata:{name:"ghcr-pull-secret",namespace:"mmo"}}' | kubectl apply -f -
kubectl -n mmo patch serviceaccount default -p '{"imagePullSecrets":[{"name":"ghcr-pull-secret"}]}'
pass homelab/mmo/argocd-deploy-key > /tmp/k && kubectl -n argocd create secret generic videogame-repo \
  --from-file=sshPrivateKey=/tmp/k --from-literal=type=git \
  --from-literal=url=git@github.com:AzSkyLab/videogame.git && shred -u /tmp/k
kubectl -n argocd label secret videogame-repo argocd.argoproj.io/secret-type=repository
```

The database was made with `ansible-playbook playbooks/create-app-db.yml -e app_name=mmo -e app_db_password="$(pass homelab/mmo/db-password)"`.

## SWGEmu Core3 (Star Wars Galaxies Emulator)

[swgemu/Core3](https://github.com/swgemu/Core3) (pre-CU SWG server, C++, AGPL) runs in the `swgemu` namespace with its
own MariaDB. Upstream only ships a dev container (gdb, screen, interactive shell), so the image is our own:
`images/swgemu-core3/`.

The Linux client, the scripts that built the TRE set (`tools/fetch-tre.sh`) and our game settings live in the local
repo `~/github/swgemu` on the workstation (not on GitHub). Server changes go here, client and tooling there.

### Architecture

```
SWG client → UDP 44453 (login) → core3 LB 10.0.20.84 → core3 pod
           ← galaxy table hands out GALAXY_ADDRESS:44463 (zone) and :44462 (ping)
core3 pod → mariadb:3306 (accounts, characters list, galaxy row)
core3 pod → /data (PVC core3-data: Berkeley DB world state, navmeshes, logs) and /tre (PVC core3-tre: client TRE files)
```

### Key Details

| Setting | Value |
|---------|-------|
| Image | `ghcr.io/azskylab/swgemu-core3:<core3 sha8>-<homelab sha7>` (private; the homelab part is the last commit touching `images/swgemu-core3/`), built on the workstation, tag in `core3.yml` |
| Core3 commit | `CORE3_REF` build arg in the Dockerfile (unstable branch) |
| Our scripts | `images/swgemu-core3/custom_scripts/`, copied over Core3's empty `bin/scripts/custom_scripts/` hooks (Living Cities: player-looking city crowds; bot players' jobs and roster). Specs in `~/github/swgemu/specs/` |
| Our C++ | `images/swgemu-core3/patches/` (bot players), applied at image build |
| Clock | `TZ=America/New_York` (scripts read the local hour) |
| Galaxy | `Homelab`, id 2; address from `GALAXY_ADDRESS` (written into the `galaxy` table at every start) |
| Registration | Closed (`AUTOREG=0`); make accounts with `add-account` |
| Admin account | `cameren`, admin level 15 (`pass homelab/swgemu/admin-password`) |
| Storage | `local-path`: `mariadb-data` 5Gi, `core3-data` 20Gi, `core3-tre` 5Gi (all landed on k3s-agent-01) |
| Resources | ~3–4 GiB RSS with all 12 ground + 10 space zones; limits 2 CPU / 12Gi; boot ≈ 1 min |
| TRE files (source) | `~/Games/swg-original/tre` on the workstation (51 needed + 2 hotfix, 2.8 GB); rebuild with `~/github/swgemu/tools/fetch-tre.sh` |

### Important Design Decisions and Gotchas

- **CPU target.** The agents are Sandy Bridge (E5-2670: AVX, no AVX2/BMI/FMA). Upstream builds with `-march=native`,
  which on the workstation would emit instructions that crash on the agents. The Dockerfile sets `ENABLE_NATIVE=OFF`,
  `-march=sandybridge`, and fails the build if objdump finds AVX2/BMI/FMA opcodes.
- **Checkout path must not contain `src/`.** `src/CMakeLists.txt` derives autogen paths by replacing every `src/` in
  the absolute path; a checkout at `/src` breaks every IDL object ("no such file"). The image builds in `/core3`.
- **Legacy docker builder here** (no buildx), so no `COPY --chmod`.
- **Console on a FIFO.** Core3 reads commands from stdin; at EOF its reader would spin. The entrypoint feeds stdin from
  `/run/core3/console` (held open) and the `console` helper writes to it. Output goes to the pod log.
- **Clean stops.** No SIGTERM handler in Core3, so the entrypoint traps it and sends `shutdown 0` (full save, then exit).
  Measured: ~80 s with an empty world; `terminationGracePeriodSeconds: 600`. Never `kubectl delete pod --force`.
  No liveness probe on purpose (a slow load or save must not be killed); readiness = status port 44455.
- **TRE files.** The server reads game data from the original client files. 21 came from the 2003 retail discs
  (`unshield` on `data1.cab`); the JTL `data_sku1_*` and all `patch_*` files came from the SWGEmu Launchpad mirror
  `http://www.launchpad2.net/SWGEmu/`, checked against its `required2.txt` MD5s (what the official launcher does for
  disc owners). The entrypoint waits, logging what's missing, until every `TreFiles` entry exists in `/tre`.
- **CPU limit (2) and `MaxNavMeshJobs = 2`.** Core3 builds navmeshes on first boot (and when regions change) with 6
  parallel jobs by default. Uncapped, that pinned k3s-agent-01 at 100% (load 60 on 4 vCPUs); the MetalLB speaker there
  failed its probes and crash-looped, which dropped every LB IP it announces (10.0.20.53, .80, .83, .84). Navmeshes
  persist in `/data/navmeshes`, so a restart resumes the build.
- **Accounts.** `add-account` inserts unsalted SHA1; Core3 accepts that once and rewrites it as
  SHA256(`DBSecret` + password + salt) on first login.
- **Our scripts never edit upstream files.** Core3 includes `scripts/custom_scripts/{screenplays/screenplays,mobile,
  object,loot}/serverobjects.lua` last; ours live there. Screenplays reload live (`console reloadscreenplays`, then
  `console runLuaFunction LivingCities:restart` to rebuild the crowds); mobile templates and outfits only load at boot.
  The directory is owned by `swgemu`, so a quick test can `kubectl cp` a script into the pod; a restart goes back to the
  image's copy.
- **NPCs that talk (talk bridge).** A second container, `talk`, in the core3 pod, from the same image (keep both
  `image:` tags equal). It runs `images/swgemu-core3/talk/talk_bridge.py` (Python standard library). Core3's Lua can't
  call out without stalling a server thread, so it writes request files to the shared `emptyDir` `/run/talk/req/`;
  the bridge asks LiteLLM (`http://litellm.litellm.svc:4000/v1`, model `TALK_MODEL`, default `vm/qwen3.8:27b`, thinking
  off) and writes `/run/talk/rep/<id>.txt`. City fact sheets: `talk/facts.json`, built by
  `~/github/swgemu/tools/living_cities/build_facts.py`. Logs: `kubectl -n swgemu logs deploy/core3 -c talk` (one line
  per reply, with its latency). The key is `swgemu-secrets` `litellm-key` (`pass homelab/swgemu/litellm-key`): a LiteLLM
  virtual key limited to the model. Without it the bridge gets 401s and the NPCs give canned lines. Test from the
  workstation: `LITELLM_URL=https://llm.home.lab/v1 LITELLM_KEY=... python3 talk/talk_bridge.py --ask mos_eisley
  "where's the bank?"`.
- **Local test server.** `images/swgemu-core3/dev/docker-compose.yml` runs our image on the workstation with only
  Tatooine, Corellia and Naboo and `custom_scripts` bind-mounted. Build it once with `--build-arg
  CORE3_CXX_EXTRA=-DDEBUG_AI` (tag `dev-debug-ai`): Core3 reads `AiAgentLoadTesting` (AI awake with no player near)
  only in `DEBUG_AI` builds, and a Release build leaves every NPC standing until a player comes. Production leaves the
  arg empty. Copy the three planets' navmeshes from the cluster into its data dir first, or the first boot builds
  them.
- **Our C++ (bot players).** `images/swgemu-core3/patches/` holds:
  - `bots/`: our own files, copied into `MMOCoreORB/src/server/zone/managers/bot/`;
  - six hook patches (`NNNN-*.patch`), applied with `git apply`.

  The Dockerfile applies both after the checkout, and a patch that doesn't apply fails the build. After a
  `CORE3_REF` bump, fix the patches first. `patches/README.md` lists the hooks and how to write one.
- **Dev builds of the C++.** `bash images/swgemu-core3/dev/build-core3.sh`:
  - builds incrementally in `~/.cache/swgemu-scratch/core3-dev`, with production's toolchain plus `-DDEBUG_AI`;
  - tags `dev-bots` for the local test server (`CORE3_IMAGE=ghcr.io/azskylab/swgemu-core3:dev-bots docker compose
    up -d`);
  - the first build takes about 20 minutes, the rest only what changed.
- **Bot players.** Six characters the server plays itself, with no client: a master doctor and a master dancer in Mos
  Eisley, Coronet and Theed.
  - **Roster:** `custom_scripts/bots/roster.lua`.
  - **Accounts and characters:** `bot_<firstname>` accounts with unusable passwords, made on first boot.
  - **When they're online:** they log in a minute after the first human and out 10 minutes after the last.
  - **Status port:** never counts them, so `scripts/swgemu-deploy.sh`'s players check still means humans.
  - **A stuck bot:** `BotJobs:logout:<first>` then `login:<first>`. A restart also puts every bot back at its
    station.
  - Spec: `~/github/swgemu/specs/2026-10-23-bot-players/`.

### Common Tasks

```bash
kubectl -n swgemu logs deploy/core3 -f
kubectl -n swgemu exec deploy/core3 -- console help             # also: save, chars, broadcast <msg>, shutdown <min>
kubectl -n swgemu exec -i deploy/core3 -- add-account <name> [admin_level] <<< '<password>'
# Status XML (players online, uptime)
timeout 5 bash -c 'exec 3<>/dev/tcp/10.0.20.84/44455; cat <&3'
# Copy TRE files onto a fresh core3-tre volume (pod waits for them), then verify
tar cf - -C ~/Games/swg-original/tre . | kubectl -n swgemu exec -i deploy/core3 -- tar xf - -C /tre
# Update Core3 (bump CORE3_REF in images/swgemu-core3/Dockerfile) or our scripts: commit on main, then
bash scripts/swgemu-deploy.sh     # build + push the image, set the tag in core3.yml, commit, push, wait, show start lines
bash scripts/swgemu-talk-key.sh   # once: LiteLLM key for the talk bridge into pass and swgemu-secrets
# Living Cities (crowd report, rebuild the crowds, every NPC's state)
kubectl -n swgemu exec deploy/core3 -- console runLuaFunction LivingCities:report
kubectl -n swgemu exec deploy/core3 -- console runLuaFunction LivingCities:restart
kubectl -n swgemu exec deploy/core3 -- console runLuaFunction LivingCities:dump
# Bot players (every bot and its job state; force one in or out; a bot's buffs, wounds and HAM)
kubectl -n swgemu exec deploy/core3 -c core3 -- console runLuaFunction BotJobs:list
kubectl -n swgemu exec deploy/core3 -c core3 -- console runLuaFunction BotJobs:login:Hesk
kubectl -n swgemu exec deploy/core3 -c core3 -- console runLuaFunction BotJobs:devBuffs:Hesk
```

### Recreating K8s Secrets

```bash
kubectl create namespace swgemu
kubectl -n swgemu create secret generic swgemu-secrets \
  --from-literal=db-password="$(pass homelab/swgemu/db-password)" \
  --from-literal=db-root-password="$(pass homelab/swgemu/db-root-password)" \
  --from-literal=db-secret="$(pass homelab/swgemu/db-secret)" \
  --from-literal=litellm-key="$(pass homelab/swgemu/litellm-key)"
kubectl -n corpocache get secret ghcr-pull-secret -o json \
  | jq '{apiVersion,kind,type,data,metadata:{name:"ghcr-pull-secret",namespace:"swgemu"}}' | kubectl apply -f -
kubectl -n swgemu patch serviceaccount default -p '{"imagePullSecrets":[{"name":"ghcr-pull-secret"}]}'
```

## GitHub Actions CI/CD (ARC)

### Architecture

GitHub (`github.com/azskylab`) is the primary git remote. CI runs on self-hosted runners via Actions Runner Controller (ARC) on k3s.

```
Developer pushes to GitHub (git@github.com:azskylab/<repo>)
  → GitHub Actions triggers CI workflow
    → Builds Docker image
    → Pushes to GHCR (ghcr.io/azskylab/<image>)
  → ArgoCD watches GitHub repo for k8s manifest changes → deploys
```

**Components:**
- **ARC Controller** — Rendered manifests in `kubernetes/manifests/arc-controller/`, manages runner lifecycle
- **ARC Runner Scale Set** — Rendered manifests in `kubernetes/manifests/arc-runners/`, org-level runners for `azskylab` org
- **GHCR** — GitHub Container Registry at `ghcr.io`, free for public repos, auth via `GITHUB_TOKEN`

### Runner Configuration

ARC runners use Docker-in-Docker (DinD) mode for Docker builds:

- **Runner scale set name**: `homelab-runners` (use in `runs-on:`)
- **GitHub config URL**: `https://github.com/azskylab` (org-level)
- **Authentication**: GitHub App (`arc-github-app` secret in `arc-runners` namespace)
- **Scaling**: 0-3 runners (scales to zero when idle)
- **DNS**: `10.0.20.53` (CoreDNS)

Config files:
- `kubernetes/apps/arc/arc-controller.yml` — ArgoCD Application for ARC controller
- `kubernetes/apps/arc/arc-runner-set.yml` — ArgoCD Application for runner scale set
- `kubernetes/manifests/arc-controller/controller.yml` — ARC controller rendered manifests
- `kubernetes/manifests/arc-runners/runner-set.yml` — Runner scale set rendered manifests
- `kubernetes/manifests/arc-runners/ca-configmap.yml` — Home Lab root CA cert

### CI Workflow Pattern

Each app repo has `.github/workflows/docker.yml`:

```yaml
name: Build and Push
on:
  push:
    branches: [main]
    paths:
      - "src/**"
      - "Dockerfile"
      - ".github/workflows/docker.yml"

jobs:
  build:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write
    steps:
      - uses: actions/checkout@v4
      - uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}
      - uses: docker/build-push-action@v6
        with:
          context: .
          push: true
          tags: |
            ghcr.io/${{ github.repository_owner }}/<image>:latest
            ghcr.io/${{ github.repository_owner }}/<image>:sha-${{ github.sha }}
```

### Adding CI to a New Repo

1. **Create workflow** at `.github/workflows/docker.yml` following the pattern above
2. **Ensure GitHub App** has access to the new repo (Settings → Developer settings → GitHub Apps → azskylab-arc-runner → Install App → Repository access)
3. **Push to GitHub** — CI triggers automatically, images pushed to `ghcr.io/azskylab/<image>`

### Recreating ARC K8s Secret

```bash
kubectl create secret generic arc-github-app -n arc-runners \
  --from-literal=github_app_id="$(pass homelab/arc/github-app-id)" \
  --from-literal=github_app_installation_id="$(pass homelab/arc/github-app-installation-id)" \
  --from-literal=github_app_private_key="$(pass homelab/arc/github-app-private-key)"
```

## WireGuard VPN (Remote Access)

WireGuard provides remote access to all homelab VLANs via `wg-easy` (WireGuard + web UI) running on k3s.

### Architecture

```
Internet → USG port forward (UDP 443) → k3s-agent-01:443 (hostNetwork) → wg-easy pod
VPN client → wg0 tunnel → pod masquerade → k3s node → USG → all VLANs
Web UI: https://vpn.home.lab (Traefik ingress, internal only)
```

### Key Details

| Setting | Value |
|---------|-------|
| External endpoint | `malliefivpn.duckdns.org:443` (UDP) |
| VPN subnet | `10.8.0.0/24` |
| Allowed IPs | `10.0.0.0/16` (all homelab traffic) |
| Client DNS | `10.0.20.53` (CoreDNS) |
| Pod runs on | k3s-agent-01 (`10.0.20.21`) via hostNetwork |
| Web UI | `https://vpn.home.lab` |
| DDNS | DuckDNS CronJob (every 5 min) |

### Important Design Decisions

- **`hostNetwork: true`** — Required so masqueraded VPN traffic uses the node's real IP (`10.0.20.21`). Without this, masquerade uses the pod IP (`10.42.x.x`) which isn't routable outside the cluster.
- **UDP port 443** — Standard WireGuard port 51820 is blocked by many mobile carriers and corporate firewalls. UDP 443 (used by QUIC/HTTP3) is never blocked.
- **Privileged init container** — k3s forbids unsafe sysctls in pod spec. An init container with `privileged: true` runs `sysctl -w net.ipv4.ip_forward=1` instead.
- **Secrets NOT in git** — `wireguard-secrets` and `duckdns-secrets` are created manually via `kubectl`, not managed by ArgoCD (to avoid self-heal overwriting with placeholder values).

### USG Port Forward

- Name: `WireGuard VPN`
- From: Anywhere
- Port: 443 (UDP)
- Forward IP: `10.0.20.21`
- Forward Port: 443
- Protocol: UDP

### Managing Clients

1. Access `https://vpn.home.lab` and log in
2. Click **+ New** to create a client
3. Scan QR code (mobile) or download `.conf` file (desktop)
4. Install WireGuard app and import the config

### Recreating K8s Secrets

```bash
kubectl create secret generic wireguard-secrets -n wireguard \
  --from-literal=PASSWORD_HASH="$(pass homelab/wireguard/password-hash)" \
  --from-literal=WG_HOST="$(pass homelab/wireguard/wg-host)"

kubectl create secret generic duckdns-secrets -n wireguard \
  --from-literal=token="$(pass homelab/wireguard/duckdns-token)" \
  --from-literal=subdomain="$(pass homelab/wireguard/duckdns-subdomain)"
```

### Manifest Files

- `kubernetes/manifests/wireguard/deployment.yml` — wg-easy pod (hostNetwork, init container, capabilities)
- `kubernetes/manifests/wireguard/service.yml` — LoadBalancer UDP 443 at 10.0.20.82
- `kubernetes/manifests/wireguard/service-ui.yml` — ClusterIP for web UI (port 51821)
- `kubernetes/manifests/wireguard/ingress.yml` — Traefik ingress at `vpn.home.lab`
- `kubernetes/manifests/wireguard/pvc.yml` — 100Mi for WireGuard config persistence
- `kubernetes/manifests/wireguard/cronjob.yml` — DuckDNS IP updater (every 5 min)
- `kubernetes/apps/wireguard/wireguard.yml` — ArgoCD Application

## Documentation

- [docs/network.md](docs/network.md) — VLANs, firewall rules, IP assignments
- [docs/unifi-setup.md](docs/unifi-setup.md) — USG Pro + AP configuration
- [docs/ad-migration.md](docs/ad-migration.md) — Domain migration runbook
