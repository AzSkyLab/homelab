# Unifi USG 4 Pro + AP VLAN/SSID Configuration

Step-by-step guide for configuring VLANs on the USG 4 Pro and mapping SSIDs to VLANs on Unifi APs.

## Prerequisites

- Unifi Controller running on Cloud Key Plus (10.0.10.3)
- USG 4 Pro adopted into controller (10.0.10.1)
- UAP-AC-Pro adopted into controller (10.0.10.5)
- U7 Pro adopted into controller (10.0.10.4)
- US-24-250W Switch adopted into controller (10.0.10.2)

## Step 1: Create Networks (VLANs)

In Unifi Controller: **Settings → Networks**

Create each network:

### Management (Default — renamed)
- **This is the existing Default network, renamed.** Do not create a new network.
- Name: `Management`
- Gateway/Subnet: `10.0.10.1/24`
- DHCP Range: `10.0.10.100 - 10.0.10.200`
- DHCP DNS: `1.1.1.1, 8.8.8.8`
- DHCP Lease Time: `86400` (24 hours — default)
- Domain Name: `home.lab`
- IGMP Snooping: Off
- Multicast DNS: On
- Network Isolation: Off
- Note: No VLAN ID — this is the native/untagged network

### Kubernetes (VLAN 20)
- Name: `Kubernetes`
- Purpose: Corporate
- VLAN ID: `20`
- Gateway/Subnet: `10.0.20.1/24`
- DHCP: Disabled (static IPs via Terraform)
- IGMP Snooping: Off
- Multicast DNS: Off
- Network Isolation: Off

### Database (VLAN 30)
- Name: `Database`
- Purpose: Corporate
- VLAN ID: `30`
- Gateway/Subnet: `10.0.30.1/24`
- DHCP: Disabled (static IPs via Terraform)
- IGMP Snooping: Off
- Multicast DNS: Off
- Network Isolation: Off

### Sandbox (VLAN 40)
- Name: `Sandbox`
- Purpose: Corporate
- VLAN ID: `40`
- Gateway/Subnet: `10.0.40.1/24`
- DHCP Range: `10.0.40.100 - 10.0.40.200`
- DHCP DNS: `10.0.20.53, 1.1.1.1`
- DHCP Lease Time: `86400` (24 hours — default)
- Domain Name: `home.lab`
- IGMP Snooping: Off
- Multicast DNS: Off
- Network Isolation: Off

### Work (VLAN 50)
- Name: `Work`
- Purpose: Corporate
- VLAN ID: `50`
- Gateway/Subnet: `10.0.50.1/24`
- DHCP Range: `10.0.50.100 - 10.0.50.200`
- DHCP DNS: `1.1.1.1, 8.8.8.8`
- DHCP Lease Time: `28800` (8 hours)
- Domain Name: *(leave blank)*
- IGMP Snooping: Off
- Multicast DNS: Off
- Network Isolation: Off

### Personal (VLAN 60)
- Name: `Personal`
- Purpose: Corporate
- VLAN ID: `60`
- Gateway/Subnet: `10.0.60.1/24`
- DHCP Range: `10.0.60.100 - 10.0.60.200`
- DHCP DNS: `10.0.20.53, 1.1.1.1`
- DHCP Lease Time: `28800` (8 hours)
- Domain Name: *(leave blank)*
- IGMP Snooping: **On** (TV and PS5 streaming)
- Multicast DNS: **On** (phones discover TV, speakers)
- Network Isolation: Off

### IoT (VLAN 70)
- Name: `IoT`
- Purpose: Corporate
- VLAN ID: `70`
- Gateway/Subnet: `10.0.70.1/24`
- DHCP Range: `10.0.70.100 - 10.0.70.200`
- DHCP DNS: `10.0.20.53, 1.1.1.1`
- DHCP Lease Time: `28800` (8 hours)
- Domain Name: *(leave blank)*
- IGMP Snooping: **On** (smart device multicast)
- Multicast DNS: **On** (smart devices need to be discoverable)
- Network Isolation: Off

