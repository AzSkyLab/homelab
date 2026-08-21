# Homelab Infrastructure

IaC-driven homelab running Proxmox VE across 3 nodes, provisioning Kubernetes (k3s), PostgreSQL, and on-demand sandbox VMs with Terraform, Packer, and Ansible. Kubernetes workloads are deployed via ArgoCD GitOps with Forgejo CI/CD.

## Architecture

```
                            ┌──────────────────────────────────────────┐
                            │              Internet                     │
                            └──────────────────┬───────────────────────┘
                                               │
                            ┌──────────────────┴───────────────────────┐
                            │          USG 4 Pro (10.0.10.1)           │
                            │            Router / Firewall              │
                            └──────────────────┬───────────────────────┘
                                               │
                            ┌──────────────────┴───────────────────────┐
                            │     US-24-250W PoE Switch (10.0.10.2)    │
                            │          VLAN Trunk to All Nodes          │
                            └───┬──────────────┬───────────────┬───────┘
                                │              │               │
                ┌───────────────┴──┐  ┌────────┴───────┐  ┌───┴───────────────┐
                │   pve-identity   │  │    pve-r720    │  │    pve-desktop    │
                │  E3-1230 / 32GB  │  │ 2xE5-2670     │  │   5900x / 32GB    │
                │                  │  │ 128GB RAM      │  │   RTX 3090        │
                │  dc-01 (AD/DNS)  │  │                │  │                   │
                │  dc-02 (AD/DNS)  │  │ k3s-agent-01   │  │  k3s-server-01    │
                │  dc-03 (AD/DNS)  │  │ k3s-agent-02   │  │  ollama-01 (GPU)  │
                │  NFS media share │  │ k3s-agent-03   │  │                   │
                │                  │  │ postgres-01    │  │                   │
                │                  │  │ sandbox VMs    │  │                   │
                └──────────────────┘  └────────────────┘  └───────────────────┘

                                    ┌──────────────────────┐
                                    │     Workstation       │
                                    │   10.0.10.40          │
                                    │   RTX 5090 (32GB)     │
                                    │   Ollama inference    │
                                    └──────────────────────┘
```

## Network

| VLAN | Name | Subnet | Purpose |
|------|------|--------|---------|
| — | Management | 10.0.10.0/24 | Proxmox hosts, admin access, workstation |
| 20 | Kubernetes | 10.0.20.0/24 | k3s cluster, Ollama VM |
| 30 | Database | 10.0.30.0/24 | PostgreSQL |
| 40 | Sandbox | 10.0.40.0/24 | Test VMs |
| 50 | Work | 10.0.50.0/24 | Work WiFi |
| 60 | Personal | 10.0.60.0/24 | Personal WiFi |
| 70 | IoT | 10.0.70.0/24 | Smart devices |
| 80 | Guest | 10.0.80.0/24 | Guest WiFi |

See [docs/network.md](docs/network.md) for full VLAN map, firewall rules, and IP assignments.

## Kubernetes Services

ArgoCD manages all workloads via an app-of-apps pattern. Infrastructure services are deployed from Helm charts; applications use raw manifests or external repos.

### Infrastructure

