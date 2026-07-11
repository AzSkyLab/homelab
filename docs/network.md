# Network Architecture

## Unifi Hardware

| Device | Model | IP | VLAN | Notes |
|--------|-------|----|------|-------|
| Gateway | USG 4 Pro | 10.0.10.1 | Management | Router, firewall, inter-VLAN routing |
| Switch | US-24-250W (24-port PoE) | 10.0.10.2 | Management | Trunk + access ports, powers APs |
| Controller | Cloud Key Plus | 10.0.10.3 | Management | Unifi Network controller |
| AP | UAP-AC-Pro | 10.0.10.5 | Management | WiFi — 802.11ac Wave 1 |
| AP | U7 Pro | 10.0.10.6 | Management | WiFi — WiFi 7 |

## Physical Topology

```
Internet
  │
  ▼
USG 4 Pro (10.0.10.1)
  │
  ├── LAN1 ──► US-24-250W (10.0.10.2)
  │               │
  │               ├── Port 1  (trunk)           ──► USG uplink
  │               ├── Port 2  (trunk)           ──► pve-identity — LAN 1
  │               ├── Port 3  (trunk)           ──► pve-identity — LAN 2
  │               ├── Port 4  (access, Mgmt)    ──► pve-identity — IPMI
  │               ├── Port 5  (trunk)           ──► pve-r720 — LAN 1
  │               ├── Port 6  (trunk)           ──► pve-r720 — LAN 2
  │               ├── Port 7  (trunk)           ──► pve-r720 — LAN 3
  │               ├── Port 8  (trunk)           ──► pve-r720 — LAN 4
  │               ├── Port 9  (access, Mgmt)    ──► pve-r720 — iDRAC
  │               ├── Port 10 (trunk)           ──► pve-desktop — LAN
  │               ├── Port 11 (access, Mgmt)    ──► neuromancer (workstation)
  │               ├── Port 12 (access, Mgmt)    ──► Cloud Key Plus (PoE)
  │               ├── Port 13 (PoE, trunk)      ──► UAP-AC-Pro (10.0.10.5)
  │               ├── Port 14 (PoE, trunk)      ──► U7 Pro (10.0.10.6)
  │               ├── Port 15 (access, Personal)──► Room connection #1
  │               ├── Port 16 (access, Personal)──► Room connection #2
  │               ├── Port 17 (access, Personal)──► Room connection #3
  │               ├── Port 18 (access, Personal)──► TV
  │               ├── Port 19 (access, Personal)──► PlayStation 5
  │               └── Ports 20-24               ──► Available
  │
  └── LAN2 ──► (unused or secondary)

Unifi APs (PoE from switch)
  ├── SSID "MallieFi-Mgmt"  → Management (native)
  ├── SSID "MallieFi-Work"  → VLAN 50
  ├── SSID "MallieFi"       → VLAN 60
  ├── SSID "MallieFi-IoT"   → VLAN 70
  └── SSID "MallieFi-Guest" → VLAN 80
```

## VLAN Map

| VLAN ID | Name | Subnet | Gateway | Type | Purpose |
|---------|------|--------|---------|------|---------|
| — | Management (default) | 10.0.10.0/24 | 10.0.10.1 | Both | Proxmox, workstation, network gear — SSID: "MallieFi-Mgmt" |
| 20 | Kubernetes | 10.0.20.0/24 | 10.0.20.1 | Virtual | k3s nodes (Proxmox bridge only) |
| 30 | Database | 10.0.30.0/24 | 10.0.30.1 | Virtual | PostgreSQL (Proxmox bridge only) |
| 40 | Sandbox | 10.0.40.0/24 | 10.0.40.1 | Virtual | On-demand test VMs (Proxmox bridge only) |
| 50 | Work | 10.0.50.0/24 | 10.0.50.1 | WiFi | Work laptop — SSID: "MallieFi-Work" |
| 60 | Personal | 10.0.60.0/24 | 10.0.60.1 | Both | Personal devices wired + wireless — SSID: "MallieFi" |
| 70 | IoT | 10.0.70.0/24 | 10.0.70.1 | Both | Smart devices wired + wireless — SSID: "MallieFi-IoT" |
| 80 | Guest | 10.0.80.0/24 | 10.0.80.1 | WiFi | Guest WiFi — SSID: "MallieFi-Guest" |

Management is the renamed default network (no VLAN tag — native/untagged).

## IP Assignments (Management — 10.0.10.0/24)

| IP | Device | Role |
|----|--------|------|
| 10.0.10.1 | USG 4 Pro | Gateway / router |
| 10.0.10.2 | US-24-250W | Switch management |
| 10.0.10.3 | Cloud Key Plus | Unifi Controller |
| 10.0.10.5 | UAP-AC-Pro | AP |
| 10.0.10.6 | U7 Pro | AP |
| 10.0.10.10 | dc-01 | AD DC / DNS / Entra Connect (azureskylab.net) |
| 10.0.10.11 | pve-identity | Proxmox node (Intel E3-1230 v3) |
| 10.0.10.12 | pve-r720 | Proxmox node (R720xd) |
| 10.0.10.13 | pve-desktop | Proxmox node (5900x) |
| 10.0.10.14 | pve-identity IPMI | Out-of-band management |
| 10.0.10.15 | pve-r720 iDRAC | Out-of-band management |
| 10.0.10.20 | dc-02 | AD DC / DNS (mis.azureskylab.net) |
| 10.0.10.30 | dc-03 | AD DC / DNS (mas.azureskylab.net) |
| 10.0.10.50 | neuromancer | Admin workstation |

