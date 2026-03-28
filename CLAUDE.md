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
│   │   └── wireguard/           # WireGuard VPN (wg-easy)
│   └── manifests/
│       ├── ingress/              # Traefik Ingress resources for infra services
│       ├── arc/                  # ARC runner CA certificate
│       ├── litellm/             # LiteLLM proxy (ConfigMap, Deployment, Service, Ingress)
│       └── wireguard/           # wg-easy + DuckDNS CronJob
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
| Traefik LB | 10.0.20.80 | `*.home.lab` ingress |
| CoreDNS LB | 10.0.20.53 | Internal DNS |
| PostgreSQL | 10.0.30.10 | `postgres.home.lab` |
| Ollama (VM) | 10.0.20.30 | `ollama.home.lab` |
| Ollama (Workstation) | 10.0.10.40 | `desktop.home.lab` |
| LiteLLM | 10.0.20.80 | `llm.home.lab` (via Traefik) |
| WireGuard | 10.0.20.21 (hostNetwork) | `vpn.home.lab` (web UI) |

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
| CoreDNS | coredns | Helm | LB at 10.0.20.53 |
| cert-manager | cert-manager | Helm | Internal CA (`home-lab-ca`) |
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

For proper GitOps, apps should have a GitHub Actions CI workflow that builds images on push and pushes to Harbor. See the GitHub Actions CI/CD section below.

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

Models are listed explicitly per backend in `kubernetes/manifests/litellm/configmap.yml`. When pulling a new model on either Ollama instance, add a corresponding entry to the ConfigMap.

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

## GitHub Actions CI/CD (ARC)

### Architecture

GitHub (`github.com/azskylab`) is the primary git remote. CI runs on self-hosted runners via Actions Runner Controller (ARC) on k3s.

```
Developer pushes to GitHub (git@github.com:azskylab/<repo>)
  → GitHub Actions triggers CI workflow
    → ARC scales up runner pod on k3s (DinD mode)
    → Runner builds Docker image
    ��� Pushes to Harbor (registry.home.lab)
  → ArgoCD watches GitHub repo for k8s manifest changes → deploys
```

**Components:**
- **ARC Controller** — Helm chart (`gha-runner-scale-set-controller`) in `arc-systems` namespace, manages runner lifecycle
- **ARC Runner Scale Set** — Helm chart (`gha-runner-scale-set`) in `arc-runners` namespace, org-level runners for `azskylab` org
- **Harbor** — Container registry at `registry.home.lab`, robot account `robot$forgejo-ci` for CI push access

### Runner Configuration

ARC runners use Docker-in-Docker (DinD) mode for Docker builds:

- **Runner scale set name**: `homelab-runners` (use in `runs-on:`)
- **GitHub config URL**: `https://github.com/azskylab` (org-level)
- **Authentication**: GitHub App (`arc-github-app` secret in `arc-runners` namespace)
- **Scaling**: 0-3 runners (scales to zero when idle)
- **DNS**: `10.0.20.53` (CoreDNS, resolves `registry.home.lab`)
- **CA trust**: Home Lab root CA injected via init container for Harbor HTTPS

Config files:
- `kubernetes/apps/arc/arc-controller.yml` — ArgoCD Application for ARC controller
- `kubernetes/apps/arc/arc-runner-set.yml` — ArgoCD Application for runner scale set
- `kubernetes/apps/arc/arc-manifests.yml` — ArgoCD Application for supporting manifests
- `kubernetes/manifests/arc/ca-configmap.yml` — Home Lab root CA cert for runners

### CI Workflow Pattern

Each app repo has `.github/workflows/ci.yml`:

```yaml
name: Build and Push
on:
  push:
    branches: [main]
    paths-ignore:
      - "k8s/**"
      - "*.md"

jobs:
  build:
    runs-on: homelab-runners
    steps:
      - uses: actions/checkout@v4
      - name: Login to Harbor
        env:
          HARBOR_USER: ${{ secrets.HARBOR_USERNAME }}
          HARBOR_PASS: ${{ secrets.HARBOR_PASSWORD }}
        run: echo "$HARBOR_PASS" | docker login registry.home.lab -u "$HARBOR_USER" --password-stdin
      - name: Build and push
        run: |
          docker build -t registry.home.lab/csgit34/<image>:${{ github.sha }} -t registry.home.lab/csgit34/<image>:latest .
          docker push registry.home.lab/csgit34/<image>:${{ github.sha }}
          docker push registry.home.lab/csgit34/<image>:latest
```

**Important:** Harbor credentials MUST use `env:` vars (not inline `${{ secrets.* }}`). The `$` in `robot$forgejo-ci` gets interpreted by bash if placed directly in double-quoted strings.

### Adding CI to a New Repo

1. **Create Harbor project** (if needed) for the image namespace
2. **Add GitHub repo secrets** (Settings → Secrets and variables → Actions):
   - `HARBOR_USERNAME`: `robot$forgejo-ci`
   - `HARBOR_PASSWORD`: value from `pass homelab/forgejo/harbor-robot-secret`
3. **Create workflow** at `.github/workflows/ci.yml` following the pattern above
4. **Ensure GitHub App** has access to the new repo (Settings → Developer settings → GitHub Apps → homelab-arc-runner → Install App → Repository access)
5. **Push to GitHub** — CI triggers automatically

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
