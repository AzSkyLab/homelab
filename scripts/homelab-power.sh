#!/usr/bin/env bash
# homelab-power.sh — Graceful shutdown / startup of the entire homelab.
#
# Runs from the workstation (10.0.10.40) over SSH to the Proxmox hosts.
# All guest VMs are stopped/started via `qm` on their host, in dependency
# order. Uses the QEMU guest agent for graceful shutdown and boot readiness.
#
# Usage:
#   bash scripts/homelab-power.sh down     # stop all VMs, then power off hosts
#   bash scripts/homelab-power.sh up        # start VMs in order (hosts must be ON)
#   bash scripts/homelab-power.sh status    # show qm list on every host
#
# Options:
#   --with-ad     also shut down / start the AD domain controllers (dc-01/02/03)
#   --no-hosts    (down only) stop VMs but leave the Proxmox hosts running
#
# NOTE: `up` cannot power on a Proxmox host that is fully off. Either press the
# power button, or set the WOL MACs below and the script will send magic packets.

set -euo pipefail

# --- Proxmox hosts (management IPs) ---
PVE_IDENTITY="10.0.10.11"   # AD/DNS + NFS media
PVE_R720="10.0.10.12"       # k3s workers, postgres, sandbox
PVE_DESKTOP="10.0.10.13"    # k3s control plane, ollama (GPU)

HOSTS=("$PVE_R720" "$PVE_DESKTOP" "$PVE_IDENTITY")

# Wake-on-LAN MACs (optional). Fill in to let `up` power hosts on remotely.
declare -A WOL_MAC=(
  # ["$PVE_IDENTITY"]="aa:bb:cc:dd:ee:11"
  # ["$PVE_R720"]="aa:bb:cc:dd:ee:12"
  # ["$PVE_DESKTOP"]="aa:bb:cc:dd:ee:13"
)

SSH="ssh -o ConnectTimeout=10 -o BatchMode=yes"
SHUTDOWN_TIMEOUT=180   # seconds qm waits for a guest to stop gracefully
BOOT_TIMEOUT=180       # seconds to wait for the guest agent after start

WITH_AD=false
NO_HOSTS=false

# --- VM inventory: "host_ip vmid name" ---------------------------------------
# Shutdown phases run top-to-bottom; VMs within a phase stop in parallel and
# the phase blocks until all are stopped. Startup runs the reverse dependency
# order (data -> control plane -> workers -> inference).

# Phase 1 (shutdown first / start last): app workers + inference
WORKERS=(
  "$PVE_R720 210 k3s-agent-01"
  "$PVE_R720 211 k3s-agent-02"
  "$PVE_R720 212 k3s-agent-03"
  "$PVE_DESKTOP 500 ollama-01"
)
# Phase 2: k3s control plane
CONTROL=(
  "$PVE_DESKTOP 200 k3s-server-01"
)
# Phase 3: database
DATA=(
  "$PVE_R720 300 postgres-01"
)
# Optional: AD domain controllers
AD=(
  "$PVE_IDENTITY 100 dc-01"
  "$PVE_IDENTITY 101 dc-02"
  "$PVE_IDENTITY 102 dc-03"
)