## IP Assignments (VLAN 20 — Kubernetes)

| IP | VM | Role |
|----|----|------|
| 10.0.20.10 | k3s-server-01 | Control plane |
| 10.0.20.21 | k3s-agent-01 | Worker |
| 10.0.20.22 | k3s-agent-02 | Worker |
| 10.0.20.23 | k3s-agent-03 | Worker |
| 10.0.20.53 | CoreDNS (k8s svc) | Local DNS for home.lab |

## IP Assignments (VLAN 30 — Database)

| IP | VM | Role |
|----|----|------|
| 10.0.30.10 | postgres-01 | Primary PostgreSQL |

## IP Assignments (VLAN 40 — Sandbox)

DHCP range: 10.0.40.100–10.0.40.200 (on-demand VMs)

## Firewall Rules (USG 4 Pro)

| # | Source | Destination | Action | Notes |
|---|--------|-------------|--------|-------|
| 1a | All VLANs | 10.0.20.53 (UDP 53) | Allow | Local DNS (CoreDNS on k3s) |
| 1b | All VLANs | 10.0.20.53 (TCP 53) | Allow | Local DNS (TCP for large responses) |
| 2 | Management | All VLANs | Allow | Admin access everywhere |
| 3 | Kubernetes (20) | Database (30) | Allow | Apps need DB access |
| 3a | Kubernetes (20) | 10.0.10.11-13 (TCP 8006,9100) | Allow | PVE API + node_exporter |
| 3b | Kubernetes (20) | 10.0.10.3 (TCP 443) | Allow | Unifi controller for UnPoller |
| 4 | Personal (60) | IoT (70) | Allow | Control smart devices |
| 5 | Personal (60) | 10.0.20.80 (TCP 80,443) | Allow | Access k8s web apps via Traefik |
| 6 | Database (30) | RFC1918 | Drop | Isolated — accepts inbound only |
| 7 | Sandbox (40) | Management | Drop | No lateral movement |
| 8 | Work (50) | RFC1918 | Drop | Complete isolation — internet only |
| 9 | IoT (70) | RFC1918 | Drop | Locked down — internet only |
| 10 | Guest (80) | RFC1918 | Drop | Complete isolation — internet only |

**Rule order matters.** Allow rules before deny rules. Work (50) is blocked from all RFC1918, so it can't reach any local resources. See [docs/unifi-setup.md](unifi-setup.md) for step-by-step firewall rule creation.

## Proxmox Network Config

All nodes use a VLAN-aware bridge (`vmbr0`). pve-identity and pve-r720 use LACP bonding for redundancy and throughput.

### pve-identity (2x 1Gbps LACP — switch ports 2+3)

```
auto bond0
iface bond0 inet manual
    bond-slaves nic0 nic1
    bond-miimon 100
    bond-mode 802.3ad
    bond-xmit-hash-policy layer3+4

auto vmbr0
iface vmbr0 inet static
    address 10.0.10.11/24
    gateway 10.0.10.1
    bridge-ports bond0
    bridge-stp off
    bridge-fd 0
    bridge-vlan-aware yes
    bridge-vids 10 20 30 40
```

### pve-r720 (4x 1Gbps LACP — switch ports 5+6+7+8)

```
auto bond0
iface bond0 inet manual
    bond-slaves nic0 nic1 nic2 nic3
    bond-miimon 100
    bond-mode 802.3ad
    bond-xmit-hash-policy layer3+4

auto vmbr0
iface vmbr0 inet static
    address 10.0.10.12/24
    gateway 10.0.10.1
    bridge-ports bond0
    bridge-stp off
    bridge-fd 0
    bridge-vlan-aware yes
    bridge-vids 10 20 30 40
```

### pve-desktop (single NIC — switch port 10)

```
auto vmbr0
iface vmbr0 inet static
    address 10.0.10.13/24
    gateway 10.0.10.1
    bridge-ports nic0
    bridge-stp off
    bridge-fd 0
    bridge-vlan-aware yes
    bridge-vids 10 20 30 40
```

VMs are tagged to VLANs via Terraform's `vlan_id` parameter on the network device. No per-VLAN bridge needed.

Switch LAG config: Unifi US-24 ports set to "Aggregating" operation for each bond group.

## DNS

> **State (2026-07): client VLANs now use the USG gateway as DNS, not CoreDNS `10.0.20.53`.**
> Done to stop WiFi/internet dying when pve-desktop (k3s control plane) is off. Side effect:
> `home.lab` no longer resolves on those VLANs until a modern gateway takes over local DNS.
> Full context + cutover plan: [unifi/dns-and-gateway-plan.md](unifi/dns-and-gateway-plan.md).

- **Client VLANs (Management, Personal 60, IoT 70, Sandbox 40):** DHCP hands out the USG
  gateway IP for that VLAN (e.g. `10.0.60.1`) as the single DNS server; the USG forwards to
  public DNS. Keeps internet working with every server off. `home.lab` does NOT resolve here.
- **CoreDNS `coredns-external` (`10.0.20.53`, on k3s):** still serves the `home.lab` zone and
  forwards other queries — used by the workstation split-DNS and in-cluster pods
  (`kube-system` `coredns-custom` forwards `home.lab → 10.0.20.53`). No longer handed to client VLANs.
- **Workstation:** split DNS (`~home.lab → 10.0.20.53`, else public) via NetworkManager.
- **AD DNS:** dc-01 (`10.0.10.10`) — AD-joined machines / Entra Connect only.
- **Work/Guest VLANs:** public DNS only (`8.8.8.8`), no local DNS needed.