### Guest (VLAN 80)
- Name: `Guest`
- Purpose: Guest
- VLAN ID: `80`
- Gateway/Subnet: `10.0.80.1/24`
- DHCP Range: `10.0.80.100 - 10.0.80.200`
- DHCP DNS: `1.1.1.1, 8.8.8.8`
- DHCP Lease Time: `28800` (8 hours)
- Domain Name: *(leave blank)*
- IGMP Snooping: Off
- Multicast DNS: Off
- Network Isolation: **On** (guests can't see each other)

**Optional Guest extras** (configured outside of network creation):
- Content Filtering: **Settings → CyberSecure → Content Filtering** — select the Guest network
- Captive Portal / Hotspot: **Settings → Hotspot** — enable and assign to the Guest network's WiFi SSID

### Settings Reference

All settings (IGMP, mDNS, isolation, lease times, domain names) are listed inline per network above.

**Key callouts:**
- IGMP Snooping is only needed on Personal (60) and IoT (70) for streaming/multicast
- mDNS is enabled on Management, Personal, and IoT only (3 of 8 — well within USG's 5-network mDNS limit)
- Network Isolation is only enabled on Guest (80) to prevent guests from seeing each other
- Homelab VLANs with DHCP enabled (Management, Sandbox) use `home.lab` as the DHCP domain name
- WiFi-heavy VLANs (Work, Personal, IoT, Guest) use 8-hour DHCP leases; server VLANs use 24-hour default

## Step 2: Configure WiFi SSIDs

In Unifi Controller: **Settings → WiFi**

### SSID: MallieFi-Work
- Name: `MallieFi-Work`
- Security: WPA3
- Network: `Work` (VLAN 50)
- Band: 2.4 GHz + 5 GHz
- Notes: Work devices only

### SSID: MallieFi
- Name: `MallieFi`
- Security: WPA3
- Network: `Personal` (VLAN 60)
- Band: 2.4 GHz + 5 GHz
- Notes: Personal wireless devices

### SSID: MallieFi-IoT
- Name: `MallieFi-IoT`
- Security: WPA2 (some IoT devices don't support WPA3)
- Network: `IoT` (VLAN 70)
- Band: 2.4 GHz + 5 GHz
- Notes: Smart devices

### SSID: MallieFi-Guest
- Name: `MallieFi-Guest`
- Security: WPA2
- Network: `Guest` (VLAN 80)
- Band: 2.4 GHz + 5 GHz
- Guest policies: Client isolation enabled
- Notes: Internet-only access

## Step 3: Configure Unifi US-24 Switch Ports

In Unifi Controller: **Devices → US-24 → Ports → (click port)**

Each port has:
- **Native VLAN / Network** — dropdown to select the untagged network on the port
- **Tagged VLAN Management** — radio buttons: `Allow All`, `Block All`, or `Custom`

For **Proxmox nodes and APs**: Native VLAN = `Management`, Tagged VLAN Management = `Allow All`
For **end devices**: Native VLAN = their network, Tagged VLAN Management = `Block All`

### Port Map

| Port | Native VLAN / Network | Tagged VLAN Management | Device |
|------|----------------------|----------------------|--------|
| 1 | `Management` | `Allow All` | USG 4 Pro LAN1 (uplink) — **do not change native VLAN** |
| 2 | `Management` | `Allow All` | pve-identity — LAN 1 (LAG) |
| 3 | `Management` | `Allow All` | pve-identity — LAN 2 (LAG) |
| 4 | `Management` | `Block All` | pve-identity — IPMI (10.0.10.14) |
| 5 | `Management` | `Allow All` | pve-r720 — LAN 1 (LAG) |
| 6 | `Management` | `Allow All` | pve-r720 — LAN 2 (LAG) |
| 7 | `Management` | `Allow All` | pve-r720 — LAN 3 (LAG) |
| 8 | `Management` | `Allow All` | pve-r720 — LAN 4 (LAG) |
| 9 | `Management` | `Block All` | pve-r720 — iDRAC (10.0.10.15) |
| 10 | `Management` | `Allow All` | pve-desktop — LAN |
| 11 | `Management` | `Block All` | neuromancer (workstation) |
| 12 | `Management` | `Block All` | Cloud Key Gen 2 (PoE) |
| 13 | `Management` | `Allow All` | Unifi AP #1 (PoE) |
| 14 | `Management` | `Allow All` | Unifi AP #2 (PoE) |
| 15 | `Personal` | `Block All` | Room connection #1 |
| 16 | `Personal` | `Block All` | Room connection #2 |
| 17 | `Personal` | `Block All` | Room connection #3 |
| 18 | `Personal` | `Block All` | TV |
| 19 | `Personal` | `Block All` | PlayStation 5 |
| 20-24 | `Management` | `Block All` | Available |

**Notes:**
- IPMI (port 4) and iDRAC (port 9) use the `Management` profile for out-of-band access on VLAN 10
- pve-identity: Ports 2+3 configured as LAG (LACP 802.3ad) — Operation: Aggregating
- pve-r720: Ports 5+6+7+8 configured as LAG (LACP 802.3ad) — Operation: Aggregating
- pve-desktop uses 1 LAN port (second port available as spare)

## Step 4: Configure Firewall Rules

### Step 4b: Create Firewall Rules

In Unifi Controller: **Settings → Firewall & Security → Firewall Rules → Create New Rule**

**Rules are evaluated top to bottom. Create them in this exact order.**

Source Type options and their fields:
- **Network** — shows: Network (dropdown), Network Type (`IPv4 Subnet`), MAC Address (optional)
- **IP Address** — shows: IP address input
- **List** — shows: Address Group (dropdown with `Any` + `New`), Port List (dropdown with `Any` + `New`)

---

**Rule 1a: Allow Homelab VLANs → CoreDNS (UDP)**

| Field | Value |
|-------|-------|
| Type | `LAN In` |
| Name | `Allow Homelab to CoreDNS UDP` |
| Action | `Accept` |
| Protocol | `UDP` |
| **Source** | |
| Source Type | `List` |
| Address Group | `Any` |
| Port List | `Any` |
| **Destination** | |
| Destination Type | `IP Address` |
| IP Address | `10.0.20.53` |
| Port | `53` |
| Advanced | `Auto` |

**Rule 1b: Allow Homelab VLANs → CoreDNS (TCP)**

| Field | Value |
|-------|-------|
| Type | `LAN In` |
| Name | `Allow Homelab to CoreDNS TCP` |
| Action | `Accept` |
| Protocol | `TCP` |
| **Source** | |
| Source Type | `List` |
| Address Group | `Any` |
| Port List | `Any` |
| **Destination** | |
| Destination Type | `IP Address` |
| IP Address | `10.0.20.53` |
| Port | `53` |
| Advanced | `Auto` |

*Most DNS is UDP, but TCP is needed for large responses. Work (50) is blocked by its deny rule (#7) before it can hit these allows — Work uses public DNS only.*

---

**Rule 2: Allow Management → All**

| Field | Value |
|-------|-------|
| Type | `LAN In` |
| Name | `Allow Management to All` |
| Action | `Accept` |
| Protocol | `All` |
| **Source** | |
| Source Type | `Network` |
| Network | `Management` |
| Network Type | `IPv4 Subnet` |
| **Destination** | |
| Destination Type | `List` |
| Address Group | `Any` |
| Port List | `Any` |
| Advanced | `Auto` |

---

**Rule 3: Allow Kubernetes → Database**

| Field | Value |
|-------|-------|
| Type | `LAN In` |
| Name | `Allow Kubernetes to Database` |
| Action | `Accept` |
| Protocol | `All` |
| **Source** | |
| Source Type | `Network` |
| Network | `Kubernetes` |
| Network Type | `IPv4 Subnet` |
| **Destination** | |
| Destination Type | `Network` |
| Network | `Database` |
| Network Type | `IPv4 Subnet` |
| Advanced | `Auto` |

---

**Rule 4: Allow Personal → IoT**

| Field | Value |
|-------|-------|
| Type | `LAN In` |
| Name | `Allow Personal to IoT` |
| Action | `Accept` |
| Protocol | `All` |
| **Source** | |
| Source Type | `Network` |
| Network | `Personal` |
| Network Type | `IPv4 Subnet` |
| **Destination** | |
| Destination Type | `Network` |
| Network | `IoT` |
| Network Type | `IPv4 Subnet` |
| Advanced | `Auto` |

---

**Rule 5: Block Database → All inter-VLAN**

| Field | Value |
|-------|-------|
| Type | `LAN In` |
| Name | `Block Database inter-VLAN` |
| Action | `Drop` |
| Protocol | `All` |
| **Source** | |
| Source Type | `Network` |
| Network | `Database` |
| Network Type | `IPv4 Subnet` |
| **Destination** | |
| Destination Type | `List` |
| Address Group | click **New** → Name: `RFC1918` → Type: `IPv4 Address/Subnet` → add `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16` |
| Port List | `Any` |
| Advanced | `Auto` |

---

**Rule 6: Block Sandbox → Management**

| Field | Value |
|-------|-------|
| Type | `LAN In` |
| Name | `Block Sandbox to Management` |
| Action | `Drop` |
| Protocol | `All` |
| **Source** | |
| Source Type | `Network` |
| Network | `Sandbox` |
| Network Type | `IPv4 Subnet` |
| **Destination** | |
| Destination Type | `Network` |
| Network | `Management` |
| Network Type | `IPv4 Subnet` |
| Advanced | `Auto` |

---

**Rule 7: Block Work → All inter-VLAN**

| Field | Value |
|-------|-------|
| Type | `LAN In` |
| Name | `Block Work inter-VLAN` |
| Action | `Drop` |
| Protocol | `All` |
| **Source** | |
| Source Type | `Network` |
| Network | `Work` |
| Network Type | `IPv4 Subnet` |
| **Destination** | |
| Destination Type | `List` |
| Address Group | `RFC1918` |
| Port List | `Any` |
| Advanced | `Auto` |

---

**Rule 8: Block IoT → All inter-VLAN**

| Field | Value |
|-------|-------|
| Type | `LAN In` |
| Name | `Block IoT inter-VLAN` |
| Action | `Drop` |
| Protocol | `All` |
| **Source** | |
| Source Type | `Network` |
| Network | `IoT` |
| Network Type | `IPv4 Subnet` |
| **Destination** | |
| Destination Type | `List` |
| Address Group | `RFC1918` |
| Port List | `Any` |
| Advanced | `Auto` |

---

**Rule 9: Block Guest → All inter-VLAN**

| Field | Value |
|-------|-------|
| Type | `LAN In` |
| Name | `Block Guest inter-VLAN` |
| Action | `Drop` |
| Protocol | `All` |
| **Source** | |
| Source Type | `Network` |
| Network | `Guest` |
| Network Type | `IPv4 Subnet` |
| **Destination** | |
| Destination Type | `List` |
| Address Group | `RFC1918` |
| Port List | `Any` |
| Advanced | `Auto` |

## Step 5: Verification

After configuration, verify from devices on each VLAN:

```bash
# From Management (10) — should reach everything
ping 10.0.20.10   # k3s server
ping 10.0.30.10   # postgres

# From Kubernetes (20) — should reach DB, not management
ping 10.0.30.10   # Should succeed (DB)
ping 10.0.10.11   # Should fail (management, unless rule allows)

# From Database (30) — should not initiate to other VLANs
ping 10.0.20.10   # Should fail (k8s)

# From IoT (70) — should only reach internet
ping 8.8.8.8      # Should succeed (internet)
ping 10.0.10.11   # Should fail (management)

# From Guest (80) — internet only
ping 8.8.8.8      # Should succeed
ping 10.0.10.1    # Should fail
```

### DNS Verification (after k3s + CoreDNS are deployed)

```bash
# From any VLAN — local DNS resolution via CoreDNS
dig @10.0.20.53 postgres.home.lab    # Should resolve to 10.0.30.10
dig @10.0.20.53 google.com                # Should resolve (forwarded to 1.1.1.1)

# Fallback — if CoreDNS is down, 1.1.1.1 still works
dig @1.1.1.1 google.com                   # Should resolve
```