log()  { printf '\033[1;34m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
warn() { printf '\033[1;33m[%s] WARN:\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
die()  { printf '\033[1;31m[%s] ERROR:\033[0m %s\n' "$(date +%H:%M:%S)" "$*" >&2; exit 1; }

# --- helpers -----------------------------------------------------------------

vm_status() {  # host_ip vmid -> prints "running"/"stopped"
  $SSH "root@$1" "qm status $2" 2>/dev/null | awk '{print $2}'
}

# Stop a group of VMs in parallel, block until all report stopped.
shutdown_group() {
  local -n group=$1
  local label=$2
  [[ ${#group[@]} -eq 0 ]] && return 0
  log "Shutting down: $label"
  local pids=()
  for entry in "${group[@]}"; do
    read -r host id name <<<"$entry"
    if [[ "$(vm_status "$host" "$id")" != "running" ]]; then
      log "  $name ($id) already stopped"
      continue
    fi
    log "  -> $name ($id) on $host"
    $SSH "root@$host" "qm shutdown $id -timeout $SHUTDOWN_TIMEOUT" &
    pids+=($!)
  done
  local rc=0
  for p in "${pids[@]}"; do wait "$p" || rc=1; done
  if [[ $rc -ne 0 ]]; then
    warn "A guest did not stop gracefully within ${SHUTDOWN_TIMEOUT}s; check with 'status'."
  fi
  # verify
  for entry in "${group[@]}"; do
    read -r host id name <<<"$entry"
    [[ "$(vm_status "$host" "$id")" == "running" ]] && warn "  $name ($id) STILL running"
  done
}

# Start a group and wait for each guest agent to answer (OS booted).
start_group() {
  local -n group=$1
  local label=$2
  [[ ${#group[@]} -eq 0 ]] && return 0
  log "Starting: $label"
  for entry in "${group[@]}"; do
    read -r host id name <<<"$entry"
    if [[ "$(vm_status "$host" "$id")" == "running" ]]; then
      log "  $name ($id) already running"
      continue
    fi
    log "  -> $name ($id) on $host"
    $SSH "root@$host" "qm start $id" || warn "  failed to start $name ($id)"
  done
  # wait for guest agents
  for entry in "${group[@]}"; do
    read -r host id name <<<"$entry"
    local waited=0
    while ! $SSH "root@$host" "qm agent $id ping" >/dev/null 2>&1; do
      sleep 5; waited=$((waited+5))
      if [[ $waited -ge $BOOT_TIMEOUT ]]; then
        warn "  $name ($id) guest agent not responding after ${BOOT_TIMEOUT}s"
        break
      fi
    done
    [[ $waited -lt $BOOT_TIMEOUT ]] && log "  $name ($id) up (agent responded in ${waited}s)"
  done
}

host_up()  { ping -c1 -W2 "$1" >/dev/null 2>&1; }

# --- subcommands -------------------------------------------------------------

do_status() {
  for h in "${HOSTS[@]}"; do
    echo "=== $h ==="
    if host_up "$h"; then
      $SSH "root@$h" "hostname; qm list" 2>&1 || warn "  qm list failed on $h"
    else
      warn "  $h is DOWN / unreachable"
    fi
    echo
  done
}

do_down() {
  log "Preflight: checking host reachability"
  for h in "${HOSTS[@]}"; do
    host_up "$h" || warn "$h unreachable — its VMs will be skipped"
  done

  shutdown_group WORKERS "k3s agents + ollama"
  shutdown_group CONTROL "k3s control plane"
  shutdown_group DATA    "postgres"
  if $WITH_AD; then shutdown_group AD "AD domain controllers"; fi

  if $NO_HOSTS; then
    log "VMs stopped. Leaving Proxmox hosts running (--no-hosts)."
    return 0
  fi

  log "Powering off Proxmox hosts"
  for h in "${HOSTS[@]}"; do
    host_up "$h" || continue
    log "  -> poweroff $h"
    $SSH "root@$h" "shutdown -h now" 2>/dev/null || true
  done

  log "Waiting for hosts to drop off the network"
  for h in "${HOSTS[@]}"; do
    local waited=0
    while host_up "$h"; do
      sleep 8; waited=$((waited+8))
      [[ $waited -ge 240 ]] && { warn "$h still up after 240s"; break; }
    done
    host_up "$h" || log "  $h is down"
  done
  log "All servers down. Safe to unplug."
}

wake_hosts() {
  local down=()
  for h in "${HOSTS[@]}"; do host_up "$h" || down+=("$h"); done
  [[ ${#down[@]} -eq 0 ]] && return 0
  local waker=""
  command -v wakeonlan >/dev/null 2>&1 && waker="wakeonlan"
  command -v etherwake  >/dev/null 2>&1 && waker="${waker:-etherwake}"
  for h in "${down[@]}"; do
    local mac="${WOL_MAC[$h]:-}"
    if [[ -n "$mac" && -n "$waker" ]]; then
      log "WOL magic packet -> $h ($mac)"
      $waker "$mac" >/dev/null 2>&1 || warn "  WOL send failed for $h"
    else
      warn "Host $h is OFF — power it on manually (no WOL MAC/tool configured)"
    fi
  done
  log "Waiting for Proxmox hosts to come online"
  for h in "${down[@]}"; do
    local waited=0
    while ! host_up "$h"; do
      sleep 5; waited=$((waited+5))
      [[ $waited -ge 300 ]] && die "$h did not come online within 300s — power it on and retry"
    done
    # give pvedaemon a moment
    until $SSH "root@$h" "true" 2>/dev/null; do sleep 3; done
    log "  $h online"
  done
}

do_up() {
  wake_hosts
  start_group DATA    "postgres"
  start_group CONTROL "k3s control plane"
  start_group WORKERS "k3s agents + ollama"
  if $WITH_AD; then start_group AD "AD domain controllers"; fi
  log "Startup complete. Verify: bash scripts/homelab-power.sh status"
  log "Then check ArgoCD: kubectl get applications -n argocd"
}

# --- arg parsing -------------------------------------------------------------
CMD="${1:-}"; shift || true
for arg in "$@"; do
  case "$arg" in
    --with-ad)  WITH_AD=true ;;
    --no-hosts) NO_HOSTS=true ;;
    *) die "unknown option: $arg" ;;
  esac
done

case "$CMD" in
  down)   do_down ;;
  up)     do_up ;;
  status) do_status ;;
  *) die "Usage: $0 {down|up|status} [--with-ad] [--no-hosts]" ;;
esac
