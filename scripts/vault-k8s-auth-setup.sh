#!/usr/bin/env bash
# vault-k8s-auth-setup.sh — Configure Vault's Kubernetes auth method + KV engine,
# and onboard apps so their pods pull secrets using only a ServiceAccount JWT.
#
# Vault runtime config (auth methods, policies, roles, secrets) is NOT managed by
# ArgoCD/GitOps — this script is the reproducible source of truth for it. It is
# idempotent and safe to re-run (e.g. after a storage loss + re-init).
#
# Requires: kubectl access to the cluster, `pass homelab/vault/root-token`, and an
# unsealed Vault (`vault-0` in namespace `vault`). All `vault` commands run via
# `kubectl exec` inside the vault-0 pod, so no local vault CLI is needed.
#
# Usage:
#   scripts/vault-k8s-auth-setup.sh bootstrap
#   scripts/vault-k8s-auth-setup.sh add-app <app-name> <namespace> [service-account]
#
# Examples:
#   scripts/vault-k8s-auth-setup.sh bootstrap
#   scripts/vault-k8s-auth-setup.sh add-app linkwarden linkwarden          # SA defaults to app name
#   scripts/vault-k8s-auth-setup.sh add-app grafana monitoring grafana-sa

set -euo pipefail

VAULT_NS="vault"
VAULT_POD="vault-0"

# Run a vault command inside the vault-0 pod (reuses the login token stored below).
vault_exec() { kubectl exec -n "$VAULT_NS" "$VAULT_POD" -- vault "$@"; }
# Same, but pipe stdin (for `policy write -`).
vault_exec_i() { kubectl exec -i -n "$VAULT_NS" "$VAULT_POD" -- vault "$@"; }

login() {
  # Log in once with the root token via stdin; token persists to ~/.vault-token
  # in the container. Keeps the token out of argv and out of stdout.
  printf '%s' "$(pass homelab/vault/root-token)" \
    | kubectl exec -i -n "$VAULT_NS" "$VAULT_POD" -- vault login - >/dev/null
  echo "  authenticated to Vault as root"
}

bootstrap() {
  echo "== Vault Kubernetes auth bootstrap =="
  login

  if vault_exec auth list 2>/dev/null | grep -q '^kubernetes/'; then
    echo "  kubernetes auth: already enabled"
  else
    vault_exec auth enable kubernetes
  fi

  # In-cluster config: Vault uses its own pod's CA cert + SA JWT (disable_local_ca_jwt=false)
  # to call the TokenReview API, so only kubernetes_host is required.
  vault_exec write auth/kubernetes/config \
    kubernetes_host="https://kubernetes.default.svc:443"
  echo "  kubernetes auth: configured (host=https://kubernetes.default.svc:443)"

  if vault_exec secrets list 2>/dev/null | grep -q '^secret/'; then
    echo "  kv-v2 at secret/: already enabled"
  else
    vault_exec secrets enable -path=secret kv-v2
  fi

  echo "Done. Onboard an app with: $0 add-app <app> <namespace> [sa]"
}

add_app() {
  local app="${1:?app name required}"
  local ns="${2:?namespace required}"
  local sa="${3:-$app}"
  local policy="${app}-read"

  echo "== onboarding app '${app}' (ns=${ns}, sa=${sa}) =="
  login

  # Policy: read the app's own KV subtree only. KV v2 data lives under secret/data/<app>/*.
  printf 'path "secret/data/%s/*" {\n  capabilities = ["read"]\n}\n' "$app" \
    | vault_exec_i policy write "$policy" -
  echo "  policy '${policy}' written (read on secret/data/${app}/*)"

  vault_exec write "auth/kubernetes/role/${app}" \
    bound_service_account_names="$sa" \
    bound_service_account_namespaces="$ns" \
    token_policies="$policy" \
    ttl=1h
  echo "  role '${app}' bound to SA '${sa}' in ns '${ns}' -> policy '${policy}'"

  cat <<EOF

Next steps:
  1. Store secrets:   kubectl exec -n ${VAULT_NS} ${VAULT_POD} -- vault kv put secret/${app}/config key=value ...
  2. Ensure ServiceAccount '${sa}' exists in namespace '${ns}'.
  3. From a pod using that SA (VAULT_ADDR=http://vault.vault.svc:8200):
       JWT=\$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
       vault write -field=token auth/kubernetes/login role=${app} jwt="\$JWT"
     ...or use the Vault Agent Injector via pod annotations.
EOF
}

case "${1:-}" in
  bootstrap) bootstrap ;;
  add-app)   shift; add_app "$@" ;;
  *) echo "Usage: $0 {bootstrap | add-app <app> <namespace> [service-account]}" >&2; exit 1 ;;
esac
