# DNS state + pending gateway migration

_Status as of 2026-07. Revisit when the new UniFi gateway is purchased._

## Why this exists

Client VLANs used to be handed `10.0.20.53` (CoreDNS on k3s) as their **primary**
DNS. That VIP depends on the single k3s control plane (`k3s-server-01`), which runs
only on **pve-desktop**. Powering off pve-desktop stranded the DNS VIP and killed all
internet name resolution on WiFi ("wireless internet stops working").

## What was changed (the fix that's live now)

In the UniFi controller, the **DHCP DNS server** for the four client VLANs was
switched from `10.0.20.53, 8.8.8.8` to the **USG gateway IP** for each VLAN (single
entry, no secondary). The USG forwards to public DNS, so WiFi/internet no longer
depends on any server.

| VLAN            | DNS now (single) | Was (rollback value) |
|-----------------|------------------|----------------------|
| Management      | `10.0.10.1`      | `10.0.20.53, 8.8.8.8`|
| Personal (60)   | `10.0.60.1`      | `10.0.20.53, 8.8.8.8`|
| IoT (70)        | `10.0.70.1`      | `10.0.20.53, 8.8.8.8`|
| Sandbox (40)    | `10.0.40.1`      | `10.0.20.53, 8.8.8.8`|

> This change lives in the **UniFi UI only** — it is NOT in this repo (no IaC for the
> Gen1 USG's DHCP). Rollback = set the values back to `10.0.20.53, 8.8.8.8`.

Database/Work/Guest were already public-DNS-only and untouched.

## Open item (the known tradeoff)

`home.lab` names **do not resolve on those four VLANs** anymore — the USG doesn't know
the zone, and a Gen1 USG-4-Pro has no UI for local DNS records. So phones/laptops on
WiFi can't open `grafana.home.lab` etc. Not fixed on purpose; waiting on the gateway.

Still works, unchanged:
- **Workstation** — split DNS (`~home.lab → 10.0.20.53`, else public) via NetworkManager.
- **In-cluster pods** — `kube-system` `coredns-custom` forwards `home.lab → 10.0.20.53`.
- **CoreDNS / `coredns-external` (10.0.20.53)** still serves the zone to anything pointed at it.

## Interim options if `home.lab`-on-WiFi is wanted before the gateway

1. **CoreDNS-pin** — pin `coredns-external` + its MetalLB VIP onto the always-on
   pve-r720 agents (off `k3s-server-01`), then point the four VLANs back at
   `10.0.20.53`. home.lab + internet both work and survive pve-desktop off; internet
   DNS then rides the k3s box again. Fully in-repo (GitOps).
2. **USG `config.gateway.json`** — `server=/home.lab/10.0.20.53` on the Cloud Key
   (`/.../data/sites/default/config.gateway.json`) + Force Provision. Needs UniFi OS
   console SSH (`root@10.0.10.3`). Rejected as too fiddly / legacy.

## End-state: cut LAN DNS over to the new gateway

A modern UniFi gateway (UCG-Fiber / UCG-Ultra/Max / UDM-*) can fully own user-facing
DNS via **Local DNS Records**, letting us **retire `coredns-external` + the
`10.0.20.53` MetalLB VIP** (the SPOF that caused the incident). The k8s-internal
`kube-system/coredns` (cluster.local) stays — not replaceable.

**Buy-time checklist:**

1. **Match the WAN port to the ISP handoff** — UCG-Fiber = SFP+ (fiber); UCG-Ultra/Max
   + UDM = RJ45. If cameras (Protect) ever wanted → UDM-SE/Pro (has storage).
2. **Add Local DNS Records** on the gateway:
   - `*.home.lab → 10.0.20.80` (wildcard; covers all Traefik apps: grafana, jellyfin,
     glance, argocd, linkwarden, chat, n8n, llm, vpn, workout, cache, pgadmin, speedtest…)
   - Specific overrides for non-Traefik hosts: `ollama→10.0.20.30`,
     `postgres→10.0.30.10`, `k3s-server→10.0.20.10`, `k3s-agent-0{1,2,3}→10.0.20.2{1,2,3}`,
     `ollama/desktop→10.0.10.40`, `glance-k8s→10.0.20.61`, plus pve/switch/cloudkey/AP
     host records as desired. Source of truth: `kubernetes/apps/coredns/coredns.yml`.
3. **Repoint everything off `10.0.20.53` → the gateway:**
   - `kube-system` `coredns-custom` ConfigMap: `forward . 10.0.20.53` → `forward . 10.0.20.1`
     (gateway's VLAN-20 interface) so pods still resolve `home.lab`.
   - Workstation NetworkManager split-DNS `~home.lab` → gateway.
   - Sandbox VLAN DHCP DNS (if still `10.0.20.53`) → gateway.
4. **Retire `coredns-external`:** delete `kubernetes/apps/coredns/` Application (frees the
   `10.0.20.53` VIP). Keep `kube-system/coredns`.
5. **Update `docs/network.md`** DNS section to the new reality.

**Tradeoff to accept:** DNS records move from git (`coredns.yml`) to the gateway UI —
not IaC (UniFi TF providers don't cleanly manage local DNS records). The wildcard keeps
upkeep minimal.

## Bonus retirements the new gateway also enables

- **VPN stack** (`kubernetes/manifests/wireguard/*` — wg-easy, hostNetwork, privileged
  init, USG port-forward, PVC) → native gateway WireGuard/Teleport.
- **DuckDNS cronjob** → gateway built-in Dynamic DNS.
- **Cloud Key Plus** → gateway runs the Network app itself (optional; requires device re-adoption).
- **IDS/IPS at line rate**, Zone-Based Firewall for the 8 VLANs, multi-gig routing.