| Service | Access | Description |
|---------|--------|-------------|
| ArgoCD | [argocd.home.lab](https://argocd.home.lab) | GitOps deployment engine |
| Traefik | 10.0.20.80 | Ingress controller + TLS termination |
| MetalLB | 10.0.20.50–99 | Bare-metal load balancer (L2 mode) |
| CoreDNS | 10.0.20.53 | Internal DNS for `home.lab` zone |
| cert-manager | — | Auto-provisioned TLS via internal CA |
| Prometheus + Grafana | [grafana.home.lab](https://grafana.home.lab) | Monitoring, 6 dashboards |

### Applications

| App | Access | Description |
|-----|--------|-------------|
| Glance | [glance.home.lab](https://glance.home.lab) | Startpage with infra widgets |
| Linkwarden | [linkwarden.home.lab](https://linkwarden.home.lab) | Bookmark manager + Meilisearch |
| Jellyfin | [jellyfin.home.lab](https://jellyfin.home.lab) | Media server (NFS-backed) |
| Open WebUI | [chat.home.lab](https://chat.home.lab) | Chat UI for local LLMs |
| LiteLLM | [llm.home.lab](https://llm.home.lab) | Multi-GPU OpenAI-compatible API proxy |
| n8n | [n8n.home.lab](https://n8n.home.lab) | Workflow automation |
| Forgejo | [git.home.lab](https://git.home.lab) | Git forge + CI/CD (Actions) |
| Harbor | [registry.home.lab](https://registry.home.lab) | Container registry + Trivy scanning |
| pgAdmin | [pgadmin.home.lab](https://pgadmin.home.lab) | PostgreSQL admin UI |
| Speedtest Tracker | [speedtest.home.lab](https://speedtest.home.lab) | Automated speed tests |
| Workout Tracker | [workout.home.lab](https://workout.home.lab) | Exercise tracking app |
| CorpoCache | [cache.home.lab](https://cache.home.lab) | Corporate cache tool |
| Redis | internal | Shared key-value store |
| WireGuard | [vpn.home.lab](https://vpn.home.lab) | Remote access VPN (wg-easy) |

## AI / LLM Infrastructure

Two Ollama backends are aggregated behind LiteLLM for unified model access:

```
                        ┌──────────────────┐
                        │   Open WebUI      │
                        │  chat.home.lab    │
                        └────────┬─────────┘
                                 │
                        ┌────────┴─────────┐
                        │     LiteLLM      │
                        │  llm.home.lab    │
                        │  (API gateway)   │
                        └──┬───────────┬───┘
                           │           │
              ┌────────────┴──┐  ┌─────┴────────────┐
              │  ollama-01    │  │   Workstation     │
              │  RTX 3090     │  │   RTX 5090        │
              │  24GB VRAM    │  │   32GB VRAM       │
              │  10.0.20.30   │  │   10.0.10.40      │
              │  vm/<model>   │  │   ws/<model>      │
              └───────────────┘  └───────────────────┘
```

- **`vm/<model>`** — routes to RTX 3090 (Proxmox VM)
- **`ws/<model>`** — routes to RTX 5090 (Workstation)
- **`ollama/<model>`** — load-balanced across both

**Current flagship models (2026-08):**

| Model | Backend | Size | Notes |
|-------|---------|------|-------|
| `ws/qwen3.6:35b-a3b` | RTX 5090 | 23GB | MoE (3B active), thinking modes, agentic coding |
| `vm/qwen3.6:27b` | RTX 3090 | 17GB | Dense, vision-capable |
| `ws/` + `vm/qwen3-coder:30b` | both | 19GB | Previous coder, load-balanced as `ollama/qwen3-coder:30b` |
| `ws/` + `vm/deepseek-r1:32b` | both | 20GB | Reasoning |

Both backends run with `OLLAMA_CONTEXT_LENGTH` raised from the 4096 default
(32k workstation / 16k VM, `OLLAMA_NUM_PARALLEL=1`) via `zz-context.conf` systemd
drop-ins — the stock default silently truncates agentic prompts.

### Local coding agent (oh-my-pi)

[omp](https://github.com/can1357/oh-my-pi) runs on the workstation against the LiteLLM
gateway — a terminal coding agent (LSP, subagents, browser tools) powered entirely by
local GPUs. Default model: `qwen3.6:35b-a3b` on the 5090.

```bash
omp "refactor this function"       # interactive
omp -p "explain this error"        # print mode
omp --model qwen3-coder "..."      # fuzzy model switch
```

Config: `~/.omp/agent/models.yml` (provider → `http://llm.home.lab/v1`, `api: openai-chat`);
setup notes and gotchas in [CLAUDE.md](CLAUDE.md#oh-my-pi-omp--local-coding-agent-on-the-workstation).

## Remote Access (WireGuard VPN)

WireGuard VPN via [wg-easy](https://github.com/wg-easy/wg-easy) provides remote access to all homelab VLANs.

```
Phone/Laptop → malliefivpn.duckdns.org:443 (UDP)
  → USG port forward → k3s-agent-01 (hostNetwork)
  → wg0 tunnel → masquerade → all VLANs (10.0.0.0/16)
```

- **VPN subnet:** 10.8.0.0/24
- **Client DNS:** 10.0.20.53 (CoreDNS — resolves `*.home.lab`)
- **DDNS:** DuckDNS CronJob updates public IP every 5 min
- **Web UI:** [vpn.home.lab](https://vpn.home.lab) (manage clients, internal only)
- **Port:** UDP 443 (avoids carrier/corporate port blocking)

## CI/CD Pipeline

```
Developer pushes to Forgejo (git@git.home.lab)
  → Forgejo Actions triggers CI workflow
    → Runner builds Docker image (DinD sidecar)
    → Pushes to Harbor (registry.home.lab)
  → Forgejo push-mirrors to GitHub (backup)
  → ArgoCD watches repo for manifest changes → deploys
```

## Toolchain

| Tool | Purpose |
|------|---------|
| Proxmox VE 8.x | Hypervisor (3-node cluster) |
| Terraform + bpg/proxmox | VM provisioning |
| Packer | VM template builds (Ubuntu 24.04) |
| Cloud-init | First-boot configuration |
| Ansible | Post-provisioning (k3s, PostgreSQL, Ollama) |
| k3s | Lightweight Kubernetes |
| ArgoCD | GitOps continuous deployment |
| Traefik | Ingress + TLS via internal CA |
| Forgejo | Git forge + Actions CI |
| Harbor | Container registry |

## Quick Start

### 1. Build VM Template

```bash
cd packer/ubuntu-2404/
packer init .
packer build -var-file=variables.pkr.hcl .
```

### 2. Provision Infrastructure

```bash
# k3s cluster
cd terraform/stacks/k3s-cluster/
terraform init && terraform apply

# PostgreSQL
cd ../database/
terraform init && terraform apply

# Ollama inference server
cd ../ollama/
terraform init && terraform apply

# Sandbox (set vm_count > 0 in terraform.tfvars)
cd ../sandbox/
terraform init && terraform apply
```

### 3. Configure Services

```bash
cd ansible/
ansible-playbook playbooks/site.yml
```

### 4. Access Cluster

```bash
export KUBECONFIG=ansible/kubeconfig
kubectl get nodes
```

### 5. Bootstrap GitOps

ArgoCD is deployed via Ansible and watches `kubernetes/apps/` for Application CRs. Push changes to git and ArgoCD syncs automatically.

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
│   ├── projects/                 # ArgoCD AppProjects
│   ├── apps/                     # ArgoCD Application CRs (auto-discovered)
│   └── manifests/                # Raw k8s manifests for in-repo apps
└── docs/                         # Network design, Unifi setup, AD migration
```

## Documentation

- [Network Architecture](docs/network.md) — VLANs, firewall rules, IP assignments
- [Unifi Setup](docs/unifi-setup.md) — USG Pro + AP configuration
- [AD Migration](docs/ad-migration.md) — Domain migration runbook
