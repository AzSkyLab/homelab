#!/usr/bin/env bash
# lab-status.sh — Read-only snapshot of the whole lab in one run (the first step of an update sweep).
# Changes nothing. Hosts are checked in parallel; an unreachable host shows as UNREACHABLE.
#
# Usage: bash scripts/lab-status.sh          (from the repo root or anywhere)

set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
export KUBECONFIG="${KUBECONFIG:-$REPO/ansible/kubeconfig}"
SSHO=(-o ConnectTimeout=5 -o BatchMode=yes)
PVE_HOSTS=(10.0.10.11 10.0.10.12 10.0.10.13)
VMS=(10.0.20.10 10.0.20.21 10.0.20.22 10.0.20.23 10.0.30.10 10.0.20.30)
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

# --- fan out the slow remote checks first ---
for h in "${PVE_HOSTS[@]}"; do
  ssh "${SSHO[@]}" root@"$h" '
    echo "$(hostname) pve=$(pveversion | cut -d/ -f2) running=$(uname -r)"
    newest=$(ls -1 /boot/vmlinuz-* 2>/dev/null | sed "s#/boot/vmlinuz-##" | sort -V | tail -1)
    [ "$newest" != "$(uname -r)" ] && echo "  REBOOT NEEDED: newest kernel $newest"
    apt-get -qq update >/dev/null 2>&1
    n=$(apt-get -s dist-upgrade 2>/dev/null | grep -c "^Inst ")
    echo "  upgradable=$n"
  ' >"$OUT/pve-$h" 2>&1 || echo "$h UNREACHABLE" >"$OUT/pve-$h" &
done
for h in "${VMS[@]}"; do
  ssh "${SSHO[@]}" ubuntu@"$h" '
    echo "$(hostname) running=$(uname -r) upgradable=$(apt list --upgradable 2>/dev/null | grep -c upgradable) disk=$(df -h / | awk "NR==2{print \$5}")"
    [ -f /var/run/reboot-required ] && echo "  REBOOT NEEDED"
    command -v ollama >/dev/null && echo "  ollama $(ollama -v 2>/dev/null | grep -o "[0-9.]*$")"
    command -v nvidia-smi >/dev/null && echo "  gpu $(nvidia-smi --query-gpu=name,driver_version,memory.used,memory.total --format=csv,noheader)"
    true
  ' >"$OUT/vm-$h" 2>&1 || echo "$h UNREACHABLE" >"$OUT/vm-$h" &
done

# --- local, fast checks while those run ---
say "git ($REPO)"
git -C "$REPO" fetch -q 2>/dev/null
git -C "$REPO" status -sb | head -20

say "workstation"
echo "$(hostname) running=$(uname -r) ollama=$(ollama -v 2>/dev/null | grep -o '[0-9.]*$')"
command -v checkupdates >/dev/null && echo "  pacman upgradable=$(checkupdates 2>/dev/null | wc -l)"
systemctl --failed --no-legend | sed 's/^/  FAILED UNIT: /'

say "k3s nodes"
kubectl get nodes -o custom-columns='NAME:.metadata.name,STATUS:.status.conditions[?(@.type=="Ready")].status,VERSION:.status.nodeInfo.kubeletVersion,KERNEL:.status.nodeInfo.kernelVersion'

say "ArgoCD applications not Synced+Healthy"
kubectl get applications -n argocd --no-headers \
  -o custom-columns='N:.metadata.name,S:.status.sync.status,H:.status.health.status' \
  | awk '$2!="Synced"||$3!="Healthy"{print; bad=1} END{if(!bad) print "all green (" NR " apps)"}'

say "problem pods"
kubectl get pods -A --no-headers | awk '$4!="Running"&&$4!="Completed"{print; bad=1} END{if(!bad) print "none"}'

say "k3s upgrade plans"
kubectl get plans.upgrade.cattle.io -n system-upgrade --no-headers 2>/dev/null \
  -o custom-columns='PLAN:.metadata.name,VERSION:.spec.version,LATEST:.status.latestVersion' || echo "no system-upgrade-controller"

say "Proxmox hosts"
wait
cat "$OUT"/pve-*
say "VMs"
cat "$OUT"/vm-*
